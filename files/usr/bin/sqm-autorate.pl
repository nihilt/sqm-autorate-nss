#!/usr/bin/env perl
use strict;
use warnings;
use POSIX qw(strftime);
use IO::Handle;
use Fcntl ':flock';
use IPC::Open3;
use Symbol 'gensym';
eval { require File::Which; import File::Which 'which'; };
# Sub-second clock (needs perlbase-time on OpenWrt); falls back to whole seconds.
# Intervals use the monotonic clock when available: a router without RTC steps its wall clock
# (often by years) when NTP syncs, which must not look like years of idle time or a stuck hold-down.
my $HAVE_HIRES = eval { require Time::HiRes; 1 } ? 1 : 0;
my $HAVE_MONO  = ($HAVE_HIRES && eval { Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()); 1 }) ? 1 : 0;
sub now {
    return Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()) if $HAVE_MONO;
    return $HAVE_HIRES ? Time::HiRes::time() : time();
}

# ------------- Paths and files -------------
my $CONFIG_FILE   = $ENV{"CONFIG"} // "/var/sqm-autorate.conf";
my $PIDFILE       = $ENV{"PIDFILE"} // "/var/run/sqm-autorate.pid";
my $LOGFILE       = $ENV{"LOGFILE"} // "/var/log/sqm-autorate.log";
my $TC            = $ENV{"TC"}      // "/sbin/tc";

# ------------- Runtime toggles -------------
my $log_enabled   = 1;
my $log_level     = 1;
my $log_format    = "compact";
# 0 = silent, 1 = event-driven, 2 = tick-driven
my $log_mode = 1;
my $log_change_threshold_percent = 2;   # event-driven threshold (can be 0)

# Track last logged values for event-driven mode
my $last_up     = 0;
my $last_down   = 0;
my $last_floorU = 0;
my $last_floorD = 0;

# ------------- Interfaces and pinger -------------
my $upload_if        = "";
my $download_if      = "";               # fixed to "nssifb" in load_config
my $pinger_method    = "automatic";
my $resolved_pinger  = "";               # resolved binary choice
my $probe_setuid_fix = 0;                # allow setuid adjustment if needed

my @reflectors    = ();
my $reflector_count    = 3;
my $reflector_rotation = "roundrobin";
my $reflector_index    = 0;

# ------------- Base bandwidths (kbit/s) -------------
my $upload_base_kbits   = 10000;
my $download_base_kbits = 50000;

# ------------- Floors (% of base) -------------
my $upload_min_percent   = 50;
my $download_min_percent = 55;

# ------------- Latency thresholds (ms) -------------
my $latency_low_up_ms     = 10;
my $latency_high_up_ms    = 15;
my $latency_low_down_ms   = 12;
my $latency_high_down_ms  = 20;

# ------------- Probing -------------
my $probe_ms        = 250;
my $probe_fast_ms   = 150;
my $elastic_probe   = 1;
my $variance_thresh_ms = 3;
my $probe_min_ms    = 100;              # lower bound for elastic probing
my $probe_timeout_ms = 100;             # fping -t: a reply slower than this counts as "no reply"
my $probe_blackout_s = 3;               # no probe answered for this long while a direction is loaded: a missing reply then counts as a
                                        # reading of probe_timeout_ms and the normal decrease logic runs (shorter gaps hold; 0 = always hold)

# ------------- Latency smoothing -------------
my $latency_filter      = "median";     # "median" or "ewma"
my $latency_window_size = 4;
my $alpha_ewma          = 0.4;

# ------------- Rate adjustment percentages -------------
my $increase_rate_percent_up    = 15;
my $decrease_rate_percent_up    = 6;
my $increase_rate_percent_down  = 10;
my $decrease_rate_percent_down  = 6;

# ------------- Adaptive floor (with decay) -------------
my $adaptive_floor                 = 1;
my $adaptive_floor_step            = 3;
my $adaptive_floor_min             = 60;
my $adaptive_floor_max             = 90;
my $adaptive_floor_trigger_ms      = 15;
my $adaptive_floor_trigger_count   = 7;
my $adaptive_floor_decay_interval  = 60;
my $adaptive_floor_decay_step      = 8;

# ------------- Load-aware bias -------------
my $load_aware                 = 1;
my $load_bias_decrease         = 2;
my $load_bias_threshold_percent = 40;   # a direction is "loaded" when measured >= X% of its current shaper rate
my $decrease_min_load_percent  = 20;    # latency-triggered decrease / floor raise only if that direction carries >= X% of its rate
my $apply_min_change_percent   = 1;     # only touch tc when a rate moved >= X% since the last apply

# ------------- Ramp control (hold-down + slow ramp) -------------
my $hold_after_decrease_ms  = 600;      # after a decrease: no increases for this long, so the queue can drain (0 = off)
my $slow_increase_percent   = 2.0;      # increase step used near the rate where bufferbloat last started
my $ramp_fast_until_percent = 90;       # use the normal (fast) increase step only below X% of that rate
my $trouble_memory_s        = 30;       # forget that rate after this long without bufferbloat (0 = slow ramp off)

# ------------- ISP cap detection (robust) -------------
my $cap_trigger_cycles    = 12;
my $cap_threshold_percent = 95;         # shaper rate (% of base) that counts as "at the cap"
my $cap_load_percent      = 90;         # ...and that direction must also carry >= X% of its shaper rate

# ------------- Internal state -------------
my $running            = 1;
my $reload_requested   = 0;
my $cycle              = 0;
my ($applied_up, $applied_down);        # last rates actually pushed to tc
my $last_counter_src   = "";
my @recent_raw         = ();
my ($upload_floor_base, $download_floor_base) = (60, 60);

my $ewma_up;
my $ewma_down;
my @lat_window_up   = ();
my @lat_window_down = ();

my $upload_min   = $upload_min_percent;
my $download_min = $download_min_percent;

my $trigger_hits_up   = 0;
my $trigger_hits_down = 0;
my $last_decay_cycle  = 0;

# Calm-window guard state
my $calm_window_cycles = 5;   # default calm period in cycles
my $calm_window_active = $calm_window_cycles;

sub calm_window_guard {
    if ($calm_window_active > 0) {
        $calm_window_active--;
        log_line("Calm-window active: skipping rate changes for $calm_window_active more cycles", 2);
        return 1; # guard is active, skip adjustments
    }
    return 0; # guard expired, allow adjustments
}

# Bytes the counters moved during the last poll (informational; rates come from %rs below)
my $bytes_interval_up    = 0;
my $bytes_interval_down  = 0;

# Which qdisc stats to parse (nsstbl or nssfq_codel) - NSS only
my $qdisc_stats = "nsstbl";

# --- Throughput smoothing ---
# Choose between "average" or "ewma"
my $rate_filter = "average";   # default, can be overridden in config
my $smooth_size = 3;           # window size for average mode (>=1)
my $alpha_rate  = 0.4;         # EWMA weight (0.0–1.0)

# NSS publishes qdisc statistics to the host in steps (about once per second), so a counter that
# did not move between two polls means "no update yet", not "no traffic". Dividing a stepped
# counter by the poll interval makes the rate swing between ~0 and several times the real value.
# Instead every counter update becomes the average rate of one sync period, that rate is held
# until the next update, and a direction only counts as idle once whole sync periods pass without
# any bytes. The smoothing above is applied per update. counter_sync_s=0: plain per-poll rates.
my $counter_sync_s = 1.0;

# Per-direction estimator state: counter source/baseline, time of the last counter update,
# zero samples already fed since then, and the smoothed rate (kbit/s)
sub _new_rate_state { return { src => "", prev => 0, ev_ts => 0, zero_fed => 0, est => undef, win => [] }; }
my %rs = (up => _new_rate_state(), down => _new_rate_state());

# Measured rates in kbit/s (set in update_intervals)
our $measured_up_kbps   = 0;
our $measured_down_kbps = 0;
my $last_ts = now();

# --- Qdisc options ---
my $EQDISC_OPTS = "";
my $IQDISC_OPTS = "";
# optional root burst overrides (bytes)
my $ROOT_BURST_UP   = 1518;
my $ROOT_BURST_DOWN = 1518;
# ------------- Logging helpers -------------

