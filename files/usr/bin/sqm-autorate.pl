#!/usr/bin/env perl
use strict;
use warnings;
use POSIX qw(strftime);
use IO::Handle;
use Fcntl ':flock';
use IPC::Open3;
use Symbol 'gensym';
eval { require File::Which; import File::Which 'which'; };

# ------------- Paths and files -------------
my $CONFIG_FILE   = $ENV{"CONFIG"} // "/var/sqm-autorate.conf";
my $PIDFILE       = "/var/run/sqm-autorate.pid";
my $LOGFILE       = "/var/log/sqm-autorate.log";

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
my $probe_setuid_fix = 1;                # allow setuid adjustment if needed

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
my $load_bias_threshold_bytes  = 20000000;  # ~20 MB per cycle

# ------------- ISP cap detection (robust) -------------
my $cap_trigger_cycles    = 12;
my $cap_threshold_percent = 95;

# ------------- Internal state -------------
my $running            = 1;
my $reload_requested   = 0;
my $cycle              = 0;

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

# Per-interval load (bytes) and previous counters
my $bytes_interval_up    = 0;
my $bytes_interval_down  = 0;
my $prev_tx_upload       = 0;
my $prev_rx_download     = 0;
my $counters_initialized = 0;

# Which qdisc stats to parse (nsstbl or nssfq_codel) - NSS only
my $qdisc_stats = "nsstbl";

# --- Throughput smoothing ---
# Choose between "average" or "ewma"
my $rate_filter = "average";   # default, can be overridden in config
my $smooth_size = 3;           # window size for average mode (>=1)
my $alpha_rate  = 0.4;         # EWMA weight (0.0–1.0)
my @smooth_up   = ();
my @smooth_down = ();
my $ewma_up_rate   = 0;
my $ewma_down_rate = 0;

