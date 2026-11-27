# common.sh - code shared by the sqm-autorate init script, switch-profile and sqm-status.
# This file is sourced, never run. POSIX sh plus the BusyBox applets that OpenWrt ships (awk, sed, tr, grep, kill).
#
# Where things live. Memory is the default; flash is written only on an explicit request.
#
#   memory (tmpfs, gone at reboot)
#     /var/run/sqm-autorate/profile        name of the active profile
#     /var/run/sqm-autorate/override.conf  runtime settings   (sqm-status set ...)
#     /var/sqm-autorate.conf               what the daemon reads: profile + saved + runtime settings
#   flash (written only when you ask for it)
#     /etc/sqm-profiles/sqm-autorate-NAME.conf      the profiles (you edit these)
#     /etc/sqm-profiles/sqm-autorate-NAME.override  settings kept for NAME   (sqm-status save)
#     /etc/sqm-default                              profile used at boot     (switch-profile NAME --default)
#     /etc/logrotate.d/sqm-autorate                 log rotation on / off    (sqm-status rotate-on / rotate-off)
#
# The daemon lets a later "key=value" line win over an earlier one, so the runtime file is simply the
# profile followed by the saved and the runtime settings.
#
# SQMAR_ROOT is empty on the router. The tests set it to a scratch directory so that nothing real is touched.

SQMAR_ROOT=${SQMAR_ROOT:-}
SQMAR_PROFILE_DIR=${SQMAR_ROOT}/etc/sqm-profiles
SQMAR_DEFAULT_FILE=${SQMAR_ROOT}/etc/sqm-default
SQMAR_RUN_DIR=${SQMAR_ROOT}/var/run/sqm-autorate
SQMAR_CONF=${SQMAR_ROOT}/var/sqm-autorate.conf
SQMAR_PIDFILE=${SQMAR_ROOT}/var/run/sqm-autorate.pid
SQMAR_LOGFILE=${SQMAR_ROOT}/var/log/sqm-autorate.log
SQMAR_SCRIPT=${SQMAR_ROOT}/usr/bin/sqm-autorate.pl
SQMAR_INIT=${SQMAR_ROOT}/etc/init.d/sqm-autorate
SQMAR_LOGROTATE=${SQMAR_ROOT}/etc/logrotate.d/sqm-autorate
SQMAR_LOGROTATE_TPL=${SQMAR_ROOT}/usr/share/sqm-autorate/logrotate.conf
SQMAR_PROC=${SQMAR_PROC:-/proc}
SQMAR_UCI=${UCI:-uci}
SQMAR_TC=${TC:-tc}

# Keys that a profile may carry although the daemon does not read them, and keys it still reads but ignores.
SQMAR_DOC_KEYS="download_interface"
SQMAR_OBSOLETE_KEYS="load_bias_threshold_bytes"
# Keys a profile may leave out: no key means "take the options of the sqm queue section", on purpose.
SQMAR_OPTIONAL_KEYS="eqdisc_opts iqdisc_opts"

sqmar_err() { printf 'sqm-autorate: %s\n' "$*" >&2; }

# ------------------------------------------------------------------ names and files

sqmar_valid_name() {
    case "$1" in
        ''|*[!A-Za-z0-9_-]*) return 1 ;;
    esac
    [ "${#1}" -le 32 ]
}

sqmar_profile_file() { printf '%s/sqm-autorate-%s.conf' "$SQMAR_PROFILE_DIR" "$1"; }
sqmar_saved_file()   { printf '%s/sqm-autorate-%s.override' "$SQMAR_PROFILE_DIR" "$1"; }
sqmar_runtime_file() { printf '%s/override.conf' "$SQMAR_RUN_DIR"; }

# A profile is a regular file. A symlink is not one: older versions left sqm-autorate-default.conf behind.
sqmar_profile_exists() {
    local f
    sqmar_valid_name "$1" || return 1
    f=$(sqmar_profile_file "$1")
    [ -f "$f" ] && [ ! -L "$f" ]
}

