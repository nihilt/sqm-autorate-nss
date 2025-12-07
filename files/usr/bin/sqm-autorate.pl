#!/usr/bin/perl
use strict;
use warnings;
use Time::HiRes qw(usleep);
use POSIX qw(SIGHUP);

# --- Config ---
my $config_file = "/var/sqm-autorate.conf";
my %cfg = ();

sub load_config {
    %cfg = ();
    open(my $fh, "<", $config_file) or die "Cannot open $config_file: $!";
    while (<$fh>) {
        chomp;
        next if /^#/ || /^\s*$/;
        if (/^([^=]+)=(.+)$/) {
            my ($k, $v) = ($1, $2);
            $v =~ s/\s+#.*$//;          # strip inline comments
            $v =~ s/^\s+|\s+$//g;       # trim
            $v =~ s/^"(.*)"$/$1/;       # strip quotes
            $v =~ s/^'(.*)'$/$1/;
            $cfg{$k} = $v;
        }
    }
    close($fh);
}

# LOAD CONFIG NOW
load_config();

# --- Base values ---
my $upload_base   = $cfg{"upload_base_kbits"}   // 85000;
my $download_base = $cfg{"download_base_kbits"} // 830000;

# Floors
my $upload_min_pct   = $cfg{"upload_min_percent"}   // 50;
my $download_min_pct = $cfg{"download_min_percent"} // 55;
my $upload_min   = int($upload_base   * $upload_min_pct   / 100);
my $download_min = int($download_base * $download_min_pct / 100);

# Current rates
my $up_rate   = $upload_base;
my $down_rate = $download_base;

# --- Thresholds ---
my $low_up    = $cfg{"delay_low_target_up"}    // 8;
my $high_up   = $cfg{"delay_high_target_up"}   // 20;
my $low_down  = $cfg{"delay_low_target_down"}  // 8;
my $high_down = $cfg{"delay_high_target_down"} // 20;

# --- Percentages ---
my $inc_up    = $cfg{"increase_rate_percent_up"}   // 2;
my $dec_up    = $cfg{"decrease_rate_percent_up"}   // 5;
my $inc_down  = $cfg{"increase_rate_percent_down"} // 2;
my $dec_down  = $cfg{"decrease_rate_percent_down"} // 5;

# --- Latency smoothing ---
my @latency_window;
my $window_size = $cfg{"latency_window_size"} // 5;
my $filter_mode = $cfg{"latency_filter"}      // "median"; # raw|average|median

# Resolve ping path once (OpenWrt safe)
my $ping = '/bin/ping';
$ping = '/usr/bin/ping' if -x '/usr/bin/ping';