sub log_open {
    return unless $log_enabled;
    my ($size) = (stat($LOGFILE))[7] // 0;
    # Simple guard: truncate if >5MB
    if ($size && $size > 5*1024*1024) {
        open my $tfh, ">", $LOGFILE or return;
        print $tfh "";
        close $tfh;
    }
    open my $fh, ">>", $LOGFILE or return;
    $fh->autoflush(1);
    return $fh;
}

sub log_line {
    my ($msg, $level) = @_;
    $level //= 1;
    return if !$log_enabled || $level > $log_level;
    my $ts = strftime("%Y-%m-%d %H:%M:%S", localtime);
    my $fh = log_open();
    return unless $fh;
    print $fh "[$ts] $msg\n";
    close $fh;
}

# ------------- Helpers: clamp and choice -------------

sub _clamp {
    my ($v, $lo, $hi) = @_;
    $v = $lo if $v < $lo;
    $v = $hi if $v > $hi;
    return $v;
}

sub _validate_choice {
    my ($val, @allowed) = @_;
    foreach my $a (@allowed) { return $val if $val eq $a; }
    return $allowed[0];
}

# ------------- Config loader (robust parsing with inline comment stripping) -------------

sub parse_kv_line {
    my ($line) = @_;
    $line =~ s/^\s+|\s+$//g;
    return if $line eq "" || $line =~ /^\s*#/;

    my ($k, $v) = split(/\s*=\s*/, $line, 2);
    return unless defined $k && defined $v;

    $v =~ s/\s+#.*$//;
    $v =~ s/^\s+|\s+$//g;
    $v =~ s/^"(.*)"$/$1/;
    $v =~ s/^'(.*)'$/$1/;

    return ($k, $v);
}

sub _have_cmd {
    my ($cmd) = @_;
    if (defined(&which)) {
        return !!which($cmd);
    } else {
        return (system("$cmd --version >/dev/null 2>&1") == 0);
    }
}

sub _resolve_pinger_nss {
    my ($method) = @_;
    return "fping" if $method eq "fping" && _have_cmd("fping");
    return "ping"  if $method eq "ping"  && _have_cmd("ping");
    if ($method eq "automatic") {
        return "fping" if _have_cmd("fping");
        return "ping"  if _have_cmd("ping");
    }
    return ""; # irtt intentionally excluded for ipq806x NSS build
}

sub _ensure_probe_access {
    return unless $probe_setuid_fix;
    foreach my $bin ("/usr/bin/fping", "/bin/ping") {
        next unless -x $bin;
        my $mode = (stat($bin))[2];
        next if ($mode & 04000);
        system("chmod u+s $bin");
    }
}

