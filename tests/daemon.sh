#!/bin/sh
# tests/daemon.sh - run sqm-autorate.pl against stand-ins for tc, uci and fping, in a scratch directory.
#
#   sh tests/daemon.sh                 test the daemon in this repository
#   DAEMON=/path/old.pl sh tests/daemon.sh   run the same checks on another copy (for comparing versions)
#
# Needs perl (JSON::PP is a core module) and a /sys/class/net/eth0. Takes about 40 seconds.

HERE=$(cd "$(dirname "$0")/.." && pwd)
DAEMON=${DAEMON:-$HERE/files/usr/bin/sqm-autorate.pl}
PROFILE=$HERE/files/etc/sqm-profiles/sqm-autorate-custom.conf
PASS=0
FAILN=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAILN=$((FAILN + 1)); printf 'FAIL: %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1" "expected: $2
got:      $3"; fi; }
has() { if printf '%s' "$3" | grep -q -- "$2"; then ok; else bad "$1 (missing: $2)" "$3"; fi; }
hasnt() { if printf '%s' "$3" | grep -q -- "$2"; then bad "$1 (unexpected: $2)" "$3"; else ok; fi; }

[ -d /sys/class/net/eth0 ] || { echo "skipped: no /sys/class/net/eth0"; exit 0; }

T=$(mktemp -d "${TMPDIR:-/tmp}/sqmar-daemon.XXXXXX") || exit 1
trap 'kill $DPID 2>/dev/null; rm -rf "$T"' EXIT INT TERM
DPID=
mkdir -p "$T/bin" "$T/tcdir" "$T/var/log" "$T/var/run"

# ----------------------------------------------------------------------------- stand-ins
cat > "$T/bin/fping" <<'EOT'
#!/bin/sh
# fping -c1 -tMS TARGET. FAKE_LAT: ms to report (or "fail"); FAKE_DELAY: seconds to take
[ "$1" = "--version" ] && { echo "fping: Version 5.1"; exit 0; }
for a; do t=$a; done
echo "$t" >> "$FAKE_DIR/fping.log"
[ -n "$FAKE_DELAY" ] && sleep "$FAKE_DELAY"
lat=$(cat "$FAKE_DIR/lat" 2>/dev/null || echo 5.0)
if [ "$lat" = fail ]; then echo "$t : xmt/rcv/%loss = 1/0/100%" >&2; exit 1; fi
echo "$t : [0], 64 bytes, $lat ms ($lat avg, 0% loss)"
echo "$t : xmt/rcv/%loss = 1/1/0%, min/avg/max = $lat/$lat/$lat" >&2
EOT
# the fake tc is not on the PATH: only a daemon that uses $TC finds it
cat > "$T/tcdir/tc" <<'EOT'
#!/bin/sh
# records every call; "qdisc show" prints an nsstbl root and leaf; counters grow with the time (FAKE_BPS bytes/s)
echo "$*" >> "$FAKE_DIR/tc.log"
case "$*" in
  *"qdisc change"*) exit 0 ;;
  *"qdisc show dev "*)
    dev=$(echo "$*" | sed 's/.*qdisc show dev \([^ ]*\).*/\1/')
    sent=$(awk -v bps="${FAKE_BPS:-0}" 'BEGIN { "date +%s" | getline t; printf "%d", (t - 1700000000) * bps }')
    echo "qdisc nsstbl 1: dev $dev root refcnt 2 buffer/maxburst 10654b rate 80Mbit mtu 1522b accel_mode 0"
    case " $* " in *" -s "*) echo " Sent $sent bytes 1000 pkt (dropped 0, overlimits 0 requeues 0)"; echo " backlog 0b 0p requeues 0" ;; esac
    echo "qdisc nssfq_codel 10: dev $dev parent 1: target 3.5ms limit 350p interval 50ms flows 1024 quantum 304 set_default accel_mode 0"
    case " $* " in *" -s "*) echo " Sent $sent bytes 1000 pkt (dropped 0, overlimits 0 requeues 0)"; echo " backlog 0b 0p requeues 0" ;; esac ;;