sqmar_list_profiles() {
    local f n
    for f in "$SQMAR_PROFILE_DIR"/sqm-autorate-*.conf; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        n=${f##*/sqm-autorate-}
        n=${n%.conf}
        sqmar_valid_name "$n" || continue
        printf '%s\n' "$n"
    done
}

# Atomic write to FILE from stdin (same directory, then rename; a symlink at FILE is replaced, not followed).
sqmar_write() {
    local f=$1 t
    t="$f.tmp.$$"
    cat > "$t" || { rm -f "$t"; return 1; }
    mv -f "$t" "$f" || { rm -f "$t"; return 1; }
}

# first line of a file, blanks removed
sqmar_first_word() {
    local v=
    [ -r "$1" ] && { IFS= read -r v < "$1" || :; }
    printf '%s' "$v" | tr -d ' \t\r'
}

# the profile named in /etc/sqm-default, as written (may not exist)
sqmar_default_name() { sqmar_first_word "$SQMAR_DEFAULT_FILE"; }

# the profile that is used at boot: the default; when that is missing "custom", then the first one found
sqmar_boot_name() {
    local n first=
    n=$(sqmar_default_name)
    if sqmar_profile_exists "$n"; then printf '%s' "$n"; return 0; fi
    if sqmar_profile_exists custom; then printf 'custom'; return 0; fi
    first=$(sqmar_list_profiles | head -n 1)
    printf '%s' "$first"
}

# the active profile: what was switched to in memory, else the boot profile
sqmar_active_name() {
    local n
    n=$(sqmar_first_word "$SQMAR_RUN_DIR/profile")
    if sqmar_profile_exists "$n"; then printf '%s' "$n"; else sqmar_boot_name; fi
}

sqmar_set_active() {
    mkdir -p "$SQMAR_RUN_DIR" || return 1
    printf '%s\n' "$1" | sqmar_write "$SQMAR_RUN_DIR/profile"
}

# ------------------------------------------------------------------ reading config files like the daemon

# sqmar_conf_get FILE KEY: the last value of KEY (comments after a value and quotes removed); rc 1 when absent
sqmar_conf_get() {
    awk -v k="$2" -v q="'" '
    {
        line = $0
        sub(/^[ \t\r]+/, "", line); sub(/[ \t\r]+$/, "", line)
        if (line == "" || line ~ /^#/) next
        i = index(line, "="); if (i == 0) next
        key = substr(line, 1, i - 1); val = substr(line, i + 1)
        sub(/[ \t]+$/, "", key); sub(/^[ \t]+/, "", val)
        sub(/[ \t]+#.*$/, "", val); sub(/[ \t\r]+$/, "", val)
        if (val ~ /^".*"$/ || val ~ ("^" q ".*" q "$")) val = substr(val, 2, length(val) - 2)
        if (key == k) { found = 1; out = val }
    }
    END { if (found) { print out; exit 0 } exit 1 }' "$1"
}

# every key of FILE, one per line, in order (duplicates repeated)
sqmar_conf_keys() {
    awk '
    {
        line = $0
        sub(/^[ \t\r]+/, "", line); sub(/[ \t\r]+$/, "", line)
        if (line == "" || line ~ /^#/) next
        i = index(line, "="); if (i == 0) next
        key = substr(line, 1, i - 1); sub(/[ \t]+$/, "", key)
        print key
    }' "$1"
}

# line numbers of lines that are neither blank, comment nor key=value
sqmar_conf_badlines() {
    awk '
    {
        line = $0
        sub(/^[ \t\r]+/, "", line); sub(/[ \t\r]+$/, "", line)
        if (line == "" || line ~ /^#/) next
        if (index(line, "=") == 0) print NR
    }' "$1"
}

# the keys sqm-autorate.pl reads, from the script itself, so this list cannot drift from the code
sqmar_script_keys() {
    [ -r "$SQMAR_SCRIPT" ] || return 1
    awk '{ s = $0; while (match(s, /\$cfg[{]"[a-z0-9_]+"[}]/)) { print substr(s, RSTART + 6, RLENGTH - 8); s = substr(s, RSTART + RLENGTH) } }' \
        "$SQMAR_SCRIPT" | sort -u | while read -r k; do
        case " $SQMAR_OBSOLETE_KEYS " in *" $k "*) continue ;; esac
        printf '%s\n' "$k"
    done
}

# ------------------------------------------------------------------ settings that may be changed at run time

# sqmar_key_spec KEY: "int LO HI", "num LO HI" or "enum a b c"; rc 1 when the key cannot be set from here
sqmar_key_spec() {
    case "$1" in
        log_enabled) echo "int 0 1" ;;
        log_level|log_mode) echo "int 0 2" ;;
        log_format) echo "enum compact verbose json" ;;
        log_change_threshold_percent) echo "int 0 50" ;;
        reflector_count) echo "int 1 10" ;;
        reflector_rotation) echo "enum roundrobin random" ;;
        pinger_method) echo "enum automatic fping ping" ;;
        probe_setuid_fix|elastic_probe|adaptive_floor|load_aware|manage_child) echo "int 0 1" ;;
        probe_ms|probe_fast_ms|probe_min_ms) echo "int 50 5000" ;;
        probe_timeout_ms) echo "int 20 1000" ;;
        probe_blackout_s) echo "num 0 3600" ;;
        variance_thresh_ms) echo "int 1 100" ;;
        latency_filter) echo "enum median ewma" ;;
        latency_window_size) echo "int 1 20" ;;
        alpha_ewma|alpha_rate) echo "num 0 1" ;;
        rate_filter) echo "enum average ewma" ;;
        smooth_size) echo "int 1 50" ;;
        counter_sync_s) echo "num 0 10" ;;
        upload_base_kbits|download_base_kbits) echo "intauto 100 10000000" ;;
        upload_min_percent|download_min_percent) echo "int 0 100" ;;
        increase_rate_percent_up|increase_rate_percent_down|decrease_rate_percent_up|decrease_rate_percent_down) echo "int 0 100" ;;
        latency_low_up_ms|latency_high_up_ms|latency_low_down_ms|latency_high_down_ms) echo "int 1 1000" ;;
        hold_after_decrease_ms|decrease_settle_ms) echo "int 0 60000" ;;
        slow_increase_percent) echo "num 0.1 50" ;;
        ramp_fast_until_percent) echo "int 10 100" ;;
        trouble_memory_s) echo "int 0 86400" ;;
        decrease_settle_bypass_factor) echo "num 1 100" ;;
        adaptive_floor_step|adaptive_floor_decay_step) echo "int 0 100" ;;
        adaptive_floor_min|adaptive_floor_max) echo "int 0 100" ;;
        adaptive_floor_trigger_ms) echo "int 1 1000" ;;
        adaptive_floor_trigger_count) echo "int 1 1000" ;;
        adaptive_floor_decay_interval) echo "int 1 100000" ;;
        load_bias_decrease) echo "int 0 50" ;;
        load_bias_threshold_percent) echo "int 1 100" ;;
        load_bias_max_util_percent) echo "int 0 200" ;;
        decrease_min_load_percent) echo "int 0 100" ;;
        apply_min_change_percent) echo "num 0 50" ;;
        calm_window_cycles) echo "int 0 100" ;;
        cap_trigger_cycles) echo "int 0 1000" ;;
        cap_threshold_percent|cap_load_percent) echo "int 1 100" ;;
        qdisc_stats) echo "enum nsstbl nssfq_codel" ;;
        *) return 1 ;;
    esac
}

