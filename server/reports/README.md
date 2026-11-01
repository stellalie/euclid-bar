# Crash reports and usage ping

Opt-in: `[privacy] crash_reports = true` in config.toml, or **Send Crash Reports** in the menu bar icon
or in search. Off until the user says yes: on first launch Euclid asks once, with crash reports and the usage ping
both pre-ticked. Nothing is sent before that, and nothing from before it was turned on.

## What's sent

One JSON `CrashReport` (`Sources/EuclidCore/Reports/CrashReport.swift`) per crash or internal error:

- app version, build, update channel, macOS version, CPU arch
- crashes: exception type, Swift's "Fatal error: …" line, the crashed thread's frames (from the macOS
  crash log in `~/Library/Logs/DiagnosticReports`, read on the next launch)
- errors: a category and message, for internal failures only (a store that won't open), once per launch
- a fingerprint, so repeats group

Never queries, clipboard, file contents, config, or IDs. `/Users/<name>` becomes `~`, emails become
`<email>`. Each report is saved to `~/Library/Logs/Euclid/Reports` before it's sent.

## Where it goes

`POST https://reports.lgtm.ninja/v1/report` → this Cloudflare Worker → one issue per bug, labelled
`crash-report`, in the private `stellalie/euclid-bar` repo. Repeats comment on the open issue (up to 50);
a bug that comes back after its issue closed opens a new one that links the old. The Worker checks every
field, caps sizes, allows 5 reports a minute per address, and keeps nothing. Sent text only appears inside
code fences, so it can't @mention anyone or add markup.

```sh
cd server/reports
npm test                                    # node --test, no dependencies
npx wrangler@4 deploy                       # Cloudflare login on first run
npx wrangler@4 secret put GITHUB_TOKEN      # fine-grained token: euclid-bar, Issues read/write
```

## Fixing them

A daily Claude routine reads open `crash-report` issues and, for each one without a fix PR:

1. Finds the code from the stack (`euclid-bar  Type.method + offset` frames; demangle with `swift demangle`
   if a symbol is mangled) or the error message.
2. Reproduces it in a test where it can (EuclidCore tests run on Linux: `scripts/test-core-linux.sh`).
3. Opens a PR that says `Fixes #<issue>`, and comments on the issue with the PR. Merges it once CI is
   green, as with any of Claude's PRs (CLAUDE.md).
4. If it can't find a cause, comments what it checked and labels the issue `needs-info`, and leaves it.

## Usage ping

Opt-in, offered pre-ticked in the first-launch prompt: `[privacy] usage_ping = true`, or **Send Anonymous Usage Ping** in the menu bar
icon or in search. Counts how many people use Euclid.

- Sent once per UTC day while Euclid runs (`UsagePing`, `Sources/EuclidCore/Reports/UsagePing.swift`):
  a random install ID, app version, build, channel, macOS version, CPU arch. The ID is made when the ping is
  turned on and deleted when it's turned off. The last one sent is in `~/Library/Logs/Euclid/Reports/usage-ping.json`.
- `POST /v1/ping` → one SQLite Durable Object (`src/pings.js`): one row per install per day (kept 90 days, macOS
  major version only), plus each install's first and last day. No IPs. 10 pings a minute per address.
- **Counts:** an hourly cron writes them to the issue "Install stats (opt-in usage ping)" in `stellalie/euclid-bar`
  (made on the first run, then edited in place): installs, active today / 7 / 30 days, 14 days of active and
  new installs, and last week's versions, macOS, channels and CPUs. Uses the same `GITHUB_TOKEN`.
