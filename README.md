# koha-starman-worker-watcher

A small Perl daemon that watches the Starman workers backing each Koha
instance on a host, and posts a Slack alert when one runs too long or
eats too much memory. On alert it can attach `strace` to the offending
worker, stream-compress the trace to disk, and include a tail of it in
the Slack message so you can see what the worker was stuck on.

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

When a worker is **simultaneously** over `runtime_threshold_seconds`
**and** `memory_threshold_mb` on the same scan pass, the daemon fires
**one** Slack alert for that PID. The conditions are ANDed — crossing
only one threshold is ignored. The daemon will not re-alert the same
worker again unless that PID dies and is reused.

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

Captures live under `/var/lib/koha-starman-worker-watcher/captures/`,
named `<instance>-<pid>-<timestamp>.strace.gz`. Read them with `zcat` or
`zless`.

## Config

The shipped example at `/etc/koha-starman-worker-watcher/config.yaml`
is annotated. Key knobs:

| Setting | Default | Notes |
|---|---|---|
| `poll_interval_seconds` | 10 | How often the daemon rescans `/proc`. |
| `runtime_threshold_seconds` | 300 | Minimum worker runtime before it can alert. ANDed with `memory_threshold_mb`. |
| `memory_threshold_mb` | 1024 | Minimum RSS before the worker can alert. ANDed with `runtime_threshold_seconds`. Swap is reported but not evaluated. |
| `capture.enabled` | `true` | Attach `strace` on alert. |
| `capture.duration_seconds` | 5 | How long to trace. Note: strace will slow the traced worker for this window — see "About strace overhead" below. |
| `capture.keep` | 50 | Maximum `.strace.gz` files to retain. Oldest are unlinked after each new capture. |
| `capture.attach_tail_lines` | 40 | Lines from the tail of the trace included inline in the Slack message. |
| `slack.enabled` | `true` | Set to `false` for log-only mode — alerts still go to journald and captures are still written, but nothing is POSTed and `webhook_url` is not required. |
| `slack.webhook_url` | (unset) | Required when `slack.enabled` is true. Daemon refuses to start without it (use `--dry-run` to override, or set `slack.enabled: false`). |
| `ignore_scripts` | `[]` | Basenames or paths to skip for runtime alerts. |
| `ignore_instances` | `[]` | Koha instance names to skip entirely. |

### Log-only mode

If you would rather scrape alerts from journald than push to Slack, set:

```yaml
slack:
  enabled: false
```

The daemon will start without a `webhook_url`, still run the evaluator,
still write strace captures to disk, and still log the full formatted
alert text to journald — it just never contacts Slack. Operational
entries are prefixed `[log-only slack]` and carry the same multi-line
format as a normal alert.

## Alert format

```
:rotating_light: Koha worker exceeded runtime and memory thresholds
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
was already going to be slow — but if you would rather not pay that
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
- **Auto-kill of runaway workers.** Today the daemon is alert-only. A
  `kill_after_seconds` option could `SIGTERM` (then `SIGKILL`) workers
  that stay over threshold past a grace period.
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
- **`gdb` one-shot stack capture.** Complementary to strace — useful
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
