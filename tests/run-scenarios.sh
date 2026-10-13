#!/usr/bin/env bash
# Runs reliable-smoke-test.sh against mock servers and checks exit codes.
set -uo pipefail
cd "$(dirname "$0")/.."

SCRIPT=tests/reliable-smoke-test.sh
FX="$PWD/tests/fixtures"
IMAGE=python:3.11-slim
failures=0

# run_case NAME MODE PORT EXPECTED_EXIT "ENV_OVERRIDES" [mock extra args...]
run_case() {
  local name=$1 mode=$2 port=$3 expected=$4 envstr=$5; shift 5
  docker rm -f "mock-$name" >/dev/null 2>&1 || true
  docker run -d --rm --name "mock-$name" -p "$port:8000" \
    -v "$FX:/fx:ro" "$IMAGE" python /fx/mock_server.py "$mode" 8000 "$@" >/dev/null
  echo
  echo "=== scenario: $name (expect exit $expected)"
  local start=$SECONDS
  env $envstr bash "$SCRIPT" "http://localhost:$port/" "mock-$name"
  local actual=$?
  local took=$((SECONDS - start))
  local leftover=""
  if docker ps -a --format '{{.Names}}' | grep -qx "mock-$name"; then
    leftover=" (CONTAINER NOT CLEANED UP)"
  fi
  if [ "$actual" -eq "$expected" ] && [ -z "$leftover" ]; then
    echo ">>> PASS: $name exited $actual in ${took}s"
    results+=("PASS  $name  exit=$actual  ${took}s")
  else
    echo ">>> FAIL: $name exited $actual, expected $expected$leftover"
    results+=("FAIL  $name  exit=$actual expected=$expected$leftover")
    failures=$((failures + 1))
  fi
}

results=()
run_case ok    ok   8081 0  ""
run_case slow  slow 8082 0  ""            8
run_case e500  500  8083 11 ""
run_case hang  hang 8084 12 ""
run_case never slow 8085 10 "MAX_TOTAL=12" 120

echo
echo "================ SUMMARY ================"
printf '%s\n' "${results[@]}"
echo "failures: $failures"
exit "$failures"
