# koha-starman-worker-watcher

A small Perl daemon that watches the Starman workers backing each Koha
instance on a host, and posts a Slack alert when one exceeds a memory
threshold. On alert it can attach `strace` to the offending worker,
stream-compress the trace to disk, and include a tail of it in the
Slack message so you can see what the worker was stuck on. When a
worker is auto-killed it also greps `/var/log/koha/<instance>/` for
`4xx`/`5xx` access-log entries near the kill time so the culprit URL
shows up alongside the notice.

## What it does

Every `poll_interval_seconds`, the daemon scans `/proc` for processes
that look like Koha Starman workers (the worker proctitle is
`starman worker ...`, or the path to a `.pl` script when running a CGI
through `Plack::App::CGIBin`). For each worker it tracks:

- start time (so it can compute runtime),
- RSS (resident RAM, from `/proc/<pid>/status` `VmRSS`),
- swap used (from `VmSwap`),
- which Koha instance it belongs to (parsed from the `KOHA_CONF`
  environment variable, or by walking up to the `starman master` parent),
- the script path it is currently executing, if one is detectable from
  the proctitle (CGIBin rewrites it per request; REST API and plain
  Plack handlers leave it as `starman worker`, rendered `(none)`).

When a worker's RSS exceeds `memory_threshold_mb`, the daemon fires
**one** Slack alert for that PID, whether or not a script path is
visible in the proctitle. The daemon will not re-alert the same worker
again unless that PID dies and is reused.

On startup, if `slack.webhook_url` is set, the daemon also posts a
one-line heartbeat notice identifying the host and active thresholds.
This makes it easy to tell from Slack history when the watcher was
restarted.

## Install

```
sudo dpkg -i koha-starman-worker-watcher_*.deb
sudoedit /etc/koha-starman-worker-watcher/config.yaml   # set slack.webhook_url
sudo systemctl enable --now koha-starman-worker-watcher
```

Operational logs go to journald:

```
journalctl -u koha-starman-worker-watcher -f
```

Captures live under `/var/lib/koha-starman-worker-watcher/captures/`:
strace captures are named `<instance>-<pid>-<timestamp>.strace.gz`
(read with `zcat` / `zless`) and kill-time log bundles are named
`<instance>-<pid>-<timestamp>-<signal>.logs.txt`.

## Config

The shipped example at `/etc/koha-starman-worker-watcher/config.yaml`
is annotated. Key knobs:

| Setting | Default | Notes |
|---|---|---|
| `poll_interval_seconds` | 10 | How often the daemon rescans `/proc`. |
| `memory_threshold_mb` | 1024 | RSS (from `/proc/<pid>/status VmRSS`) bar above which a worker fires one alert. Also anchors the kill dwell clock. Swap is reported but not evaluated. |
| `kill_runtime_threshold_seconds` | (unset) | Optional. Dwell time: a worker must sustain RSS above `memory_threshold_mb` for this many seconds before being killed. If it drops below, the clock resets. |
| `kill_memory_threshold_mb` | (unset) | Optional. Additional current-RSS bar. When set, the worker must also currently exceed this value at kill time (ANDed with the dwell check). |
| `capture.enabled` | `true` | Top-level switch for all forensic probes on alert. |
| `capture.keep` | 50 | Maximum `.stack.txt` (and `.strace.gz`) files to retain. Oldest are unlinked after each new capture. Rotated per-type. |
| `capture.tail_lines` | 40 | Lines from the tail of the combined capture included inline in the Slack message. |
| `capture.gdb_enabled` | `false` | Run `gdb -batch -p PID -ex bt -ex detach` as part of the capture. Fast (~ms); does not risk an Apache 502. Requires the `gdb` package. Off by default — opt in per host. |
| `capture.gdb_timeout` | 10 | Seconds to wait on gdb before giving up. |
| `capture.strace_enabled` | `false` | Run `strace -p PID` for `strace_duration_seconds` and write a gzipped sidecar. Pauses the worker for the whole window — see "About strace overhead" below. Requires the `strace` package. |
| `capture.strace_duration_seconds` | 5 | Seconds to trace when `strace_enabled` is on. |
| `capture.perl_stack_signal` | `false` | Send SIGUSR2 to the worker and slurp a cooperating `Carp::longmess` dump. Requires `plack.psgi` to load `Koha::StarmanWorkerWatcher::Stack`; see the "Perl-level stack trace on alert" section below. Off by default because USR2's default OS disposition is Term. |
| `capture.perl_stack_wait` | 2 | Seconds to wait for the SIGUSR2 dump file before giving up. |
| `slack.enabled` | `true` | Set to `false` for log-only mode, alerts still go to journald and captures are still written, but nothing is POSTed and `webhook_url` is not required. |
| `slack.webhook_url` | (unset) | Required when `slack.enabled` is true. Daemon refuses to start without it (use `--dry-run` to override, or set `slack.enabled: false`). |
| `ignore_scripts` | `[]` | Basenames or paths to skip for alerts and kills. |
| `ignore_instances` | `[]` | Koha instance names to skip entirely. |

