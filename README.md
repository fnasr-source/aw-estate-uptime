# aw-estate-uptime

A small public-hosts uptime monitor. Every 15 minutes a GitHub Actions run fetches
each host over HTTPS and requires a final HTTP 200. A host going down is sent to the
Admireworks alert router (one email plus push); only when the router cannot be reached
does the run fail on purpose, so GitHub's own "run failed" email reaches the account
that owns the workflow. A recovery or a silent monitor is a morning-page line and never
fails the run. No push service and no paid service. Nothing else is monitored here and
no Google Cloud resource is used (a Cloud Monitoring check would bill through the
shared card and die with it).

This README is the public README. The canonical source lives in the Admireworks
Internal OS repo at `scripts/estate-uptime/`. The public repo is published by
copying files from there. Never edit the public repo directly.

## Files

| In Internal OS (`scripts/estate-uptime/`) | In the public repo | Notes |
|---|---|---|
| `check.sh` | `check.sh` | the checker, also runs locally |
| `estate-uptime.yml` | `.github/workflows/estate-uptime.yml` | the workflow |
| `README.md` | `README.md` | this file |
| `hosts.json` | **never copied** | the host list; stays in Internal OS only |
| (created by the heartbeat job) | `heartbeat.txt` | one date, committed monthly |

Public repo contents are exactly: `README.md`, `check.sh`, `.github/workflows/estate-uptime.yml`
and `heartbeat.txt`. There is no host file. The workflow log is public, so host names
are kept in an Actions secret and masked with `::add-mask::` in every log line.

## What the check does

- Each host is fetched as `https://<host>/?cb=<epoch>` with `curl -L` (redirects
  followed, cache-buster added). Only a final status of 200 counts as up.
- Anything else is retried once after 60 seconds. Hosts still failing are listed
  as `FAIL <host> <status>` (status `000` means no HTTP answer at all) and the
  script exits 1.
- Extra URLs can be given as arguments: `bash check.sh https://example.invalid/`.
- Exit codes: `0` all up, `1` at least one down, `2` configuration error (no hosts
  found, bad delay).

### Local use (Internal OS checkout)

```bash
bash scripts/estate-uptime/check.sh; echo rc=$?
bash scripts/estate-uptime/check.sh https://uptime-negative.invalid/; echo rc=$?
```

Locally the host list is read from `hosts.json` beside the script. Setting the
`ESTATE_HOSTS` environment variable overrides it (any text containing host names
works: JSON, one per line, or space separated).

`RETRY_DELAY_SECONDS` (default `60`) sets the pause before the single retry. Use a
small value for a quick local test, for example
`RETRY_DELAY_SECONDS=2 bash scripts/estate-uptime/check.sh https://uptime-negative.invalid/`.
Leave it unset in Actions.

Works on macOS bash 3.2 and ubuntu-latest; needs only bash, curl, tr, grep and awk.

## Workflow behaviour

- Triggers: every 15 minutes, plus manual `workflow_dispatch` with an optional
  `extra_url` input (the input is visible in the run summary, so never put a client
  host there; it is also masked in the logs).
- Alerts go through the Admireworks alert router (quiet inbox, 19 Oct 2026): each
  state change is POSTed to the portal (`OPS_FEED_URL`, default
  `https://my.admireworks.com/api/ops-feed/signal`, Bearer `OPS_FEED_INGEST_SECRET`).
  The router sends ONE `[ACT]` email plus push when hosts go down (one reminder after
  24 h if still down) and puts the recovery on the portal morning page with no email.
  "Down" already means down twice in a row: `check.sh` retries each failure after 60 s.
  - scheduled run, previously up and now failing: job "ALERT estate host down" posts `down`;
  - scheduled run, previously failing and now up: job "NOTICE estate recovered" posts
    `up` (resolved); it never emails and never fails the run;
  - the previous scheduled run is more than 6 hours old: job "NOTICE monitor was silent"
    posts a morning line (severity `high`; GitHub throttles 15-minute schedules on quiet
    repos); it never emails and never fails the run (a failed run makes GitHub email the
    account owner). If the router cannot be reached or `OPS_FEED_INGEST_SECRET` is unset,
    it prints a `::warning::` in the log and nothing else. A site that is down still
    alerts through job "ALERT estate host down";
  - a manual run whose check fails posts a morning line on its own `manual-test` entity,
    so a test with a `.invalid` extra URL proves the path without leaving the estate
    marked down.
