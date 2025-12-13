
# SQM-Autorate (NSS version)

Smart Queue Management Perl daemon for OpenWrt NSS builds (ipq806x).  
It dynamically adjusts `nsstbl`/`nssfq_codel` shaper rates based on latency and throughput smoothing.

---

## 🚀 Features

- Profile switching (gaming, streaming, performance, debug, custom)
- Adaptive floors to prevent wild swings and stabilize latency under load
- Load-aware bias to cut rates more aggressively when traffic volume is high
- ISP cap detection to recognize when the ISP is enforcing throughput limits
- Throughput smoothing options (`rate_filter`, `alpha_rate`, `smooth_size`) for stable rate estimation
- Latency filter options (`median`, `ewma`) with configurable window size and EWMA alpha
- Flexible probing logic:
  - `probe_ms`, `probe_fast_ms`, `probe_min_ms`
  - Elastic probing (`elastic_probe`) with variance threshold (`variance_thresh_ms`)
  - Probe setuid fix toggle (`probe_setuid_fix`) for compatibility with `fping`
- Full integration with `nss-rk.qos`
- Keeps advanced qdisc parameters (`buffer`, `mtu`, `target`, `interval`, `flows`, `quantum`, `accel_mode`) as configured by SQM
- Regional reflector support (users can add local servers for better latency measurement)
- Logging controls:
  - Enable/disable logging
  - Verbosity levels (1–3)
  - Log formats (compact/verbose)
  - Log modes (silent, event-driven, tick-driven)
  - Log rotation management
- Status helper (`sqm-status`) with:
  - Service dashboard
  - Active/default profile reporting
  - Process uptime
  - Log tail and live streaming
  - Config toggles (reflectors, probe settings, logging)

---

## 📦 Dependencies

Install required packages on OpenWrt NSS builds:

```sh
apk update
apk add \
  perl \
  perlbase-ipc perlbase-threads perlbase-symbol \
  perlbase-file perlbase-io perlbase-time perlbase-storable \
  perlbase-cwd perlbase-digest perlbase-data perlbase-fcntl \
  perlbase-socket perlbase-getopt \
  ip-full tc-full iputils-ping \
  logrotate procps-ng coreutils procd \
  jsonfilter \
  fping
```

Enable in build config:

```ini
CONFIG_PACKAGE_perl=y
CONFIG_PACKAGE_perlbase-ipc=y
CONFIG_PACKAGE_perlbase-threads=y
CONFIG_PACKAGE_perlbase-symbol=y
CONFIG_PACKAGE_perlbase-file=y
CONFIG_PACKAGE_perlbase-io=y
CONFIG_PACKAGE_perlbase-time=y
CONFIG_PACKAGE_perlbase-storable=y
CONFIG_PACKAGE_perlbase-cwd=y
CONFIG_PACKAGE_perlbase-digest=y
CONFIG_PACKAGE_perlbase-data=y
CONFIG_PACKAGE_perlbase-fcntl=y
CONFIG_PACKAGE_perlbase-socket=y
CONFIG_PACKAGE_perlbase-getopt=y
CONFIG_PACKAGE_ip-full=y
CONFIG_PACKAGE_tc-full=y
CONFIG_PACKAGE_iputils-ping=y
CONFIG_PACKAGE_logrotate=y
CONFIG_PACKAGE_procps-ng=y
CONFIG_PACKAGE_coreutils=y
CONFIG_PACKAGE_procd=y
CONFIG_PACKAGE_fping=y
CONFIG_PACKAGE_jsonfilter=y
CONFIG_PACKAGE_sqm-autorate-nss=y
```
Add feed:

```ini
feeds.conf.default:
src-git sqm_autorate_nss https://github.com/nihilt/sqm-autorate-nss.git
```
---

## 🔧 Service Commands

```sh
/etc/init.d/sqm-autorate start        # Start the sqm-autorate service
/etc/init.d/sqm-autorate stop         # Stop the sqm-autorate service
/etc/init.d/sqm-autorate restart      # Restart the service (stop + start)
/etc/init.d/sqm-autorate reload       # Reload config without full restart
/etc/init.d/sqm-autorate enable       # Enable service autostart at boot
/etc/init.d/sqm-autorate disable      # Disable service autostart at boot
/etc/init.d/sqm-autorate status       # Show running state and PID
```

