# sqm-autorate-nss

A small daemon for Qualcomm NSS routers (IPQ806x: Netgear R7800, TP-Link Archer C2600) that keeps the SQM shaper matched to what the line can carry right now.

SQM on these routers runs on the NSS cores: `nss-rk.qos` builds an `nsstbl` token bucket with an `nssfq_codel` queue behind it, one for upload (on `eth0`) and one for download (on `nssifb`). Those rates are fixed numbers from `/etc/config/sqm`. When the real capacity of the line drops (a busy cable segment, a congested peer, a noisy evening), a fixed rate that is too high lets queues build upstream of the shaper and latency goes up. This daemon pings a few public servers with `fping` (the probes of one cycle run side by side), watches the round-trip time, and changes the rate of the two `nsstbl` roots with `tc qdisc change`: down when the latency rises, back up when it is quiet. It never creates or deletes a qdisc; building the shaper stays the job of `nss-rk.qos`.

## Contents

* [Requirements](#requirements)
* [Installation](#installation)
* [Memory first, flash only on request](#memory-first-flash-only-on-request)
* [Daily use](#daily-use)
* [Profiles](#profiles)
* [Command reference](#command-reference)
* [Working with nss-rk.qos](#working-with-nss-rkqos)
* [Setting it up for your line](#setting-it-up-for-your-line)
* [When something looks wrong](#when-something-looks-wrong)
* [Upgrades and sysupgrade](#upgrades-and-sysupgrade)
* [Tests](#tests)
* [Licence](#licence)

## Requirements

* An NSS build with `nss-rk.qos` working on the WAN device (`sqm-scripts-nss`, see the README of that repository). The daemon only changes a shaper that already exists.
* `sqm-scripts` (the `sqm` service and `/etc/config/sqm`), a `tc` that knows the NSS qdiscs, and `fping`.
* Perl with the modules `POSIX`, `IO::Handle`, `Fcntl`, `IPC::Open3` and `Symbol`, and `Time::HiRes` for good throughput timing. On OpenWrt these are the packages `perl`, `perlbase-posix`, `perlbase-io`, `perlbase-fcntl`, `perlbase-ipc`, `perlbase-symbol` and `perlbase-time`.
* `logrotate` is optional: without it the daemon still empties its own log when it reaches 5 MB.

## Installation

### In your own build

    echo "src-git sqm_autorate_nss https://github.com/nihilt/sqm-autorate-nss.git" >> feeds.conf
    ./scripts/feeds update sqm_autorate_nss
    ./scripts/feeds install sqm-autorate-nss

Enable `sqm-autorate-nss` in `make menuconfig` (Network, Quality of Service). The dependencies above are pulled in by the package. Dependencies that earlier versions listed and the daemon does not use (`ip-full`, `iputils-ping`, `jsonfilter`, `procps-ng`, `coreutils`, `logrotate` and a few perl modules) are no longer pulled in; select any of them in the configuration if you want them in the image for other reasons.

### On a running router

Copy the contents of `files/` to the same places under `/` (keep the modes: scripts are 755), then:

    chmod 755 /etc/init.d/sqm-autorate /usr/bin/sqm-autorate.pl /usr/bin/sqm-status /usr/bin/switch-profile
    /etc/init.d/sqm-autorate enable
    /etc/init.d/sqm-autorate start

`/usr/lib/sqm-autorate/common.sh` is new in this version and is needed by the init script and both helpers: it must be copied too.

### First check

    sqm-status
    sqm-status check

The second command compares the active profile with the script and with `/etc/config/sqm` and says what it found. Fix anything it names before relying on the daemon.

## Memory first, flash only on request

Flash memory wears out, and an autorate daemon that rewrites files all day would be a bad neighbour. Everything this package does is kept in memory (`/var`, a tmpfs) and is gone at the next reboot, unless you ask for it to be kept:

| What | Where it lives | Written to flash when |
|---|---|---|
| The configuration the daemon reads, `/var/sqm-autorate.conf` | memory | never (rebuilt at every start, reload and change) |
| Which profile is active | memory | never |
| Settings changed with `sqm-status set`, `log-on` and friends | memory | never |
| Settings you choose to keep (`/etc/sqm-profiles/sqm-autorate-NAME.override`) | flash | `sqm-status save` (and removed by `sqm-status unsave`) |
| Which profile starts at boot (`/etc/sqm-default`) | flash | `switch-profile NAME --default`, and only when the name changes |
| The profiles themselves (`/etc/sqm-profiles/sqm-autorate-NAME.conf`) | flash | when you edit them |
| Log rotation file (`/etc/logrotate.d/sqm-autorate`) | flash | `sqm-status rotate-on` / `rotate-off` |
| The log, `/var/log/sqm-autorate.log` | memory | never |

Starting, stopping, reloading and switching profiles write nothing to flash. The daemon's configuration file is built from the active profile, then the settings you saved for it, then the settings you changed since boot; where a key appears more than once the last one wins.

## Daily use

    sqm-status                      # overview: daemon, profile, shaper rates, checks, last log lines
    sqm-status full                 # the same, plus every saved and runtime setting and 20 log lines
    switch-profile                  # the active profile, the boot profile, the available profiles
    switch-profile gaming           # use the gaming profile now (until the next reboot)
    switch-profile gaming --default # ... and at every boot

The overview of a healthy router looks like this (R7800, 80 Mbit/s up, 875 Mbit/s down):

    daemon      running, PID 1873, up 00:00:00
    profile     custom
    settings    0 runtime (memory), 0 saved for this profile (flash)
    shaper
      eth0     76500Kbit  = 76500 kbit/s, 96% of base 80000
      nssifb   875Mbit  = 875000 kbit/s, 100% of base 875000
    log         enabled=1 level=1 mode=1 format=json, rotation on
    probing     reflectors=3 (roundrobin), probe_min=100 ms, alpha_ewma=0.4, setuid_fix=0
    checks      ok

Changing a setting for the moment, then keeping it:

    sqm-status set log_level 2          # applied at once, memory only
    sqm-status get log_level            # log_level=2   (runtime setting, memory)
    sqm-status save                     # keep the runtime settings for this profile (writes flash)
    sqm-status reset                    # or: drop the runtime settings and go back to the profile

Settings are checked before they are applied. A value outside the range the daemon accepts is refused with the range, and nothing changes:

    $ sqm-status set probe_ms 5
    sqm-autorate: probe_ms must be from 50 to 5000

Switching profile drops the runtime settings, because they were made on top of the previous profile (settings you saved with `save` belong to their profile and stay with it). The command says so:

    $ switch-profile gaming
    dropping 1 runtime setting(s): log_level=2
    profile: custom -> gaming (memory only)
    daemon told to reload (SIGHUP)
    boot profile stays: custom  (add --default to change it)

The service itself is a normal procd service: `start`, `stop`, `restart`, `reload`, `enable`, `disable`. `/etc/init.d/sqm-autorate status` prints `running` or `inactive`, which is all that OpenWrt's own `status` does; use `sqm-status` for the detail. The service also reloads by itself when `/etc/config/sqm` changes.

## Profiles

A profile is a file `/etc/sqm-profiles/sqm-autorate-NAME.conf` with lines `key=value`. A `#` starts a comment, also after a value (with a space before it); quotes around a value are removed. Every profile sets every key the daemon reads, so that switching never leaves a value of the previous profile behind. `sqm-autorate-custom.conf` is the reference: each key has a comment with its meaning, its accepted range and the built-in default. The two keys `eqdisc_opts` and `iqdisc_opts` are the exception: leave them out and the options of `/etc/config/sqm` are used.

| | custom | debug | gaming | performance | streaming |
|---|---|---|---|---|---|
| Purpose | daily driver | troubleshooting | lowest latency | throughput first | steady video |
| Floor up / down (% of base) | 60 / 60 | 40 / 40 | 50 / 60 | 70 / 70 | 50 / 50 |
| Latency low / high, up (ms) | 13 / 17 | 15 / 25 | 9 / 13 | 12 / 18 | 12 / 20 |
| Latency low / high, down (ms) | 14 / 19 | 18 / 30 | 11 / 16 | 15 / 22 | 15 / 25 |
| Step up, up / down (%) | 15 / 15 | 3 / 3 | 20 / 20 | 18 / 15 | 8 / 7 |
| Step down, up / down (%) | 12 / 12 | 3 / 3 | 10 / 15 | 6 / 7 | 5 / 6 |
| Probe interval, normal / fast (ms) | 200 / 100 | 500 / 300 | 150 / 80 | 250 / 150 | 300 / 200 |
| Reflectors | 3 | 5 | 3 | 5 | 3 |
| Adaptive floor | off | on | on | on | on |
| Load-aware bias | on | on | on | off | on |
| Log | json, level 1 | verbose, level 2, every cycle | json, level 1 | compact, level 1 | compact, level 1 |

`custom` holds the values the author runs. The other four were regenerated for this version from the same key list and have the same base rates; they are starting points that have not been tuned against the current daemon. Try one, watch `sqm-status` and the log, and adjust.

All profiles share the same base rates (`upload_base_kbits`, `download_base_kbits`). They must equal `upload` and `download` in `/etc/config/sqm`; `sqm-status check` tells you when they do not. Instead of a number you can write `auto`: the daemon then takes the rate from the queue section of `/etc/config/sqm` that belongs to the upload interface, so the two can never disagree, and a change of that config makes the service reload (the init script watches it). If the sqm config has no usable rate for `auto`, the daemon warns and keeps the previous value.

Edit a profile with any editor, then `sqm-status reload`. A restart (`/etc/init.d/sqm-autorate restart`) is needed only after you add or remove a key.

To make your own profile, copy one to a new name (`sqm-autorate-night.conf`) and `switch-profile night`. Names use letters, digits, `-` and `_`, up to 32 characters.

## Command reference

`sqm-status` (no argument: overview)

| Command | What it does | Writes flash |
|---|---|---|
| `full` | overview, every runtime and saved setting, the profile check, the last 20 log lines | no |
| `current` | name of the active profile | no |
| `rates` | the rate each shaper has now, next to its base rate | no |
| `check [NAME]` | compares a profile with the daemon's keys, the `/etc/config/sqm` rates and the `fping` setuid bit | no |
| `get KEY` | the value in use and where it comes from (profile, saved, runtime) | no |
| `keys` | the keys `set` accepts, with their ranges | no |
| `log-live` | follows the log until Ctrl+C | no |
| `set KEY VALUE`, `unset KEY`, `reset` | change one runtime setting, drop one, drop all | no |
| `reload` | renders the configuration again and tells the daemon | no |
| `log-on`, `log-off`, `log-level-0/1/2`, `log-mode-0/1/2`, `log-format-compact/verbose/json` | logging settings | no |
| `reflector-count N`, `reflector-rotation-random/roundrobin` | reflector settings | no |
| `probe-min MS`, `probe-setuid-on/off`, `alpha-ewma V` | probing settings | no |
| `log-clear` | empties the log | no |
| `save` | keeps the runtime settings for the active profile | yes, if they differ from what is saved |
| `unsave` | forgets the settings saved for the active profile | yes |
| `rotate-on`, `rotate-off` | puts the logrotate file in place or removes it | yes |

Log levels are 0 (errors only), 1 (normal) and 2 (with per-cycle details); log modes are 0 (silent), 1 (on rate changes) and 2 (every cycle). With `log_format=json` every event line, after the timestamp, is one JSON object: `{"event":"rate_change","cycle":163,"shaper_up":73100,"shaper_down":830000,"latency":{"up":13.3,"down":13.4},"measured_up":4,"measured_down":4,"floors":{"up":86,"down":89}}`. Rates are kbit/s, latencies are milliseconds, floors are percent of the base rate; a latency that is not known yet is `null`. The events are `startup`, `rate_change` and `tick`.

`switch-profile`

| Command | What it does |
|---|---|
| (none) | the active profile, the boot profile, the available profiles |
| `list`, `current` | the names, or the active name |
| `NAME` | use NAME now; the boot profile stays as it is |
| `NAME --default` | use NAME now and at every boot (writes `/etc/sqm-default` only when the name changes) |

Before it switches, `switch-profile` runs the same check as `sqm-status check` on the target profile and prints what it finds. Findings do not stop the switch.

### Looking at the daemon itself

    sqm-autorate.pl --version                 # the version, and nothing else
    sqm-autorate.pl --check                   # read /var/sqm-autorate.conf, say what a start would complain about
    sqm-autorate.pl --check /etc/sqm-profiles/sqm-autorate-night.conf

`--check` reads the configuration the way a start does and prints the warnings (an unusable base rate, an unknown interface, no pinger, low thresholds above high ones, ...). It exits 0 when there is nothing to report and 1 otherwise. It starts no daemon and never touches a running one: no pidfile, no `tc` call, no log entry. A profile file is not exactly what the daemon reads (the init script renders it together with your saved and runtime settings), but it is the quickest check of a profile you have just edited.

## Working with nss-rk.qos

`nss-rk.qos` (from `sqm-scripts-nss`) builds the shaper; this daemon steers it. Three things connect them:

* After every successful SQM start `nss-rk.qos` asks a running daemon to reload (`nss_reload_autorate`, on by default). SQM has just put the static rates back, and the reload makes the daemon take its rates and burst from the new shaper. It never starts the daemon: if you want autorate at boot, `enable` the service.
* The daemon does not wait for SQM at start. With no shaper yet it waits quietly and picks it up when SQM has built it.
* The base rates in the profile must equal the rates in `/etc/config/sqm`. When the line changes, change both, then `sqm-status reload`.

The daemon understands the single queue and the `nssprio` upload classes of `nss-rk.qos` (`nss_dscp_classes '1'`): with classes it changes only the rate of the root and leaves the three queues alone. It does not know `nsswrr` or `nsswfq`; stop it if you use those.

## Setting it up for your line

1. Switch SQM off and run a bufferbloat test (for example the Waveform one) to learn what the line really delivers, up and down.
2. In `/etc/config/sqm` set `upload` and `download` a little below that, and start SQM with `nss-rk.qos`.
3. Put the same two numbers in every profile you use (`upload_base_kbits`, `download_base_kbits`) and run `sqm-status check`.
4. Reflectors: the profiles ping public resolvers (1.1.1.1, 9.9.9.9, 8.8.8.8). Put your provider's gateway or DNS server in front of them in `reflectors`, in every profile you use; a target close to you measures your own line rather than the internet beyond it. Try each address first, `fping -c 5 ADDRESS ADDRESS`, and keep only those that answer every time.
5. Start the daemon, load the line, and watch `sqm-status` (the shaper rate against its base) and the log. Adjust the latency thresholds and the steps of the profile until the rate follows the line without swinging.
6. `/etc/init.d/sqm-autorate enable` for the start at boot; `switch-profile NAME --default` if the boot profile should not be `custom`.

## When something looks wrong

Start with `sqm-status full`; it shows the check, the settings and the log tail. The log is `/var/log/sqm-autorate.log`. The lines that matter, and what to do:

| Log line or sign | Meaning | What to do |
|---|---|---|
| `Config: missing ... using built-in defaults` | the daemon found no configuration file | `sqm-status reload`; if it persists, `ls /etc/sqm-profiles` |
| `Reload failed; keeping previous config` | the new file could not be read | `sqm-status check`, fix the profile, reload |
| `Failed to apply ... root rate` | `tc` refused the new rate | `tc -s qdisc show dev eth0`; is SQM running with `nss-rk.qos`? |
| `Latency measurement failed: no valid samples` / `no usable reflector samples; holding rates` | no reflector answered | rates are held; check the WAN, `fping 1.1.1.1`, and `sqm-status check` for the `fping` finding below |
| `sqm-status` says `daemon NOT running` | the process is gone | `/etc/init.d/sqm-autorate start`; procd restarts it if it crashes |
| `check` says `fping has the setuid bit` | the bit is not needed, because the daemon runs as root; `check` only reports it | `chmod u-s /usr/bin/fping` if you want it cleared (writes flash; the daemon changes the bit only with `probe_setuid_fix=1`) |
| `check` says `upload_base_kbits=... but /etc/config/sqm says upload ...` | the profile and the SQM config disagree | make them equal |
| `check` says `missing key(s)` | a profile lacks a key the daemon reads | add it (see the custom profile), then restart |
| shaper rate stays at the base rate | the line is quiet, or the daemon does not see load | `sqm-status log-level-2`, load the line, read the log |

## Upgrades and sysupgrade

`/lib/upgrade/keep.d/sqm-autorate` makes sysupgrade keep `/etc/sqm-profiles/` (profiles and saved settings), `/etc/sqm-default` and the logrotate file. The program files are part of the image and are not kept: do not list `/etc/init.d/sqm-autorate`, `/usr/bin/sqm-status` or `/usr/bin/switch-profile` in `/etc/sysupgrade.conf`, or an old copy replaces the new one after the flash (the new init script needs `/usr/lib/sqm-autorate/common.sh` from the same version).

If you ran an older version: it left a symlink `/etc/sqm-profiles/sqm-autorate-default.conf`. The init script removes it once, at the first start (the only write to flash that happens without a command from you). The profile that was linked is still there under its own name, and `/etc/sqm-default` still names the boot profile.

## Tests

`tests/run.sh` runs the init script, `switch-profile` and `sqm-status` against a scratch directory with stand-ins for `uci`, `tc` and the daemon; nothing on the machine is touched. It checks, among other things, that the read-only commands leave `/etc` byte for byte as it was and that each command writes flash only where the table above says so. `tests/daemon.sh` runs the real daemon for a few seconds at a time against stand-ins for `tc`, `uci` and `fping`: `--version` and `--check`, `auto` base rates, JSON log lines, a reload that cannot read its file, probes that run side by side.

    sh tests/run.sh
    SH=bash sh tests/run.sh      # the helpers under another shell
    sh tests/daemon.sh           # the daemon, about 40 seconds
    sh tools/check-profiles.sh   # every profile has every key the daemon reads, none unknown, same base rates

The same checks run on each push (`.github/workflows/check.yml`). What they cannot cover is the router itself: the procd reload trigger, BusyBox applet details and the NSS firmware.

## Licence

GNU General Public License version 3, see [LICENSE](LICENSE).
