# DevOps Professional Lab

A small project that builds a full delivery path around one service: a
hardened Docker image, a bounded smoke test, a secured CI pipeline, a Compose
staging stack, and a release and rollback drill.

The service is the `vote` app (Flask and Redis) from
[dockersamples/example-voting-app](https://github.com/dockersamples/example-voting-app).
See that repository's LICENSE for the original terms. I changed `app.py` to
add `/healthz`, `/ready`, bounded Redis calls and honest 503 responses.

## What is in here

| Topic | What it covers | Document |
|---|---|---|
| 1. Docker image | multi-stage, non-root, pinned, scanned | `docs/DOCKER-BEST-PRACTICES.md` |
| 2. CI reliability | bounded smoke test, failure scenarios | `docs/CI-RELIABILITY.md` |
| 3. Actions security | threat model, SHA pinning, scan, SBOM | `docs/GITHUB-ACTIONS-SECURITY.md` |
| 4. Compose staging | Redis, networks, health checks, breakage | `docs/COMPOSE-STAGING.md` |
| 5. Release and rollback | digest deploys, bad release drill, runbook | `docs/DEPLOYMENT-AND-ROLLBACK.md` |

## Results, each backed by evidence in the docs

- Image: 241MB to 206MB, root to uid 10001, Docker Scout findings 60 to 28.
- Smoke test: five scenarios (healthy, slow start, HTTP 500, hung, never
  ready) each end with their own exit code and clean up the container.
- CI: every pull request builds the image, starts the whole Compose stack,
  checks `/ready`, does a vote round trip, and proves that readiness fails
  when Redis is down.
- Compose drill: with Redis down the original app gave no response for 31
  seconds while still reporting healthy. After the fix, `/ready` and votes
  fail with a 503 in 1 to 3 seconds and the container turns unhealthy.
- Release drill: a bad release was rejected by the health gate in 4 seconds,
  and a rollback to the previous digest finished in 7 seconds with no votes
  lost. The full output is in `docs/evidence/release-drill.log`.

## Layout

```
Dockerfile, .dockerignore, app.py, requirements.txt, templates/, static/
compose/
  docker-compose.yml          staging stack: vote and Redis
  docker-compose.release.yml  release stack: image chosen by digest
tests/
  reliable-smoke-test.sh      bounded HTTP smoke test
  run-scenarios.sh            runs the smoke test against mock servers
  compose-failure-drill.sh    breaks Redis three ways
  release-drill.sh            bad release, evidence, rollback
  fixtures/                   mock server and the bad release image
.github/
  workflows/pull-request.yml  build, start stack, smoke test, failure check
  workflows/security.yml      Trivy scan and SBOM
  dependabot.yml              weekly updates for actions, Docker and pip
docs/                         one document per topic, plus docs/evidence/
```

## Run it

Needs Docker with Compose, and bash (WSL on Windows).

```
docker build -t vote:local .
docker compose -f compose/docker-compose.yml up -d --build --wait
curl -s http://localhost:8080/ready
bash tests/reliable-smoke-test.sh http://localhost:8080/ready
bash tests/run-scenarios.sh
bash tests/compose-failure-drill.sh
docker compose -f compose/docker-compose.yml down -v
```

`run-scenarios.sh` uses ports 8081 to 8085. `compose-failure-drill.sh` expects
the stack above to be running. The release drill needs a local registry, and
its steps are in section E of `docs/DEPLOYMENT-AND-ROLLBACK.md`.

## What is not done

- No image signing or provenance attestation, and no CodeQL.
- One `vote` replica, so a release has a gap. Zero-downtime rolling needs two
  or more replicas behind a proxy.
- No request metrics, so the 5xx rate and p95 latency release gates are
  design targets only.
- Registry, digest and promotion steps are manual and not part of CI.

Each document ends with its own limitations section.