### Profile Switching

```sh
switch-profile list                   # List all available profiles
switch-profile gaming                 # Switch to gaming profile
switch-profile streaming              # Switch to streaming profile
switch-profile performance            # Switch to performance profile
switch-profile debug                  # Switch to debug profile
switch-profile custom                 # Switch to custom profile
switch-profile <profile> --default    # Switch to profile AND set it as default for next boot
```

### SQM-Status Helpers

```sh
- sqm-status                  # Show service state, active/default profile, uptime, log size, recent logs
- sqm-status current          # Print only the active profile name
- sqm-status reload           # Send SIGHUP to daemon for config reload (fallback to restart if needed)

# Logging toggles
- sqm-status log-on           # Enable logging
- sqm-status log-off          # Disable logging
- sqm-status log-level-1      # Set log verbosity to LEVEL 1 (minimal)
- sqm-status log-level-2      # Set log verbosity to LEVEL 2 (medium)
- sqm-status log-level-3      # Set log verbosity to LEVEL 3 (debug)
- sqm-status log-format-compact  # Set log format to COMPACT
- sqm-status log-format-verbose  # Set log format to VERBOSE
- sqm-status log-mode-0       # Set log mode to SILENT
- sqm-status log-mode-1       # Set log mode to EVENT-DRIVEN
- sqm-status log-mode-2       # Set log mode to TICK-DRIVEN

# Reflector settings
- sqm-status reflector-count <number>       # Set reflector count
- sqm-status reflector-rotation-random      # Set reflector rotation to RANDOM
- sqm-status reflector-rotation-roundrobin  # Set reflector rotation to ROUNDROBIN

# Probe settings
- sqm-status probe-min <milliseconds>       # Set probe minimum interval
- sqm-status probe-setuid-on                # Enable probe setuid fix
- sqm-status probe-setuid-off               # Disable probe setuid fix
- sqm-status alpha-ewma <value>             # Set latency EWMA alpha (0.0–1.0)

# Log rotation
- sqm-status rotate-on          # Enable log rotation
- sqm-status rotate-off         # Disable log rotation

# Log file management
- sqm-status log-live           # Stream live log entries until Ctrl+C
- sqm-status log-clear          # Clear log file
- sqm-status log-disable-all    # Disable all logging and rotation
- sqm-status log-enable-all     # Enable all logging and rotation

```
---

## 📄 Example Profile: Custom (Daily Driver, Latency-Optimized)

