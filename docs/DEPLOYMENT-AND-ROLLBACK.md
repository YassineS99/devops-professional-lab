# Deployment and Rollback

Files: `compose/docker-compose.release.yml`, `tests/release-drill.sh`,
`tests/fixtures/bad-release/`, `docs/evidence/release-drill.log`

## Section A: Production delivery blueprint

### A1. Artifact lifecycle

```
 developer
    |  git push / pull request
    v
 [1 Commit]            the git SHA is the release identity
    |
    v
 [2 CI test]           pull-request.yml: build, start Compose stack,
    |                  smoke test /ready, vote round trip, failure check
    |                  security.yml: Trivy scan (gate) and SBOM
    v
 [3 Digest generation] docker build, label = git SHA, read the sha256 digest
    |
    v
 [4 Registry push]     image stored, referenced as name@sha256:...
    |
    v
 [5 Staging verify]    deploy that exact digest, wait for the health gate
    |
    v
 [6 Prod promotion]    same digest, no rebuild, previous digest recorded
```

What is implemented in this lab and what is design only:

- Stages 1 and 2 run in GitHub Actions (pull requests #1, #2 and #8).
- Stages 3 and 4 were done by hand against a local `registry:2` on port 5000.
  They are not yet in CI.
- Stage 5 is the release Compose file with the `--wait` health gate.
- Stage 6 is design only. Promotion means redeploying the same digest.

Rules: promote digests and never rebuild between stages. Record the digest
that is currently running before every deploy, because it is the rollback
target.

### A2. Deployment strategy: rolling update

Why rolling: the app tier is stateless and the only shared state is the Redis
list, so replicas can be replaced one at a time with small extra capacity.

How it works in production:

1. Run at least 2 `vote` replicas behind a load balancer or reverse proxy.
2. Start one replica on the new digest.
3. The balancer sends it traffic only after `/ready` returns 200.
4. Drain and stop one old replica, then repeat.
5. If the gate fails, stop the rollout. The remaining old replicas keep
   serving, so users see no outage.

Service discovery: replicas share one service name that Docker DNS resolves.
The balancer takes replicas in and out of rotation based on readiness.

What the lab actually does: one `vote` replica. `up -d` removes the old
container and starts the new one, so there is a gap. The drill measured
`http=000` for user traffic while the bad release was running. Zero-downtime
cutover needs two or more replicas and a proxy, which this lab does not have.

Alternatives considered:

- Blue/green: run a full second copy, switch all traffic at once, roll back
  by switching back. Instant rollback, but it needs double capacity and the
  shared state must work with both versions.
- Canary: send a small share of traffic to the new version and watch the
  metrics. Best at catching subtle problems, but it needs weighted routing
  and metrics that this lab does not have.

State and schema compatibility: during a rolling update the old and new
versions run together. The shared state is the Redis `votes` list holding
JSON like `{"voter_id": "...", "vote": "a"}`. Changes to that format must be
additive: the new version keeps the old fields and consumers ignore unknown
ones. Remove old fields only after every old version is gone (expand, then
contract). A rollback does not touch Redis, so votes accepted by the new
version stay in the list.

### A3. Release gates matrix

| Gate | Healthy | Failure | Action on breach | In lab |
|---|---|---|---|---|
| `/ready` probe | 200 within 3s | 2 failures in a row | abort, roll back | yes |
| Restart count | 0 in the window | 1 or more | abort, alert | partial |
| Smoke test | exit 0 | exit 10, 11, 12, 13 | block promotion | yes, CI |
| Image scan | no fixable HIGH | any fixable HIGH | block the build | yes, CI |
| 5xx rate | under 0.1% | over 1% for 2 min | automatic rollback | no |
| p95 latency | 250ms or less | over 800ms sustained | halt rollout | no |

Notes on the lab column:

- The readiness gate is Compose `--wait` with a health check on `/ready`
  (interval 5s, timeout 4s, 2 retries, 5s start period).
- Restart count is partial. The gate caught the restart loop through the
  unhealthy status, and `restarts=2` was visible in `docker inspect`, but no
  script checks the count explicitly.
- The 5xx rate and p95 gates need request metrics. The lab collects none, so
  these two gates are design targets only.

### A4. Evidence from the drill

| Measure | Result |
|---|---|
| Gate rejected the bad release | `up --wait` exit 1 after 4s, "is unhealthy" |
| State right after | `Restarting (1)`, `restarts=2`, `health=starting` |
| User traffic during bad release | `http=000`, curl exit 56 |
| Cause in the logs | `KeyError: 'REDIS_URL'`, `app.py` line 4 |
| Rollback time | 7s with `up -d --wait` on the old digest |
| After rollback | `/ready` 200, vote POST 200, one container per service |
| Votes | 1 before the bad release, 2 after one more vote |
| Running image after | `sha256:52726dde...`, same as before the release |

Reading the state: the line `state=running exit_code=0 restarts=2` is a
snapshot of a momentarily running instance between restarts. Use
`docker compose ps -a` to recognise a restart loop (`Restarting (1)`).

The bad image was built from the good one with only `app.py` replaced, and
its commit label was changed to `bad-demo-3c029cc`, so `docker inspect` shows
that it is not the reviewed commit. The full output is in
`docs/evidence/release-drill.log`.

## Section B: On-call failure playbook

Setup used in the commands below:

```
C="docker compose -f compose/docker-compose.release.yml"
```

### B1. Triage and detection

- Alert (design): the `vote` service unhealthy for more than 1 minute,
  `/ready` returning 503, or a rising restart count. The lab has no alerting,
  so detection here means running the commands below.
- First look: `$C ps -a`. Look for `Restarting`, `unhealthy`, or a missing
  container. In production the first dashboard panel would be readiness
  state and restart count per replica.
- Verify customer impact with the three paths users depend on:

```
curl -s -o /dev/null --max-time 5 -w '%{http_code}\n' http://localhost:8080/
curl -s -o /dev/null --max-time 5 -w '%{http_code}\n' http://localhost:8080/ready
curl -s -o /dev/null --max-time 5 -w '%{http_code}\n' -X POST -d vote=a http://localhost:8080/
```

- Reading the results: the page failing means the service is down. The page
  at 200 with `/ready` at 503 means a dependency (Redis) is the problem. A
  failing POST means votes are being lost.
- Do not restart anything yet. Capture evidence first (section B4), because
  a rollback recreates the container and its logs go with it.

### B2. Identification

```
docker inspect vote-release-vote-1 --format 'image={{.Config.Image}}'
docker inspect vote-release-vote-1 \
  --format 'commit={{index .Config.Labels "org.opencontainers.image.revision"}}'
git show --stat <commit>
```

- The first command gives the running image reference, which should be a
  digest. The second gives the git commit that built it. The third shows what
  that commit changed.
- A commit label that does not exist in git, or one that looks like
  `bad-demo-...`, is a red flag.
- The last known-good digest must be recorded before every deploy. The drill
  reads it from the running container before changing anything. In production
  it comes from the release log.

### B3. Rollback execution

```
export VOTE_IMAGE=localhost:5000/vote@sha256:<last-good-digest>
$C up -d --wait --wait-timeout 60
```

Verify:

```
$C ps -a
curl -s -w ' http=%{http_code}\n' http://localhost:8080/ready
curl -s -o /dev/null -w 'vote http=%{http_code}\n' -X POST -d vote=a http://localhost:8080/
$C exec -T redis redis-cli llen votes
docker inspect vote-release-vote-1 --format 'image={{.Config.Image}}'
```

Success means all of these hold:

- `vote` shows `(healthy)` and both URLs return 200.
- There is one container per service and no leftover containers.
- The running digest equals the digest you rolled back to.
- The vote count did not go down.

Only `vote` is recreated. Redis and its volume are not touched, so no data
is lost. Never roll back to `:latest` or to a version tag.

### B4. Post-incident diagnostics

Run these before the rollback. They only read state, so they do not change
the system.

```
mkdir -p incident
$C ps -a > incident/ps.txt
$C logs --no-color vote > incident/vote.log
docker inspect vote-release-vote-1 > incident/vote-inspect.json
docker inspect vote-release-vote-1 \
  --format 'exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restarts={{.RestartCount}}'
```

- The logs show why the process failed. In the drill the first useful line
  was `KeyError: 'REDIS_URL'` before any request was served.
- `OOMKilled=true` points to the 256MB memory limit.
- The exit code is reliable for a stopped container. While a container is
  restarting the snapshot can show 0, so use `ps -a` for the status.

## Section C: Answers to the verification questions

### C1. If the deployment script crashes halfway, what state is left?

Compose only recreates services whose image or configuration changed, and
Redis is never part of a `vote` release. The possible states are:

1. The crash comes before the recreate: the old version keeps running and
   nothing has changed.
2. The crash comes after the old container was replaced but before the new
   one is verified: the new container is running without a health decision,
   or is crash-looping because of the restart policy.
3. The crash lands exactly between removing the old container and creating
   the new one: the service container is missing.

Detection: `ps -a` plus the image digest and commit label from `docker
inspect` show which version is actually running, whatever the script intended.

Recovery: Compose is declarative and idempotent. Run `up -d --wait` again
with the intended reference, either the new digest or the rollback digest.
No manual cleanup is needed and the Redis volume keeps the data.

Honest limit: I tested a failed release and a rollback, but I did not kill
the script halfway. State 3 comes from how Compose works, not from a test.

### C2. Why is rolling back to `:latest` or a version tag an anti-pattern?

- A tag is a movable pointer. During an outage `:latest` may point at the
  broken build, or at something newer than the last good one.
- Different hosts can hold different images cached under the same tag, so a
  "rolled back" fleet can run different bytes.
- A digest is content-addressed. The same digest means the same bytes
  everywhere, and the drill verified it: the check "running the previous
  digest" passed.
- In this lab even the tag names looked alike (`good-3c029cc` and
  `bad-3c029cc`). Only the digests told the images apart.

### C3. How does a load balancer tell cache initialisation from a deadlock?

It uses separate probes.

- Readiness asks whether the replica can take traffic now. Liveness asks
  whether the process is alive.
- An initialising replica answers but is not ready: liveness passes,
  readiness fails with 503. The balancer withholds traffic and the
  orchestrator waits inside the start period without restarting it.
- A deadlocked replica does not answer at all: the connection is accepted
  and no response arrives within the timeout. Liveness fails repeatedly, so
  the replica is removed from rotation and restarted.
- The Topic 2 smoke test classified these the same way: a refused or reset
  connection means not ready, and a connected request with no response means
  hung.

In this lab the app has `/healthz` (liveness) and `/ready` (readiness), but
the Compose health check uses only `/ready`, and Compose does not restart
unhealthy containers. So the lab shows the distinction without acting on it.
A deadlock of the app itself was not simulated. The hang I tested was a
paused Redis.

## Section D: Limitations

- One `vote` replica means a gap during any release. The drill did not send
  continuous traffic, so the length of the gap was not measured.
- The registry is local, unauthenticated and plain HTTP. Building, tagging
  and pushing digests are manual steps, not part of CI.
- Rollback was run by a script. Nothing triggers it automatically. An
  automatic version would record the running digest, run `up --wait`, and on
  failure save evidence and redeploy the recorded digest.
- There are no request metrics, so the 5xx and p95 gates are design targets.
- Digests prove which bytes run, not who built them. Image signing and
  provenance are not implemented.
- The simulated failure is a crash at start. Slow memory leaks, wrong
  answers, and failures that only appear under load pass a boot-time gate and
  need metric gates.
- `restart: unless-stopped` keeps a crashing container looping until someone
  acts.
- Redis payload changes were not tested.

## Section E: Reproduce

```
docker run -d --restart unless-stopped --name registry -p 5000:5000 registry:2
# build and push the good image, then record its digest as GOOD
# build tests/fixtures/bad-release on top of it, record its digest as BAD
source .release.env
export GOOD BAD
bash tests/release-drill.sh 2>&1 | tee docs/evidence/release-drill.log
```