sqmar_settable_keys() {
    local k
    for k in $(sqmar_script_keys 2>/dev/null); do
        sqmar_key_spec "$k" >/dev/null && printf '%s\n' "$k"
    done
}

# sqmar_validate KEY VALUE: rc 0 when the daemon will take it; otherwise one line on stdout says why
sqmar_validate() {
    local key=$1 val=$2 spec kind lo hi x alt=
    if ! spec=$(sqmar_key_spec "$key"); then
        echo "'$key' cannot be set here (unknown key, or one that is edited in the profile: sqm-status keys lists the others)"
        return 1
    fi
    set -- $spec
    kind=$1; lo=${2:-}; hi=${3:-}
    if [ "$kind" = intauto ]; then      # a number, or "auto" (the daemon reads the rate from /etc/config/sqm)
        [ "$val" = auto ] && return 0
        kind=int; alt=", or auto"
    fi
    case "$kind" in
        int)
            case "$val" in ''|*[!0-9]*) echo "$key needs a whole number from $lo to $hi$alt"; return 1 ;; esac
            if [ "${#val}" -gt 9 ] || ! awk -v v="$val" -v lo="$lo" -v hi="$hi" 'BEGIN { exit !(v + 0 >= lo && v + 0 <= hi) }'; then
                echo "$key must be from $lo to $hi$alt"; return 1
            fi ;;
        num)
            if ! awk -v v="$val" 'BEGIN { exit !(v ~ /^[0-9]+([.][0-9]+)?$/) }' || [ "${#val}" -gt 12 ]; then
                echo "$key needs a number from $lo to $hi"; return 1
            fi
            if ! awk -v v="$val" -v lo="$lo" -v hi="$hi" 'BEGIN { exit !(v + 0 >= lo && v + 0 <= hi) }'; then
                echo "$key must be from $lo to $hi"; return 1
            fi ;;
        enum)
            shift
            for x in "$@"; do [ "$val" = "$x" ] && return 0; done
            echo "$key must be one of: $*"; return 1 ;;
    esac
    return 0
}