### Auto-kill

Kill is enabled when either `kill_runtime_threshold_seconds` or
`kill_memory_threshold_mb` is set.

`kill_runtime_threshold_seconds` is a **dwell time**: a worker must
sustain RSS above `memory_threshold_mb` for that many seconds before
being killed. If the worker's RSS drops back below
`memory_threshold_mb` at any scan, the dwell clock resets. This is the
common case — set `memory_threshold_mb: 1024` and
`kill_runtime_threshold_seconds: 1800` and the daemon will kill any
worker that stays above 1 GiB for 30 minutes.

`kill_memory_threshold_mb`, if also set, is an additional
current-RSS bar that must be exceeded at kill time (ANDed with the
dwell check). Use it when you want the dwell to apply only to the
most egregious workers — e.g. "only kill after 30 min over 1 GiB
**and** currently also over 4 GiB". Set alone (without
`kill_runtime_threshold_seconds`), it collapses to "kill immediately
on current RSS alone", bypassing the dwell.

The first time a worker satisfies the kill conditions the daemon
sends `SIGTERM`; if the same PID is still present on the next scan,
the daemon escalates to `SIGKILL`. Each signal is logged and posted
to Slack as a notice (`:skull: ... sent SIGTERM ...`).

After sending the signal, the daemon waits ~2s for Apache to notice
the dropped upstream, then scans these files under
`/var/log/koha/<instance>/`:

- `opac-access.log`, `intranet-access.log`, `plack.log` — kept if
  the line's timestamp is within ±60s of the kill **and** the status
  is `4xx`/`5xx` (this is where the `502 Bad Gateway` lands with the
  culprit URL).
- `opac-error.log`, `intranet-error.log` — kept if the line's
  timestamp is within ±60s of the kill. Multi-line continuations
  inherit the header line's timestamp.
- `plack-error.log` — last 20 lines verbatim (the format is
  inconsistent and usually has no parseable timestamp).

Everything is written to a `.logs.txt` bundle next to the strace
capture, and the access-log matches are included inline in the
Slack kill notice. Paths and thresholds are hard-coded; the feature
has no config knobs.

Alerts always fire the first time a worker crosses
`memory_threshold_mb`; the kill happens separately on dwell. In
practice you'll see a Slack alert first and, only if the worker stays
bloated for `kill_runtime_threshold_seconds`, a follow-up kill notice.

### Perl-level stack trace on alert

The gdb backtrace in a capture shows the C stack of the running worker
(libperl functions like `Perl_pp_multideref`, libmariadb calls, etc.).
Debian's stock perl does not ship debug symbols, so gdb cannot resolve
Perl-level variables like `PL_curcop`, which means the file/line of the
running Perl code isn't reachable from outside the process.

The watcher gets around this by signalling the worker and having the
worker introspect itself. This requires a one-time edit to each Koha
instance's `plack.psgi` so that workers carry a `SIGUSR2` handler
which writes a `Carp::longmess` backtrace to
`<capture.output_dir>/koha-stack-<pid>.txt`. At capture time the
watcher sends the signal, waits briefly for the dump to appear,
slurps its contents into the capture file (and the Slack alert tail),
and unlinks it.

