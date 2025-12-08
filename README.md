

# SQM-Autorate (NSS version)

Smart Queue Management Perl daemon for OpenWrt NSS builds.  
It dynamically adjusts `nsstbl` shaper rates based on latency, with:

- Profile switching (gaming, streaming, performance, debug, custom)
- Adaptive floors to prevent wild swings
- Full integration with `nss-rk.qos`
- Keeps advanced qdisc parameters (`buffer`, `mtu`, `target`, `interval`, `flows`, `quantum`, `accel_mode`) as configured by SQM
- Flexible probing logic (auto-selects best pinger method: `ping`, `fping`, `tsping`, `irtt`)
- Regional reflector support (users can add local servers for better latency measurement)

## 🚀 Service Commands

```sh
/etc/init.d/sqm-autorate start        # Start the sqm-autorate service
/etc/init.d/sqm-autorate stop         # Stop the sqm-autorate service
/etc/init.d/sqm-autorate restart      # Restart the service (stop + start)
/etc/init.d/sqm-autorate enable       # Enable service autostart at boot
/etc/init.d/sqm-autorate disable      # Disable service autostart at boot

# Switch Profiles
switch-profile list                   # List all available profiles
switch-profile gaming                 # Switch to gaming profile
switch-profile streaming              # Switch to streaming profile
switch-profile performance            # Switch to performance profile
switch-profile debug                  # Switch to debug profile
switch-profile custom                 # Switch to custom profile
switch-profile <profile> --default    # Switch to profile AND set it as default for next boot

# SQM-Status Helpers
sqm-status                            # Show full dashboard (service state, profiles, uptime, logs, summary)
sqm-status current                    # Show only the active profile (one-liner)

# Logging controls
sqm-status log-on                     # Enable logging
sqm-status log-off                    # Disable logging
sqm-status log-enable-all             # Enable logging AND rotation
sqm-status log-disable-all            # Disable logging AND rotation

# Verbosity levels
sqm-status log-level-1                # Detailed (logs every rate change)
sqm-status log-level-2                # Medium (recommended default)
sqm-status log-level-3                # Debug (most detail)

# Rotation controls
sqm-status rotate-on                  # Enable log rotation
sqm-status rotate-off                 # Disable log rotation

# Log file management
sqm-status log-live                   # Live stream the log file (Ctrl+C to stop)
sqm-status log-clear                  # Clear the log file contents
```

---

## 📦 Dependencies

Install required packages:

```sh
apk update && apk add perl perlbase-file perlbase-getopt perlbase-time perlbase-threads ip-full tc-full iputils-ping logrotate procps-ng coreutils procd jsonfilter
```

Enable in build config:

```ini
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
CONFIG_PACKAGE_sqm-autorate-nss=y
```

Add feed:

```ini
feeds.conf.default:
src-git sqm_autorate_nss https://github.com/nihilt/sqm-autorate-nss.git
```

---

## 🔧 Probing Logic

- **Methods supported**: `ping`, `fping`, `tsping`, `irtt`
- **Auto-selection**: `pinger_method=auto` chooses the best available tool at startup
- **Periodic re-selection**: daemon re-evaluates every interval to ensure optimal probing
- **Elastic probing**: probe interval adapts based on latency variance
- **Regional reflectors**: users can add local servers to profiles for better latency measurement in their region

---

## 📖 Key Concepts

- **Base rates** → maximum speeds (autorate tries to return to these).
- **Floors** → lowest speeds autorate will allow.
- **Latency thresholds** → trigger points for rate changes.
- **Adaptive floors** → floors rise if latency stays bad, preventing wild swings.
- **Decay settings** → floors slowly drop back down, letting speeds recover faster.
- **Load-aware bias** → extra safety cut when traffic is heavy, keeping latency smooth.

---

## 🔧 Recommended Tuning Procedure

1. Disable SQM/NSS QoS and run the Waveform Bufferbloat Test. Note max up/down throughput.  
2. Set `upload_base_kbits` and `download_base_kbits` to ~95% of measured line rate.  
3. Enable SQM with NSS QoS (`nss-rk.qos`) and re-run Waveform to verify reduced latency under load.  
4. Adjust base values to match shaped throughput reported by Waveform.  
5. Copy tuned base values into each profile (gaming, streaming, performance, debug, custom).  
6. Enable autorate at boot and restart:

```sh
/etc/init.d/sqm-autorate enable
/etc/init.d/sqm-autorate restart
sqm-status
```

---

## 📊 Example Log Output

```text
root@OpenWrt:~# sqm-status log-live
=== LIVE LOG STREAM (Ctrl+C to stop) ===
Mon Dec  8 12:14:36 2025 sqm-autorate started
Mon Dec  8 12:14:55 2025 Adaptive floor decayed: uplink floor=55%, downlink floor=55%
Mon Dec  8 12:15:14 2025 Adaptive floor decayed: uplink floor=55%, downlink floor=55%
Mon Dec  8 12:15:33 2025 Adaptive floor decayed: uplink floor=55%, downlink floor=55%
Mon Dec  8 12:15:52 2025 Adaptive floor decayed: uplink floor=55%, downlink floor=55%
```

---