# Measured rates using actual elapsed time (set in update_intervals)
our $measured_up_kbps   = 0;
our $measured_down_kbps = 0;
my $last_ts = time();

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
    if (system("ip link show $upload_if >/dev/null 2>&1") != 0) {
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
    $upload_min   = _clamp($upload_min_percent,   $adaptive_floor_min, $adaptive_floor_max);
    $download_min = _clamp($download_min_percent, $adaptive_floor_min, $adaptive_floor_max);

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

    # Load-aware
    $load_aware                 = int($cfg{"load_aware"} // $load_aware);
    $load_bias_decrease         = int($cfg{"load_bias_decrease"} // $load_bias_decrease);
    $load_bias_threshold_bytes  = int($cfg{"load_bias_threshold_bytes"} // $load_bias_threshold_bytes);
    
    # Calm-window guard
    $calm_window_cycles = int($cfg{"calm_window_cycles"} // $calm_window_cycles);
    $calm_window_cycles = _clamp($calm_window_cycles, 0, 100);
    $calm_window_active = $calm_window_cycles;  # reset on reload

    # ISP cap detection
    $cap_trigger_cycles    = int($cfg{"cap_trigger_cycles"}    // $cap_trigger_cycles);
    $cap_threshold_percent = int($cfg{"cap_threshold_percent"} // $cap_threshold_percent);
    $cap_threshold_percent = _clamp($cap_threshold_percent, 1, 100);

    # --- Throughput smoothing options ---
    $rate_filter = $cfg{"rate_filter"} // $rate_filter;
    $rate_filter = _validate_choice($rate_filter, "average", "ewma");
    $alpha_rate  = 0.0 + ($cfg{"alpha_rate"} // $alpha_rate);
    $alpha_rate  = _clamp($alpha_rate, 0.0, 1.0);
    $smooth_size = int($cfg{"smooth_size"} // $smooth_size);
    $smooth_size = _clamp($smooth_size, 1, 50);

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

    # --- Config reload summary ---
    log_line("Reloaded config from $CONFIG_FILE", 1);
    log_line("Interfaces: upload_if=$upload_if (egress), download_if=$download_if (ignored; NSS ingress via nssifb)", 2);
    log_line("Qdisc stats source: $qdisc_stats", 2);
    log_line("Throughput smoothing: filter=$rate_filter alpha=$alpha_rate window=$smooth_size", 2);
    if ($latency_filter eq "ewma") {
        log_line("Latency smoothing: filter=$latency_filter window=$latency_window_size alpha_ewma=$alpha_ewma", 2);
    } else {
        log_line("Latency smoothing: filter=$latency_filter window=$latency_window_size", 2);
    }
    log_line("Pinger: method=$pinger_method resolved=$resolved_pinger reflectors=".(join(",",@reflectors)), 2);
    log_line("Rates base: up=${upload_base_kbits}k down=${download_base_kbits}k floors=${upload_min}%/${download_min}%", 2);
    log_line("Latency thresholds: up ${latency_low_up_ms}/${latency_high_up_ms} ms, down ${latency_low_down_ms}/${latency_high_down_ms} ms", 2);
    log_line("Logging format active: $log_format (mode=$log_mode)", 1);
}

# ------------- PID file management -------------

sub write_pidfile {
    open my $pfh, ">", $PIDFILE or do {
        log_line("PID: failed to write $PIDFILE", 0);
        return;
    };
    if (!flock($pfh, LOCK_EX|LOCK_NB)) {
        log_line("PID: another instance appears to be running", 0);
        close $pfh;
        exit 1;
    }
    print $pfh $$;
    close $pfh;
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

log_line("Startup complete; entering main loop", 1);

# ------------- Interface counter helpers (strict NSS) -------------

# Read bytes sent from NSS root (nsstbl) or child (nssfq_codel)
sub read_qdisc_bytes_nss {
    my ($iface, $kind) = @_;
    my $out = `tc -s qdisc show dev $iface 2>/dev/null`;

    if ($kind eq "nsstbl") {
        # root aggregate on eth0 / nssifb
        if ($out =~ /qdisc\s+nsstbl\s+\S+:\s+dev\s+\Q$iface\E\s+root.*?\n\s*Sent\s+(\d+)\s+bytes/s) {
            return int($1);
        }
    } elsif ($kind eq "nssfq_codel") {
        # child fairness scheduler under nsstbl (parent 1:) on eth0 / nssifb
        if ($out =~ /qdisc\s+nssfq_codel\s+\S+:\s+dev\s+\Q$iface\E\s+parent\s+1:.*?\n\s*Sent\s+(\d+)\s+bytes/s) {
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

    # Timing
    my $now     = time();
    my $elapsed = $now - $last_ts;
    $last_ts    = $now;
    $elapsed    = 1 if $elapsed <= 0;

    # First run: initialize baselines
    if (!$counters_initialized) {
        $prev_tx_upload       = $tx_now;
        $prev_rx_download     = $rx_now;
        $counters_initialized = 1;
        $bytes_interval_up    = 0;
        $bytes_interval_down  = 0;
        return;
    }

    # Compute deltas against the exact same sources chosen this cycle
    my $delta_up   = $tx_now - $prev_tx_upload;
    my $delta_down = $rx_now - $prev_rx_download;

    # Guard against wrap/negative deltas
    $delta_up   = 0 if $delta_up   < 0;
    $delta_down = 0 if $delta_down < 0;

    # Update previous to the exact current used
    $prev_tx_upload   = $tx_now;
    $prev_rx_download = $rx_now;

    # Smooth deltas
    if ($rate_filter eq "average") {
        push @smooth_up,   $delta_up;
        push @smooth_down, $delta_down;

        shift @smooth_up   if @smooth_up   > $smooth_size;
        shift @smooth_down if @smooth_down > $smooth_size;

        my $avg_up   = 0; $avg_up   += $_ for @smooth_up;
        my $avg_down = 0; $avg_down += $_ for @smooth_down;

        $bytes_interval_up   = @smooth_up   ? int($avg_up   / @smooth_up)   : 0;
        $bytes_interval_down = @smooth_down ? int($avg_down / @smooth_down) : 0;

    } else { # ewma
        if ($ewma_up_rate   == 0) { $ewma_up_rate   = $delta_up;   }
        if ($ewma_down_rate == 0) { $ewma_down_rate = $delta_down; }
        $ewma_up_rate   = ($alpha_rate * $delta_up)   + ((1 - $alpha_rate) * $ewma_up_rate);
        $ewma_down_rate = ($alpha_rate * $delta_down) + ((1 - $alpha_rate) * $ewma_down_rate);

        $bytes_interval_up   = int($ewma_up_rate);
        $bytes_interval_down = int($ewma_down_rate);
    }

    # Convert to kbps using actual elapsed time
    $measured_up_kbps   = int(($bytes_interval_up   * 8) / $elapsed / 1000);
    $measured_down_kbps = int(($bytes_interval_down * 8) / $elapsed / 1000);

    # Optional debug: show chosen sources and raw deltas at level 2
    log_line(sprintf("Counters: up_src=%s down_src=%s delta_up=%d delta_down=%d", $up_src, $down_src, $delta_up, $delta_down), 2);
}

# ------------- Latency measurement (robust multi-reflector) -------------

sub run_cmd {
    my @cmd = @_;
    my $err = gensym;
    local *OUT;
    my $pid = open3(undef, \*OUT, $err, @cmd);
    my $output = do { local $/; <OUT> };
    close(OUT);
    waitpid($pid, 0);
    return $output // "";
}

sub _ping_once {
    my ($tool, $target) = @_;
    if ($tool eq "fping") {
        my $out = run_cmd("fping", "-c1", "-t100", $target);
        return $1 if $out =~ /(\d+\.\d+)\s*ms/;
    } elsif ($tool eq "ping") {
        my $out = run_cmd("ping", "-c1", "-W1", $target);
        return $1 if $out =~ /time=(\d+\.\d+)/;
    }
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
    foreach my $target (@targets) {
        my $lat = ($tool ne "") ? _ping_once($tool, $target) : undef;
        push @sampled, defined $lat ? $lat : 999;
    }

    if (!@sampled) {
        log_line("Latency measurement failed: no valid samples from reflectors", 1);
        return 999;
    }

    @sampled = sort { $a <=> $b } @sampled;
    my $mid = int(@sampled/2);
    my $median = $sampled[$mid];
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
    my ($avg_lat_up, $avg_lat_down) = @_;

    if ($avg_lat_up > $adaptive_floor_trigger_ms) {
        $trigger_hits_up++;
        if ($trigger_hits_up >= $adaptive_floor_trigger_count) {
            $upload_min += $adaptive_floor_step;
            $upload_min = $adaptive_floor_max if $upload_min > $adaptive_floor_max;
            $trigger_hits_up = 0;
            log_line("Adaptive floor raised (upload_min=$upload_min)", 2);
        }
    }

    if ($avg_lat_down > $adaptive_floor_trigger_ms) {
        $trigger_hits_down++;
        if ($trigger_hits_down >= $adaptive_floor_trigger_count) {
            $download_min += $adaptive_floor_step;
            $download_min = $adaptive_floor_max if $download_min > $adaptive_floor_max;
            $trigger_hits_down = 0;
            log_line("Adaptive floor raised (download_min=$download_min)", 2);
        }
    }

    if ($cycle - $last_decay_cycle >= $adaptive_floor_decay_interval) {
        $upload_min   -= $adaptive_floor_decay_step;
        $download_min -= $adaptive_floor_decay_step;
        $upload_min   = $adaptive_floor_min if $upload_min   < $adaptive_floor_min;
        $download_min = $adaptive_floor_min if $download_min < $adaptive_floor_min;
        $last_decay_cycle = $cycle;
        log_line("Adaptive floor decayed (upload_min=$upload_min, download_min=$download_min)", 2);
    }
}

# ------------- Rate adjustment logic -------------

sub adjust_rates {
    my ($avg_lat_up, $avg_lat_down, $current_up, $current_down) = @_;

    if ($avg_lat_up > $latency_high_up_ms) {
        $current_up = int($current_up * (1 - $decrease_rate_percent_up/100.0));
    } elsif ($avg_lat_up < $latency_low_up_ms) {
        $current_up = int($current_up * (1 + $increase_rate_percent_up/100.0));
    }

    if ($avg_lat_down > $latency_high_down_ms) {
        $current_down = int($current_down * (1 - $decrease_rate_percent_down/100.0));
    } elsif ($avg_lat_down < $latency_low_down_ms) {
        $current_down = int($current_down * (1 + $increase_rate_percent_down/100.0));
    }

    my $min_up_rate   = int($upload_base_kbits   * $upload_min/100.0);
    my $min_down_rate = int($download_base_kbits * $download_min/100.0);
    $current_up   = $min_up_rate   if $current_up   < $min_up_rate;
    $current_down = $min_down_rate if $current_down < $min_down_rate;

    if ($load_aware) {
        if ($bytes_interval_up > $load_bias_threshold_bytes) {
            $current_up = int($current_up * (1 - $load_bias_decrease/100.0));
            log_line("Load-aware bias applied to upload", 2);
        }
        if ($bytes_interval_down > $load_bias_threshold_bytes) {
            $current_down = int($current_down * (1 - $load_bias_decrease/100.0));
            log_line("Load-aware bias applied to download", 2);
        }
    }

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

    my $cap_load_min = $load_bias_threshold_bytes;

    my $load_ok    = ($bytes_interval_up >= $cap_load_min || $bytes_interval_down >= $cap_load_min);
    my $latency_ok = ($avg_lat_up <= $latency_high_up_ms && $avg_lat_down <= $latency_high_down_ms);

    if (($current_up >= $up_cap || $current_down >= $down_cap) && $load_ok && $latency_ok) {
        $cap_hit_cycles++;
        if ($cap_hit_cycles >= $cap_trigger_cycles && $cap_trigger_cycles > 0) {
            log_line("ISP cap suspected: sustained near-cap throughput with stable latency", 1);
            $cap_hit_cycles = 0;
        }
    } else {
        $cap_hit_cycles = 0;
    }
}

# ------------- Apply new rates (stub) -------------

sub apply_rates {
    my ($up_rate, $down_rate) = @_;
    # TODO: integrate with tc or sqm APIs
    log_line("Applied rates: up=${up_rate}k down=${down_rate}k", 2);
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

while ($running) {
    $cycle++;

    if ($reload_requested) {
        eval { load_config(); 1 } or log_line("Reload failed; keeping previous config", 1);
        $reload_requested = 0;
    }

    update_intervals();

    my $lat_up   = measure_latency("up");
    my $lat_down = measure_latency("down");

    my $avg_lat_up   = smooth_latency("up", $lat_up);
    my $avg_lat_down = smooth_latency("down", $lat_down);

    if ($adaptive_floor) {
        adaptive_floor_logic($avg_lat_up, $avg_lat_down);
    }

    # Calm-window guard
    if (!calm_window_guard()) {
        ($current_up, $current_down) = adjust_rates($avg_lat_up, $avg_lat_down, $current_up, $current_down);
        isp_cap_check($current_up, $current_down, $avg_lat_up, $avg_lat_down);
        apply_rates($current_up, $current_down);
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

        if ($up_change > $thr || $down_change > $thr || $floorU_diff || $floorD_diff) {
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

    select(undef, undef, undef, $probe_ms / 1000.0);
}

# ------------- Cleanup and shutdown -------------
sub cleanup {
    log_line("Cleaning up before exit", 1);
    remove_pidfile();

    # Reset floors to configured minimums
    $upload_min   = $upload_min_percent;
    $download_min = $download_min_percent;

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