# ------------------------------------------------------------------ override files (key=value, one per line)

# sqmar_ovr_put FILE KEY VALUE: replace or append one line
sqmar_ovr_put() {
    local f=$1 k=$2 v=$3
    mkdir -p "${f%/*}" || return 1
    { [ -f "$f" ] && awk -F= -v k="$k" '$1 != k' "$f"; printf '%s=%s\n' "$k" "$v"; } | sqmar_write "$f"
}

# sqmar_ovr_del FILE KEY: remove a line; the file goes away when it is empty
sqmar_ovr_del() {
    local f=$1 k=$2
    [ -f "$f" ] || return 0
    awk -F= -v k="$k" '$1 != k' "$f" | sqmar_write "$f" || return 1
    [ -s "$f" ] || rm -f "$f"
}

sqmar_ovr_count() {
    [ -f "$1" ] || { echo 0; return 0; }
    awk 'NF { n++ } END { print n + 0 }' "$1"
}

# ------------------------------------------------------------------ the runtime file

# sqmar_render [NAME]: write /var/sqm-autorate.conf (memory). Atomic, so the daemon never reads half a file.
sqmar_render() {
    local name=${1:-} pf= sv rt
    [ -n "$name" ] || name=$(sqmar_active_name)
    mkdir -p "${SQMAR_CONF%/*}" "$SQMAR_RUN_DIR" || return 1
    if [ -n "$name" ] && sqmar_profile_exists "$name"; then
        pf=$(sqmar_profile_file "$name")
        sv=$(sqmar_saved_file "$name")
    else
        sqmar_err "no usable profile in $SQMAR_PROFILE_DIR; the daemon will run on its built-in defaults"
        name=
        sv=
    fi
    rt=$(sqmar_runtime_file)
    {
        echo "# Rendered by sqm-autorate into memory. Edit the profile, not this file."
        echo "# profile: ${name:-none}"
        if [ -n "$pf" ]; then
            cat "$pf"
            echo
        fi
        if [ -n "$sv" ] && [ -s "$sv" ]; then
            echo "# ---- settings saved for this profile (flash)"
            cat "$sv"
            echo
        fi
        if [ -s "$rt" ]; then
            echo "# ---- runtime settings (memory)"
            cat "$rt"
            echo
        fi
    } | sqmar_write "$SQMAR_CONF"
}

# the read-only views read the rendered file; when it is not there yet (daemon never started since boot) make it
# in memory, so a look at the state never shows "not set" for everything
sqmar_ensure_conf() {
    [ -s "$SQMAR_CONF" ] || sqmar_render >/dev/null 2>&1
    return 0
}

# ------------------------------------------------------------------ the daemon

# PID of the running daemon: pidfile, and the process must really be sqm-autorate.pl (the pid may be stale)
sqmar_daemon_pid() {
    local pid
    pid=$(sqmar_first_word "$SQMAR_PIDFILE")
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ -r "$SQMAR_PROC/$pid/cmdline" ] || return 1
    tr '\0' ' ' < "$SQMAR_PROC/$pid/cmdline" | grep -q 'sqm-autorate\.pl' || return 1
    printf '%s' "$pid"
}

