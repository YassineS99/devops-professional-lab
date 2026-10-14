#!/usr/bin/env bash
# Breaks Redis three ways and records how the stack responds.
set -uo pipefail
F=compose/docker-compose.yml
C="docker compose -f $F"
VOTE=http://localhost:8080

probe() {
  local get ready post
  get=$(curl -s -o /dev/null --max-time 40 -w '%{http_code}/%{time_total}s' $VOTE/)
  ready=$(curl -s -o /dev/null --max-time 40 -w '%{http_code}/%{time_total}s' $VOTE/ready)
  post=$(curl -s -o /dev/null --max-time 40 -w '%{http_code}/%{time_total}s' -X POST -d vote=a $VOTE/)
  printf '%-22s GET / %s | GET /ready %s | POST %s\n' "$1" "$get" "$ready" "$post"
}
status() { $C ps --format '{{.Service}}={{.State}}/{{.Health}}' | tr '\n' ' '; echo; }

echo "== baseline";                    probe baseline; status

echo "== 1. redis stopped"
$C stop redis >/dev/null 2>&1
probe "redis stopped"; sleep 15; status
$C start redis >/dev/null 2>&1; sleep 10
probe "after start"; status

echo "== 2. redis paused (hung)"
$C pause redis >/dev/null 2>&1
probe "redis paused"; sleep 15; status
$C unpause redis >/dev/null 2>&1; sleep 10
probe "after unpause"; status

echo "== 3. redis cut off from the network"
docker network disconnect vote-lab_back vote-lab-redis-1
probe "redis disconnected"; sleep 15; status
docker network connect --alias redis vote-lab_back vote-lab-redis-1; sleep 10
probe "after reconnect"; status
