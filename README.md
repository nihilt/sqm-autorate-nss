

---

# SQM-Autorate (NSS version)

Smart Queue Management Perl daemon for OpenWrt NSS builds (ipq806x).  
It dynamically adjusts `nsstbl` shaper rates based on latency and throughput smoothing.

---

## 🚀 Features
- Profile switching (gaming, streaming, performance, debug, custom)
- Adaptive floors to prevent wild swings
- Full integration with `nss-rk.qos`
- Keeps advanced qdisc parameters (`buffer`, `mtu`, `target`, `interval`, `flows`, `quantum`, `accel_mode`) as configured by SQM
- Flexible probing logic (auto-selects best pinger method: `ping`, `fping`, `irtt`)
- Regional reflector support (users can add local servers for better latency measurement)
- **New:** Throughput smoothing options (`rate_filter`, `alpha_rate`, `smooth_size`) for stable rate estimation

---

```ini
# PROFILE: custom (daily driver, tuned)
# Balanced profile for everyday use: lowest latency possible, smooth recovery,
# bias enabled for uplink/downlink load response

# Interfaces
upload_interface=eth0                 # Physical uplink interface (egress shaping)
download_interface=nssifb             # Virtual downlink interface (ingress shaping)
pinger_method=fping                   # Use fping for latency probing

# Base bandwidths (kbit/s)
upload_base_kbits=85000               # Base uplink bandwidth in kilobits per second
download_base_kbits=830000            # Base downlink bandwidth in kilobits per second

# Minimum floor percentages
upload_min_percent=50                 # Minimum uplink rate as % of base
download_min_percent=50               # Minimum downlink rate as % of base

# Rate adjustment percentages
increase_rate_percent_up=15           # % increase uplink when latency < low target
decrease_rate_percent_up=6            # % decrease uplink when latency > high target
increase_rate_percent_down=10         # % increase downlink when latency < low target
decrease_rate_percent_down=6          # % decrease downlink when latency > high target

# Latency thresholds (ms)
latency_low_up_ms=10                  # Uplink latency threshold to allow increase
latency_high_up_ms=15                 # Uplink latency threshold to force decrease
latency_low_down_ms=12                # Downlink latency threshold to allow increase
latency_high_down_ms=20               # Downlink latency threshold to force decrease

# Latency filter
latency_filter=median                 # Filter mode: raw|average|median
latency_window_size=3                 # Number of samples kept for smoothing

# Probing
probe_ms=250                          # Default probe interval (ms)
probe_fast_ms=150                     # Faster probe interval when congestion detected
elastic_probe=1                       # Enable elastic probing (adaptive interval)
variance_thresh_ms=3                  # Variance threshold (ms) to trigger faster probing

# Adaptive floor control
adaptive_floor=1                      # Enable adaptive floor adjustment
adaptive_floor_step=3                 # Step size (% points) to raise floor
adaptive_floor_min=60                 # Minimum floor percentage allowed
adaptive_floor_max=90                 # Maximum floor percentage allowed
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
log_mode=1                            # Event-driven logging
log_format=compact                    # Compact log format

# Reflectors
reflectors="1.1.1.1 1.0.0.1 208.67.220.220 208.67.222.222 208.67.220.2 208.67.222.2 9.9.9.9 9.9.9.10 9.9.9.11 149.112.112.112 8.8.8.8 8.8.4.4"
                                      # Global reflectors (Cloudflare, OpenDNS, Quad9, Google)

# Robust pinger settings
reflector_count=3                     # Number of reflectors to probe each cycle
reflector_rotation=roundrobin         # Rotate reflectors in round-robin fashion

# ISP cap detection
cap_trigger_cycles=12                 # Consecutive cycles below threshold to confirm cap
cap_threshold_percent=95              # % of base rate considered capped

# Qdisc stats source
qdisc_stats=nssfq_codel               # Options: nsstbl (root aggregate) or nssfq_codel (child fairness scheduler)

# Throughput smoothing
rate_filter=ewma                      # Smoothing method: average or ewma
alpha_rate=0.4                        # EWMA weighting factor (0.0–1.0)
smooth_size=3                         # Window size for average mode (ignored in ewma)
```