This is **opt-in** and off by default. `SIGUSR2`'s OS-level default
disposition is **terminate the process**, so sending it to a worker
that hasn't loaded the handler would kill the very worker the
watcher is trying to inspect. Enable it only after completing the
`plack.psgi` wire-up on every instance served by this host.

#### Wire-up in plack.psgi

Edit `/etc/koha/sites/<instance>/plack.psgi` on every host where the
watcher runs. Add these two lines near the top of the file, right
after `use Modern::Perl;` and *before* any Koha module `use` lines,
so the handler is registered in the starman master and inherited by
every forked worker:

```perl
use Koha::StarmanWorkerWatcher::Stack;
Koha::StarmanWorkerWatcher::Stack->install;
```

Then restart the instance's plack:

```
sudo koha-plack --restart <instance>
```

Once the .deb is installed, `Koha::StarmanWorkerWatcher::Stack` sits
at `/usr/share/perl5/Koha/StarmanWorkerWatcher/Stack.pm`, which is on
Debian perl's default `@INC`, so no extra lib path is needed. For dev
work against an uninstalled checkout, prepend a `use lib '/path/to/
koha-starman-worker-watcher/lib';` line before the `use` above.

`/etc/koha/sites/<instance>/plack.psgi` is a concrete per-instance
file created by `koha-create`, not a symlink, so edits are durable
and survive package upgrades of `koha-common`. Any permanent change
would need to land in the Koha source template (not in this repo).

`install` reads `capture.output_dir` from
`/etc/koha-starman-worker-watcher/config.yaml` so the worker and the
watcher always agree on the dump path; if the config is unreadable
at plack start (it shouldn't be — it's a dpkg conffile) the handler
falls back to `/var/lib/koha-starman-worker-watcher/captures`, the
package default.

The handler is registration-only: it occupies one slot in `%SIG` and
has no runtime cost unless the watcher actually sends `SIGUSR2`.

#### Turning it on

After every instance's `plack.psgi` is wired up and restarted, flip
the flag in `config.yaml`:

```yaml
capture:
  perl_stack_signal: true
```

and restart the watcher:

```
sudo systemctl restart koha-starman-worker-watcher
```

The package creates `/var/lib/koha-starman-worker-watcher/captures`
with mode `1777` (sticky-bit world-writable, same discipline as
`/tmp`) so every instance's worker user can drop its own dump there.
The watcher runs as root and can always read and unlink. If your
environment needs stricter permissions, adjust the dir after install
— the only hard requirement is that every Koha worker user can
create files in it.

#### Verifying it's wired up

With the handler installed and plack restarted, pick any worker PID
under `starman master` and signal it by hand:

```
sudo kill -USR2 <pid>
ls /var/lib/koha-starman-worker-watcher/captures/koha-stack-<pid>.txt
```

If the file appears within a second or two, the handler is live.
Delete the file, then turn on `perl_stack_signal: true` and wait for
the next alert: captures and Slack tails will carry a
`=== Perl stack (pid <pid>, via SIGUSR2) ===` section with the full
Perl backtrace.

#### Limitations

Perl only dispatches safe signals between ops, so a worker blocked
deep inside a C-level call — a slow DBI query, a blocking `read`,
`sleep`, etc. — will not produce a dump until control returns to the
interpreter. In those cases the capture records
`(no dump within Ns -- handler not installed, or worker stuck in C)`
and gdb's C backtrace is still the useful piece (libmariadb frames
for DB stalls, `__skb_wait_for_more_packets` for genuinely idle
workers, and so on).

### Log-only mode

If you would rather scrape alerts from journald than push to Slack, set:

```yaml
slack:
  enabled: false
```

The daemon will start without a `webhook_url`, still run the evaluator,
still write captures to disk, and still log the full formatted alert
text to journald, it just never contacts Slack. Operational entries are
prefixed `[log-only slack]` and carry the same multi-line format as a
normal alert.

## Alert format

