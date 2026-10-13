#!/usr/bin/env bash
# reliable-smoke-test.sh - bounded, diagnosable HTTP smoke test.
#
# Usage: reliable-smoke-test.sh URL [CONTAINER]
#
# Exit codes:
#   0   healthy (HTTP 200)
#   2   bad usage
#   10  never became ready within MAX_ATTEMPTS / MAX_TOTAL
#   11  server answered with repeated HTTP 5xx
#   12  server accepted connections but never answered (hung)
#   13  unexpected result (other HTTP status or curl error)
#
# If CONTAINER is given, its logs are saved to ARTIFACT_DIR before it is
# removed. This happens on every exit path, success or failure.
set -euo pipefail

URL="${1:-}"
CONTAINER="${2:-}"
if [ -z "$URL" ]; then
  echo "usage: $0 URL [CONTAINER]" >&2
  exit 2
fi

CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-2}"   # seconds to open a connection
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-3}"   # max seconds for any single request
MAX_ATTEMPTS="${MAX_ATTEMPTS:-10}"        # max number of requests
MAX_TOTAL="${MAX_TOTAL:-30}"              # hard deadline for the whole test
BACKOFF_INITIAL="${BACKOFF_INITIAL:-1}"   # first pause between attempts
BACKOFF_MAX="${BACKOFF_MAX:-4}"           # pause never grows beyond this
MAX_HANGS="${MAX_HANGS:-2}"               # consecutive hung requests allowed
MAX_5XX="${MAX_5XX:-3}"                   # consecutive HTTP 5xx allowed
ARTIFACT_DIR="${ARTIFACT_DIR:-smoke-artifacts}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$CONTAINER" ]; then
    mkdir -p "$ARTIFACT_DIR"
    docker logs "$CONTAINER" >"$ARTIFACT_DIR/$CONTAINER.log" 2>&1 || true
    if [ "$rc" -ne 0 ]; then
      log "--- last 20 lines of container logs ($CONTAINER) ---"
      tail -n 20 "$ARTIFACT_DIR/$CONTAINER.log" || true
      log "--- end of container logs ---"
    fi
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    log "cleanup: container $CONTAINER removed, logs in $ARTIFACT_DIR/$CONTAINER.log"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  local code=$1; shift
  log "FAIL (exit $code): $*"
  exit "$code"
}

attempt=0
backoff=$BACKOFF_INITIAL
hangs=0
errors5xx=0
last="no request completed"
SECONDS=0

log "smoke test: url=$URL max_attempts=$MAX_ATTEMPTS max_total=${MAX_TOTAL}s request_timeout=${REQUEST_TIMEOUT}s"

while :; do
  remaining=$((MAX_TOTAL - SECONDS))
  if [ "$remaining" -le 0 ]; then
    fail 10 "not ready after ${SECONDS}s (deadline ${MAX_TOTAL}s). Last result: $last"
  fi
  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    fail 10 "not ready after $attempt attempts. Last result: $last"
  fi
  attempt=$((attempt + 1))
  timeout=$(( remaining < REQUEST_TIMEOUT ? remaining : REQUEST_TIMEOUT ))

  curl_rc=0
  out=$(LC_ALL=C curl -sS -o /dev/null -w '%{http_code} %{time_connect}' \
        --connect-timeout "$CONNECT_TIMEOUT" --max-time "$timeout" "$URL" 2>/dev/null) || curl_rc=$?
  [ -n "$out" ] || out="000 0"
  code=${out%% *}
  tconn=${out##* }
  prefix="attempt $attempt/$MAX_ATTEMPTS (t=${SECONDS}s)"

  if [ "$curl_rc" -eq 0 ]; then
    hangs=0
    case "$code" in
      200)
        log "$prefix: HTTP 200 - PASS"
        exit 0
        ;;
      5??)
        errors5xx=$((errors5xx + 1))
        last="HTTP $code"
        log "$prefix: HTTP $code (server error $errors5xx/$MAX_5XX)"
        if [ "$errors5xx" -ge "$MAX_5XX" ]; then
          fail 11 "server answered HTTP $code $errors5xx times in a row"
        fi
        ;;
      *)
        fail 13 "unexpected HTTP status $code"
        ;;
    esac
  else
    errors5xx=0
    case "$curl_rc" in
      7|52|56)
        hangs=0
        last="connection refused or reset (curl exit $curl_rc)"
        log "$prefix: not ready - $last"
        ;;
      28)
        if [ "$tconn" = "0.000000" ]; then
          hangs=0
          last="connect timeout (curl exit 28)"
          log "$prefix: not ready - $last"
        else
          hangs=$((hangs + 1))
          last="connected but no response within ${timeout}s (curl exit 28)"
          log "$prefix: HUNG - $last ($hangs/$MAX_HANGS)"
          if [ "$hangs" -ge "$MAX_HANGS" ]; then
            fail 12 "server accepts connections but never responds"
          fi
        fi
        ;;
      *)
        fail 13 "unexpected curl error (exit $curl_rc)"
        ;;
    esac
  fi

  remaining=$((MAX_TOTAL - SECONDS))
  pause=$(( backoff < remaining ? backoff : remaining ))
  if [ "$pause" -gt 0 ]; then
    log "retrying in ${pause}s"
    sleep "$pause"
  fi
  backoff=$((backoff * 2))
  if [ "$backoff" -gt "$BACKOFF_MAX" ]; then
    backoff=$BACKOFF_MAX
  fi
done
