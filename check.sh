#!/usr/bin/env bash
# Estate uptime check. Fetches every host over HTTPS and requires a final 200.
#
# Usage:
#   bash check.sh [extra_url ...]     check the host list plus any extra URLs
#   bash check.sh --hosts-line        print the host list as one space-separated
#                                     line (no trailing newline) and exit 0; this
#                                     is the value to store in the ESTATE_HOSTS
#                                     Actions secret
#
# Host list source, first match wins:
#   1. the ESTATE_HOSTS environment variable (Actions: the ESTATE_HOSTS secret)
#   2. hosts.json beside this script (local runs in the Internal OS repo)
# Either is read as plain text: every token that looks like a host name is used
# (JSON, one per line, or space separated all work).
#
# Each URL gets a cb=<epoch> cache-buster and curl follows redirects (-L). Any
# final status other than 200 is retried ONCE after RETRY_DELAY_SECONDS
# (default 60; set a small number to test locally, e.g. RETRY_DELAY_SECONDS=2).
#
# Exit codes: 0 every target answered 200; 1 at least one failed (each is listed
# on a line starting "FAIL <host> <status>"; status 000 means no HTTP answer);
# 2 usage or configuration error (no hosts found, bad RETRY_DELAY_SECONDS).
#
# Works on macOS bash 3.2 and ubuntu-latest. Needs only bash, curl, tr, grep, awk.

set -u
export LC_ALL=C

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TAB=$(printf '\t')

RETRY_DELAY_SECONDS=${RETRY_DELAY_SECONDS:-60}
case $RETRY_DELAY_SECONDS in
  ''|*[!0-9]*)
    echo "check.sh: RETRY_DELAY_SECONDS must be a whole number of seconds" >&2
    exit 2
    ;;
esac

parse_hosts() {
  tr -c 'A-Za-z0-9.-' '\n' \
    | grep -E '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$' \
    | awk '!seen[$0]++'
}

load_hosts() {
  if [ -n "${ESTATE_HOSTS:-}" ]; then
    printf '%s\n' "$ESTATE_HOSTS" | parse_hosts
  elif [ -f "$here/hosts.json" ]; then
    parse_hosts < "$here/hosts.json"
  fi
}

if [ "${1:-}" = "--hosts-line" ]; then
  hosts=$(load_hosts)
  [ -n "$hosts" ] || { echo "check.sh: no hosts found" >&2; exit 2; }
  printf '%s' "$hosts" | tr '\n' ' ' | sed 's/ $//'
  exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/estate-uptime.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT

# targets file: label<TAB>base-url, one per line
targets="$work/targets"
: > "$targets"
hosts=$(load_hosts)
if [ -n "$hosts" ]; then
  printf '%s\n' "$hosts" | while IFS= read -r h; do
    printf '%s\thttps://%s/\n' "$h" "$h"
  done >> "$targets"
fi
for a in "$@"; do
  [ -n "$a" ] || continue
  case $a in
    http://*|https://*) u=$a ;;
    *) u="https://$a/" ;;
  esac
  printf '%s\t%s\n' "$a" "$u" >> "$targets"
done

total=$(wc -l < "$targets" | tr -d ' ')
if [ "$total" -eq 0 ]; then
  echo "check.sh: no hosts to check (set ESTATE_HOSTS or provide hosts.json)" >&2
  exit 2
fi

# run_pass <targets-file> <failed-file>: probes all targets in parallel, prints
# one result line per target, writes the failing targets (label<TAB>url) to
# <failed-file>, and sets PASS_FAILED to their count.
run_pass() {
  local in=$1 out=$2 dir cb i label url code
  dir=$(mktemp -d "$work/pass.XXXXXX")
  cb=$(date +%s)
  : > "$out"
  i=0
  while IFS="$TAB" read -r label url; do
    i=$((i + 1))
    case $url in
      *\?*) url="$url&cb=$cb" ;;
      *) url="$url?cb=$cb" ;;
    esac
    (
      c=$(curl -sS -L --max-redirs 5 --connect-timeout 10 --max-time 25 \
            -o /dev/null -w '%{http_code}' --url "$url" 2>/dev/null) || true
      [ -n "$c" ] || c=000
      printf '%s' "$c" > "$dir/$i"
    ) &
  done < "$in"
  wait
  PASS_FAILED=0
  i=0
  while IFS="$TAB" read -r label url; do
    i=$((i + 1))
    code=$(cat "$dir/$i" 2>/dev/null)
    [ -n "$code" ] || code=000
    if [ "$code" = "200" ]; then
      echo "ok   $code $label"
    else
      echo "bad  $code $label"
      printf '%s\t%s\t%s\n' "$label" "$url" "$code" >> "$out"
      PASS_FAILED=$((PASS_FAILED + 1))
    fi
  done < "$in"
}

echo "estate-uptime check, $total targets, $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
failed1="$work/failed1"
run_pass "$targets" "$failed1"
n1=$PASS_FAILED

if [ "$n1" -eq 0 ]; then
  echo "up $total of $total"
  exit 0
fi

# retry once, only the failures; the targets file keeps label<TAB>base-url
retry="$work/retry"
: > "$retry"
while IFS="$TAB" read -r label url code; do
  awk -F "$TAB" -v l="$label" '$1 == l { print; exit }' "$targets" >> "$retry"
done < "$failed1"
echo "retrying $n1 failed target(s) once after ${RETRY_DELAY_SECONDS}s"
sleep "$RETRY_DELAY_SECONDS"
failed2="$work/failed2"
run_pass "$retry" "$failed2"
n2=$PASS_FAILED

up=$((total - n2))
echo "up $up of $total"
if [ "$n2" -eq 0 ]; then
  exit 0
fi
while IFS="$TAB" read -r label url code; do
  echo "FAIL $label $code"
done < "$failed2"
exit 1
