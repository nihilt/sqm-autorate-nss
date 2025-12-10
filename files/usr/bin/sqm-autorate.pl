#!/usr/bin/env perl
use strict;
use warnings;
use POSIX qw(strftime setsid);
use IO::Handle;
use Fcntl ':flock';

# ------------- Paths and files -------------
my $CONFIG_FILE   = $ENV{"CONFIG"} // "/var/sqm-autorate.conf";
my $PIDFILE       = "/var/run/sqm-autorate.pid";
my $LOGFILE       = "/var/log/sqm-autorate.log";

# ------------- Runtime toggles -------------
my $log_enabled   = 1;
my $log_level     = 1;
my $log_format    = "compact";

# --- Logging mode ---
# 0 = silent, 1 = event-driven, 2 = tick-driven
my $log_mode = 1;

# Track last logged values for event-driven mode
my $last_up     = 0;
my $last_down   = 0;
my $last_floorU = 0;
my $last_floorD = 0;

# ------------- Interfaces and pinger -------------
my $upload_if     = "";
my $download_if   = "";
my $pinger_method = "automatic";
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
my $probe_ms       = 250;
my $probe_fast_ms  = 150;
my $elastic_probe  = 1;
my $variance_thresh_ms = 3;

# ------------- Latency smoothing -------------
my $latency_filter      = "median";   # "median" or "ewma"
my $latency_window_size = 4;          # shorter window for responsiveness
my $alpha_ewma          = 0.4;        # used if latency_filter="ewma"

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

# Per-interval load (bytes) and previous counters
my $bytes_interval_up    = 0;
my $bytes_interval_down  = 0;
my $prev_tx_upload       = 0;
my $prev_rx_download     = 0;
my $counters_initialized = 0;

# Which qdisc stats to parse (nsstbl or nssfq_codel)
my $qdisc_stats = "nsstbl";

# --- Throughput smoothing ---
# Choose between "average" or "ewma"
my $rate_filter = "average";   # default, can be overridden in config
my $smooth_size = 3;           # window size for average mode
my $alpha_rate  = 0.4;         # EWMA weight (0.0–1.0)
my @smooth_up   = ();
my @smooth_down = ();
my $ewma_up_rate   = 0;
my $ewma_down_rate = 0;

# ------------- Logging helpers -------------

