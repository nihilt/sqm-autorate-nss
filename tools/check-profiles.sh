#!/bin/sh
# check-profiles.sh - compare every profile with the keys sqm-autorate.pl reads.
#
#   sh tools/check-profiles.sh [REPO_DIR]
#
# Fails (exit 1) when a profile lacks a key the daemon reads, carries a key it does not read, still has an
# obsolete key, sets a key twice, or has a line that is not key=value. The key list is taken from the script
# itself, so it cannot drift from the code. Also checks that every profile sets the same base rates and that
# the log rotation template is identical to the installed rotation file.

repo=${1:-$(cd "$(dirname "$0")/.." && pwd)}
export SQMAR_ROOT=$repo/.nonexistent       # nothing under it is used; only the paths below matter
SQMAR_LIB=${SQMAR_LIB:-$repo/files/usr/lib/sqm-autorate}
# shellcheck disable=SC1091
. "$SQMAR_LIB/common.sh" || exit 1
SQMAR_SCRIPT=$repo/files/usr/bin/sqm-autorate.pl
SQMAR_PROFILE_DIR=$repo/files/etc/sqm-profiles
SQMAR_UCI=false                             # no sqm config here: the base-rate comparison is skipped

fail=0
n=0
for name in $(sqmar_list_profiles); do
    n=$((n + 1))
    out=$(sqmar_check "$name"); rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'FAIL %s\n' "$name"
        printf '%s\n' "$out" | sed 's/^/     /'
        fail=1
    else
        printf 'ok   %s\n' "$name"
    fi
done
[ "$n" -gt 0 ] || { echo "no profiles found in $SQMAR_PROFILE_DIR"; exit 1; }

# one base rate everywhere (the profiles are meant to be interchangeable)
for key in upload_base_kbits download_base_kbits; do
    vals=$(for name in $(sqmar_list_profiles); do sqmar_conf_get "$(sqmar_profile_file "$name")" "$key"; done | sort -u)
    if [ "$(printf '%s\n' "$vals" | wc -l)" -ne 1 ]; then
        echo "FAIL $key differs between profiles: $(printf '%s' "$vals" | tr '\n' ' ')"
        fail=1
    fi
done

# the boot profile named in /etc/sqm-default must exist
def=$(sqmar_first_word "$repo/files/etc/sqm-default")
sqmar_profile_exists "$def" || { echo "FAIL files/etc/sqm-default names '$def', which is not a profile"; fail=1; }

if ! cmp -s "$repo/files/etc/logrotate.d/sqm-autorate" "$repo/files/usr/share/sqm-autorate/logrotate.conf"; then
    echo "FAIL files/etc/logrotate.d/sqm-autorate and files/usr/share/sqm-autorate/logrotate.conf differ"
    fail=1
fi

[ "$fail" -eq 0 ] && echo "all $n profiles ok"
exit "$fail"