## 📝 Notes

- Profiles are stored in `/etc/sqm-profiles/`.  
- Default profile is set with `switch-profile <name> --default`.  
- Logs are written to `/var/log/sqm-autorate.log` and rotated via logrotate.  
- `nss-rk.qos` integration ensures NSS rate-keeping and QoS coordination.  
- Users can add **regional reflectors** to profiles for localized latency probing.

---

## 📄 Example Profile: Custom (Daily Driver)

```ini
# PROFILE: custom (daily driver)
# Balanced profile for everyday use: lowest latency possible, smooth recovery,
# bias enabled for testing uplink/downlink load response

# Interfaces to shape
upload_interface=eth0                 # Physical uplink interface (egress shaping)
download_interface=nssifb             # Virtual downlink interface (ingress shaping)

# Reflector probing
reflector_protocol=automatic          # Auto-select best probing method (ping/fping/tsping/irtt)
reflectors="1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 9.9.9.9 149.112.112.112" 
                                      # Global US-based reflectors (Cloudflare, Google, Quad9)

# Base rates (maximum shaped speeds)
upload_base_kbits=85000               # Base uplink bandwidth in kilobits per second
download_base_kbits=830000            # Base downlink bandwidth in kilobits per second

# Required rate/burst parameters (needed by nsstbl qdisc)
upload_rate_kbits=85000               # Initial uplink rate
upload_burst_bytes=15000              # Burst size in bytes for uplink
download_rate_kbits=830000            # Initial downlink rate
download_burst_bytes=30000            # Burst size in bytes for downlink

# Minimum floors (percentage of base)
upload_min_percent=50                 # Minimum uplink rate as % of base
download_min_percent=50               # Minimum downlink rate as % of base

# Rate adjustment percentages
increase_rate_percent_up=10           # % increase uplink when latency < low target
decrease_rate_percent_up=8            # % decrease uplink when latency > high target
increase_rate_percent_down=5          # % increase downlink when latency < low target
decrease_rate_percent_down=9          # % decrease downlink when latency > high target

# Latency thresholds (ms)
delay_low_target_up=10                # Uplink latency threshold to allow increase
delay_high_target_up=15               # Uplink latency threshold to force decrease
delay_low_target_down=12              # Downlink latency threshold to allow increase
delay_high_target_down=20             # Downlink latency threshold to force decrease

# Latency filtering
latency_filter=median                 # Filter mode: raw|average|median
latency_window_size=8                 # Number of samples kept for smoothing

# Probing intervals
ping_interval_ms=250                  # Default probe interval (ms)
ping_interval_fast_ms=150             # Faster probe interval when congestion detected
elastic_probe=1                       # Enable elastic probing (adaptive interval)
elastic_variance_ms=3                 # Variance threshold (ms) to trigger faster probing

# Adaptive floor logic
adaptive_floor=1                      # Enable adaptive floor adjustment
adaptive_floor_step=3                 # Step size (% points) to raise floor
adaptive_floor_min=55                 # Minimum floor percentage allowed
adaptive_floor_max=70                 # Maximum floor percentage allowed
adaptive_floor_trigger_ms=15          # Latency threshold (ms) to trigger floor bump
adaptive_floor_trigger_count=7        # Consecutive samples needed to trigger bump
adaptive_floor_decay_interval=60      # Interval (s) to decay floor back down
adaptive_floor_decay_step=8           # Step size (% points) to reduce floor during decay

# Load-aware bias
load_aware=1                          # Enable load-aware bias
load_bias_decrease=2                  # % decrease applied when bias triggers
load_bias_threshold_bytes=20000000    # Traffic threshold (bytes) to trigger bias

# Logging
log_enabled=1                         # Enable logging
log_level=2                           # Verbosity: 1=minimal, 2=normal, 3=debug

# ISP cap detection
cap_trigger_cycles=3                  # Consecutive cycles below threshold to confirm cap
cap_threshold_percent=80              # % of base rate considered capped


```
## 📊 SQM-Autorate Profile Comparison

| Profile               | Burst (Up/Down) | Load Bias Decrease | Load Bias Threshold | Latency Targets (Up/Down) | Logging Level | Notes |
|-----------------------|-----------------|--------------------|---------------------|---------------------------|---------------|-------|
| **Custom**            | 15 KB / 30 KB | 2%                 | 20 MB               | 10–15 ms / 12–20 ms       | 2 (medium)    | Balanced everyday use |
| **Gaming**            | 8 KB / 16 KB    | 4%                 | 4 MB                | 8–12 ms / 10–15 ms        | 2             | Tight bursts, lowest latency priority |
| **Debug**             | 15 KB / 30 KB   | 5%                 | 5 MB                | 10–15 ms / 12–20 ms       | 3 (verbose)   | Safe defaults, extra logging for troubleshooting |
| **Performance**       | 20 KB / 40 KB   | 6%                 | 6 MB                | 12–18 ms / 15–25 ms       | 1 (minimal)   | Larger bursts, maximize throughput |
| **Streaming**         | 18 KB / 35 KB   | 2%                 | 20 MB               | 11–16 ms / 13–22 ms       | 2             | Gentler bias, smoother video/audio playback |
---
