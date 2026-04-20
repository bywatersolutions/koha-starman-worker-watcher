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
`starman worker ...` when idle, or the path to a `.pl` script when
running a CGI through `Plack::App::CGIBin`). For each worker it tracks:

- start time (so it can compute runtime),
- RSS (resident RAM, from `/proc/<pid>/status` `VmRSS`),
- swap used (from `VmSwap`),
- which Koha instance it belongs to (parsed from the `KOHA_CONF`
  environment variable, or by walking up to the `starman master` parent),
- the script path it is currently executing (or `(idle)`).

When a worker's RSS exceeds `memory_threshold_mb` while it is serving
a request (i.e. not idle), the daemon fires **one** Slack alert for
that PID. The daemon will not re-alert the same worker again unless
that PID dies and is reused.

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
| `memory_threshold_mb` | 1024 | RSS (from `/proc/<pid>/status VmRSS`) bar above which a non-idle worker fires one alert. Also anchors the kill dwell clock. Swap is reported but not evaluated. |
| `kill_runtime_threshold_seconds` | (unset) | Optional. Dwell time: a worker must sustain RSS above `memory_threshold_mb` for this many seconds before being killed. If it drops below, the clock resets. |
| `kill_memory_threshold_mb` | (unset) | Optional. Additional current-RSS bar. When set, the worker must also currently exceed this value at kill time (ANDed with the dwell check). |
| `capture.enabled` | `true` | Attach `strace` on alert. |
| `capture.duration_seconds` | 5 | How long to trace. Note: strace will slow the traced worker for this window, see "About strace overhead" below. |
| `capture.keep` | 50 | Maximum `.strace.gz` files to retain. Oldest are unlinked after each new capture. |
| `capture.attach_tail_lines` | 40 | Lines from the tail of the trace included inline in the Slack message. |
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

Alerts always fire the first time a non-idle worker crosses
`memory_threshold_mb`; the kill happens separately on dwell. In
practice you'll see a Slack alert first and, only if the worker stays
bloated for `kill_runtime_threshold_seconds`, a follow-up kill notice.

### Log-only mode

If you would rather scrape alerts from journald than push to Slack, set:

```yaml
slack:
  enabled: false
```

The daemon will start without a `webhook_url`, still run the evaluator,
still write strace captures to disk, and still log the full formatted
alert text to journald, it just never contacts Slack. Operational
entries are prefixed `[log-only slack]` and carry the same multi-line
format as a normal alert.

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
(strace tail, fenced)
```

## About strace overhead

`strace` uses `ptrace`, so every syscall the worker makes is intercepted.
On an I/O-heavy worker that can be a 10–50× slowdown for the duration of
the capture. The watcher only attaches *after* the worker has already
crossed a threshold, so in practice you are slowing down a request that
was already going to be slow, but if you would rather not pay that
cost, set `capture.enabled: false` in the config. You will still get the
Slack alert with PID, instance, script, runtime, RSS, and swap.

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