sub log_open {
    return unless $log_enabled;
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

sub log_compact_cycle {
    return unless $log_enabled && $log_format eq "compact";
    my ($up_rate, $down_rate, $lat_up, $lat_down) = @_;
    my $ts = strftime("%H:%M:%S", localtime);
    my $fh = log_open();
    return unless $fh;
    printf $fh "[%s] up=%dk down=%dk lat_up=%.1fms lat_down=%.1fms floors=%u%%/%u%%\n",
        $ts, $up_rate, $down_rate, $lat_up, $lat_down, $upload_min, $download_min;
    close $fh;
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

    # Interfaces
    $upload_if     = $cfg{"upload_interface"}   // $upload_if;
    $upload_if     = "eth0" if (!defined $upload_if || $upload_if eq "");
    $download_if   = $cfg{"download_interface"} // $download_if; # ignored for counters on NSS
    $pinger_method = $cfg{"pinger_method"}      // $pinger_method;

    # Qdisc stats source
    $qdisc_stats   = $cfg{"qdisc_stats"}        // "nsstbl";

    if (defined $cfg{"reflectors"}) {
        my $list = $cfg{"reflectors"};
        @reflectors = grep { $_ ne "" } split(/\s+/, $list);
        @reflectors = map { s/['"]//g; $_ } @reflectors;
        @reflectors = ('1.1.1.1') unless @reflectors;
    }

    $reflector_count    = int($cfg{"reflector_count"} // $reflector_count);
    $reflector_rotation = $cfg{"reflector_rotation"} // $reflector_rotation;

    $log_enabled = int($cfg{"log_enabled"} // $log_enabled);
    $log_level   = int($cfg{"log_level"}   // $log_level);
    $log_format  = $cfg{"log_format"}      // $log_format;
    $log_mode    = int($cfg{"log_mode"}    // $log_mode);

    $upload_base_kbits   = int($cfg{"upload_base_kbits"}   // $upload_base_kbits);
    $download_base_kbits = int($cfg{"download_base_kbits"} // $download_base_kbits);

    $upload_min_percent   = int($cfg{"upload_min_percent"}   // $upload_min_percent);
    $download_min_percent = int($cfg{"download_min_percent"} // $download_min_percent);
    $upload_min   = $upload_min_percent;
    $download_min = $download_min_percent;

    $latency_low_up_ms     = int($cfg{"latency_low_up_ms"}     // $latency_low_up_ms);
    $latency_high_up_ms    = int($cfg{"latency_high_up_ms"}    // $latency_high_up_ms);
    $latency_low_down_ms   = int($cfg{"latency_low_down_ms"}   // $latency_low_down_ms);
    $latency_high_down_ms  = int($cfg{"latency_high_down_ms"}  // $latency_high_down_ms);

    $probe_ms        = int($cfg{"probe_ms"}        // $probe_ms);
    $probe_fast_ms   = int($cfg{"probe_fast_ms"}   // $probe_fast_ms);
    $elastic_probe   = int($cfg{"elastic_probe"}   // $elastic_probe);
    $variance_thresh_ms = int($cfg{"variance_thresh_ms"} // $variance_thresh_ms);

    $latency_filter      = $cfg{"latency_filter"}      // $latency_filter;
    $latency_window_size = int($cfg{"latency_window_size"} // $latency_window_size);
    $alpha_ewma          = 0.0 + ($cfg{"alpha_ewma"} // $alpha_ewma);

    $increase_rate_percent_up    = int($cfg{"increase_rate_percent_up"}    // $increase_rate_percent_up);
    $decrease_rate_percent_up    = int($cfg{"decrease_rate_percent_up"}    // $decrease_rate_percent_up);
    $increase_rate_percent_down  = int($cfg{"increase_rate_percent_down"}  // $increase_rate_percent_down);
    $decrease_rate_percent_down  = int($cfg{"decrease_rate_percent_down"}  // $decrease_rate_percent_down);

    $adaptive_floor                 = int($cfg{"adaptive_floor"} // $adaptive_floor);
    $adaptive_floor_step            = int($cfg{"adaptive_floor_step"} // $adaptive_floor_step);
    $adaptive_floor_min             = int($cfg{"adaptive_floor_min"}  // $adaptive_floor_min);
    $adaptive_floor_max             = int($cfg{"adaptive_floor_max"}  // $adaptive_floor_max);
    $adaptive_floor_trigger_ms      = int($cfg{"adaptive_floor_trigger_ms"} // $adaptive_floor_trigger_ms);
    $adaptive_floor_trigger_count   = int($cfg{"adaptive_floor_trigger_count"} // $adaptive_floor_trigger_count);
    $adaptive_floor_decay_interval  = int($cfg{"adaptive_floor_decay_interval"} // $adaptive_floor_decay_interval);
    $adaptive_floor_decay_step      = int($cfg{"adaptive_floor_decay_step"} // $adaptive_floor_decay_step);

    $load_aware                 = int($cfg{"load_aware"} // $load_aware);
    $load_bias_decrease         = int($cfg{"load_bias_decrease"} // $load_bias_decrease);
    $load_bias_threshold_bytes  = int($cfg{"load_bias_threshold_bytes"} // $load_bias_threshold_bytes);

    $cap_trigger_cycles    = int($cfg{"cap_trigger_cycles"}    // $cap_trigger_cycles);
    $cap_threshold_percent = int($cfg{"cap_threshold_percent"} // $cap_threshold_percent);

    # --- Throughput smoothing options ---
    $rate_filter = $cfg{"rate_filter"} // $rate_filter;
    $alpha_rate  = 0.0 + ($cfg{"alpha_rate"} // $alpha_rate);
    $smooth_size = int($cfg{"smooth_size"} // $smooth_size);

    log_line("Reloaded config from $CONFIG_FILE", 1);
    log_line("Interfaces: upload_if=$upload_if (egress), download_if=$download_if (ignored; NSS ingress uses nssifb)", 2);
    log_line("Qdisc stats source: $qdisc_stats", 2);
    log_line("Throughput smoothing: filter=$rate_filter alpha=$alpha_rate window=$smooth_size", 2);
    log_line("Pinger: method=$pinger_method reflectors=".(join(",",@reflectors)), 2);
    log_line("Rates base: up=${upload_base_kbits}k down=${download_base_kbits}k floors=${upload_min}%/${download_min}%", 2);
    log_line("Latency thresholds: up ${latency_low_up_ms}/${latency_high_up_ms} ms, down ${latency_low_down_ms}/${latency_high_down_ms} ms", 2);
}

# ------------- Interface counter helpers -------------

# Parse "Sent <bytes> ..." from tc -s qdisc output
sub read_qdisc_bytes {
    my ($iface, $qdisc) = @_;
    my $out = `tc -s qdisc show dev $iface 2>/dev/null`;

    # If user specified a qdisc (e.g. nssfq_codel), match that line
    if ($qdisc && $out =~ /qdisc\s+$qdisc.*?\n\s*Sent\s+(\d+)\s+bytes/) {
        return int($1);
    }

    # Otherwise, default to root nsstbl stats
    if ($out =~ /qdisc\s+nsstbl.*?\n\s*Sent\s+(\d+)\s+bytes/) {
        return int($1);
    }

    return 0;
}

sub update_intervals {
    # Upload: physical WAN interface (eth0)
    my $tx_now = read_qdisc_bytes($upload_if, $qdisc_stats);

    # Download: NSS ingress mirror (nssifb)
    my $rx_now = read_qdisc_bytes("nssifb", $qdisc_stats);

    if (!$counters_initialized) {
        $prev_tx_upload   = $tx_now;
        $prev_rx_download = $rx_now;
        $counters_initialized = 1;
        $bytes_interval_up   = 0;
        $bytes_interval_down = 0;
        return;
    }

    # Raw deltas since last cycle
    my $delta_up   = $tx_now - $prev_tx_upload;
    my $delta_down = $rx_now - $prev_rx_download;

    $prev_tx_upload   = $tx_now;
    $prev_rx_download = $rx_now;

    # --- Smoothing ---
    if ($rate_filter eq "average") {
        # Simple moving average over last $smooth_size cycles
        push @smooth_up,   $delta_up;
        push @smooth_down, $delta_down;

        shift @smooth_up   if @smooth_up   > $smooth_size;
        shift @smooth_down if @smooth_down > $smooth_size;

        my $avg_up   = 0; $avg_up   += $_ for @smooth_up;
        my $avg_down = 0; $avg_down += $_ for @smooth_down;

        $bytes_interval_up   = int($avg_up   / @smooth_up);
        $bytes_interval_down = int($avg_down / @smooth_down);

    } elsif ($rate_filter eq "ewma") {
        # Exponential weighted moving average
        $ewma_up_rate   = ($alpha_rate * $delta_up)   + ((1 - $alpha_rate) * $ewma_up_rate);
        $ewma_down_rate = ($alpha_rate * $delta_down) + ((1 - $alpha_rate) * $ewma_down_rate);

        $bytes_interval_up   = int($ewma_up_rate);
        $bytes_interval_down = int($ewma_down_rate);
    }
}

# ------------- Latency measurement (robust multi-reflector) -------------

use IPC::Open3;
use Symbol 'gensym';
eval { require File::Which; import File::Which 'which'; };

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

sub _have_cmd {
    my ($cmd) = @_;
    if (defined(&which)) {
        return !!which($cmd);
    } else {
        return (system("$cmd --version >/dev/null 2>&1") == 0);
    }
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

    foreach my $bin ("/usr/bin/fping", "/bin/ping", "/usr/bin/irtt") {
        if (-x $bin) {
            my $mode = (stat($bin))[2];
            if (!($mode & 04000)) {
                log_line("Applying setuid to $bin for probe access", 1);
                system("chmod u+s $bin");
            }
        }
    }

    foreach my $target (@targets) {
        my $lat;
        if ($pinger_method eq "fping" || ($pinger_method eq "automatic" && _have_cmd("fping"))) {
            my $out = run_cmd("fping", "-c1", "-t100", $target);
            if ($out =~ /(\d+\.\d+)\s*ms/) { $lat = $1; }
        }
        elsif ($pinger_method eq "ping" || ($pinger_method eq "automatic" && _have_cmd("ping"))) {
            my $out = run_cmd("ping", "-c1", "-W1", $target);
            if ($out =~ /time=(\d+\.\d+)/) { $lat = $1; }
        }
        elsif ($pinger_method eq "irtt" || ($pinger_method eq "automatic" && _have_cmd("irtt"))) {
            my $out = run_cmd("irtt", "client", "-d", "1s", $target);
            if ($out =~ /min=(\d+\.\d+)\s*ms/) { $lat = $1; }
        }
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

# ------------- PID file management -------------

sub write_pidfile {
    open my $pfh, ">", $PIDFILE or do {
        log_line("PID: failed to write $PIDFILE", 0);
        return;
    };
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

if (!-w $LOGFILE) {
    my $dir = "/var/log";
    unless (-d $dir) {
        mkdir $dir or warn "Failed to create $dir: $!";
    }
    open my $fh, ">>", $LOGFILE or warn "Cannot open $LOGFILE for writing: $!";
    close $fh;
}

log_line("Startup complete; entering main loop", 1);

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

    # Clamp to base values to avoid runaway
    $current_up   = $upload_base_kbits   if $current_up   > $upload_base_kbits;
    $current_down = $download_base_kbits if $current_down > $download_base_kbits;

    return ($current_up, $current_down);
}

# ------------- ISP cap detection (robust) -------------
my $cap_hit_cycles = 0;

sub isp_cap_check {
    my ($current_up, $current_down, $avg_lat_up, $avg_lat_down) = @_;

    my $up_cap   = int($upload_base_kbits   * $cap_threshold_percent/100.0);
    my $down_cap = int($download_base_kbits * $cap_threshold_percent/100.0);

    # Require meaningful load before considering cap detection
    my $cap_load_min = $load_bias_threshold_bytes;

    my $load_ok = ($bytes_interval_up >= $cap_load_min || $bytes_interval_down >= $cap_load_min);
    my $latency_ok = ($avg_lat_up <= $latency_high_up_ms && $avg_lat_down <= $latency_high_down_ms);

    if (($current_up >= $up_cap || $current_down >= $down_cap)
        && $load_ok
        && $latency_ok) {

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
    # In production, use tc or sqm APIs to set shaper rates.
    log_line("Applied rates: up=${up_rate}k down=${down_rate}k", 2);
}

# ------------- Main loop -------------
my $current_up   = $upload_base_kbits;
my $current_down = $download_base_kbits;

while ($running) {
    $cycle++;

    if ($reload_requested) {
        load_config();
        $reload_requested = 0;
    }

    # Update measured load from interface counters
    update_intervals();

    # Measure latency using robust multi-reflector pinger
    my $lat_up   = measure_latency("up");
    my $lat_down = measure_latency("down");

    # Smooth latency
    my $avg_lat_up   = smooth_latency("up", $lat_up);
    my $avg_lat_down = smooth_latency("down", $lat_down);

    # Adaptive floor logic
    if ($adaptive_floor) {
        adaptive_floor_logic($avg_lat_up, $avg_lat_down);
    }

    # Adjust rates
    ($current_up, $current_down) = adjust_rates($avg_lat_up, $avg_lat_down, $current_up, $current_down);

    # ISP cap detection (robust)
    isp_cap_check($current_up, $current_down, $avg_lat_up, $avg_lat_down);

    # Apply rates
    apply_rates($current_up, $current_down);

    # --- Logging control ---
    if ($log_enabled) {
        my $measured_up_kbps   = int(($bytes_interval_up * 8) / ($probe_ms/1000.0) / 1000);
        my $measured_down_kbps = int(($bytes_interval_down * 8) / ($probe_ms/1000.0) / 1000);

        if ($log_mode == 0) {
            # Silent mode
        }
        elsif ($log_mode == 1) {
            # Event-driven: log only when rates/floors change >2%
            my $up_change   = ($last_up == 0) ? 1 : abs($current_up - $last_up) / $last_up;
            my $down_change = ($last_down == 0) ? 1 : abs($current_down - $last_down) / $last_down;
            my $floorU_diff = ($upload_min   != $last_floorU);
            my $floorD_diff = ($download_min != $last_floorD);

            if ($up_change > 0.02 || $down_change > 0.02 || $floorU_diff || $floorD_diff) {
                if ($log_format eq "compact") {
                    log_line(sprintf(
                        "RATE CHANGE: shaper_up=%dk shaper_down=%dk measured_up=%dk measured_down=%dk floors=%u%%/%u%%",
                        $current_up, $current_down, $measured_up_kbps, $measured_down_kbps,
                        $upload_min, $download_min
                    ), 1);
                } else {
                    log_line(sprintf(
                        "RATE CHANGE: shaper_up=%dk shaper_down=%dk measured_up=%dk measured_down=%dk floors=%u%%/%u%% lat_up=%.1fms lat_down=%.1fms",
                        $current_up, $current_down, $measured_up_kbps, $measured_down_kbps,
                        $upload_min, $download_min, $avg_lat_up, $avg_lat_down
                    ), 1);
                }
                $last_up     = $current_up;
                $last_down   = $current_down;
                $last_floorU = $upload_min;
                $last_floorD = $download_min;
            }
        }
        else {
            # Tick-driven
            log_line(sprintf(
                "TICK: shaper_up=%dk shaper_down=%dk measured_up=%dk measured_down=%dk floors=%u%%/%u%% lat_up=%.1fms lat_down=%.1fms",
                $current_up, $current_down, $measured_up_kbps, $measured_down_kbps,
                $upload_min, $download_min, $avg_lat_up, $avg_lat_down
            ), 1);
        }
    }

    # Sleep until next probe
    my $interval = $probe_ms;
    if ($elastic_probe && abs($lat_up - $avg_lat_up) > $variance_thresh_ms) {
        $interval = $probe_fast_ms;
    }
    select(undef, undef, undef, $interval/1000.0);
}

# ------------- Cleanup and shutdown -------------

sub cleanup {
    log_line("Cleaning up before exit", 1);
    remove_pidfile();

    # Reset floors to configured minimums
    $upload_min   = $upload_min_percent;
    $download_min = $download_min_percent;

    # Reset shaper to base rates (stub)
    apply_rates($upload_base_kbits, $download_base_kbits);
}

END {
    cleanup();
}

# ------------- Exit message -------------

log_line("Daemon stopped after $cycle cycles", 1);

exit 0;
