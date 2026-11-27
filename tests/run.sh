#!/bin/sh
# tests/run.sh - exercise the init script, switch-profile and sqm-status against a scratch root.
#
#   sh tests/run.sh            run with sh
#   SH=bash sh tests/run.sh    run the helpers with another shell (dash, bash, "busybox sh")
#
# Nothing outside a temporary directory is touched: SQMAR_ROOT points every path there, and uci, tc and fping
# are small stand-ins. A fake daemon records the SIGHUPs it gets. Needs GNU find (-printf) for the flash check.

SH=${SH:-sh}
HERE=$(cd "$(dirname "$0")/.." && pwd)
BIN=$HERE/files/usr/bin
LIBDIR=$HERE/files/usr/lib/sqm-autorate
PASS=0
FAILN=0

ok()  { PASS=$((PASS + 1)); }
bad() { FAILN=$((FAILN + 1)); printf 'FAIL: %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1" "expected: $2
got:      $3"; fi; }
yes() { desc=$1; shift; if "$@" >/dev/null 2>&1; then ok; else bad "$desc (expected success)"; fi; }
no()  { desc=$1; shift; if "$@" >/dev/null 2>&1; then bad "$desc (expected failure)"; else ok; fi; }
has() { if printf '%s' "$3" | grep -q -- "$2"; then ok; else bad "$1 (missing: $2)" "$3"; fi; }
hasnt() { if printf '%s' "$3" | grep -q -- "$2"; then bad "$1 (unexpected: $2)" "$3"; else ok; fi; }

# --------------------------------------------------------------------------- scratch root
T=$(mktemp -d "${TMPDIR:-/tmp}/sqmar-test.XXXXXX") || exit 1
export SQMAR_ROOT=$T
export SQMAR_LIB=$LIBDIR
trap 'kill "$DPID" 2>/dev/null; rm -rf "$T"' EXIT INT TERM
DPID=

reset_root() {
    kill "$DPID" 2>/dev/null; DPID=
    rm -rf "$T"; mkdir -p "$T"
    mkdir -p "$T/etc/sqm-profiles" "$T/etc/logrotate.d" "$T/usr/bin" "$T/usr/share/sqm-autorate" "$T/var/run" "$T/var/log" "$T/stub" "$T/fake"
    cp "$HERE"/files/etc/sqm-profiles/*.conf "$T/etc/sqm-profiles/"
    cp "$HERE/files/etc/sqm-default" "$T/etc/sqm-default"
    cp "$HERE/files/usr/bin/sqm-autorate.pl" "$T/usr/bin/"
    cp "$HERE/files/etc/logrotate.d/sqm-autorate" "$T/etc/logrotate.d/"
    cp "$HERE/files/usr/share/sqm-autorate/logrotate.conf" "$T/usr/share/sqm-autorate/"
    # uci: the sqm config of the router (queue section named eth1 on interface eth0, like the real one)
    cat > "$T/stub/uci" <<'EOT'
#!/bin/sh
[ "$1" = "-q" ] && shift
[ "$1" = show ] && [ "$2" = sqm ] && cat "$SQMAR_ROOT/stub/uci.sqm"
EOT
    printf "sqm.eth1=queue\nsqm.eth1.interface='eth0'\nsqm.eth1.enabled='1'\nsqm.eth1.upload='80000'\nsqm.eth1.download='830000'\n" > "$T/stub/uci.sqm"
    cat > "$T/stub/tc" <<'EOT'
#!/bin/sh
[ "$1 $2 $3" = "qdisc show dev" ] && cat "$SQMAR_ROOT/stub/tc.$4" 2>/dev/null
EOT
    echo "qdisc nsstbl 1: root refcnt 2 rate 76500Kbit burst 12Kb mtu 1518b" > "$T/stub/tc.eth0"
    echo "qdisc nsstbl 1: root refcnt 2 rate 1.5Gbit burst 99Kb mtu 1518b" > "$T/stub/tc.nssifb"
    chmod 755 "$T/stub/uci" "$T/stub/tc"
    export UCI=$T/stub/uci TC=$T/stub/tc
    # a fake daemon (the process name must contain sqm-autorate.pl): counts SIGHUPs
    cat > "$T/fake/sqm-autorate.pl" <<'EOT'
#!/bin/sh
trap 'echo hup >> "$SQMAR_ROOT/hup.log"' HUP
while :; do sleep 0.1; done
EOT
}

start_daemon() {
    : > "$T/hup.log"
    SQMAR_ROOT=$T sh "$T/fake/sqm-autorate.pl" &
    DPID=$!
    echo "$DPID" > "$T/var/run/sqm-autorate.pid"
    sleep 0.3
}
hups() { sleep 0.3; wc -l < "$T/hup.log" | tr -d ' '; }

# a stand-in for "is flash untouched": every file under etc with inode, mtime, size (a rewrite with equal
# content still changes the inode)
flash() { find "$T/etc" -printf '%y %p %i %T@ %s\n' | sort; }

run() { $SH "$@"; }
sw()  { run "$BIN/switch-profile" "$@"; }
st()  { run "$BIN/sqm-status" "$@"; }
conf_get() { . "$LIBDIR/common.sh"; sqmar_conf_get "$@"; }

# ============================================================================ names, listing
reset_root
. "$LIBDIR/common.sh"
for n in custom gaming a_b-1 X; do yes "valid name $n" sqmar_valid_name "$n"; done
for n in '' '../x' 'a b' 'a/b' 'a.b' '$(id)' 'abcdefghijklmnopqrstuvwxyzabcdefghij'; do no "invalid name '$n'" sqmar_valid_name "$n"; done

# the old version left a symlink sqm-autorate-default.conf; it must not count as a profile
ln -s "$T/etc/sqm-profiles/sqm-autorate-custom.conf" "$T/etc/sqm-profiles/sqm-autorate-default.conf"
eq "profiles listed, legacy link left out" "custom debug gaming performance streaming" "$(sqmar_list_profiles | tr '\n' ' ' | sed 's/ $//')"
out=$(sw default --default 2>&1); rc=$?
eq "switch-profile default --default fails (S1)" 1 "$rc"
has "S1 message" "not found" "$out"
eq "boot profile untouched by the failed call" custom "$(cat "$T/etc/sqm-default")"
[ -L "$T/etc/sqm-profiles/sqm-autorate-default.conf" ] && ok || bad "S1: the link was changed"
no "S1: no self-referencing link" test "$(readlink "$T/etc/sqm-profiles/sqm-autorate-default.conf")" = "$T/etc/sqm-profiles/sqm-autorate-default.conf"

# ============================================================================ rendering (D1) and the symlink case (T2)
reset_root
# the state an old version leaves: /var/sqm-autorate.conf is a symlink to the profile
ln -s "$T/etc/sqm-profiles/sqm-autorate-custom.conf" "$T/var/sqm-autorate.conf"
before=$(cksum < "$T/etc/sqm-profiles/sqm-autorate-custom.conf")
st reload >/dev/null 2>&1
[ -L "$T/var/sqm-autorate.conf" ] && bad "T2: runtime file is still a symlink" || ok
yes "runtime file is a regular file" test -f "$T/var/sqm-autorate.conf"
eq "T2: the profile on flash was not touched" "$before" "$(cksum < "$T/etc/sqm-profiles/sqm-autorate-custom.conf")"
has "rendered header names the profile" "^# profile: custom" "$(cat "$T/var/sqm-autorate.conf")"
eq "rendered upload base" 80000 "$(conf_get "$T/var/sqm-autorate.conf" upload_base_kbits)"
eq "quotes removed from the reflector list" "1.1.1.1 9.9.9.9 8.8.8.8" "$(conf_get "$T/var/sqm-autorate.conf" reflectors)"
eq "inline comment removed" 0 "$(conf_get "$T/var/sqm-autorate.conf" probe_setuid_fix)"

# ============================================================================ switching: memory only, SIGHUP
reset_root; start_daemon
f0=$(flash)
out=$(sw gaming 2>&1); rc=$?
eq "switch to gaming succeeds" 0 "$rc"
eq "flash untouched by a switch" "$f0" "$(flash)"
eq "active profile in memory" gaming "$(cat "$T/var/run/sqm-autorate/profile")"
eq "rendered file is the gaming profile" gaming "$(sed -n 's/^# profile: //p' "$T/var/sqm-autorate.conf")"
eq "rendered gaming value (latency_low_up_ms)" 9 "$(conf_get "$T/var/sqm-autorate.conf" latency_low_up_ms)"
eq "daemon got one SIGHUP" 1 "$(hups)"
has "boot profile reported" "boot profile stays: custom" "$out"
eq "sqm-status current" "Active profile: gaming" "$(st current)"
eq "switch-profile current" gaming "$(sw current)"
has "no-argument view marks active and boot" "gaming (active)" "$(sw)"
has "no-argument view marks boot" "custom (boot)" "$(sw)"

# --default writes /etc/sqm-default once, and not again when nothing changes
sw performance --default >/dev/null 2>&1
eq "default written" performance "$(cat "$T/etc/sqm-default")"
f1=$(flash)
out=$(sw performance --default 2>&1)
has "second --default says flash is not written" "flash not written" "$out"
eq "no flash write when the default is unchanged" "$f1" "$(flash)"
no "bad option rejected" sw gaming --bogus
no "bad name rejected" sw '../etc/passwd'
no "unknown profile rejected" sw nope
eq "active profile unchanged after the rejected calls" performance "$(sw current)"

# a stale pid must not receive a signal: put the pid of a plain sleep in the pidfile
sleep 30 & SP=$!
echo "$SP" > "$T/var/run/sqm-autorate.pid"
st reload >/dev/null 2>&1
if kill -0 "$SP" 2>/dev/null; then ok; else bad "a process that is not the daemon got the SIGHUP"; fi
kill "$SP" 2>/dev/null
echo "$DPID" > "$T/var/run/sqm-autorate.pid"

# ============================================================================ set / unset / reset (T1, T3, T4, T10)
reset_root; start_daemon
# a profile that lacks log_level (T1: the old sed fallback never fired)
printf 'upload_base_kbits=80000\ndownload_base_kbits=830000\nlog_enabled=1\n' > "$T/etc/sqm-profiles/sqm-autorate-tiny.conf"
sw tiny >/dev/null 2>&1
f0=$(flash)
out=$(st set log_level 2 2>&1)
eq "T1: set works for a key the profile does not have" 2 "$(conf_get "$T/var/sqm-autorate.conf" log_level)"
eq "T1: runtime override file" "log_level=2" "$(cat "$T/var/run/sqm-autorate/override.conf")"
eq "flash untouched by set" "$f0" "$(flash)"
st log-level-0 >/dev/null 2>&1
eq "T10: level 0 can be set" 0 "$(conf_get "$T/var/sqm-autorate.conf" log_level)"
eq "no duplicate line after a second set" 1 "$(grep -c '^log_level=' "$T/var/run/sqm-autorate/override.conf")"
eq "get shows the source" "log_level=0   (runtime setting, memory)" "$(st get log_level)"
st unset log_level >/dev/null 2>&1
no "unset removed the runtime setting" conf_get "$T/var/sqm-autorate.conf" log_level
st reflector-count 4 >/dev/null 2>&1
st alpha-ewma 0.25 >/dev/null 2>&1
st log-format-json >/dev/null 2>&1
eq "reflector-count" 4 "$(conf_get "$T/var/sqm-autorate.conf" reflector_count)"
eq "alpha-ewma" 0.25 "$(conf_get "$T/var/sqm-autorate.conf" alpha_ewma)"
eq "log-format-json" json "$(conf_get "$T/var/sqm-autorate.conf" log_format)"
st reset >/dev/null 2>&1
no "reset dropped everything" test -e "$T/var/run/sqm-autorate/override.conf"
# the profile on flash keeps its inline comments: the toggles never touch it
reset_root; start_daemon
before=$(cksum < "$T/etc/sqm-profiles/sqm-autorate-custom.conf")
st log-level-2 >/dev/null 2>&1; st probe-min 120 >/dev/null 2>&1
eq "profile file unchanged by toggles" "$before" "$(cksum < "$T/etc/sqm-profiles/sqm-autorate-custom.conf")"

# rejected input
for bad_in in "log_level 9" "log_level x" "log_level -1" "reflector_count 3/d" "reflector_count 0" "alpha_ewma 1.5" "alpha_ewma a" \
              "log_format yaml" "upload_base_kbits 5" "nonsense 1" "reflectors 1.1.1.1" "probe_ms 99999999999"; do
    # shellcheck disable=SC2086
    no "rejected: set $bad_in" st set $bad_in
done
no "set without a value" st set log_level
no "T4: unknown command" st log-levl-2
no "log-level-3 refused" st log-level-3
out=$(st log-level-3 2>&1); has "log-level-3 explains why" "does not exist" "$out"
no "no override written by rejected input" test -s "$T/var/run/sqm-autorate/override.conf" -a "$(grep -vc '^log_level=2\|^probe_min_ms=120' "$T/var/run/sqm-autorate/override.conf")" != 0
eq "the sed attack leaves the profile alone" "$before" "$(cksum < "$T/etc/sqm-profiles/sqm-autorate-custom.conf")"

# a switch drops runtime settings and says so
out=$(sw gaming 2>&1)
has "switch announces the dropped settings" "dropping 2 runtime setting" "$out"
no "override file gone after the switch" test -e "$T/var/run/sqm-autorate/override.conf"

# ============================================================================ save / unsave (flash only on request)
reset_root; start_daemon
st log-level-2 >/dev/null 2>&1
f0=$(flash)
out=$(st save 2>&1)
has "save writes flash" "flash written" "$out"
yes "saved file exists" test -s "$T/etc/sqm-profiles/sqm-autorate-custom.override"
eq "saved content" "log_level=2" "$(cat "$T/etc/sqm-profiles/sqm-autorate-custom.override")"
no "runtime file emptied after save" test -e "$T/var/run/sqm-autorate/override.conf"
eq "rendered value after save" 2 "$(conf_get "$T/var/sqm-autorate.conf" log_level)"
eq "get shows it as saved" "log_level=2   (saved setting, flash)" "$(st get log_level)"
f1=$(flash)
out=$(st save 2>&1); has "nothing to save" "no runtime settings" "$out"
st log-level-2 >/dev/null 2>&1
out=$(st save 2>&1); has "same value: not written again" "already saved" "$out"
eq "no flash write for an unchanged save" "$f1" "$(flash)"
sw gaming >/dev/null 2>&1
eq "other profile does not use custom's saved setting" 1 "$(conf_get "$T/var/sqm-autorate.conf" log_level)"
sw custom >/dev/null 2>&1
eq "saved setting returns with its profile" 2 "$(conf_get "$T/var/sqm-autorate.conf" log_level)"
st unsave >/dev/null 2>&1
no "unsave removed the file" test -e "$T/etc/sqm-profiles/sqm-autorate-custom.override"
eq "value back to the profile's" 1 "$(conf_get "$T/var/sqm-autorate.conf" log_level)"

# ============================================================================ status commands change nothing
reset_root; start_daemon
f0=$(flash); r0=$(find "$T/var" -type f | sort | xargs cksum 2>/dev/null)
for c in status full current rates check keys "get log_level"; do
    # shellcheck disable=SC2086
    out=$(st $c 2>&1); rc=$?
    [ "$rc" -le 1 ] && ok || bad "sqm-status $c exited $rc" "$out"
done
eq "flash untouched by the read-only commands" "$f0" "$(flash)"
out=$(st 2>&1)
has "overview: daemon" "daemon      running" "$out"
has "overview: profile" "profile     custom" "$out"
has "overview: shaper rate and percent" "eth0.*76500Kbit.*= 76500 kbit/s, 96% of base 80000" "$out"
has "overview: nssifb in Gbit" "nssifb.*1.5Gbit.*= 1500000 kbit/s" "$out"
has "overview: log flags" "log         enabled=1 level=1 mode=1 format=json" "$out"
has "overview: checks line" "checks" "$out"
echo 12345 > "$T/var/run/sqm-autorate.pid"
st >/dev/null 2>&1
yes "T6: the overview leaves a stale pidfile alone" test -f "$T/var/run/sqm-autorate.pid"
kill "$DPID"; DPID=
out=$(st 2>&1); has "daemon not running is reported" "NOT running" "$out"
no "no daemon: reload still renders, exit 0" test "$(st reload >/dev/null 2>&1; echo $?)" != 0

# ============================================================================ check (S3, P2, P3)
reset_root
out=$(st check 2>&1); rc=$?
eq "custom is clean" 0 "$rc"
has "clean message" "^ok " "$out"
P=$T/etc/sqm-profiles/sqm-autorate-bad.conf
grep -v '^hold_after_decrease_ms=' "$T/etc/sqm-profiles/sqm-autorate-custom.conf" > "$P"
printf 'made_up_key=1\nload_bias_threshold_bytes=5\nlog_level=2\nnot a setting\nupload_base_kbits=85000\nprobe_setuid_fix=1\n' >> "$P"
out=$(st check bad 2>&1); rc=$?
eq "findings give exit 1" 1 "$rc"
has "missing key named" "missing key(s): .*hold_after_decrease_ms" "$out"
has "unknown key named" "unknown key(s).*made_up_key" "$out"
has "obsolete key named" "obsolete key(s).*load_bias_threshold_bytes" "$out"
has "duplicate named" "set twice.*log_level" "$out"
has "bad line number" "line(s) .* are not key=value" "$out"
has "P2: base rate against the sqm config" "upload_base_kbits=85000 but /etc/config/sqm says upload 80000" "$out"
has "P3: setuid fix flagged" "probe_setuid_fix=1" "$out"
no "check of a missing profile fails" st check nope
eq "missing profile gives exit 2" 2 "$(st check nope >/dev/null 2>&1; echo $?)"
# auto is accepted as a base rate
sed -i 's/^upload_base_kbits=.*/upload_base_kbits=auto/' "$P"
hasnt "auto base rate is not a mismatch" "upload_base_kbits=auto but" "$(st check bad 2>&1)"
# "auto" for the base rates (the daemon reads them from /etc/config/sqm)
reset_root
out=$(st set upload_base_kbits auto 2>&1); rc=$?
eq "set upload_base_kbits auto is accepted" 0 "$rc"
eq "auto lands in the rendered file" auto "$(conf_get "$T/var/sqm-autorate.conf" upload_base_kbits)"
out=$(st set download_base_kbits fast 2>&1); rc=$?
eq "a word other than auto is refused" 2 "$rc"
has "the refusal mentions auto" "or auto" "$out"
has "keys lists auto" "upload_base_kbits .*or auto" "$(st keys 2>&1)"
st reset >/dev/null 2>&1
: > "$T/stub/uci.sqm"
sed 's/^upload_base_kbits=.*/upload_base_kbits=auto/' "$T/etc/sqm-profiles/sqm-autorate-custom.conf" > "$T/etc/sqm-profiles/sqm-autorate-autop.conf"
out=$(st check autop 2>&1)
has "auto without an sqm rate is flagged" "upload_base_kbits=auto but /etc/config/sqm has no upload rate" "$out"
reset_root
# a setuid fping is reported, never changed
mkdir -p "$T/pathbin"; printf '#!/bin/sh\n' > "$T/pathbin/fping"; chmod 4755 "$T/pathbin/fping"
out=$(PATH="$T/pathbin:$PATH" st check 2>&1)
has "setuid fping reported" "fping has the setuid bit" "$out"
eq "mode of fping untouched" "-rwsr-xr-x" "$(ls -l "$T/pathbin/fping" | cut -c1-10)"

# ============================================================================ the parser matches the daemon's
reset_root
cat > "$T/parse.conf" <<'EOT'
# comment
  indented_key = spaced value   # trailing comment
quoted="a b c"
single='x y'
hash=val#notcomment
empty=
dup=1
dup=2
equals=a=b
   # indented comment
no_equals_line
tabbed	=	7
EOT
perl -e '
    my $src = do { local $/; open my $f, "<", $ARGV[0] or die; <$f> };
    $src =~ /(sub parse_kv_line \{.*?\n\})/s or die "parse_kv_line not found"; eval $1; die $@ if $@;
    my %c; open my $c, "<", $ARGV[1] or die;
    while (my $l = <$c>) { chomp $l; my ($k, $v) = parse_kv_line($l); next unless defined $k; $c{$k} = $v; }
    print "$_=$c{$_}\n" for sort keys %c;' "$HERE/files/usr/bin/sqm-autorate.pl" "$T/parse.conf" > "$T/perl.out"
for k in $(sqmar_conf_keys "$T/parse.conf" | sort -u); do printf '%s=%s\n' "$k" "$(sqmar_conf_get "$T/parse.conf" "$k")"; done | sort > "$T/sh.out"
eq "shell parser = daemon parser" "$(cat "$T/perl.out")" "$(cat "$T/sh.out")"

# ============================================================================ the init script
reset_root; start_daemon
cat > "$T/initrun.sh" <<'EOT'
# stand-ins for the procd helpers: print what the init script asks for
procd_open_instance()  { echo "open"; }
procd_close_instance() { echo "close"; }
procd_set_param()      { echo "param $*"; }
procd_add_reload_trigger() { echo "trigger $*"; }
. "$INIT"
EOT
initrun() { INIT=$HERE/files/etc/init.d/sqm-autorate $SH -c ". \"$T/initrun.sh\"; $1" 2>&1; }
ln -s "$T/etc/sqm-profiles/sqm-autorate-custom.conf" "$T/etc/sqm-profiles/sqm-autorate-default.conf"
out=$(initrun "start_service; service_triggers")
has "init: command" "param command $T/usr/bin/sqm-autorate.pl" "$out"
has "init: respawn" "param respawn" "$out"
has "init: env points at the runtime file" "CONFIG=$T/var/sqm-autorate.conf" "$out"
has "init: pidfile and log passed to the daemon" "PIDFILE=$T/var/run/sqm-autorate.pid LOGFILE=$T/var/log/sqm-autorate.log" "$out"
has "init: reload trigger on the sqm config" "trigger sqm" "$out"
hasnt "init: no pidfile param (the daemon owns it)" "param pidfile" "$out"
hasnt "init: no file param for the log" "param file" "$out"
hasnt "init: no 8.8.8.8 gate" "8.8.8.8" "$(cat "$HERE/files/etc/init.d/sqm-autorate")"
hasnt "init: does not wait for nsstbl" "nsstbl" "$(cat "$HERE/files/etc/init.d/sqm-autorate")"
has "init: removes the legacy link" "removed the old link" "$out"
no "init: the legacy link is gone" test -e "$T/etc/sqm-profiles/sqm-autorate-default.conf" -o -L "$T/etc/sqm-profiles/sqm-autorate-default.conf"
yes "init: config rendered at start" test -f "$T/var/sqm-autorate.conf"
# a start with nothing running and the daemon missing from the process table does not fail
: > "$T/hup.log"
out=$(initrun reload_service); rc=$?
eq "init: reload exit code" 0 "$rc"
eq "init: reload sends SIGHUP" 1 "$(hups)"
# a reload renders again: a profile edited on disk shows up in the runtime file
before=$(sqmar_conf_get "$T/var/sqm-autorate.conf" log_level)
if [ "$before" = 0 ]; then newlv=2; else newlv=0; fi
sed -i "s/^log_level=.*/log_level=$newlv/" "$T/etc/sqm-profiles/sqm-autorate-custom.conf"
initrun reload_service >/dev/null
eq "init: reload renders the profile again" "$newlv" "$(sqmar_conf_get "$T/var/sqm-autorate.conf" log_level)"
kill "$DPID"; DPID=; rm -f "$T/var/run/sqm-autorate.pid"
# a pidfile that names some other live process is not the daemon: it must not get the signal
sleep 30 & OTHER=$!
echo "$OTHER" > "$T/var/run/sqm-autorate.pid"
no "stale pidfile naming another process: not running" sqmar_running
out=$(initrun reload_service); rc=$?
eq "init: reload with a foreign pid is not an error" 0 "$rc"
yes "the foreign process was left alone (no SIGHUP)" kill -0 "$OTHER"
st reload >/dev/null 2>&1
yes "sqm-status reload leaves the foreign process alone" kill -0 "$OTHER"
kill "$OTHER" 2>/dev/null; rm -f "$T/var/run/sqm-autorate.pid"
out=$(initrun reload_service); rc=$?
eq "init: reload with no daemon is not an error" 0 "$rc"
has "init: says it is not running" "not running" "$out"
# no profile at all: the init still starts the daemon (built-in defaults)
rm -f "$T"/etc/sqm-profiles/*.conf "$T/etc/sqm-default"
out=$(initrun start_service)
has "init: still opens the instance without profiles" "^open" "$out"
has "init: warns about missing profiles" "no usable profile" "$out"

# ============================================================================ boot profile fallbacks
reset_root
rm -f "$T/etc/sqm-default"
eq "no default file: custom" custom "$(sqmar_boot_name)"
echo "gone" > "$T/etc/sqm-default"
eq "default names a missing profile: custom" custom "$(sqmar_boot_name)"
echo "  gaming  " > "$T/etc/sqm-default"
eq "blanks around the default are ignored" gaming "$(sqmar_boot_name)"
rm -f "$T/etc/sqm-profiles/sqm-autorate-custom.conf"
echo "gone" > "$T/etc/sqm-default"
eq "no custom: first profile found" debug "$(sqmar_boot_name)"

# ============================================================================ log rotation commands
reset_root
touch "$T/etc/logrotate.d/sqm-autorate.disabled"
st rotate-off >/dev/null 2>&1
no "rotate-off removes the file" test -e "$T/etc/logrotate.d/sqm-autorate"
no "rotate-off removes a leftover .disabled" test -e "$T/etc/logrotate.d/sqm-autorate.disabled"
st rotate-on >/dev/null 2>&1
yes "rotate-on restores it" test -f "$T/etc/logrotate.d/sqm-autorate"
eq "rotation file equals the template" "$(cat "$T/usr/share/sqm-autorate/logrotate.conf")" "$(cat "$T/etc/logrotate.d/sqm-autorate")"
has "shipped rotation keeps one copy" "rotate 1" "$(cat "$HERE/files/etc/logrotate.d/sqm-autorate")"

# ============================================================================ the profile checker catches drift
reset_root
cp -r "$HERE" "$T/repo" 2>/dev/null
rm -rf "$T/repo/.git"
yes "check-profiles passes on the repo" $SH "$T/repo/tools/check-profiles.sh" "$T/repo"
sed -i '/^cap_load_percent=/d' "$T/repo/files/etc/sqm-profiles/sqm-autorate-gaming.conf"
no "check-profiles fails on a missing key" $SH "$T/repo/tools/check-profiles.sh" "$T/repo"
cp "$HERE/files/etc/sqm-profiles/sqm-autorate-gaming.conf" "$T/repo/files/etc/sqm-profiles/"
sed -i 's/^upload_base_kbits=.*/upload_base_kbits=85000/' "$T/repo/files/etc/sqm-profiles/sqm-autorate-gaming.conf"
no "check-profiles fails on differing base rates" $SH "$T/repo/tools/check-profiles.sh" "$T/repo"
cp "$HERE/files/etc/sqm-profiles/sqm-autorate-gaming.conf" "$T/repo/files/etc/sqm-profiles/"
printf '\nmystery=1\n' >> "$T/repo/files/etc/sqm-profiles/sqm-autorate-gaming.conf"
no "check-profiles fails on an unknown key" $SH "$T/repo/tools/check-profiles.sh" "$T/repo"
# a new key in the script is noticed
cp "$HERE/files/etc/sqm-profiles/sqm-autorate-gaming.conf" "$T/repo/files/etc/sqm-profiles/"
sed -i 's/\$cfg{"calm_window_cycles"}/$cfg{"calm_window_cycles"} \/\/ $cfg{"brand_new_key"}/' "$T/repo/files/usr/bin/sqm-autorate.pl"
no "check-profiles notices a key added to the script" $SH "$T/repo/tools/check-profiles.sh" "$T/repo"

# the version of the daemon and of the package are the same number
v_pl=$(sed -n 's/^my \$VERSION *= *"\([0-9]*\)";.*/\1/p' "$HERE/files/usr/bin/sqm-autorate.pl")
v_mk=$(sed -n 's/^PKG_VERSION:=//p' "$HERE/openwrt/sqm-autorate-nss/Makefile")
eq "daemon version = package version" "$v_mk" "$v_pl"
# every file under files/ is installed with the mode the package needs
for f in etc/init.d/sqm-autorate usr/bin/sqm-autorate.pl usr/bin/sqm-status usr/bin/switch-profile; do
    [ -x "$HERE/files/$f" ] && ok || bad "$f is not executable in the repository"
done

printf '\n%s passed, %s failed (helpers run with: %s)\n' "$PASS" "$FAILN" "$SH"
[ "$FAILN" -eq 0 ]