sub measure_latency {
    my $best = 999;
    for my $r (grep { length } split(/\s+/, $cfg{"reflectors"} // "8.8.8.8 1.1.1.1")) {
        my $out = '';
        if (open(my $ph, '-|', $ping, '-c1', '-W1', $r)) {
            local $/; $out = <$ph>; close $ph;
        }
        if ($out =~ /time=([\d\.]+)/) {
            my $lat = $1 + 0;
            $best = $lat if $lat < $best;
        }
    }
    if ($best != 999) {
        log_decision("Raw latency sample: $best ms", 3);
        push @latency_window, $best;
        shift @latency_window if @latency_window > $window_size;
    }

    return $best if $filter_mode eq "raw" || !@latency_window;

    if ($filter_mode eq "average") {
        my $sum = 0; $sum += $_ for @latency_window;
        return int($sum / scalar(@latency_window));
    }

    my @sorted = sort { $a <=> $b } @latency_window;
    my $n = scalar(@sorted);
    return int($sorted[int($n/2)]) if $n % 2;
    return int(($sorted[$n/2 - 1] + $sorted[$n/2]) / 2);
}

# --- Logging ---
my $logfile     = "/var/log/sqm-autorate.log";
my $log_enabled = $cfg{"log_enabled"} // 1;
my $log_level   = $cfg{"log_level"}   // 2;

$log_level =~ s/\D.*//;
$log_level = int($log_level);

sub log_decision {
    my ($msg, $level) = @_;
    $level = 1 unless defined $level;   # default to minimal
    return unless $log_enabled;
    return if $level > $log_level;
    if (open(my $fh, ">>", $logfile)) {
        my $old = select($fh); $| = 1; select($old);
        print $fh scalar(localtime) . " $msg\n";
        close($fh);
    }
}

$SIG{HUP} = sub {
    load_config();
    $log_enabled = $cfg{"log_enabled"} // 1;
    $log_level   = $cfg{"log_level"}   // 2;
    $log_level =~ s/\D.*//;
    $log_level = int($log_level);
};

if (open(my $fh, ">>", $logfile)) {
    print $fh scalar(localtime) . " sqm-autorate started\n";
    close($fh);
}

# --- Elastic probing ---
my $probe_ms        = $cfg{"ping_interval_ms"}      // 500;
my $probe_fast_ms   = $cfg{"ping_interval_fast_ms"} // 200;
my $elastic_probe   = $cfg{"elastic_probe"}         // 1;
my $variance_thresh = $cfg{"elastic_variance_ms"}   // 3;
my @variance_window;

sub update_probe_interval {
    my ($lat) = @_;
    push @variance_window, $lat;
    shift @variance_window if @variance_window > 5;
    return unless $elastic_probe;

    my $min = $variance_window[0];
    my $max = $variance_window[0];
    for my $v (@variance_window) {
        $min = $v if $v < $min;
        $max = $v if $v > $max;
    }
    my $spread = $max - $min;

    if ($spread >= $variance_thresh || $lat > $high_up) {
        $probe_ms = $probe_fast_ms;
    } else {
        $probe_ms = $cfg{"ping_interval_ms"} // 500;
    }
    log_decision("Probe interval: ${probe_ms} ms (spread=$spread, lat=$lat)", 3);
}

# --- Adaptive floors ---
my $adaptive_floor       = $cfg{"adaptive_floor"} // 0;
my $floor_step           = $cfg{"adaptive_floor_step"} // 5;
my $floor_max            = $cfg{"adaptive_floor_max"} // 70;
my $trigger_ms           = $cfg{"adaptive_floor_trigger_ms"} // $high_up;
my $trigger_count_needed = $cfg{"adaptive_floor_trigger_count"} // 5;
my $high_latency_streak  = 0;

# --- Load-aware bias ---
my $load_aware     = $cfg{"load_aware"} // 0;
my $load_check_int = $cfg{"load_check_interval"} // 5;
my $load_bias_dec  = $cfg{"load_bias_decrease"} // 5;
my $load_thresh    = $cfg{"load_bias_threshold_bytes"} // 5000000;
my $cycle_count    = 0;
my %last_bytes;

sub get_bytes {
    my ($iface) = @_;
    my $out = '';
    if (open(my $fh, '-|', 'tc', '-s', 'qdisc', 'show', 'dev', $iface)) {
        local $/; $out = <$fh>; close $fh;
    }
    if ($out =~ /Sent\s+(\d+)\s+bytes/) {
        return $1;
    }
    return 0;
}

sub load_bias {
    $cycle_count++;
    return unless $load_aware;
    if ($cycle_count % $load_check_int == 0) {
        my $up_bytes   = get_bytes("eth0");
        my $down_bytes = get_bytes("nssifb");

        my $up_delta   = $up_bytes   - ($last_bytes{"eth0"}   // $up_bytes);
        my $down_delta = $down_bytes - ($last_bytes{"nssifb"} // $down_bytes);

        $last_bytes{"eth0"}   = $up_bytes;
        $last_bytes{"nssifb"} = $down_bytes;

        if ($up_delta > $load_thresh || $down_delta > $load_thresh) {
            $up_rate   = int($up_rate   * (100 - $load_bias_dec) / 100);
            $down_rate = int($down_rate * (100 - $load_bias_dec) / 100);
            log_decision("Load-aware bias applied: up=$up_delta down=$down_delta cut=$load_bias_dec%", 1);
        }
    }
}

# --- Rate decisions ---
sub decide_rates {
    my ($lat) = @_;
    my $old_up   = $up_rate;
    my $old_down = $down_rate;

    if ($lat > $high_up) {
        $up_rate = int($up_rate * (100 - $dec_up) / 100);
    } elsif ($lat < $low_up) {
        $up_rate = int($up_rate * (100 + $inc_up) / 100);
    }

    if ($lat > $high_down) {
        $down_rate = int($down_rate * (100 - $dec_down) / 100);
    } elsif ($lat < $low_down) {
        $down_rate = int($down_rate * (100 + $inc_down) / 100);
    }

    # enforce floors/ceilings
    $up_rate   = $up_rate   < $upload_min   ? $upload_min   : $up_rate;
    $down_rate = $down_rate < $download_min ? $download_min : $down_rate;
    $up_rate   = $up_rate   > $upload_base  ? $upload_base  : $up_rate;
    $down_rate = $down_rate > $download_base? $download_base: $down_rate;

    # log only if changed
    if ($up_rate != $old_up) {
        log_decision("UP changed (lat=$lat ms) -> $up_rate kbps", 1);
    }
    if ($down_rate != $old_down) {
        log_decision("DOWN changed (lat=$lat ms) -> $down_rate kbps", 1);
    }
}

# --- Apply rates with burst (bytes) ---
my $last_up_applied   = $upload_base;
my $last_down_applied = $download_base;

sub get_burst_bytes {
    my ($iface) = @_;
    my $default_burst = 15000; # fallback ~15kB
    my $burst = $default_burst;
    if (open(my $tc, '-|', 'tc', 'qdisc', 'show', 'dev', $iface)) {
        while (<$tc>) {
            if (/burst (\d+)b/) {
                $burst = $1;
                last;
            }
        }
        close($tc);
    }
    return $burst;
}

sub apply_rates {
    my ($up, $down, $lat) = @_;

    $up   ||= $upload_base;
    $down ||= $download_base;

    my $up_burst_bytes   = defined $cfg{"upload_burst_kbits"}
        ? int($cfg{"upload_burst_kbits"} * 1000 / 8)
        : get_burst_bytes("eth0");

    my $down_burst_bytes = defined $cfg{"download_burst_kbits"}
        ? int($cfg{"download_burst_kbits"} * 1000 / 8)
        : get_burst_bytes("nssifb");

    my $rc_up   = system('tc','qdisc','change','dev','eth0','root','nsstbl',
                         'rate', $up.'kbit','burst',$up_burst_bytes.'b');
    my $up_exit = $? >> 8;

    my $rc_down = system('tc','qdisc','change','dev','nssifb','root','nsstbl',
                         'rate', $down.'kbit','burst',$down_burst_bytes.'b');
    my $down_exit = $? >> 8;

    return unless $log_enabled;
    if ($up != $last_up_applied || $down != $last_down_applied) {
        log_decision("Latency=$lat ms Applied NSS rates: UPLINK=$up kbps burst=${up_burst_bytes}b (rc=$up_exit), DOWNLINK=$down kbps burst=${down_burst_bytes}b (rc=$down_exit)", 1);
        $last_up_applied   = $up;
        $last_down_applied = $down;
    }
}

# --- Helper: measure throughput over last probe interval ---
sub measure_throughput {
    my ($iface) = @_;
    my $delta_bytes = $last_bytes{$iface} // 0;
    my $kbps = int(($delta_bytes * 8) / ($probe_ms / 1000) / 1000);
    return $kbps;
}

# --- Update byte counters each cycle ---
sub update_byte_counters {
    for my $iface (qw(eth0 nssifb)) {
        my $rx_path = "/sys/class/net/$iface/statistics/rx_bytes";
        my $tx_path = "/sys/class/net/$iface/statistics/tx_bytes";
        my $bytes = 0;
        if (open my $fh, '<', $iface eq 'eth0' ? $tx_path : $rx_path) {
            $bytes = <$fh>;
            close $fh;
        }
        my $prev = $last_bytes{$iface} // 0;
        $last_bytes{$iface} = $bytes - $prev;
    }
}

# --- Main loop ---
my $idle_good_cycles = 0;
my $up_cap_streak    = 0;
my $down_cap_streak  = 0;

my $cap_trigger   = $cfg{"cap_trigger_cycles"}   // 3;
my $cap_threshold = $cfg{"cap_threshold_percent"} // 80;

while (1) {
    update_byte_counters();

    my $lat = measure_latency();
    log_decision("Cycle latency=$lat ms", 3);

    if ($lat >= 999) {
        update_probe_interval($lat);
        usleep($probe_ms * 1000);
        next;
    }

    decide_rates($lat);
    load_bias();

    my $load_ok = 1;
    if ($load_aware) {
        my $up_delta   = $last_bytes{"eth0"}   // 0;
        my $down_delta = $last_bytes{"nssifb"} // 0;
        $load_ok = ($up_delta < $load_thresh || $down_delta < $load_thresh);
    }

    if (($lat < $low_up && $lat < $low_down) && $load_ok) {
        $idle_good_cycles++;
    } elsif ($lat < $low_up && $lat < $low_down) {
        $idle_good_cycles++;
    } else {
        $idle_good_cycles = 0;
    }

    if ($idle_good_cycles >= 8) {
        my $measured_up   = measure_throughput("eth0");
        my $measured_down = measure_throughput("nssifb");

        if ($measured_up < ($upload_base * $cap_threshold / 100)) {
            $up_cap_streak++;
            if ($up_cap_streak >= $cap_trigger) {
                $up_rate = $measured_up;
                log_decision("ISP cap detected: uplink held at $up_rate kbps", 1);
            }
        } else {
            $up_rate = $upload_base;
            $up_cap_streak = 0;
        }

        if ($measured_down < ($download_base * $cap_threshold / 100)) {
            $down_cap_streak++;
            if ($down_cap_streak >= $cap_trigger) {
                $down_rate = $measured_down;
                log_decision("ISP cap detected: downlink held at $down_rate kbps", 1);
            }
        } else {
            $down_rate = $download_base;
            $down_cap_streak = 0;
        }

        log_decision("Idle recovery after $idle_good_cycles cycles: U=$up_rate D=$down_rate", 1);
        $idle_good_cycles = 0;
    }

    # --- Adaptive floor logic ---
    if ($adaptive_floor) {
        if ($lat >= $trigger_ms) {
            $high_latency_streak++;
            if ($high_latency_streak >= $trigger_count_needed) {
                $upload_min_pct   = $upload_min_pct   + $floor_step > $floor_max ? $floor_max : $upload_min_pct + $floor_step;
                $download_min_pct = $download_min_pct + $floor_step > $floor_max ? $floor_max : $download_min_pct + $floor_step;
                $upload_min   = int($upload_base   * $upload_min_pct   / 100);
                $download_min = int($download_base * $download_min_pct / 100);
                $high_latency_streak = 0;
                log_decision("Adaptive floor bumped: uplink floor=$upload_min_pct%, downlink floor=$download_min_pct%", 1);
            }
        } else {
            $high_latency_streak = 0;
        }
    }

    apply_rates($up_rate, $down_rate, $lat);
    update_probe_interval($lat);
    usleep($probe_ms * 1000);
}