- Fallback when the router cannot be reached (the portal may be the host that is
  down): only the down job sends the old direct email through Resend
  (`RESEND_ALERT_KEY`, recipient `ALERT_TO`; key kept in Secret Manager as
  `ESTATE_UPTIME_RESEND_KEY` in admireworks---internal-os) and fails the run. The
  recovered and silent jobs have no fallback email.
- Job "state hosts down" succeeds on every run while a host is down and is skipped
  otherwise; the next run reads it from the previous scheduled run to tell a new outage
  from a continuing one. If that history cannot be read, a failing check is treated as
  a new outage (an email rather than silence).
- No host name is ever posted or emailed. Host names never appear in the public
  log (masked) or in the run summary (only a count). To see which host is down, run
  `bash scripts/estate-uptime/check.sh` in Internal OS.
- Who receives GitHub's own "run failed" email (down-fallback runs only): for scheduled runs, the GitHub account that last changed the
  schedule in the workflow file. That attribution goes by the commit's author email, so
  publish the workflow through the GitHub API (`gh api -X PUT .../contents/...`, which
  commits as the signed-in account) or with an email linked to that account; a commit
  from a local machine address (`user@<host>.local`) is attributed to nobody and no one
  is mailed (found 2026-10-10); for a manual run, the account that started it; both
  at that account's notification address, with "Actions: notify on failed workflows"
  on in its GitHub notification settings (the default).
- A monthly heartbeat job (day 1, 03:17 UTC) commits `heartbeat.txt` so GitHub does
  not disable the schedule after 60 days without repository activity. It is the only
  job with `contents: write`.
- The weekly page shows the time of the last run.

## Publishing (Fouad, or an agent on his explicit go)

Prerequisite: decision D58 answered. Nothing below is done by the code task.

1. Confirm the GitHub account that will push the workflow (fnasr-source) sends its
   notifications to fnasr@admireworks.com and has Actions failure emails on.
2. Create the public repo `fnasr-source/aw-estate-uptime` (empty, default branch `main`).
3. From Internal OS, copy exactly three files and add the first heartbeat:
   - `scripts/estate-uptime/check.sh` to `check.sh`
   - `scripts/estate-uptime/estate-uptime.yml` to `.github/workflows/estate-uptime.yml`
   - `scripts/estate-uptime/README.md` to `README.md`
   - `date -u +%Y-%m-%d > heartbeat.txt`
   Do not copy `hosts.json`. Commit and push to `main`.
4. Set the Actions secrets (Settings, Secrets and variables, Actions, Secrets):
   - `RESEND_ALERT_KEY`: a Resend API key with sending access to admireworks.com only
     (kept in Secret Manager as `ESTATE_UPTIME_RESEND_KEY`).
   - `ALERT_TO`: the address that receives the fallback down alert.
   - `OPS_FEED_INGEST_SECRET`: the same value as the portal's `OPS_FEED_INGEST_SECRET`
     (Secret Manager, admireworks---internal-os). Never the cron secret: this repo is public.
   - `OPS_FEED_URL` (optional): only to point at another router address.
   - `ESTATE_HOSTS`: the host list as ONE line, generated from the canonical file:
     `bash scripts/estate-uptime/check.sh --hosts-line | gh secret set ESTATE_HOSTS -R fnasr-source/aw-estate-uptime`
   It is a secret, not a variable, on purpose: a variable's value is printed unmasked in
   the public step logs before any mask can apply; a secret is masked automatically.
5. Verify (see the task's acceptance commands): the first scheduled run concludes
   `success` (or `failure` naming only `***` while a host is down), and
   `gh workflow run estate-uptime.yml -R fnasr-source/aw-estate-uptime -f extra_url=https://uptime-negative.invalid/`
   fails and the "run failed" email arrives at fnasr@admireworks.com. Open the run log and confirm no host name is
   readable.

To change the host list: edit `hosts.json` in Internal OS, then re-run the `gh secret set`
command above. The workflow file and `check.sh` change only by re-copying them.

## Limits to know about

- GitHub scheduled runs can be delayed or skipped under load; the 6-hour silent check
  exists for that, and it can only fire when some run does happen.
- GitHub sends one email per failed run; only a down that could not reach the router
  fails a run, so a flapping host while the router is unreachable can still send
  several emails in an hour.
- Nothing is checked beyond status 200 on the home path: no content, TLS expiry or
  latency check.