sub load_config {
    my %cfg;
    if (-f $CONFIG_FILE) {
        open my $cfh, "<", $CONFIG_FILE or do {
            log_line("Config: failed to open $CONFIG_FILE", 0);
            return;
        };
        while (my $line = <$cfh>) {
            chomp $line;
            my ($k, $v) = parse_kv_line($line);
            next unless defined $k;
            $cfg{$k} = $v;
        }
        close $cfh;
    } else {
        log_line("Config: missing $CONFIG_FILE; using built-in defaults", 0);
    }

    # Interfaces (strict NSS defaults)
    $upload_if     = $cfg{"upload_interface"}   // $upload_if // "eth0";
    $upload_if     = "eth0" if (!defined $upload_if || $upload_if eq "");
    if ($upload_if !~ /^[A-Za-z0-9_.\-]+$/ || !-d "/sys/class/net/$upload_if") {
        log_line("Interface $upload_if not found; forcing eth0 for ipq806x NSS", 1);
        $upload_if = "eth0";
    }

    # Ingress mirror is fixed for NSS
    $download_if   = "nssifb";

    # Pinger (strict NSS: fping/ping)
    $pinger_method = $cfg{"pinger_method"}      // $pinger_method;
    $pinger_method = _validate_choice($pinger_method, "automatic", "fping", "ping");
    $probe_setuid_fix = int($cfg{"probe_setuid_fix"} // $probe_setuid_fix);

    # Qdisc stats source (strict NSS only)
    $qdisc_stats   = $cfg{"qdisc_stats"} // "nsstbl";
    $qdisc_stats   = _validate_choice($qdisc_stats, "nsstbl", "nssfq_codel");

    # Reflectors
    if (defined $cfg{"reflectors"}) {
        my $list = $cfg{"reflectors"};
        @reflectors = grep { $_ ne "" } split(/\s+/, $list);
        @reflectors = map { s/['"]//g; $_ } @reflectors;
    }
    @reflectors = ('1.1.1.1') unless @reflectors;

    $reflector_count    = int($cfg{"reflector_count"} // $reflector_count);
    $reflector_count    = _clamp($reflector_count, 1, 10);
    $reflector_rotation = $cfg{"reflector_rotation"} // $reflector_rotation;
    $reflector_rotation = _validate_choice($reflector_rotation, "roundrobin", "random");

    # Logging
    $log_enabled = int($cfg{"log_enabled"} // $log_enabled);
    $log_level   = int($cfg{"log_level"}   // $log_level);
    $log_format  = $cfg{"log_format"}      // $log_format;
    $log_format  = _validate_choice($log_format, "compact", "verbose", "json");
    $log_mode    = int($cfg{"log_mode"}    // $log_mode);
    $log_change_threshold_percent = int($cfg{"log_change_threshold_percent"} // $log_change_threshold_percent);
    $log_change_threshold_percent = _clamp($log_change_threshold_percent, 0, 50);

    # Rates and floors
    $upload_base_kbits   = int($cfg{"upload_base_kbits"}   // $upload_base_kbits);
    $download_base_kbits = int($cfg{"download_base_kbits"} // $download_base_kbits);
    $upload_base_kbits   = _clamp($upload_base_kbits,   100, 10_000_000);
    $download_base_kbits = _clamp($download_base_kbits, 100, 10_000_000);

    $upload_min_percent   = int($cfg{"upload_min_percent"}   // $upload_min_percent);
    $download_min_percent = int($cfg{"download_min_percent"} // $download_min_percent);
    $upload_min_percent   = _clamp($upload_min_percent,   0, 100);
    $download_min_percent = _clamp($download_min_percent, 0, 100);
    # (floors are initialised below, after the adaptive_floor_* keys are parsed)

    # Latency thresholds
    $latency_low_up_ms     = int($cfg{"latency_low_up_ms"}     // $latency_low_up_ms);
    $latency_high_up_ms    = int($cfg{"latency_high_up_ms"}    // $latency_high_up_ms);
    $latency_low_down_ms   = int($cfg{"latency_low_down_ms"}   // $latency_low_down_ms);
    $latency_high_down_ms  = int($cfg{"latency_high_down_ms"}  // $latency_high_down_ms);

    # Probing
    $probe_ms        = int($cfg{"probe_ms"}        // $probe_ms);
    $probe_fast_ms   = int($cfg{"probe_fast_ms"}   // $probe_fast_ms);
    $probe_min_ms    = int($cfg{"probe_min_ms"}    // $probe_min_ms);
    $probe_ms        = _clamp($probe_ms,      100, 5000);
    $probe_fast_ms   = _clamp($probe_fast_ms, 50,  5000);
    $probe_min_ms    = _clamp($probe_min_ms,  50,  5000);
    $elastic_probe   = int($cfg{"elastic_probe"}   // $elastic_probe);
    $variance_thresh_ms = int($cfg{"variance_thresh_ms"} // $variance_thresh_ms);
    $variance_thresh_ms = _clamp($variance_thresh_ms, 1, 100);
    $probe_fast_ms   = $probe_min_ms if $probe_fast_ms < $probe_min_ms;
    $probe_timeout_ms = _clamp(int($cfg{"probe_timeout_ms"} // $probe_timeout_ms), 20, 1000);
    $probe_blackout_s = _clamp(0.0 + ($cfg{"probe_blackout_s"} // $probe_blackout_s), 0, 3600);

    # Latency smoothing
    $latency_filter      = $cfg{"latency_filter"}      // $latency_filter;
    $latency_filter      = _validate_choice($latency_filter, "median", "ewma");
    $latency_window_size = int($cfg{"latency_window_size"} // $latency_window_size);
    $latency_window_size = _clamp($latency_window_size, 1, 20);
    $alpha_ewma          = 0.0 + ($cfg{"alpha_ewma"} // $alpha_ewma);
    $alpha_ewma          = _clamp($alpha_ewma, 0.0, 1.0);

    # Rate adjustment
    $increase_rate_percent_up    = int($cfg{"increase_rate_percent_up"}    // $increase_rate_percent_up);
    $decrease_rate_percent_up    = int($cfg{"decrease_rate_percent_up"}    // $decrease_rate_percent_up);
    $increase_rate_percent_down  = int($cfg{"increase_rate_percent_down"}  // $increase_rate_percent_down);
    $decrease_rate_percent_down  = int($cfg{"decrease_rate_percent_down"}  // $decrease_rate_percent_down);

    # Adaptive floor
    $adaptive_floor                 = int($cfg{"adaptive_floor"} // $adaptive_floor);
    $adaptive_floor_step            = int($cfg{"adaptive_floor_step"} // $adaptive_floor_step);
    $adaptive_floor_min             = int($cfg{"adaptive_floor_min"}  // $adaptive_floor_min);
    $adaptive_floor_max             = int($cfg{"adaptive_floor_max"}  // $adaptive_floor_max);
    $adaptive_floor_min             = _clamp($adaptive_floor_min, 0, 100);
    $adaptive_floor_max             = _clamp($adaptive_floor_max, 0, 100);
    $adaptive_floor_trigger_ms      = int($cfg{"adaptive_floor_trigger_ms"} // $adaptive_floor_trigger_ms);
    $adaptive_floor_trigger_count   = int($cfg{"adaptive_floor_trigger_count"} // $adaptive_floor_trigger_count);
    $adaptive_floor_decay_interval  = int($cfg{"adaptive_floor_decay_interval"} // $adaptive_floor_decay_interval);
    $adaptive_floor_decay_step      = int($cfg{"adaptive_floor_decay_step"} // $adaptive_floor_decay_step);
    if ($adaptive_floor) {
        $upload_floor_base   = _clamp($upload_min_percent,   $adaptive_floor_min, $adaptive_floor_max);
        $download_floor_base = _clamp($download_min_percent, $adaptive_floor_min, $adaptive_floor_max);
    } else {
        $upload_floor_base   = $upload_min_percent;
        $download_floor_base = $download_min_percent;
    }
    $upload_min   = $upload_floor_base;
    $download_min = $download_floor_base;

    # Load-aware
    $load_aware                 = int($cfg{"load_aware"} // $load_aware);
    $load_bias_decrease         = int($cfg{"load_bias_decrease"} // $load_bias_decrease);
    $load_bias_threshold_percent = _clamp(int($cfg{"load_bias_threshold_percent"} // $load_bias_threshold_percent), 1, 100);
    $decrease_min_load_percent   = _clamp(int($cfg{"decrease_min_load_percent"}   // $decrease_min_load_percent),   0, 100);
    $apply_min_change_percent    = _clamp(0.0 + ($cfg{"apply_min_change_percent"} // $apply_min_change_percent),     0, 50);
    log_line("Config: load_bias_threshold_bytes is obsolete and ignored; use load_bias_threshold_percent", 1)
        if defined $cfg{"load_bias_threshold_bytes"};

    $hold_after_decrease_ms  = _clamp(int($cfg{"hold_after_decrease_ms"}  // $hold_after_decrease_ms),  0, 60000);
    $slow_increase_percent   = _clamp(0.0 + ($cfg{"slow_increase_percent"} // $slow_increase_percent),   0.1, 50);
    $ramp_fast_until_percent = _clamp(int($cfg{"ramp_fast_until_percent"} // $ramp_fast_until_percent),  10, 100);
    $trouble_memory_s        = _clamp(int($cfg{"trouble_memory_s"}        // $trouble_memory_s),          0, 86400);
    
    # Calm-window guard
    $calm_window_cycles = int($cfg{"calm_window_cycles"} // $calm_window_cycles);
    $calm_window_cycles = _clamp($calm_window_cycles, 0, 100);
    $calm_window_active = $calm_window_cycles;  # reset on reload

    # ISP cap detection
    $cap_trigger_cycles    = int($cfg{"cap_trigger_cycles"}    // $cap_trigger_cycles);
    $cap_threshold_percent = int($cfg{"cap_threshold_percent"} // $cap_threshold_percent);
    $cap_threshold_percent = _clamp($cap_threshold_percent, 1, 100);
    $cap_load_percent      = _clamp(int($cfg{"cap_load_percent"} // $cap_load_percent), 1, 100);

    # --- Throughput smoothing options ---
    $rate_filter = $cfg{"rate_filter"} // $rate_filter;
    $rate_filter = _validate_choice($rate_filter, "average", "ewma");
    $alpha_rate  = 0.0 + ($cfg{"alpha_rate"} // $alpha_rate);
    $alpha_rate  = _clamp($alpha_rate, 0.0, 1.0);
    $smooth_size = int($cfg{"smooth_size"} // $smooth_size);
    $smooth_size = _clamp($smooth_size, 1, 50);
    $counter_sync_s = 0.0 + ($cfg{"counter_sync_s"} // $counter_sync_s);
    $counter_sync_s = _clamp($counter_sync_s, 0.0, 10.0);

# Qdisc options: prefer profile conf, else fallback to SQM UCI
    if (defined $cfg{"eqdisc_opts"}) {
        $EQDISC_OPTS = $cfg{"eqdisc_opts"};
    } else {
        chomp($EQDISC_OPTS = qx(uci get sqm.\@queue[0].eqdisc_opts 2>/dev/null));
    }

    if (defined $cfg{"iqdisc_opts"}) {
        $IQDISC_OPTS = $cfg{"iqdisc_opts"};
    } else {
        chomp($IQDISC_OPTS = qx(uci get sqm.\@queue[0].iqdisc_opts 2>/dev/null));
    }

    # optional root burst overrides (bytes)
    $ROOT_BURST_UP   = int($cfg{"root_burst_up"}   // $ROOT_BURST_UP);
    $ROOT_BURST_DOWN = int($cfg{"root_burst_down"} // $ROOT_BURST_DOWN);
    $ROOT_BURST_UP   = _clamp($ROOT_BURST_UP, 1518, 10000000);
    $ROOT_BURST_DOWN = _clamp($ROOT_BURST_DOWN, 1518, 10000000);
    log_line("Root burst: up=$ROOT_BURST_UP down=$ROOT_BURST_DOWN", 2);

    # Resolve pinger once per load
    $resolved_pinger = _resolve_pinger_nss($pinger_method);
    if ($resolved_pinger eq "") {
        log_line("Pinger not available; latency probing will return 999 ms", 1);
    } else {
        _ensure_probe_access();
        log_line("Pinger selected: $resolved_pinger (method=$pinger_method)", 1);
    }

    # --- Config validation sanity checks ---
    if ($latency_low_up_ms >= $latency_high_up_ms) {
        log_line("Config warning: latency_low_up_ms ($latency_low_up_ms) >= latency_high_up_ms ($latency_high_up_ms)", 1);
    }
    if ($latency_low_down_ms >= $latency_high_down_ms) {
        log_line("Config warning: latency_low_down_ms ($latency_low_down_ms) >= latency_high_down_ms ($latency_high_down_ms)", 1);
    }
    if ($upload_min_percent > 100 || $download_min_percent > 100) {
        log_line("Config warning: floor percentages exceed 100%", 1);
    }
    if ($adaptive_floor_min > $adaptive_floor_max) {
        log_line("Config warning: adaptive_floor_min ($adaptive_floor_min) > adaptive_floor_max ($adaptive_floor_max)", 1);
    }
    if ($calm_window_cycles < 0) {
        log_line("Config warning: calm_window_cycles ($calm_window_cycles) < 0", 1);
    }
    if ($smooth_size < 1) {
        log_line("Config warning: smooth_size ($smooth_size) < 1", 1);
    }
    if ($alpha_rate < 0.0 || $alpha_rate > 1.0) {
        log_line("Config warning: alpha_rate ($alpha_rate) out of bounds (0.0–1.0)", 1);
    }

    if ($adaptive_floor && $adaptive_floor_trigger_ms < $latency_low_up_ms) {
        log_line("Config warning: adaptive_floor_trigger_ms ($adaptive_floor_trigger_ms) is below latency_low_up_ms ($latency_low_up_ms); idle jitter can raise the floor", 1);
    }

    # --- Config reload summary ---
    log_line("Reloaded config from $CONFIG_FILE", 1);
    log_line("Interfaces: upload_if=$upload_if (egress), download_if=$download_if (ignored; NSS ingress via nssifb)", 2);
    log_line("Qdisc stats source: $qdisc_stats", 2);
    log_line("Throughput smoothing: filter=$rate_filter alpha=$alpha_rate window=$smooth_size counter_sync=${counter_sync_s}s", 2);
    if ($latency_filter eq "ewma") {
        log_line("Latency smoothing: filter=$latency_filter window=$latency_window_size alpha_ewma=$alpha_ewma", 2);
    } else {
        log_line("Latency smoothing: filter=$latency_filter window=$latency_window_size", 2);
    }
    log_line("Pinger: method=$pinger_method resolved=$resolved_pinger reflectors=".(join(",",@reflectors)), 2);
    log_line("Probing: timeout=${probe_timeout_ms}ms blackout=${probe_blackout_s}s", 2);
    log_line("Rates base: up=${upload_base_kbits}k down=${download_base_kbits}k floors=${upload_min}%/${download_min}%", 2);
    log_line("Ramp: hold=${hold_after_decrease_ms}ms slow_step=${slow_increase_percent}% fast_until=${ramp_fast_until_percent}% memory=${trouble_memory_s}s", 2);
    log_line("Latency thresholds: up ${latency_low_up_ms}/${latency_high_up_ms} ms, down ${latency_low_down_ms}/${latency_high_down_ms} ms", 2);
    log_line("Logging format active: $log_format (mode=$log_mode)", 1);
}

# ------------- PID file management -------------

my $PID_FH;   # kept open for the process lifetime so the flock is held
sub write_pidfile {
    open($PID_FH, ">>", $PIDFILE) or do {
        log_line("PID: failed to write $PIDFILE", 0);
        return;
    };
    if (!flock($PID_FH, LOCK_EX|LOCK_NB)) {
        log_line("PID: another instance appears to be running", 0);
        close $PID_FH;
        # _exit skips the END block: a duplicate must not delete the live
        # instance's pidfile or reset its shaper to base rates.
        POSIX::_exit(1);
    }
    truncate($PID_FH, 0);
    seek($PID_FH, 0, 0);
    print $PID_FH $$;
    $PID_FH->flush;
}

sub remove_pidfile {
    unlink $PIDFILE if -f $PIDFILE;
}

# ------------- Signal handlers -------------

$SIG{HUP}  = sub { $reload_requested = 1; log_line("Signal: SIGHUP received, reload requested", 1); };
$SIG{TERM} = sub { $running = 0;         log_line("Signal: SIGTERM received, stopping", 1); };
$SIG{INT}  = sub { $running = 0;         log_line("Signal: SIGINT received, stopping", 1); };

# ------------- Startup -------------

write_pidfile();
load_config();

# Ensure log path
if (!-w $LOGFILE) {
    my $dir = "/var/log";
    unless (-d $dir) { mkdir $dir or warn "Failed to create $dir: $!"; }
    open my $fh, ">>", $LOGFILE or warn "Cannot open $LOGFILE for writing: $!";
    close $fh;
}

log_line("Time::HiRes not found (install perlbase-time); throughput measurement will be coarse", 1) unless $HAVE_HIRES;
log_line("Startup complete; entering main loop", 1);

# ------------- Interface counter helpers (strict NSS) -------------

# Read bytes sent from NSS root (nsstbl) or child (nssfq_codel)
sub read_qdisc_bytes_nss {
    my ($iface, $kind) = @_;
    my $out = `tc -s qdisc show dev $iface 2>/dev/null`;

    if ($kind eq "nsstbl") {
        # root aggregate on eth0 / nssifb
        if ($out =~ /qdisc\s+nsstbl\s+\S+:\s+(?:dev\s+\Q$iface\E\s+)?root.*?\n\s*Sent\s+(\d+)\s+bytes/s) {
            return int($1);
        }
    } elsif ($kind eq "nssfq_codel") {
        # child fairness scheduler under nsstbl (parent 1:) on eth0 / nssifb
        if ($out =~ /qdisc\s+nssfq_codel\s+\S+:\s+(?:dev\s+\Q$iface\E\s+)?parent\s+1:.*?\n\s*Sent\s+(\d+)\s+bytes/s) {
            return int($1);
        }
    }
    return 0;
}

# Sysfs fallback for counters
sub read_sysfs_bytes {
    my ($iface, $dir) = @_;
    my $path = "/sys/class/net/$iface/statistics/" . ($dir eq "tx" ? "tx_bytes" : "rx_bytes");
    if (-r $path) {
        open my $fh, "<", $path or return 0;
        my $val = <$fh>;
        close $fh;
        return int($val // 0);
    }
    return 0;
}

# Fold one rate sample (kbit/s) into a direction's smoothed estimate.
sub _rate_feed {
    my ($st, $kbps) = @_;
    if ($rate_filter eq "average") {
        push @{ $st->{win} }, $kbps;
        shift @{ $st->{win} } while @{ $st->{win} } > $smooth_size;
        my $sum = 0;
        $sum += $_ for @{ $st->{win} };
        $st->{est} = $sum / @{ $st->{win} };
    } else {   # ewma
        $st->{est} = defined $st->{est}
            ? ($alpha_rate * $kbps) + ((1 - $alpha_rate) * $st->{est})
            : $kbps;
    }
}

# Process one counter reading for one direction; returns the bytes it moved since the last poll.
#  $sync_s > 0: counter advances in steps of that period (NSS tc counters)
#  $sync_s = 0: counter is continuous (sysfs), every poll is a sample
sub _rate_update {
    my ($dir, $src, $bytes, $now, $poll_dt, $sync_s) = @_;
    my $st = $rs{$dir};

    # First poll, a different counter source (tc <-> sysfs), a counter that went backwards
    # (qdisc re-created) or a clock that did: nothing to compare against, restart from this reading.
    if ($st->{src} ne $src || $bytes < $st->{prev} || $now < $st->{ev_ts}) {
        @{$st}{qw(src prev ev_ts zero_fed)} = ($src, $bytes, $now, 0);
        return 0;
    }

    my $delta = $bytes - $st->{prev};
    $st->{prev} = $bytes;

    if ($sync_s <= 0) {
        _rate_feed($st, $delta * 8 / $poll_dt / 1000);
    } elsif ($delta > 0) {
        # A counter update carries the traffic of one sync period, however many polls ago the
        # previous update was (silent periods carry nothing). Only if the daemon itself went
        # quiet for longer could several updates have been merged into this one.
        my $span = ($poll_dt >= 1.5 * $sync_s) ? $poll_dt : $sync_s;
        _rate_feed($st, $delta * 8 / $span / 1000);
        $st->{ev_ts}    = $now;
        $st->{zero_fed} = 0;
    } else {
        # No update this poll. After whole sync periods without any bytes the link is idle:
        # feed one zero sample per elapsed period (the first after 1.5 periods of silence).
        my $missed = int(($now - $st->{ev_ts}) / $sync_s - 0.5);
        $missed = 100 if $missed > 100;     # the estimate is long since zero; keep the loop bounded
        while ($st->{zero_fed} < $missed) {
            _rate_feed($st, 0);
            $st->{zero_fed}++;
        }
    }
    return $delta;
}

sub update_intervals {
    # Read tc counters (preferred)
    my $tx_tc = read_qdisc_bytes_nss($upload_if, $qdisc_stats);
    my $rx_tc = read_qdisc_bytes_nss("nssifb",    $qdisc_stats);

    # Read sysfs counters (fallbacks)
    my $tx_sysfs = read_sysfs_bytes($upload_if, "tx");
    my $rx_sysfs_nss = read_sysfs_bytes("nssifb", "rx");
    my $rx_sysfs_wan = read_sysfs_bytes($upload_if, "rx");

    # Decide upstream source: tc if positive, otherwise sysfs
    my $up_src  = ($tx_tc > 0) ? "tc" : "sysfs";
    my $tx_now  = ($up_src eq "tc") ? $tx_tc : $tx_sysfs;

    # Decide downstream source in cascade: tc -> sysfs(nssifb) -> sysfs(upload_if rx)
    my $down_src = ($rx_tc > 0)            ? "tc"
                 : ($rx_sysfs_nss > 0)     ? "sysfs_nss"
                 :                           "sysfs_wan";
    my $rx_now   = ($down_src eq "tc")         ? $rx_tc
                 : ($down_src eq "sysfs_nss")  ? $rx_sysfs_nss
                 :                               $rx_sysfs_wan;

    my $src_now = "$up_src/$down_src";
    if ($src_now ne $last_counter_src) {
        log_line("Counter source: up=$up_src down=$down_src" .
                 (($up_src ne "tc" || $down_src ne "tc") ? " (tc counters unavailable; sysfs may not include NSS-accelerated traffic)" : ""), 1);
        $last_counter_src = $src_now;
    }

    # Timing: time since the previous poll; a whole-second clock cannot resolve a ~0.3 s cycle
    my $now     = now();
    my $poll_dt = $now - $last_ts;
    $last_ts    = $now;
    my $min_dt  = $HAVE_HIRES ? 0.05 : 1;
    $poll_dt    = $min_dt if $poll_dt < $min_dt;

    # NSS tc counters advance in ~1 s steps; sysfs counters are continuous
    my $up_sync   = ($up_src   eq "tc") ? $counter_sync_s : 0;
    my $down_sync = ($down_src eq "tc") ? $counter_sync_s : 0;

    my $delta_up   = _rate_update("up",   $up_src,   $tx_now, $now, $poll_dt, $up_sync);
    my $delta_down = _rate_update("down", $down_src, $rx_now, $now, $poll_dt, $down_sync);

    $measured_up_kbps   = int($rs{up}{est}   // 0);
    $measured_down_kbps = int($rs{down}{est} // 0);

    $bytes_interval_up   = int($delta_up);
    $bytes_interval_down = int($delta_down);

    # Optional debug: show chosen sources and raw deltas at level 2
    log_line(sprintf("Counters: up_src=%s down_src=%s delta_up=%d delta_down=%d", $up_src, $down_src, $delta_up, $delta_down), 2);
}

# ------------- Latency measurement (robust multi-reflector) -------------

# Exit status and stderr text of the last run_cmd (only used to explain failed probes in the log)
my ($RUN_STATUS, $RUN_ERR) = (0, "");

sub run_cmd {
    my @cmd = @_;
    my $err = gensym;
    local *OUT;
    my $pid = open3(undef, \*OUT, $err, @cmd);
    my $output = do { local $/; <OUT> };
    close(OUT);
    my $errtxt = do { local $/; <$err> };   # a line or two for fping/ping; read once stdout has hit EOF
    close($err);
    waitpid($pid, 0);
    $RUN_STATUS = ($? & 127) ? 128 + ($? & 127) : ($? >> 8);
    $RUN_ERR    = defined $errtxt ? $errtxt : "";
    return $output // "";
}

my %probe_why;              # reflector -> why its latest probe failed
my $probe_fail_detail = ""; # "ip=reason, ..." for the probes that failed in the latest cycle
my $probe_failing = 0;      # the latest cycle had no usable reply
my $probe_counted = 0;      # a missing reply was counted as a timeout reading during the current blackout
my $probe_busy_since;       # now() when the current run of failed cycles started while a direction was loaded (undef = not in one)
my $last_good_ts = now();   # now() of the latest cycle that produced a usable latency

sub _probe_reason {
    my ($status, $err) = @_;
    $err = "" unless defined $err;
    $err =~ s/\s+/ /g;
    $err =~ s/^ | $//g;
    # The ordinary "no reply" summary (fping 1/0/100% loss, ping 100% packet loss) is just a timeout
    return "timeout" if $err eq "" || $err =~ m{xmt/rcv/%loss = 1/0/100%} || $err =~ /100% packet loss/;
    return "exit=$status: " . substr($err, 0, 60);
}

# Seconds the probes wait for a reply (ping -W only takes whole seconds)
sub _probe_timeout_s {
    return ($resolved_pinger eq "ping") ? int(($probe_timeout_ms + 999) / 1000) : $probe_timeout_ms / 1000.0;
}

sub _ping_once {
    my ($tool, $target) = @_;
    if ($tool eq "fping") {
        my $out = run_cmd("fping", "-c1", "-t$probe_timeout_ms", $target);
        return $1 if $out =~ /(\d+\.\d+)\s*ms/;
    } elsif ($tool eq "ping") {
        my $out = run_cmd("ping", "-c1", "-W" . _probe_timeout_s(), $target);
        return $1 if $out =~ /time=(\d+\.\d+)/;
    } else {
        return undef;
    }
    $probe_why{$target} = _probe_reason($RUN_STATUS, $RUN_ERR);
    return undef;
}

sub measure_latency {
    my ($dir) = @_; # "up" or "down"
    my @sampled = ();
    my @targets = ();

    if (!@reflectors) {
        @reflectors = ('1.1.1.1'); # fallback default
    }

    my $n = ($reflector_count && $reflector_count > 0) ? $reflector_count : 1;

    if ($reflector_rotation eq "roundrobin") {
        for (1..$n) {
            push @targets, $reflectors[$reflector_index % @reflectors];
            $reflector_index++;
        }
    } else {
        for (1..$n) {
            push @targets, $reflectors[int(rand(@reflectors))];
        }
    }

    my $tool = $resolved_pinger;
    my @failed = ();
    foreach my $target (@targets) {
        my $lat = ($tool ne "") ? _ping_once($tool, $target) : undef;
        push @failed, "$target=" . (($tool ne "") ? ($probe_why{$target} // "timeout") : "no pinger") if !defined $lat;
        push @sampled, defined $lat ? $lat : 999;
    }
    $probe_fail_detail = join(", ", @failed);

    if (!@sampled) {
        log_line("Latency measurement failed: no valid samples from reflectors", 1);
        return 999;
    }

    @sampled = sort { $a <=> $b } @sampled;
    my $mid = int(@sampled/2);
    my $median = $sampled[$mid];
    return undef if $median >= 999;   # majority of probes failed: no usable data, caller holds rates
    return $median;
}

# ------------- Latency smoothing -------------

sub smooth_latency {
    my ($dir, $lat) = @_;
    if ($latency_filter eq "median") {
        my $window_ref = ($dir eq "up") ? \@lat_window_up : \@lat_window_down;
        push @$window_ref, $lat;
        shift @$window_ref if @$window_ref > $latency_window_size;
        my @sorted = sort { $a <=> $b } @$window_ref;
        my $mid = int(@sorted/2);
        return $sorted[$mid];
    } else {
        if ($dir eq "up") {
            $ewma_up = defined $ewma_up ? $alpha_ewma*$lat + (1-$alpha_ewma)*$ewma_up : $lat;
            return $ewma_up;
        } else {
            $ewma_down = defined $ewma_down ? $alpha_ewma*$lat + (1-$alpha_ewma)*$ewma_down : $lat;
            return $ewma_down;
        }
    }
}

# ------------- Adaptive floor logic with decay -------------

sub adaptive_floor_logic {
    my ($avg_lat_up, $avg_lat_down, $loaded_up, $loaded_down) = @_;

    # Hits must be consecutive and only count while that direction is actually
    # loaded, so idle jitter cannot ratchet the floor up.
    if ($loaded_up && $avg_lat_up > $adaptive_floor_trigger_ms) {
        $trigger_hits_up++;
        if ($trigger_hits_up >= $adaptive_floor_trigger_count) {
            $upload_min += $adaptive_floor_step;
            $upload_min = $adaptive_floor_max if $upload_min > $adaptive_floor_max;
            $trigger_hits_up = 0;
            log_line("Adaptive floor raised (upload_min=$upload_min)", 2);
        }
    } else {
        $trigger_hits_up = 0;
    }

    if ($loaded_down && $avg_lat_down > $adaptive_floor_trigger_ms) {
        $trigger_hits_down++;
        if ($trigger_hits_down >= $adaptive_floor_trigger_count) {
            $download_min += $adaptive_floor_step;
            $download_min = $adaptive_floor_max if $download_min > $adaptive_floor_max;
            $trigger_hits_down = 0;
            log_line("Adaptive floor raised (download_min=$download_min)", 2);
        }
    } else {
        $trigger_hits_down = 0;
    }

    if ($cycle - $last_decay_cycle >= $adaptive_floor_decay_interval) {
        my ($old_up_min, $old_down_min) = ($upload_min, $download_min);
        $upload_min   -= $adaptive_floor_decay_step;
        $download_min -= $adaptive_floor_decay_step;
        $upload_min   = $upload_floor_base   if $upload_min   < $upload_floor_base;
        $download_min = $download_floor_base if $download_min < $download_floor_base;
        $last_decay_cycle = $cycle;
        log_line("Adaptive floor decayed (upload_min=$upload_min, download_min=$download_min)", 2)
            if ($upload_min != $old_up_min || $download_min != $old_down_min);
    }
}

# ------------- Rate adjustment logic -------------

sub util_pct {
    my ($measured_kbps, $rate_kbps) = @_;
    return $rate_kbps > 0 ? (100.0 * $measured_kbps / $rate_kbps) : 0;
}

# Per-direction ramp state
my %hold_until   = (up => 0, down => 0);   # no increases before this time (now() seconds)
my %trouble_rate;                           # rate (kbit/s) the link carried when the latest bufferbloat episode started
my %trouble_seen = (up => 0, down => 0);   # time of the last bufferbloat decrease
use constant EPISODE_GAP_S => 1.0;          # decreases closer together than this belong to one episode

# One direction of the latency controller. Returns (new_rate, skip_load_bias).
#  - decrease on high latency, but only if this direction actually carries load
#  - after a decrease, hold (no increases) for hold_after_decrease_ms so the queue can drain
#  - after the hold, increase with the normal step until ramp_fast_until_percent of the rate where
#    trouble began, then creep with slow_increase_percent: latency lags the shaper by a few cycles,
#    so big steps near the limit overshoot every time
sub adjust_dir {
    my ($dir, $lat, $cur, $measured, $high_ms, $low_ms, $dec_pct, $inc_pct, $min_rate) = @_;
    my $t         = now();
    my $label     = ($dir eq "up") ? "Upload" : "Download";
    my $slow_ramp = ($trouble_memory_s > 0);
    my $loaded    = (util_pct($measured, $cur) >= $decrease_min_load_percent);
    my $skip_bias = 0;

    if (defined $trouble_rate{$dir} && ($t - $trouble_seen{$dir}) > $trouble_memory_s) {
        log_line("$label: trouble-rate memory expired", 2);
        undef $trouble_rate{$dir};
    }

    if ($lat > $high_ms) {
        if ($loaded) {
            if ($slow_ramp) {
                if (!defined $trouble_rate{$dir} || ($t - $trouble_seen{$dir}) > EPISODE_GAP_S) {
                    # New episode: remember what the link actually carried (the shaper rate lags and overshoots)
                    my $est = ($measured < $cur) ? $measured : $cur;
                    $est = $min_rate if $est < $min_rate;
                    $trouble_rate{$dir} = int($est);
                    my $tr = $trouble_rate{$dir};
                    log_line("$label: bufferbloat episode, trouble rate ${tr}k (shaper ${cur}k)", 2);
                }
                $trouble_seen{$dir} = $t;
            }
            $hold_until{$dir} = $t + $hold_after_decrease_ms / 1000.0;
            $cur = int($cur * (1 - $dec_pct/100.0));
        } else {
            log_line("$label latency high but " . lc($label) . " idle; holding rate", 2);
        }
    } elsif ($lat < $low_ms) {
        if ($t >= $hold_until{$dir}) {
            my $pct = $inc_pct;
            # Creep only while this direction is loaded; an idle link can return to base at the normal step
            if ($loaded && defined $trouble_rate{$dir}
                && $cur >= $trouble_rate{$dir} * $ramp_fast_until_percent / 100.0) {
                $pct = $slow_increase_percent;
                $skip_bias = 1;      # the load bias (>= the slow step) would otherwise cancel the creep
            }
            my $new = int($cur * (1 + $pct/100.0));
            $new = $cur + 1 if $new <= $cur;     # never stall on integer truncation
            $cur = $new;
        }
    }
    return ($cur, $skip_bias);
}

sub adjust_rates {
    my ($avg_lat_up, $avg_lat_down, $current_up, $current_down) = @_;

    my $min_up_rate   = int($upload_base_kbits   * $upload_min/100.0);
    my $min_down_rate = int($download_base_kbits * $download_min/100.0);

    my ($skip_bias_up, $skip_bias_down);
    ($current_up, $skip_bias_up) = adjust_dir("up", $avg_lat_up, $current_up, $measured_up_kbps,
        $latency_high_up_ms, $latency_low_up_ms,
        $decrease_rate_percent_up, $increase_rate_percent_up, $min_up_rate);
    ($current_down, $skip_bias_down) = adjust_dir("down", $avg_lat_down, $current_down, $measured_down_kbps,
        $latency_high_down_ms, $latency_low_down_ms,
        $decrease_rate_percent_down, $increase_rate_percent_down, $min_down_rate);

    $current_up   = $min_up_rate   if $current_up   < $min_up_rate;
    $current_down = $min_down_rate if $current_down < $min_down_rate;

    if ($load_aware) {
        if (!$skip_bias_up && util_pct($measured_up_kbps, $current_up) > $load_bias_threshold_percent) {
            $current_up = int($current_up * (1 - $load_bias_decrease/100.0));
            log_line("Load-aware bias applied to upload", 2);
        }
        if (!$skip_bias_down && util_pct($measured_down_kbps, $current_down) > $load_bias_threshold_percent) {
            $current_down = int($current_down * (1 - $load_bias_decrease/100.0));
            log_line("Load-aware bias applied to download", 2);
        }
    }

    $current_up   = $min_up_rate   if $current_up   < $min_up_rate;
    $current_down = $min_down_rate if $current_down < $min_down_rate;
    # Clamp to base values
    $current_up   = $upload_base_kbits   if $current_up   > $upload_base_kbits;
    $current_down = $download_base_kbits if $current_down > $download_base_kbits;

    return ($current_up, $current_down);
}

# ------------- ISP cap detection -------------

my $cap_hit_cycles = 0;

sub isp_cap_check {
    my ($current_up, $current_down, $avg_lat_up, $avg_lat_down) = @_;

    my $up_cap   = int($upload_base_kbits   * $cap_threshold_percent/100.0);
    my $down_cap = int($download_base_kbits * $cap_threshold_percent/100.0);

    # Near-cap = the shaper sits at the cap and that direction really carries about that much.
    # (A shaper at base with any 40 %+ load used to qualify, which is just a busy link.)
    my $up_util   = util_pct($measured_up_kbps,   $current_up);
    my $down_util = util_pct($measured_down_kbps, $current_down);
    my $up_hit    = ($current_up   >= $up_cap   && $up_util   >= $cap_load_percent);
    my $down_hit  = ($current_down >= $down_cap && $down_util >= $cap_load_percent);
    my $latency_ok = ($avg_lat_up <= $latency_high_up_ms && $avg_lat_down <= $latency_high_down_ms);

    if (($up_hit || $down_hit) && $latency_ok) {
        $cap_hit_cycles++;
        if ($cap_hit_cycles >= $cap_trigger_cycles && $cap_trigger_cycles > 0) {
            my @dirs;
            push @dirs, sprintf("upload %d%% of %dk",   $up_util,   $current_up)   if $up_hit;
            push @dirs, sprintf("download %d%% of %dk", $down_util, $current_down) if $down_hit;
            log_line("ISP cap suspected: sustained near-cap throughput with stable latency (" . join(", ", @dirs) . ")", 1);
            $cap_hit_cycles = 0;
        }
    } else {
        $cap_hit_cycles = 0;
    }
}

# ------------- Apply new rates (NSS integration with fq_codel + nss-rk.qos) -------------
sub _child_args {
    my ($limit, $opts) = @_;
    my @o = (defined $opts && length $opts) ? split(/\s+/, $opts) : ();
    my $s = join(" ", @o);
    my @a;
    push @a, "limit", $limit if $s !~ /(?:^|\s)limit\s/;
    push @a, "flows", 1024   if $s !~ /(?:^|\s)flows\s/;
    return (@a, @o, "set_default");
}

sub apply_rates {
    my ($up_rate, $down_rate, $do_up, $do_down) = @_;
    $do_up   //= 1;
    $do_down //= 1;

    # MTU and max delay (match nss-rk.qos defaults)
    my $mtu = 1518;
    my $maxdelay_ms = 100;

    # Calculate dynamic limits (similar to nss-rk.qos calc_limit)
    my $ELIMIT = int(( $up_rate  * 125 ) * ($maxdelay_ms / 1000) / $mtu);
    $ELIMIT = 200 if $ELIMIT < 200;   # enforce minimum

    my $ILIMIT = int(( $down_rate * 125 ) * ($maxdelay_ms / 1000) / $mtu);
    $ILIMIT = 200 if $ILIMIT < 200;   # enforce minimum

    # Egress (uplink on configured upload_if)
    # Build tc commands as argument lists to avoid shell parsing/quoting issues.
    my @cmd_up_root = (
        $TC, "qdisc", "replace", "dev", $upload_if, "root", "handle", "1:", "nsstbl",
        "rate", "${up_rate}kbit", "burst", $ROOT_BURST_UP, "mtu", $mtu
    );

    # Child args: computed limit only when the profile opts don't set one; flows is required by nssfq_codel
    my @cmd_up_child = (
        $TC, "qdisc", "replace", "dev", $upload_if, "parent", "1:", "handle", "10:", "nssfq_codel",
        _child_args($ELIMIT, $EQDISC_OPTS)
    );

    my @cmd_down_root = (
        $TC, "qdisc", "replace", "dev", $download_if, "root", "handle", "1:", "nsstbl",
        "rate", "${down_rate}kbit", "burst", $ROOT_BURST_DOWN, "mtu", $mtu
    );

    my @cmd_down_child = (
        $TC, "qdisc", "replace", "dev", $download_if, "parent", "1:", "handle", "10:", "nssfq_codel",
        _child_args($ILIMIT, $IQDISC_OPTS)
    );

    # Execute commands directly (no shell). Log the joined command on failure.
    # A direction is marked applied only if both commands succeed, so failures are retried.
    if ($do_up) {
        my $ok = 1;
        system(@cmd_up_root)  == 0 or do { log_line("Failed to apply uplink root rate: ".join(" ", @cmd_up_root), 1); $ok = 0; };
        system(@cmd_up_child) == 0 or do { log_line("Failed to apply uplink child qdisc: ".join(" ", @cmd_up_child), 1); $ok = 0; };
        $applied_up = $up_rate if $ok;
    }
    if ($do_down) {
        my $ok = 1;
        system(@cmd_down_root)  == 0 or do { log_line("Failed to apply downlink root rate: ".join(" ", @cmd_down_root), 1); $ok = 0; };
        system(@cmd_down_child) == 0 or do { log_line("Failed to apply downlink child qdisc: ".join(" ", @cmd_down_child), 1); $ok = 0; };
        $applied_down = $down_rate if $ok;
    }

    # Log both rates and fq_codel opts
    log_line("Applied rates: up=${up_rate}k down=${down_rate}k (limits: up=$ELIMIT down=$ILIMIT, opts: up=$EQDISC_OPTS down=$IQDISC_OPTS)", 2);
} 

# ------------- Startup logging -------------
if ($log_enabled) {
    my $init_lat_up   = defined $ewma_up   ? sprintf("%.1f", $ewma_up)   : "n/a";
    my $init_lat_down = defined $ewma_down ? sprintf("%.1f", $ewma_down) : "n/a";

    if ($log_format eq "json") {
        my $json = sprintf(
            '{"event":"startup","cycle":0,"shaper_up":%dk,"shaper_down":%dk,"latency":{"up":%s,"down":%s},"floors":{"up":%d%%,"down":%d%%}}',
            $upload_base_kbits, $download_base_kbits,
            $init_lat_up, $init_lat_down,
            $upload_min, $download_min
        );
        log_line($json, 1);
    } else {
        log_line(sprintf(
            "STARTUP: shaper_up=%dk shaper_down=%dk lat_up=%sms lat_down=%sms floors=%u%%/%u%%",
            $upload_base_kbits, $download_base_kbits,
            $init_lat_up, $init_lat_down,
            $upload_min, $download_min
        ), 1);
    }
}

# ------------- Main loop -------------
my $current_up   = $upload_base_kbits;
my $current_down = $download_base_kbits;
my ($avg_lat_up, $avg_lat_down) = (0, 0);

# Push rates to tc only when they moved enough (or landed exactly on base)
sub maybe_apply {
    my ($force) = @_;
    my $thr = $apply_min_change_percent / 100.0;
    my ($do_up, $do_down) = (1, 1);
    if (!$force && defined $applied_up && defined $applied_down) {
        $do_up   = ($current_up   != $applied_up
                    && (abs($current_up   - $applied_up)   >= $thr * $applied_up
                        || $current_up   == $upload_base_kbits))   ? 1 : 0;
        $do_down = ($current_down != $applied_down
                    && (abs($current_down - $applied_down) >= $thr * $applied_down
                        || $current_down == $download_base_kbits)) ? 1 : 0;
        return unless $do_up || $do_down;
    }
    apply_rates($current_up, $current_down, $do_up, $do_down);
}

# Drop smoothing/latency history after a config reload so old samples don't leak in
sub reset_runtime_state {
    @lat_window_up   = ();
    @lat_window_down = ();
    undef $ewma_up;
    undef $ewma_down;
    %rs              = (up => _new_rate_state(), down => _new_rate_state());
    $measured_up_kbps   = 0;
    $measured_down_kbps = 0;
    $trigger_hits_up = 0;
    $trigger_hits_down = 0;
    $cap_hit_cycles  = 0;
    @recent_raw      = ();
    %hold_until      = (up => 0, down => 0);
    %trouble_rate    = ();
    %trouble_seen    = (up => 0, down => 0);
    $probe_failing   = 0;
    $probe_counted   = 0;
    undef $probe_busy_since;
    $last_good_ts    = now();
}

# A cycle without any usable reply. Returns undef (hold the rates) or the latency to act on.
#  - A short gap is most likely a glitch on the path (a cycle's median needs 2 of 3 probes): hold.
#  - A long one while a direction carries traffic is what a deep queue or a link that lost its capacity
#    looks like: replies come later than the timeout, or not at all. The controller must not stay blind
#    then, so after probe_blackout_s a missing reply counts as a reading of the timeout and the normal
#    decrease logic (per-direction load gate included) decides.
#  The clock only runs while a direction is loaded: a reflector that was down while idle does not
#  throttle the first download that follows.
sub latency_after_failed_probes {
    my ($cur_up, $cur_down) = @_;
    my $t = now();
    $probe_failing = 1;

    my $busy = (util_pct($measured_up_kbps,   $cur_up)   >= $decrease_min_load_percent
             || util_pct($measured_down_kbps, $cur_down) >= $decrease_min_load_percent);
    if ($busy) { $probe_busy_since = $t unless defined $probe_busy_since; }
    else       { undef $probe_busy_since; }
    my $busy_gap = defined $probe_busy_since ? $t - $probe_busy_since : 0;

    if ($probe_blackout_s > 0 && defined $probe_busy_since && $busy_gap >= $probe_blackout_s) {
        my $worst = ($resolved_pinger eq "ping") ? 1000 * _probe_timeout_s() : $probe_timeout_ms;
        my $above = (($latency_high_up_ms > $latency_high_down_ms) ? $latency_high_up_ms : $latency_high_down_ms) + 1;
        my $lat   = ($worst > $above) ? $worst : $above;
        log_line(sprintf("Latency: no reply for %.1f s while loaded (%s); counting %d ms", $busy_gap, $probe_fail_detail, $lat), 2);
        $probe_counted = 1;
        return $lat;
    }
    log_line(sprintf("Latency: no usable reflector samples; holding rates (%s; silent %.1f s)", $probe_fail_detail, $t - $last_good_ts), 2);
    return undef;
}

while ($running) {
    $cycle++;

    if ($reload_requested) {
        my ($old_base_up, $old_base_down) = ($upload_base_kbits, $download_base_kbits);
        if (eval { load_config(); 1 }) {
            reset_runtime_state();
            # New base -> start from it; otherwise just re-clamp into [floor, base]
            $current_up   = ($upload_base_kbits != $old_base_up)
                ? $upload_base_kbits
                : _clamp($current_up,   int($upload_base_kbits   * $upload_min   / 100.0), $upload_base_kbits);
            $current_down = ($download_base_kbits != $old_base_down)
                ? $download_base_kbits
                : _clamp($current_down, int($download_base_kbits * $download_min / 100.0), $download_base_kbits);
            maybe_apply(1);   # take effect now, not after the calm window
        } else {
            log_line("Reload failed; keeping previous config", 1);
        }
        $reload_requested = 0;
    }

    update_intervals();

    # ICMP RTT cannot separate directions, so probe once and use it for both;
    # per-direction decisions come from per-direction load instead.
    my $lat = measure_latency("both");
    my $loaded_any = 0;

    if (defined $lat) {
        if ($probe_failing) {
            log_line(sprintf("Latency: replies are back after %.1f s without usable samples", now() - $last_good_ts), 2);
            $probe_failing = 0;
        }
        if ($probe_counted) {
            # The timeout readings fed to the filters were stand-ins; the real latency is known again.
            # Without this they would keep the filtered latency high (and the decreases going) for a cycle or two.
            @lat_window_up = (); @lat_window_down = ();
            undef $ewma_up; undef $ewma_down;
            @recent_raw = ();
            $probe_counted = 0;
        }
        undef $probe_busy_since;
        $last_good_ts = now();
    } else {
        $lat = latency_after_failed_probes($current_up, $current_down);   # undef = hold the rates
    }

    if (defined $lat) {
        $avg_lat_up   = smooth_latency("up",   $lat);
        $avg_lat_down = smooth_latency("down", $lat);

        my $loaded_up   = (util_pct($measured_up_kbps,   $current_up)   >= $decrease_min_load_percent) ? 1 : 0;
        my $loaded_down = (util_pct($measured_down_kbps, $current_down) >= $decrease_min_load_percent) ? 1 : 0;
        $loaded_any = ($loaded_up || $loaded_down);

        if ($adaptive_floor) {
            adaptive_floor_logic($avg_lat_up, $avg_lat_down, $loaded_up, $loaded_down);
        }

        # Calm-window guard
        if (!calm_window_guard()) {
            ($current_up, $current_down) = adjust_rates($avg_lat_up, $avg_lat_down, $current_up, $current_down);
            isp_cap_check($current_up, $current_down, $avg_lat_up, $avg_lat_down);
            maybe_apply(0);
        }
    }

# --- Logging control ---
if ($log_enabled) {
    my $mup   = $measured_up_kbps;
    my $mdown = $measured_down_kbps;

    if ($log_mode == 0) {
        # Silent mode
    }
    elsif ($log_mode == 1) {
        # Event-driven logging
        my $thr = $log_change_threshold_percent / 100.0;
        my $up_change   = ($last_up == 0)   ? 1 : abs($current_up   - $last_up)   / $last_up;
        my $down_change = ($last_down == 0) ? 1 : abs($current_down - $last_down) / $last_down;
        my $floorU_diff = ($upload_min   != $last_floorU);
        my $floorD_diff = ($download_min != $last_floorD);

        if ($up_change > $thr || $down_change > $thr) {
            if ($log_format eq "json") {
                my $json = sprintf(
                    '{"event":"rate_change","cycle":%d,"shaper_up":%dk,"shaper_down":%dk,"latency":{"up":%.1f,"down":%.1f},"measured_up":%dk,"measured_down":%dk,"floors":{"up":%d%%,"down":%d%%}}',
                    $cycle, $current_up, $current_down, $avg_lat_up, $avg_lat_down,
                    $mup, $mdown, $upload_min, $download_min
                );
                log_line($json, 1);
            } else {
                log_line(sprintf(
                    "RATE CHANGE: shaper_up=%dk shaper_down=%dk lat_up=%.1fms lat_down=%.1fms measured_up=%dk measured_down=%dk floors=%u%%/%u%%",
                    $current_up, $current_down, $avg_lat_up, $avg_lat_down,
                    $mup, $mdown, $upload_min, $download_min
                ), 1);
            }
            $last_up     = $current_up;
            $last_down   = $current_down;
            $last_floorU = $upload_min;
            $last_floorD = $download_min;
        }
    }
    elsif ($log_mode == 2) {
        # Tick-driven logging (every cycle)
        if ($log_format eq "json") {
            my $json = sprintf(
                '{"event":"tick","cycle":%d,"shaper_up":%dk,"shaper_down":%dk,"latency":{"up":%.1f,"down":%.1f},"measured_up":%dk,"measured_down":%dk,"floors":{"up":%d%%,"down":%d%%}}',
                $cycle, $current_up, $current_down, $avg_lat_up, $avg_lat_down,
                $mup, $mdown, $upload_min, $download_min
            );
            log_line($json, 2);
        } else {
            log_line(sprintf(
                "TICK: shaper_up=%dk shaper_down=%dk lat_up=%.1fms lat_down=%.1fms measured_up=%dk measured_down=%dk floors=%u%%/%u%%",
                $current_up, $current_down, $avg_lat_up, $avg_lat_down,
                $mup, $mdown, $upload_min, $download_min
            ), 2);
        }
    }
}

    # Elastic probing: probe faster only while a direction is loaded AND latency is
    # jittery or above the low threshold; never faster than probe_min_ms.
    my $sleep_ms = $probe_ms;
    if ($elastic_probe && defined $lat) {
        push @recent_raw, $lat;
        shift @recent_raw if @recent_raw > 4;
        my ($mn, $mx) = ($recent_raw[0], $recent_raw[0]);
        for (@recent_raw) { $mn = $_ if $_ < $mn; $mx = $_ if $_ > $mx; }
        if ($loaded_any && (($mx - $mn) > $variance_thresh_ms
                            || $avg_lat_up   > $latency_low_up_ms
                            || $avg_lat_down > $latency_low_down_ms)) {
            $sleep_ms = $probe_fast_ms;
        }
    }
    $sleep_ms = $probe_min_ms if $sleep_ms < $probe_min_ms;
    select(undef, undef, undef, $sleep_ms / 1000.0);
}

# ------------- Cleanup and shutdown -------------
sub cleanup {
    log_line("Cleaning up before exit", 1);
    remove_pidfile();

    # Reset shaper to base rates
    apply_rates($upload_base_kbits, $download_base_kbits);

    # Log final latency values if available
    my $final_lat_up   = defined $ewma_up   ? sprintf("%.1f", $ewma_up)   : "n/a";
    my $final_lat_down = defined $ewma_down ? sprintf("%.1f", $ewma_down) : "n/a";

    log_line(sprintf(
        "Final state before exit: shaper_up=%dk shaper_down=%dk floors=%u%%/%u%% lat_up=%sms lat_down=%sms",
        $upload_base_kbits, $download_base_kbits,
        $upload_min, $download_min,
        $final_lat_up, $final_lat_down
    ), 1);

    # Echo active logging format and mode at shutdown
    log_line("Logging format used during run: $log_format (mode=$log_mode)", 1);

    log_line("Daemon stopped after $cycle cycles", 1);
}

END { cleanup(); }