---

## 📦 Dependencies

OpenWrt NSS builds now use `apk`. Install required packages:

```sh
apk update
apk add \
  jsonfilter \
  perl \
  perlbase-ipc perlbase-threads perlbase-symbol \
  perlbase-file perlbase-io perlbase-time perlbase-storable \
  perlbase-cwd perlbase-digest perlbase-data perlbase-fcntl \
  perlbase-socket perlbase-getopt \
  ip-full tc-full iputils-ping \
  logrotate procps-ng coreutils procd \
  fping irtt
```

Enable in build config:

```ini
CONFIG_PACKAGE_jsonfilter=y
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
CONFIG_PACKAGE_irtt=y
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
sqm-status log-live                   # Live stream the log file (Ctrl+C to stop)
sqm-status log-clear                  # Clear the log file contents
```
## 🔧 Recommended Tuning Procedure

1. Disable SQM/NSS QoS and run the Waveform Bufferbloat Test. Note max up/down throughput.  
2. Set `upload_base_kbits` and `download_base_kbits` to ~95% of measured line rate.  
3. Enable SQM with NSS QoS (`nss-rk.qos`) and re-run Waveform to verify reduced latency under load.  
4. Adjust base values to match shaped throughput reported by Waveform.  
5. Copy tuned base values into each profile (gaming, streaming, performance, debug, custom).  
6. Enable autorate at boot and restart.
---

## 📖 Key Concepts
- **Base rates** → maximum speeds (autorate tries to return to these).
- **Floors** → lowest speeds autorate will allow.
- **Latency thresholds** → trigger points for rate changes.
- **Adaptive floors** → floors rise if latency stays bad, preventing wild swings.
- **Decay settings** → floors slowly drop back down, letting speeds recover faster.
- **Load-aware bias** → extra safety cut when traffic is heavy, keeping latency smooth.
- **Throughput smoothing** → EWMA or average filters stabilize measured rates.

---

## 📄 Example Profiles

Each profile now includes:
- Standardized **reflector set** (Cloudflare, OpenDNS, Quad9, Google).
- **Throughput smoothing** (`rate_filter=ewma`, `alpha_rate=0.4`, `smooth_size=3`).
- Tuned latency thresholds, floors, probing intervals, and logging.

### Custom (Daily Driver, Tuned)
Balanced everyday use: lowest latency possible, smooth recovery, bias enabled.

### Debug
Verbose logging, conservative adjustments, slower probing for troubleshooting.

### Gaming
Low latency thresholds, aggressive decreases, moderate increases for responsiveness.

### Performance
Higher floors, aggressive increases, moderate decreases, prioritizes throughput.

### Streaming
Stable throughput, gentler decreases, smoother video/audio playback.

---

## 📊 SQM-Autorate Profile Comparison

| Profile       | Floors (Up/Down) | Latency Targets (Up/Down) | Logging | Notes |
|---------------|------------------|---------------------------|---------|-------|
| **Custom**    | 50% / 50%        | 10–15 ms / 12–20 ms       | Medium  | Balanced everyday use |
| **Debug**     | 40% / 40%        | 15–25 ms / 18–30 ms       | Verbose | Troubleshooting |
| **Gaming**    | 60% / 60%        | 8–12 ms / 10–15 ms        | Compact | Lowest latency priority |
| **Performance** | 70% / 70%      | 12–18 ms / 15–22 ms       | Minimal | Max throughput |
| **Streaming** | 45% / 50%        | 12–20 ms / 15–25 ms       | Compact | Smooth video/audio |

---

## 📝 Notes
- Profiles are stored in `/etc/sqm-profiles/`.
- Default profile is set with `switch-profile <name> --default`.
- Logs are written to `/var/log/sqm-autorate.log` and rotated via logrotate.
- `nss-rk.qos` integration ensures NSS rate-keeping and QoS coordination.
- Regional reflectors can be added to profiles for localized latency probing.
- New throughput smoothing options stabilize measured rates and reduce jitter in rate changes.

---