```ini
# PROFILE: custom (daily driver, latency-optimized)

# Interfaces
upload_interface=eth0                 # Physical uplink interface (egress shaping)
download_interface=nssifb             # Virtual downlink interface (ingress shaping)
pinger_method=fping                   # Use fping for latency probing
probe_setuid_fix=1                    # Ensure fping has required privileges

# Base bandwidths (kbit/s)
upload_base_kbits=85000               # Base uplink bandwidth
download_base_kbits=830000            # Base downlink bandwidth

# Minimum floor percentages
upload_min_percent=50                 # Minimum uplink rate as % of base
download_min_percent=50               # Minimum downlink rate as % of base

# Rate adjustment percentages
increase_rate_percent_up=20           # Faster recovery to base uplink
decrease_rate_percent_up=8            # Sharper cut when uplink latency rises
increase_rate_percent_down=15         # Faster recovery to base downlink
decrease_rate_percent_down=8          # Sharper cut when downlink latency rises

# Latency thresholds (ms)
latency_low_up_ms=8                   # Uplink latency threshold to allow increase
latency_high_up_ms=12                 # Uplink latency threshold to force decrease
latency_low_down_ms=10                # Downlink latency threshold to allow increase
latency_high_down_ms=15               # Downlink latency threshold to force decrease

# Latency filter
latency_filter=median                 # Median filter for stability
latency_window_size=3                 # Number of samples kept for smoothing
alpha_ewma=0.4                        # EWMA alpha for latency smoothing

# Probing
probe_ms=200                          # Default probe interval (ms)
probe_fast_ms=100                     # Faster probe interval when congestion detected
probe_min_ms=100                      # Minimum probe interval allowed
elastic_probe=1                       # Enable adaptive probing
variance_thresh_ms=2                  # Variance threshold to trigger faster probing

# Adaptive floor control
adaptive_floor=1                      # Enable adaptive floor adjustment
adaptive_floor_step=3                 # Step size (% points) to raise floor
adaptive_floor_min=60                 # Minimum floor percentage allowed
adaptive_floor_max=90                 # Maximum floor percentage allowed
adaptive_floor_trigger_ms=12          # Latency threshold (ms) to trigger floor bump
adaptive_floor_trigger_count=5        # Consecutive samples needed to trigger bump
adaptive_floor_decay_interval=30      # Interval (s) to decay floor back down
adaptive_floor_decay_step=10          # Step size (% points) to reduce floor during decay

# Load-aware bias
load_aware=1                          # Enable load-aware bias
load_bias_decrease=3                  # % decrease applied when bias triggers
load_bias_threshold_bytes=15000000    # Traffic threshold (bytes) to trigger bias

# Logging
log_enabled=1                         # Enable logging
log_level=1                           # Minimal verbosity
log_mode=1                            # Event-driven logging
log_format=compact                    # Compact log format

# Reflectors
reflectors="1.1.1.1 1.0.0.1 208.67.220.220 208.67.222.222 9.9.9.9 9.9.9.10 8.8.8.8 8.8.4.4"
reflector_count=3                     # Number of reflectors to probe each cycle
reflector_rotation=roundrobin         # Rotate reflectors in round-robin fashion

# ISP cap detection
cap_trigger_cycles=8                  # Detect caps faster
cap_threshold_percent=95              # % of base rate considered capped

# Qdisc stats source
qdisc_stats=nssfq_codel               # Options: nsstbl (root aggregate) or nssfq_codel (child fairness scheduler)

# Throughput smoothing
rate_filter=ewma                      # Smoothing method: average or ewma
alpha_rate=0.5                        # EWMA weighting factor (0.0–1.0)
smooth_size=3                         # Window size for average mode (ignored in ewma)
```
---
## 📖 Key Concepts

- **Base rates** → maximum speeds (autorate tries to return to these).
- **Floors** → lowest speeds autorate will allow.
- **Latency thresholds** → trigger points for rate changes.
- **Adaptive floors** → floors rise if latency stays bad, preventing wild swings.
- **Decay settings** → floors slowly drop back down, letting speeds recover faster.
- **Load-aware bias** → extra safety cut when traffic is heavy, keeping latency smooth.
- **Throughput smoothing** → EWMA or average filters stabilize measured rates and reduce jitter in rate changes.
- **Probe setuid fix** → ensures `fping` can send ICMP packets if system permissions are restrictive.
```markdown
## 📊 SQM-Autorate Profile Comparison

| Profile        | Floors (Up/Down) | Latency Targets (Up/Down) | Logging   | Notes                          |
|----------------|------------------|---------------------------|-----------|--------------------------------|
| **Custom**     | 50% / 50%        | 8–12 ms / 10–15 ms        | Minimal   | Latency‑optimized daily driver; fast recovery, adaptive floors, load bias enabled |
| **Debug**      | 40% / 40%        | 15–25 ms / 18–30 ms       | Verbose   | Conservative adjustments, slower probing, detailed logs for troubleshooting |
| **Gaming**     | 60% / 60%        | 8–12 ms / 10–15 ms        | Medium    | Aggressive decreases, moderate increases; jitter‑sensitive for online play |
| **Performance**| 70% / 70%        | 12–18 ms / 15–22 ms       | Minimal   | Throughput‑first; aggressive increases, higher floors, load bias disabled |
| **Streaming**  | 45% / 50%        | 12–20 ms / 15–25 ms       | Compact   | Stable throughput, gentler decreases; smooth video/audio playback |
```

## 🔧 Recommended Tuning Procedure

1. Disable SQM/NSS QoS and run the Waveform Bufferbloat Test. Note max up/down throughput.  
2. Set `upload_base_kbits` and `download_base_kbits` to ~95% of measured line rate.  
3. Enable SQM with NSS QoS (`nss-rk.qos`) and re-run Waveform to verify reduced latency under load.  
4. Adjust base values to match shaped throughput reported by Waveform.  
5. Copy tuned base values into each profile (gaming, streaming, performance, debug, custom).  
6. Enable autorate at boot and restart.
---