sqmar_running() { sqmar_daemon_pid >/dev/null 2>&1; }

sqmar_hup() {
    local pid
    pid=$(sqmar_daemon_pid) || return 1
    kill -HUP "$pid" 2>/dev/null
}

# render, then tell the daemon (when it runs) to read the file again
sqmar_apply() {
    sqmar_render || { sqmar_err "could not write $SQMAR_CONF"; return 1; }
    if sqmar_hup; then
        echo "daemon told to reload (SIGHUP)"
    else
        echo "daemon is not running: the change is used when it starts"
    fi
    return 0
}

# leftovers of older versions (one-time cleanup at start)
sqmar_cleanup_legacy() {
    local l
    l=$(sqmar_profile_file default)
    if [ -L "$l" ]; then
        rm -f "$l" && echo "sqm-autorate: removed the old link $l (not used any more)"
    fi
    return 0
}

# ------------------------------------------------------------------ checks

# the sqm queue section of an interface: rate in kbit/s ("up" or "down"); nothing when unknown
sqmar_sqm_rate() {
    local ifc=${1%%.*} which=$2
    "$SQMAR_UCI" -q show sqm 2>/dev/null | awk -v ifc="$ifc" -v which="$which" -v q="'" '
    {
        i = index($0, "="); if (i == 0) next
        k = substr($0, 1, i - 1); v = substr($0, i + 1); gsub(q, "", v)
        n = split(k, p, ".")
        if (n == 3 && p[1] == "sqm") {
            if (!(p[2] in seen)) { seen[p[2]] = 1; order[++cnt] = p[2] }
            o[p[2], p[3]] = v
        }
    }
    END {
        for (j = 1; j <= cnt; j++) {
            s = order[j]; if (o[s, "enabled"] == "0") continue
            x = o[s, "interface"]; sub(/\.[0-9]+$/, "", x)
            if (x == ifc) { print o[s, (which == "up" ? "upload" : "download")]; exit }
        }
    }'
}

# sqmar_check NAME: findings, one per line, "ok ", "warn" or "FAIL" first. rc 0 clean, 1 warnings, 2 failure
sqmar_check() {
    local name=$1 f keys known miss unk obs dup bad warn=0 base_u base_d sq_u sq_d ifc v k
    f=$(sqmar_profile_file "$name")
    if ! sqmar_profile_exists "$name"; then
        echo "FAIL profile '$name' not found in $SQMAR_PROFILE_DIR"
        return 2
    fi
    [ -r "$f" ] || { echo "FAIL $f is not readable"; return 2; }

    bad=$(sqmar_conf_badlines "$f" | tr '\n' ' ')
    [ -z "$bad" ] || { echo "warn line(s) $bad are not key=value, the daemon ignores them"; warn=1; }

    keys=$(sqmar_conf_keys "$f" | sort -u)
    dup=$(sqmar_conf_keys "$f" | sort | uniq -d | tr '\n' ' ')
    [ -z "$dup" ] || { echo "warn key(s) set twice (the last one wins): $dup"; warn=1; }

    if known=$(sqmar_script_keys); then
        miss=$(for k in $known; do
            case " $SQMAR_OPTIONAL_KEYS " in *" $k "*) continue ;; esac
            printf '%s\n' "$keys" | grep -qx "$k" || printf '%s ' "$k"
        done)
        [ -z "$miss" ] || { echo "warn missing key(s): $miss"; echo "     -> built-in defaults apply, and after a reload the value of the previous profile stays"; warn=1; }
        unk=$(for k in $keys; do
            case " $SQMAR_DOC_KEYS $SQMAR_OBSOLETE_KEYS $SQMAR_OPTIONAL_KEYS " in *" $k "*) continue ;; esac
            printf '%s\n' "$known" | grep -qx "$k" || printf '%s ' "$k"
        done)
        [ -z "$unk" ] || { echo "warn unknown key(s), the daemon does not read them: $unk"; warn=1; }
    else
        echo "warn cannot read $SQMAR_SCRIPT, so the key list was not checked"; warn=1
    fi
    obs=$(for k in $keys; do
        case " $SQMAR_OBSOLETE_KEYS " in *" $k "*) printf '%s ' "$k" ;; esac
    done)
    [ -z "$obs" ] || { echo "warn obsolete key(s), ignored by the daemon: $obs"; warn=1; }

    # base rates against the sqm config of the upload interface
    ifc=$(sqmar_conf_get "$f" upload_interface 2>/dev/null); ifc=${ifc:-eth0}
    base_u=$(sqmar_conf_get "$f" upload_base_kbits 2>/dev/null)
    base_d=$(sqmar_conf_get "$f" download_base_kbits 2>/dev/null)
    sq_u=$(sqmar_sqm_rate "$ifc" up); sq_d=$(sqmar_sqm_rate "$ifc" down)
    if [ -n "$sq_u" ] && [ "$base_u" != auto ] && [ "$base_u" != "$sq_u" ]; then
        echo "warn upload_base_kbits=${base_u:-unset} but /etc/config/sqm says upload $sq_u for $ifc"; warn=1
    fi
    if [ -n "$sq_d" ] && [ "$base_d" != auto ] && [ "$base_d" != "$sq_d" ]; then
        echo "warn download_base_kbits=${base_d:-unset} but /etc/config/sqm says download $sq_d for $ifc"; warn=1
    fi

    if [ "$base_u" = auto ] && [ -z "$sq_u" ]; then
        echo "warn upload_base_kbits=auto but /etc/config/sqm has no upload rate for $ifc"; warn=1
    fi
    if [ "$base_d" = auto ] && [ -z "$sq_d" ]; then
        echo "warn download_base_kbits=auto but /etc/config/sqm has no download rate for $ifc"; warn=1
    fi

    v=$(sqmar_conf_get "$f" probe_setuid_fix 2>/dev/null)
    if [ "$v" = 1 ]; then
        echo "warn probe_setuid_fix=1: the daemon would run chmod u+s on fping and ping; it runs as root and does not need that"; warn=1
    fi

    [ "$warn" -eq 0 ] && echo "ok   profile '$name': all keys present, none unknown, base rates match the sqm config"
    return "$warn"
}

