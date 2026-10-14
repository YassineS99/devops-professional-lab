# Research Notes

Notes per topic: what I studied, what I learned, and where I applied it
in this repo. Each topic ends with what I did not test.

## Topic 1: Docker image engineering

- Layer caching: every instruction is a layer, and a changed layer
  invalidates all layers after it. Dependencies are installed before the app
  code is copied, so a one-line code change rebuilt in 3.5s against 11.5s
  for the bad image.
- Build context and `.dockerignore`: the whole context goes to the builder.
  Excluding `.git`, `.env` and docs keeps it small and keeps secrets out.
- Multi-stage builds: build tooling stays in the builder stage and only the
  installed packages are copied into the final image.
- Non-root `USER` with a numeric uid (10001) gives predictable ownership.
  Testing found a side effect: gunicorn needed a home directory for its
  control socket, and the log showed it.
- ENTRYPOINT is the fixed executable (gunicorn). CMD holds default
  arguments that can be overridden.
- Environment variables: `WEB_CONCURRENCY` makes the worker count tunable.
  Secrets do not belong in ENV, because `docker inspect` shows them.
- HEALTHCHECK marks a container healthy or unhealthy. It does not restart
  anything by itself.
- Tags versus digests: a tag can move, a digest names exact content. The
  base image is pinned by digest, and releases are deployed by digest.
- Provenance: BuildKit attaches attestation manifests to builds (the build
  logs show "exporting attestation manifest"). I did not verify or sign them.
- BuildKit features used: a pip cache mount and a pinned Dockerfile syntax
  frontend (`docker/dockerfile:1.7`).
- Scanning: Docker Scout found 60 findings in the original image and 28 in
  the improved one. Trivy in CI reports no fixable HIGH or CRITICAL findings.
- What makes an image production-ready: small, non-root, pinned, scanned,
  free of secrets, logs on stdout, a health signal, a reproducible build.

Not tested: image signing, rootless Docker, a read-only root filesystem.

## Topic 2: CI reliability and failure engineering

- Two timeouts are needed. A connect timeout bounds opening the socket, and
  a total request timeout bounds the whole request. A server that accepts a
  connection and never answers is only caught by the total timeout.
- Retries with exponential backoff: 1s, 2s, 4s, capped at 4s, so the waits
  cannot grow beyond the overall deadline.
- Retry storms: many clients retrying in step can overload a service that is
  recovering. Caps, jitter and retry budgets limit this. My script is a
  single client, so it has caps but no jitter.
- An overall deadline (`MAX_TOTAL`) is separate from the attempt limit, and
  each request timeout is cut to the time remaining.
- Not ready versus hung: a refused or reset connection means not ready and
  is retried. A connection that opens and then gets no response means hung
  and fails after 2 attempts. The connect time from curl tells them apart.
- Exit codes: 0 pass, 10 never ready, 11 repeated 5xx, 12 hung, 13
  unexpected. Distinct codes make a failed CI run easy to read.
- Failure propagation: `set -euo pipefail`, plus reading the HTTP status
  explicitly, because an HTTP 500 gives curl exit code 0.
- Cleanup with traps: an EXIT trap saves the container logs and removes the
  container on every path. INT and TERM map to exit codes 130 and 143.
- Artifacts and debug logging: every line has a timestamp, and logs are
  uploaded with `if: always()` so they exist for failed runs too.
- Determinism: pinned images, and retries only for the classified "not
  ready" state.

Not tested: jitter, circuit breakers, load from many clients.

## Topic 3: GitHub Actions and supply-chain security

The detailed threat model is in `GITHUB-ACTIONS-SECURITY.md`. Summary:

- `pull_request` runs with a restricted token. `pull_request_target` runs
  with base-branch privileges and is dangerous if it runs PR code.
- `GITHUB_TOKEN` is per job. `permissions: {}` at workflow level and
  `contents: read` per job gives least privilege.
- Third-party actions run inside the job. Pin them to a full commit SHA.
  Actions called by actions are pinned by their authors, not by me.
- Dependency attacks: a compromised maintainer or a moved tag (the Trivy
  incident of March 2026), typosquatting, malicious updates. Mitigations are
  pinning, a cooldown before adopting new releases, and reviewing diffs.
- Secrets: none are used. Logs mask registered secrets but not values
  derived from them, so secrets are never echoed. Fork PRs receive none.
- Fork PRs: approval is required for all external contributors.
- Artifacts are output of untrusted runs. No workflow here consumes them.
- Implemented: image scan, SBOM, Dependabot, SHA pinning enforced by a
  repository setting.

Not implemented: image signing, SLSA provenance, CodeQL.

## Topic 4: Docker Compose, networking and staging

- `depends_on` with `condition: service_healthy` orders startup only. It
  does not restart anything later.
- Networks: `front` and `back`. The `back` network is `internal: true`, so
  its containers have no route to the internet.
- Service discovery: Docker's embedded DNS resolves a service name to a
  container address inside a shared network. After disconnecting and
  reconnecting Redis, the `redis` alias had to be added again by hand.
- Volumes: a named volume survives `down` and is removed by `down -v`. The
  vote count survived a restart.
- Configuration: the staging file builds the production Dockerfile, has no
  bind mounts, sets memory limits and restart policies. Development would
  add bind mounts and debug settings.
- Secrets: none are used. Compose secrets or an untracked env file would be
  the way to add them.
- Running versus ready: a container can run while its service cannot work.
  `/ready` checks the dependency, `/healthz` does not.
- Troubleshooting order: `ps`, logs, name resolution, network membership,
  then the port.

Not tested: memory limit enforcement, Compose secrets, more than one replica.

## Topic 5: Release architecture and incident playbook

- Mutable tags can be moved. A digest is content-addressed, so deploying and
  rolling back by digest gives the same bytes everywhere.
- Strategies: rolling replaces replicas gradually, blue/green switches all
  traffic between two full copies, canary sends a small share first. They
  trade capacity, speed of detection, and how long old and new run together.
- State and schema: while old and new versions overlap, shared data formats
  must work for both. Changes are additive first, and removals come later.
- Health gates: liveness, readiness and traffic acceptance are different
  questions. Numeric gates (5xx rate, p95 latency, restarts) are in section
  A3 of `DEPLOYMENT-AND-ROLLBACK.md`.
- Automatic versus manual rollback: automatic for clear signals such as a
  failed health gate, manual when the cause is unclear or data may be
  affected.
- Roll back or roll forward: roll back when the previous version is known
  good and compatible with the current data. Roll forward when the fix is
  small and tested, or when a one-way change makes rollback unsafe.
- Observed: a bad release was rejected in 4s and rolled back in 7s, with no
  votes lost.

Not tested: canary, blue/green, killing the deploy script midway, metric
based gates.

## What I would study next

- Image signing and provenance (Sigstore cosign, SLSA).
- Metrics and alerting (request rate, error rate, latency histograms).
- Rolling updates with several replicas behind a proxy.
