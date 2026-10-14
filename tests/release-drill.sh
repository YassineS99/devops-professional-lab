#!/usr/bin/env bash
# Release drill: deploy a bad image, detect it, collect evidence, roll back.
# Usage: GOOD=<image@digest> BAD=<image@digest> bash tests/release-drill.sh
set -uo pipefail
: "${GOOD:?set GOOD to the known-good image@digest}"
: "${BAD:?set BAD to the bad image@digest}"

C="docker compose -f compose/docker-compose.release.yml"
VOTE=http://localhost:8080
SVC=vote-release-vote-1

step() { printf '\n==== %s\n' "$*"; }
run() { echo "\$ $*"; "$@"; local rc=$?; echo "[exit code $rc]"; return $rc; }

step "1. baseline: the known-good release"
export VOTE_IMAGE=$GOOD
run $C up -d --wait --wait-timeout 60
PREV=$(docker inspect $SVC --format '{{.Config.Image}}')
echo "previous known-good reference: $PREV"
run curl -s -o /dev/null -w 'ready http=%{http_code}\n' $VOTE/ready
run curl -s -o /dev/null -w 'vote http=%{http_code}\n' -X POST -d vote=a $VOTE/
BEFORE=$($C exec -T redis redis-cli llen votes | tr -d '\r\n ')
echo "votes in redis before the release: $BEFORE"

step "2. deploy the bad release"
export VOTE_IMAGE=$BAD
T0=$SECONDS
run $C up -d --wait --wait-timeout 40
DEPLOY_RC=$?
echo "bad release rejected by the health gate after $((SECONDS - T0))s"
echo "deploy exit code: $DEPLOY_RC (non-zero means the gate rejected it)"

step "3. evidence: what the orchestrator sees"
run $C ps -a
run docker inspect $SVC --format \
  'state={{.State.Status}} exit_code={{.State.ExitCode}} restarts={{.RestartCount}}'
run docker inspect $SVC --format 'health={{.State.Health.Status}}'
run docker inspect $SVC --format 'image={{.Config.Image}}'
run docker inspect $SVC --format \
  'commit={{index .Config.Labels "org.opencontainers.image.revision"}}'
run curl -s -o /dev/null --max-time 5 -w 'user traffic http=%{http_code}\n' $VOTE/

step "4. evidence: why it failed, from before any user traffic"
run $C logs --no-color --tail 30 vote

step "5. rollback to the previous known-good reference"
export VOTE_IMAGE=$PREV
T1=$SECONDS
run $C up -d --wait --wait-timeout 60
ROLLBACK_RC=$?
echo "rollback finished in $((SECONDS - T1))s"

step "6. verify recovery"
run $C ps -a
run curl -s -w ' http=%{http_code}\n' $VOTE/ready
run curl -s -o /dev/null -w 'vote http=%{http_code}\n' -X POST -d vote=a $VOTE/
AFTER=$($C exec -T redis redis-cli llen votes | tr -d '\r\n ')
echo "votes in redis: before=$BEFORE after=$AFTER (one new vote was added)"
run docker ps -a --filter name=vote-release --format '{{.Names}} {{.Status}}'
RUNNING=$(docker inspect $SVC --format '{{.Config.Image}}')
echo "running image: $RUNNING"

step "7. result"
READY=$(curl -s -o /dev/null -w '%{http_code}' $VOTE/ready)
fail=0
check() { if [ "$1" = "ok" ]; then echo "PASS $2"; else echo "FAIL $2"; fail=1; fi; }
[ "$DEPLOY_RC" -ne 0 ] && s=ok || s=bad; check $s "bad release was rejected"
[ "$ROLLBACK_RC" -eq 0 ] && s=ok || s=bad; check $s "rollback succeeded"
[ "$READY" = "200" ] && s=ok || s=bad; check $s "/ready is 200 after rollback"
[ "$RUNNING" = "$PREV" ] && s=ok || s=bad; check $s "running the previous digest"
[ "$AFTER" = "$(( ${BEFORE:-0} + 1 ))" ] && s=ok || s=bad; check $s "no votes lost"
exit $fail