esac
exit 0
EOT
cat > "$T/bin/uci" <<'EOT'
#!/bin/sh
[ "$1" = "-q" ] && shift
[ "$1" = show ] && cat "$FAKE_DIR/uci.sqm"
EOT
chmod 755 "$T/bin/"* "$T/tcdir/tc"
printf "sqm.eth1=queue\nsqm.eth1.interface='eth0'\nsqm.eth1.upload='72000'\nsqm.eth1.download='640000'\n" > "$T/uci.sqm"
export FAKE_DIR=$T
cp "$T/uci.sqm" "$T/uci.sqm.keep"
mkdir -p "$T/net/eth0" "$T/net/nssifb"; echo 1500 > "$T/net/eth0/mtu"; echo 1500 > "$T/net/nssifb/mtu"

# a configuration for the tests: the shipped custom profile, then quick probes and the log wide open
mkconf() {   # mkconf FILE [extra key=value lines...]
    f=$1; shift
    { cat "$PROFILE"; printf 'probe_ms=100\nprobe_fast_ms=50\nprobe_min_ms=50\nlog_enabled=1\nlog_level=2\nlog_mode=2\nlog_format=json\n'; for l in "$@"; do echo "$l"; done; } > "$f"
}
# the daemon, with everything pointed into the scratch directory
d() {
    PATH="$T/bin:$PATH" CONFIG=$CONF PIDFILE=$T/var/run/d.pid LOGFILE=$T/var/log/d.log TC=$T/tcdir/tc UCI=$T/bin/uci SYSFS_NET=$T/net \
        timeout 8 perl "$DAEMON" "$@"      # timeout: an older daemon ignores the options and would run on
}
# in the background the daemon replaces its subshell (exec), so $! is the daemon itself and kill reaches it
startd() {
    : > "$T/var/log/d.log"; : > "$T/tc.log"
    ( exec env PATH="$T/bin:$PATH" CONFIG=$CONF PIDFILE=$T/var/run/d.pid LOGFILE=$T/var/log/d.log TC=$T/tcdir/tc UCI=$T/bin/uci SYSFS_NET=$T/net \
        perl "$DAEMON" ) &
    DPID=$!
}
stopd()  { kill -TERM "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; DPID=; }

CONF=$T/test.conf
mkconf "$CONF" upload_base_kbits=80000 download_base_kbits=830000

# ============================================================================ --version and --check never touch the running daemon
echo 4242 > "$T/var/run/d.pid"; : > "$T/tc.log"
out=$(d --version 2>&1); rc=$?
eq "--version exit" 0 "$rc"
has "--version text" "^sqm-autorate [0-9]" "$out"
eq "--version leaves the pidfile alone" 4242 "$(cat "$T/var/run/d.pid")"
eq "--version runs no tc" 0 "$(wc -l < "$T/tc.log" | tr -d ' ')"

out=$(d --check "$CONF" 2>&1); rc=$?
eq "--check on a good configuration: exit" 0 "$rc"
has "--check says ok" "^check: ok" "$out"
eq "--check leaves the pidfile alone" 4242 "$(cat "$T/var/run/d.pid")"
eq "--check runs no tc (the shaper is not touched)" 0 "$(grep -c 'qdisc change' "$T/tc.log")"
[ ! -s "$T/var/log/d.log" ] && ok || bad "--check wrote to the log"

mkconf "$T/bad.conf" upload_base_kbits=fast
out=$(d --check "$T/bad.conf" 2>&1); rc=$?
eq "--check on a bad base rate: exit 1" 1 "$rc"
has "--check names the key" "upload_base_kbits 'fast'" "$out"
out=$(d --check "$T/missing.conf" 2>&1); rc=$?
eq "--check on a missing file: exit 1" 1 "$rc"
out=$(d --bogus 2>&1); rc=$?
eq "unknown option: exit 2" 2 "$rc"
eq "unknown option leaves the pidfile alone" 4242 "$(cat "$T/var/run/d.pid")"
rm -f "$T/var/run/d.pid"

# ============================================================================ "auto" base rates come from the sqm config
mkconf "$T/auto.conf" upload_base_kbits=auto download_base_kbits=auto
out=$(d --check "$T/auto.conf" 2>&1); rc=$?
eq "auto: --check passes" 0 "$rc"
CONF=$T/auto.conf; startd; sleep 2; stopd
has "auto: upload root at the sqm rate" "change dev eth0 root handle 1: nsstbl rate 72000kbit" "$(cat "$T/tc.log")"
has "auto: download root at the sqm rate" "change dev nssifb root handle 1: nsstbl rate 640000kbit" "$(cat "$T/tc.log")"
# no usable rate in the sqm config: warn, keep the built-in value
printf "sqm.eth1=queue\nsqm.eth1.interface='eth0'\n" > "$T/uci.sqm"
out=$(d --check "$T/auto.conf" 2>&1); rc=$?
eq "auto without an sqm rate: --check finds it" 1 "$rc"
has "auto warning" "upload_base_kbits=auto, but the sqm config has no usable 'upload'" "$out"
cp "$T/uci.sqm.keep" "$T/uci.sqm"

json_ok() {   # json_ok DESCRIPTION: every {...} after the timestamp in the log must parse
    perl -MJSON::PP -e '
        my ($bad, $n) = (0, 0);
        while (my $l = <STDIN>) { next unless $l =~ /^\[[^\]]+\] (\{.*\})\s*$/; $n++; my $j = eval { decode_json($1) }; if (!$j) { $bad++; print "invalid: $1\n"; } }
        print "checked $n lines, $bad invalid\n"; exit($bad ? 1 : 0)' < "$T/var/log/d.log" > "$T/json.out" 2>&1 \
        && ok || bad "json: $1: lines that are not JSON" "$(cat "$T/json.out")"
}
# ============================================================================ JSON log lines are JSON
CONF=$T/test.conf; export FAKE_BPS=1000000; startd; sleep 3; stopd
n=$(grep -c '"event"' "$T/var/log/d.log")
[ "$n" -ge 3 ] && ok || bad "json: expected some event lines, found $n"
json_ok "tick and startup lines"
has "json: startup line has numbers and null" '"event":"startup","cycle":0,"shaper_up":80000,"shaper_down":830000,"latency":{"up":null,"down":null}' "$(cat "$T/var/log/d.log")"