# fping or ping with the setuid bit: informational, never changed by this tool
sqmar_setuid_note() {
    local b p
    for b in fping ping; do
        p=$(command -v "$b" 2>/dev/null) || continue
        [ -u "$p" ] && printf '%s has the setuid bit (%s). Not needed (the daemon is root); to clear it: chmod u-s %s (writes flash)\n' "$b" "$p" "$p"
    done
    return 0
}

# ------------------------------------------------------------------ small helpers for the output

# "80Mbit", "1.5Gbit", "500Kbit" -> kbit/s
sqmar_to_kbit() {
    awk -v s="$1" 'BEGIN {
        if (match(s, /^[0-9.]+/) == 0) { print ""; exit }
        n = substr(s, 1, RLENGTH) + 0; u = tolower(substr(s, RLENGTH + 1))
        if (u == "gbit") n *= 1000000; else if (u == "mbit") n *= 1000; else if (u == "kbit") n *= 1; else if (u == "bit") n /= 1000; else { print ""; exit }
        printf "%d\n", n + 0.5
    }'
}

# the rate of the nsstbl root on a device, as tc prints it ("80Mbit"), or nothing
sqmar_shaper_rate() {
    "$SQMAR_TC" qdisc show dev "$1" 2>/dev/null | awk '/qdisc nsstbl/ { for (i = 1; i < NF; i++) if ($i == "rate") { print $(i + 1); exit } }'
}

# seconds the daemon has been running (from /proc), nothing when unknown
sqmar_uptime_s() {
    local l rest st up hz
    [ -r "$SQMAR_PROC/$1/stat" ] && [ -r "$SQMAR_PROC/uptime" ] || return 1
    hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
    l=$(cat "$SQMAR_PROC/$1/stat") || return 1
    rest=${l##*) }                      # the command name (field 2) may hold spaces; count from its closing parenthesis
    st=$(printf '%s\n' "$rest" | awk '{ print $20 }')   # field 22 of the line: start time in clock ticks
    up=$(awk '{ print int($1) }' "$SQMAR_PROC/uptime")
    case "$st$up$hz" in ''|*[!0-9]*) return 1 ;; esac
    echo $(( up - st / hz ))
}
