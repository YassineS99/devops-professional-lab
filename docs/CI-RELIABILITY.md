# CI Reliability: Bounded Smoke Test

Files: `tests/reliable-smoke-test.sh`, `tests/run-scenarios.sh`, `tests/fixtures/mock_server.py`

## 1. Why this exists

The original smoke test retried the HTTP request, but each individual request had no timeout. One request to a server that accepts a connection and never answers could block the CI job until the platform killed it, with no diagnosis.

A professional check has bounded failure behavior: every request has a timeout, the whole test has a deadline, retries are limited, failures say what went wrong, and cleanup always runs.

## 2. Failure model

Different failures need different handling. I probed a mock server in each state using `curl` through Docker Desktop's port forwarding and recorded what actually happens:

| Server state | What curl reports | Meaning | Handling |
|---|---|---|---|
| Healthy | HTTP 200, exit 0 | ready | pass |
| Not listening yet | exit 56 (or 7, 52), connect time ~0.0001s | **not ready** | retry with backoff |
| Starting but slow to accept | exit 28 with connect time `0.000000` | **not ready** (connect timeout) | retry with backoff |
| Broken but answering | HTTP 500, **exit 0** | application error | retry, fail after 3 in a row |
| Accepts connection, never answers | exit 28 with connect time above zero, 0 bytes, 3.0s | **hung** | fail after 2 in a row |

Two findings shaped the script:

- **Exit code alone is not enough.** An HTTP 500 returns curl exit 0, so the script must read the status code. And curl exit 28 means two different things, so the script reads `%{time_connect}`: zero means the connection never opened, above zero means it opened and then nothing came back.
- **Not-ready looks different on Docker Desktop.** A plain Linux host would give exit 7 (refused). Docker's port proxy accepts the connection and resets it, which gives exit 56, so the script treats 7, 52 and 56 as the same "nothing usable is listening yet" state.

"The application is not ready" and "the application accepted my connection but never responded" get different treatment on purpose. A not-ready app is expected during startup, so waiting is correct. A hung app is deadlocked or overloaded, and waiting longer only delays the diagnosis.

## 3. Bounds

All limits are environment variables with defaults:

| Variable | Default | Purpose |
|---|---|---|
| `CONNECT_TIMEOUT` | 2s | time allowed to open a connection |
| `REQUEST_TIMEOUT` | 3s | maximum time for any single request |
| `MAX_ATTEMPTS` | 10 | maximum number of requests |
| `MAX_TOTAL` | 30s | hard deadline for the whole test |
| `BACKOFF_INITIAL` / `BACKOFF_MAX` | 1s / 4s | pause between attempts doubles, capped |
| `MAX_HANGS` | 2 | consecutive hung requests allowed |
| `MAX_5XX` | 3 | consecutive HTTP 5xx allowed |

The loop cannot run past `MAX_TOTAL`: each request timeout is capped to the time remaining, and each pause is capped the same way. Cleanup adds a second or two after that.

Backoff is exponential (1s, 2s, 4s, then 4s) and capped, so a slow app gets time to start without the test hammering it. The test sends one request at a time, so it cannot cause a retry storm.

## 4. Exit codes

| Code | Meaning |
|---|---|
| 0 | healthy (HTTP 200) |
| 2 | bad usage |
| 10 | never became ready within the attempt or time limit |
| 11 | repeated HTTP 5xx |
| 12 | server accepts connections but never responds |
| 13 | unexpected result (other HTTP status or curl error) |
| 130 / 143 | interrupted (Ctrl+C / SIGTERM) |

Distinct codes let a CI job show a precise cause instead of just "failed".

## 5. What happens when the application fails

1. The script classifies the result from the HTTP status, the curl exit code and the connect time.
2. Every attempt logs a timestamped line saying which state it saw (not ready, HTTP 5xx, HUNG).
3. When a limit is reached, the script logs `FAIL (exit N): <reason>` and exits with that code.
4. An `EXIT` trap fires on every path, including failures and interrupts. It saves the container's logs to `smoke-artifacts/<container>.log`, prints the last 20 lines when the test failed, and removes the container.
5. The CI job fails with the specific exit code, and the saved log file can be uploaded as a build artifact.

Example, from the HTTP 500 scenario:

[15:23:27] attempt 4/10 (t=7s): HTTP 500 (server error 3/3)
[15:23:27] FAIL (exit 11): server answered HTTP 500 3 times in a row
[15:23:27] --- last 20 lines of container logs (mock-e500) ---
[mock:500] listening on port 8000
[mock:500] GET /
[mock:500] GET /
[mock:500] GET /
[15:23:27] --- end of container logs ---
[15:23:27] cleanup: container mock-e500 removed, logs in smoke-artifacts/mock-e500.log


## 6. Test evidence

`tests/run-scenarios.sh` starts a mock server in each state, runs the smoke test against it, checks the exit code, and confirms the container was removed.

| Scenario | Expected exit | Actual exit | Time | Result |
|---|---|---|---|---|
| Healthy, answers 200 immediately | 0 | 0 | 1s | PASS |
| Refuses at first, ready after ~8s | 0 | 0 | 11s | PASS |
| Answers HTTP 500 | 11 | 11 | 7s | PASS |
| Accepts connection, never responds | 12 | 12 | 9s | PASS |
| Never becomes ready (120s startup, 12s deadline) | 10 | 10 | 12s | PASS |

All five passed with no containers left behind.

**What happens if the application never becomes ready?** The test keeps retrying with capped backoff until `MAX_TOTAL` (or `MAX_ATTEMPTS`), then fails with exit 10 and the last observed state ("connection refused or reset"). In the test above it stopped at exactly 12s against a 12s deadline.

## 7. Limitations

- **The `t=` value in log lines is measured after the request completes**, so it includes the request's own duration. The decisions are correct, but the label slightly overstates when an attempt started.
- **Three HTTP 5xx in a row is a judgment call.** Real services sometimes return 503 while warming up. If that is expected for an app, raise `MAX_5XX` or treat 503 as not-ready.
- **Exit 56 as "not ready" is validated on Docker Desktop.** On other hosts, run the same probe first.
- **Only `GET /` is checked.** It proves the web server answers, not that dependencies such as Redis work. The Compose topic covers dependency readiness.
- **The mock server tests the script's logic, not the vote app itself.** The real image is covered by running the script against it with the same `URL CONTAINER` arguments.

## 8. How to run

```bash
bash tests/run-scenarios.sh                                        # all scenarios
bash tests/reliable-smoke-test.sh http://localhost:8080/ vote-app  # against a real container
MAX_TOTAL=60 MAX_ATTEMPTS=20 bash tests/reliable-smoke-test.sh URL CONTAINER
```