# rate-change lines (log_mode 1), while the line is loaded and slow
mkconf "$T/json1.conf" log_mode=1 upload_base_kbits=80000 download_base_kbits=830000
CONF=$T/json1.conf; echo 60.0 > "$T/lat"; export FAKE_BPS=10000000; startd; sleep 4; stopd; rm -f "$T/lat"
has "json: rate_change events appear" '"event":"rate_change"' "$(cat "$T/var/log/d.log")"
json_ok "rate_change lines"
CONF=$T/test.conf

# ============================================================================ the counters are read with $TC
export FAKE_BPS=1000000; startd; sleep 2; stopd
has "A6: tc -s qdisc show goes through \$TC" "^-s qdisc show dev eth0" "$(cat "$T/tc.log")"

# ============================================================================ a reload that cannot read the file does not replace the configuration
CONF=$T/reload.conf; mkconf "$CONF" upload_base_kbits=80000 download_base_kbits=830000
startd; sleep 1.5
rm -f "$CONF"; kill -HUP "$DPID"; sleep 1
log=$(cat "$T/var/log/d.log")
has "A8: missing file counts as a failed reload" "Reload failed; keeping previous config" "$log"
kill -0 "$DPID" 2>/dev/null && ok || bad "A8: the daemon died on a failed reload"
mkconf "$CONF" upload_base_kbits=79000 download_base_kbits=830000
kill -HUP "$DPID"; sleep 1
has "A8: a good file reloads again" "Rates base: up=79000k" "$(cat "$T/var/log/d.log")"
stopd

# ============================================================================ probes of one cycle run side by side
CONF=$T/test.conf
mkconf "$CONF" reflector_count=3 upload_base_kbits=80000 download_base_kbits=830000
export FAKE_DELAY=0.3; : > "$T/fping.log"; startd; sleep 3.3; stopd; unset FAKE_DELAY
calls=$(wc -l < "$T/fping.log" | tr -d ' ')
# three probes of 0.3 s: one after the other about 3 cycles in 3.3 s (9 calls), side by side about 10 cycles (30 calls)
[ "$calls" -ge 20 ] && ok || bad "A4: probes seem to run one after the other ($calls fping calls in 3.3 s, expected 20 or more)"
leftover=$(ps -eo args 2>/dev/null | grep -c "[f]ping -c1")
eq "A4: no probe processes left behind" 0 "$leftover"

# a failing reflector is reported with its reason, and the daemon holds its rates
echo fail > "$T/lat"; startd; sleep 2; stopd; rm -f "$T/lat"
has "failed probes are reported" "no usable reflector samples; holding rates" "$(cat "$T/var/log/d.log")"

printf '\n%s passed, %s failed (daemon: %s)\n' "$PASS" "$FAILN" "$DAEMON"
[ "$FAILN" -eq 0 ]
