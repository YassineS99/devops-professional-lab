#!/usr/bin/env bash
# Breaks Redis three ways and records how the stack responds.
# Needs the staging stack running and healthy:
#   docker compose -f compose/docker-compose.yml up -d --build --wait
set -uo pipefail
F=compose/docker-compose.yml
C="docker compose -f $F"
VOTE=http://localhost:8080
invalid=0

# Preflight: the drill is only valid if THIS stack serves port 8080.
health() { $C ps --format '{{.Service}}={{.Health}}' | grep "^$1=" || true; }
vstate=$(health vote); rstate=$(health redis)
if [ "$vstate" != "vote=healthy" ] || [ "$rstate" != "redis=healthy" ]; then
  echo "PREFLIGHT FAILED: vote and redis must both be healthy in this stack"
  echo "got: ${vstate:-vote missing} ${rstate:-redis missing}"
  echo "Another stack may hold port 8080. Check: docker ps"
  exit 2
fi

probe() {
  local get ready post
  get=$(curl -s -o /dev/null --max-time 40 -w '%{http_code}/%{time_total}s' $VOTE/)
  ready=$(curl -s -o /dev/null --max-time 40 -w '%{http_code}/%{time_total}s' $VOTE/ready)
  post=$(curl -s -o /dev/null --max-time 40 -w '%{http_code}/%{time_total}s' -X POST -d vote=a $VOTE/)
  printf '%-22s GET / %s | GET /ready %s | POST %s\n' "$1" "$get" "$ready" "$post"
}
status() { $C ps --format '{{.Service}}={{.State}}/{{.Health}}' | tr '\n' ' '; echo; }

# The break must change the answer, or the experiment proves nothing.
must_fail() {
  local c
  c=$(curl -s -o /dev/null --max-time 10 -w '%{http_code}' $VOTE/ready)
  if [ "$c" = "200" ]; then
    echo "INVALID: /ready is still 200 after the break"
    invalid=1
  fi
}

echo "== baseline";                    probe baseline; status

echo "== 1. redis stopped"
$C stop redis >/dev/null 2>&1
probe "redis stopped"; must_fail; sleep 15; status
$C start redis >/dev/null 2>&1; sleep 10
probe "after start"; status

echo "== 2. redis paused (hung)"
$C pause redis >/dev/null 2>&1
probe "redis paused"; must_fail; sleep 15; status
$C unpause redis >/dev/null 2>&1; sleep 10
probe "after unpause"; status

echo "== 3. redis cut off from the network"
docker network disconnect vote-lab_back vote-lab-redis-1
probe "redis disconnected"; must_fail; sleep 15; status
docker network connect --alias redis vote-lab_back vote-lab-redis-1; sleep 10
probe "after reconnect"; status

[ "$invalid" -eq 0 ] && echo "RESULT: all three breaks took effect" \
  || echo "RESULT: INVALID, a break had no effect"
exit $invalid
