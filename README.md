# SQM-Autorate (NSS version)

Smart Queue Management Perl daemon for OpenWrt NSS builds.  
It dynamically adjusts `nsstbl` shaper rates based on latency, with:

- Profile switching (gaming, streaming, performance, debug)
- Adaptive floors to prevent wild swings
- Full integration with `nss-rk.qos`
- Keeps advanced qdisc parameters (`buffer`, `mtu`, `target`, `interval`, `flows`, `quantum`, `accel_mode`) as configured by SQM


---

## 🚀 Service Commands

```sh
/etc/init.d/sqm-autorate start        # Start the sqm-autorate service
/etc/init.d/sqm-autorate stop         # Stop the sqm-autorate service
/etc/init.d/sqm-autorate restart      # Restart the service (stop + start)
/etc/init.d/sqm-autorate enable       # Enable service autostart at boot
/etc/init.d/sqm-autorate disable      # Disable service autostart at boot

Switch Profiles

switch-profile list                   # List all available profiles
switch-profile gaming                 # Switch to gaming profile
switch-profile streaming              # Switch to streaming profile
switch-profile performance            # Switch to performance profile
switch-profile debug                  # Switch to debug profile
switch-profile <profile> --default    # Switch to profile AND set it as default for next boot

SQM-Status Helpers

sqm-status                            # Show full dashboard (service state, profiles, uptime, logs, summary)
sqm-status current                    # Show only the active profile (one-liner)

# Logging controls
sqm-status log-on                     # Enable logging
sqm-status log-off                    # Disable logging
sqm-status log-enable-all             # Enable logging AND rotation
sqm-status log-disable-all            # Disable logging AND rotation

# Verbosity levels
sqm-status log-level-1                # Detailed (logs every rate change)
sqm-status log-level-2                # Medium (fewer lines, recommended default)
sqm-status log-level-3                # Debug (most detail)

# Rotation controls
sqm-status rotate-on                  # Enable log rotation
sqm-status rotate-off                 # Disable log rotation

# Log file management
sqm-status log-live                   # Live stream the log file (Ctrl+C to stop)
sqm-status log-clear                  # Clear the log file contents

📦 Dependencies

Install required packages:

apk update && apk add perl perlbase-file perlbase-getopt perlbase-time perlbase-threads ip-full tc-full iputils-ping logrotate procps-ng coreutils procd jsonfilter

Enable in build config:

CONFIG_PACKAGE_jsonfilter=y
CONFIG_PACKAGE_perl=y
CONFIG_PACKAGE_perlbase-file=y
CONFIG_PACKAGE_perlbase-getopt=y
CONFIG_PACKAGE_perlbase-time=y
CONFIG_PACKAGE_perlbase-threads=y
CONFIG_PACKAGE_ip-full=y
CONFIG_PACKAGE_tc-full=y
CONFIG_PACKAGE_iputils-ping=y
CONFIG_PACKAGE_logrotate=y
CONFIG_PACKAGE_procps-ng=y
CONFIG_PACKAGE_coreutils=y
CONFIG_PACKAGE_procd=y


🎥 Streaming Profile Example

# PROFILE: streaming
# /etc/sqm-autorate-streaming.conf

# Base line rates (~95% of max line capacity).
upload_base_kbits=85000               # Maximum uplink speed in kbps
download_base_kbits=830000            # Maximum downlink speed in kbps

# Logging defaults
log_enabled=1                         # 1 = log activity, 0 = disable logging
log_level=1                           # 1 = detailed, 2 = medium, 3 = full debug

# Reflectors (servers to ping for latency measurement).
reflectors="1.1.1.1 208.67.222.222 208.67.220.220 9.9.9.9"

# Minimum allowed rates (floors as % of base).
upload_min_percent=50                 # Uplink never drops below 50% of base
download_min_percent=50               # Downlink never drops below 50% of base

# Adjustment aggressiveness.
increase_rate_percent_up=6            # Raise uplink by 6% when latency is low
decrease_rate_percent_up=10           # Cut uplink by 10% when latency is high
increase_rate_percent_down=6          # Raise downlink by 6% when latency is low
decrease_rate_percent_down=8          # Cut downlink by 8% when latency is high

# Latency thresholds (ms).
delay_low_target_up=12                # If uplink latency < 12 ms, increase rate
delay_high_target_up=15               # If uplink latency > 15 ms, decrease rate
delay_low_target_down=15              # If downlink latency < 15 ms, increase rate
delay_high_target_down=20             # If downlink latency > 20 ms, decrease rate

# Latency smoothing.
latency_filter=median                 # Use median of last samples
latency_window_size=5                 # Number of samples considered

# Probing intervals.
ping_interval_ms=250                  # Normal probe interval
ping_interval_fast_ms=150             # Faster probe interval when variance is high
elastic_probe=1                       # Enable automatic switch between normal/fast probing
elastic_variance_ms=2                 # If latency spread > 2 ms, switch to fast probing

# Adaptive floor settings.
adaptive_floor=1                      # Enable adaptive floor adjustments
adaptive_floor_step=2                 # Raise floor by 2% each time triggered
adaptive_floor_max=70                 # Floors never exceed 70% of base
adaptive_floor_trigger_ms=15          # Latency above 15 ms contributes to streak
adaptive_floor_trigger_count=5        # After 5 consecutive triggers, floor is raised

# Decay settings.
adaptive_floor_min=50                 # Floors will not decay below 50% of base
adaptive_floor_decay_interval=300     # Every 300s (5 min), decay check runs
adaptive_floor_decay_step=2           # Floors drop by 2% each decay interval

# Load-aware bias.
load_aware=1                          # Enable load-aware bias
load_check_interval=3                 # Check every 3 cycles
load_bias_decrease=5                  # Cut rates by 5% if threshold exceeded
load_bias_threshold_bytes=4000000     # If >4 MB transferred per cycle, bias is triggered

📖 Key Concepts

Base rates → maximum speeds (autorate tries to return to these).

Floors → lowest speeds autorate will allow.

Latency thresholds → trigger points for rate changes.

Adaptive floors → floors rise if latency stays bad, preventing wild swings.

Decay settings → floors slowly drop back down, letting speeds recover faster.

Load-aware bias → extra safety cut when traffic is heavy, keeping latency smooth.

🔧 Recommended Tuning Procedure

Disable SQM/NSS QoS and run the Waveform Bufferbloat Test. Note max up/down throughput.

Set upload_base_kbits and download_base_kbits to ~95% of measured line rate.

Enable SQM with NSS QoS (nss-rk.qos) and re-run Waveform to verify reduced latency under load.

Adjust base values to match shaped throughput reported by Waveform.

Copy tuned base values into each profile (gaming, streaming, performance, debug).

Enable autorate at boot and restart:

/etc/init.d/sqm-autorate enable
/etc/init.d/sqm-autorate restart
sqm-status

📊 Example Log Output

Thu Dec  4 06:38:03 2025 Cycle latency=13 ms
Thu Dec  4 06:38:03 2025 Probe interval: 150 ms (spread=2, lat=13)
Thu Dec  4 06:38:04 2025 Latency=19 ms Applied NSS rates: UPLINK=76500 kbps burst=15000b (rc=0), DOWNLINK=747000 kbps burst=15000b (rc=0)
Thu Dec  4 06:38:11 2025 Latency=9 ms Applied NSS rates: UPLINK=80306 kbps burst=15000b (rc=0), DOWNLINK=784170 kbps burst=15000b (rc=0)
Thu Dec  4 06:39:54 2025 sqm-autorate started

📝 Notes

Profiles are stored in /etc/sqm-profiles/.

Default profile is set with switch-profile <name> --default.

Logs are written to /var/log/sqm-autorate.log and rotated via logrotate.

nss-rk.qos integration ensures NSS rate-keeping and QoS coordination.
