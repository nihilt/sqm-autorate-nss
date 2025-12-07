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
ONFIG_PACKAGE_sqm-autorate-nss=y

feeds.conf.default:
src-git sqm_autorate_nss https://github.com/nihilt/sqm-autorate-nss.git
```
```ini
# PROFILE: custom
# Balanced profile for everyday use: lowest latency possible, smooth recovery,
# bias disabled to prevent uplink dropping during sustained traffic

upload_base_kbits=85000              # Base uplink bandwidth in kilobits per second (starting point for rate control)
download_base_kbits=830000           # Base downlink bandwidth in kilobits per second

upload_min_percent=50                # Minimum allowed uplink rate as % of base (floor)
download_min_percent=50              # Minimum allowed downlink rate as % of base (floor)

increase_rate_percent_up=10          # % increase applied to uplink when latency is below low target
decrease_rate_percent_up=8           # % decrease applied to uplink when latency exceeds high target
increase_rate_percent_down=5         # % increase applied to downlink when latency is below low target
decrease_rate_percent_down=9         # % decrease applied to downlink when latency exceeds high target

delay_low_target_up=10               # Latency threshold (ms) below which uplink rate can be increased
delay_high_target_up=15              # Latency threshold (ms) above which uplink rate must be decreased
delay_low_target_down=12             # Latency threshold (ms) below which downlink rate can be increased
delay_high_target_down=20            # Latency threshold (ms) above which downlink rate must be decreased

latency_filter=median                # Method for smoothing latency samples: raw|average|median
latency_window_size=8                # Number of samples kept in latency window for filtering

ping_interval_ms=250                 # Default ping probe interval in milliseconds
ping_interval_fast_ms=150            # Faster ping interval used when congestion/variance is detected
elastic_probe=1                      # Enable elastic probing (adaptive ping interval)
elastic_variance_ms=3                # Latency variance threshold (ms) that triggers faster probing

adaptive_floor=1                     # Enable adaptive floor adjustment (raise minimum rates under stress)
adaptive_floor_step=3                # Step size (% points) to raise floor when triggered
adaptive_floor_min=55                # Minimum floor percentage allowed
adaptive_floor_max=70                # Maximum floor percentage allowed
adaptive_floor_trigger_ms=15         # Latency threshold (ms) that triggers adaptive floor bump
adaptive_floor_trigger_count=7       # Number of consecutive high-latency samples required to trigger bump
adaptive_floor_decay_interval=60     # Interval (seconds) to decay floor back down if conditions improve
adaptive_floor_decay_step=8          # Step size (% points) to reduce floor during decay

load_aware=0                         # Enable load-aware bias (reduce rates under sustained heavy traffic)
load_bias_decrease=0                 # % decrease applied when load-aware bias triggers
load_bias_threshold_bytes=100000000  # Traffic threshold (bytes) that triggers load-aware bias

log_enabled=1                        # Enable logging to /var/log/sqm-autorate.log
log_level=2                          # Logging verbosity: 1=minimal, 2=normal, 3=debug

reflectors="1.1.1.1 208.67.222.222 208.67.220.220 9.9.9.9"  # IPs to ping for latency measurement

cap_trigger_cycles=3                 # Number of consecutive cycles below threshold to confirm ISP cap
cap_threshold_percent=80             # % of base rate below which throughput is considered capped


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