```
:rotating_light: Koha worker exceeded memory threshold
Instance: mylib
PID: 12345
Script: /usr/share/koha/intranet/cgi-bin/reports/guided_reports.pl
Runtime: 00:08:42
RSS: 1124.5 MiB
Swap: 12.0 MiB
Host: koha01
```
```
(capture tail, fenced — gdb backtrace, strace tail, and/or Perl
stack, depending on which probes are enabled)
```

## About forensic probe overhead

All three optional probes (`gdb_enabled`, `strace_enabled`,
`perl_stack_signal`) are `false` by default. A fresh install writes a
`.stack.txt` with only `/proc/<pid>/{wchan,syscall,stack}` — enough to
see where the worker is parked in the kernel, with no ptrace-attaching
or signalling. Opt probes in per host after weighing their cost.

**gdb** uses `ptrace` to attach, walk the C stack, and detach. The
worker is paused for tens of milliseconds, which is well under
Apache's `ProxyTimeout`, so the browser does not see a 502. Cost is
the ptrace attach itself and `gdb_timeout` seconds in the worst case
if the process is unresponsive.

**strace** also uses `ptrace`, but stays attached for the full
`strace_duration_seconds` window, intercepting every syscall. On an
I/O-heavy worker that is a 10–50× slowdown for the duration. An
in-flight request that takes longer than Apache's `ProxyTimeout`
will return a 502 to the end user. Turn on `strace_enabled` only when
you specifically need the syscall sequence (I/O stalls, looping
`read`/`write` patterns, socket behaviour, etc.) and pick a duration
comfortably under your `ProxyTimeout`.

**SIGUSR2 Perl stack** has essentially no overhead on the worker
(just a `Carp::longmess` + file write), but requires the plack.psgi
wire-up — see below. USR2 is dangerous without the handler, which is
why it is gated separately.

If you want captures off entirely — just the Slack alert with PID,
instance, script, runtime, RSS, and swap — set `capture.enabled:
false`.

## Building from source

```
prove -Ilib -r t/         # unit tests (no /proc required, uses fixtures)
dpkg-buildpackage -us -uc -b
```

CI builds the same artifacts on Debian 12 (bookworm) and 13 (trixie)
via `.github/workflows/build-deb.yml`.

## Possible future improvements

- **Warn + critical threshold tiers.** Today there is one threshold per
  metric. A `warn_*` / `critical_*` pair could drive two escalation
  levels with different Slack channels.
- **Swap-based alerting.** Swap is currently reported in the alert
  payload but is not itself a trigger condition; could become
  `swap_threshold_mb`.
- **Size- or age-based capture rotation.** `capture.keep` is a count
  cap; `max_total_mb` and `max_age_days` would complement it.
- **Persistent state across restarts.** The PID/alert map is in-memory
  only, so restarting the daemon will re-alert any worker that is
  *still* over threshold (once). Persisting to `/var/lib/.../state.json`
  would suppress that.
- **Lower-overhead capture backends.** `perf trace -p PID` (BPF-based)
  and `bpftrace` are meaningfully cheaper than `strace` for I/O-heavy
  workers, at the cost of needing newer kernels and extra packages.
- **`gdb` one-shot stack capture.** Complementary to strace, useful
  when a worker is stuck in user code and not making syscalls.
- **Drop privileges to a dedicated user.** The daemon currently runs as
  root because ptrace + cross-user `/proc/<pid>/environ` reads need it.
  A `koha-watcher` user with ambient `CAP_SYS_PTRACE` and
  `CAP_DAC_READ_SEARCH` capabilities would be tighter.
- **Prometheus metrics endpoint.** Expose gauges (workers tracked,
  alerts fired, captures written) on a local HTTP port for scraping.
- **Rate limiting / dedup window.** Today there is exactly one alert
  per `(PID, condition)`. A global per-minute ceiling would protect
  Slack from alert storms during incidents.
- **Config reload on `SIGHUP`.** Today config changes need a
  `systemctl restart`.
- **Additional CI targets.** Ubuntu LTS variants, `sbuild` against
  multiple Debian suites.

## License

GPL-3.0-or-later. See `debian/copyright`.
