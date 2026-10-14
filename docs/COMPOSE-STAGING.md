# Compose Staging Environment

Files: `compose/docker-compose.yml`, `app.py`, `tests/compose-failure-drill.sh`

## 1. Architecture

```
        Browser / curl / smoke test
                    |
              host port 8080
                    |
     network "front" |
          +---------v----------+        network "back" (internal)
          |  vote              |  Redis protocol, TCP 6379
          |  gunicorn :8000    +----------------+
          +--------------------+                |
                                       +---------v----------+
                                       |  redis :6379       |
                                       |  volume: redis-data|
                                       +--------------------+
```

The stack builds `vote` from the same Dockerfile that CI builds and scans, so
what is tested is what runs. Redis is the stock `redis:7-alpine` image.

## 2. How services communicate

- `vote` connects to the hostname `redis` on TCP port 6379.
- Docker's embedded DNS resolves `redis` to the Redis container's IP address,
  but only for containers attached to the same network (`back`).
- Redis has no password. That is acceptable only because the network is
  internal. See the limitations section.

## 3. Ports and exposure

| Service | Container port | Published on host | Who can reach it |
|---|---|---|---|
| vote | 8000 | yes, 8080 | anything that can reach the host |
| redis | 6379 | no | only containers on network `back` |

- Only `vote` is exposed. Redis should stay internal: it has no
  authentication, and nothing outside the stack needs it.
- The `back` network is marked `internal: true`, so containers attached only
  to it cannot reach the internet. Redis has no outbound access.
- `vote` is attached to both networks. Its published port works through
  `front`, and it reaches Redis through `back`.

## 4. Persistent and ephemeral storage

- Persistent: the named volume `redis-data`, mounted at `/data`, with Redis
  append-only persistence on (`--appendonly yes`).
- Ephemeral: containers, networks, and container logs.
- Evidence: after one vote, `docker compose down` then `up -d` left
  `LLEN votes` at 1. Running `down -v` would delete the volume and the votes.
- The vote app writes to Redis and does not read from it. The Redis list is
  the queue that a worker would consume.

## 5. Running versus ready

A container being running only means its main process has not exited. A
service being ready means it can do its job. In this stack they differ.

| Check | Where it runs | What it proves |
|---|---|---|
| redis: `redis-cli ping` | inside redis | Redis answers locally |
| vote: `GET /ready` | inside vote | vote can reach Redis right now |
| `GET /healthz` | inside vote | the web server is up (liveness) |

- `/ready` pings Redis with a 2 second deadline and returns 503 on failure.
- `/healthz` never touches a dependency, so a Redis outage does not make
  Docker think the web process is dead.
- The Compose health check for `vote` uses `/ready`. It runs every 5s and
  marks the container unhealthy after 2 failures.
- `depends_on` with `condition: service_healthy` only gates startup order.
  It does not restart anything later.
- Docker does not restart an unhealthy container by itself. The
  `restart: unless-stopped` policy only applies when a process exits.
  Something else (an orchestrator, an alert, a person) must act on
  `unhealthy`.

## 6. Failure experiments

### Before: health check on `/`, no bounds on Redis calls

| Failure | What the user got | vote health |
|---|---|---|
| Redis stopped | no response after 31.7s | healthy |
| Redis paused (hung) | no response within 12s | healthy |
| Redis cut off from network | HTTP 500 after 31.4s | healthy |

- In the stopped case gunicorn killed the stuck worker at its 30 second
  timeout, so users saw a dropped connection instead of an error page.
- One Redis ping with `socket_timeout=5` took 46.6s, so the setting bounded
  nothing. Name lookups are not covered by a socket timeout.
- The log said "Received vote" even though the vote was lost, because the
  app logged before writing.
- In the network-cut case Redis also reported healthy, because its check
  runs inside its own container.
- A paused container shows no health status at all.
- `GET /` returned 200 in every case, so a smoke test on `/` would pass
  while voting was broken.

### After: `/ready`, bounded Redis calls, honest 503s

| Failure | `GET /ready` | `POST` | vote health |
|---|---|---|---|
| Redis stopped | 503 in 2.0s | 503 in 3.0s | unhealthy |
| Redis paused | 503 in 1.0s | 503 in 1.0s | unhealthy |
| Redis cut off | 503 in 2.0s | 503 in 3.0s | unhealthy |

- `GET /` stayed 200 in every case.
- In the network-cut case, Redis still showed healthy while vote was
  unhealthy. The two statuses together point at the network.
- After each fix, `/ready` and `POST` returned 200 within 10 seconds with
  no container restart.
- The paused case failed at 1.0s (the socket timeout). The stopped and
  disconnected cases ran to the full deadline, which suggests the name
  lookup is the slow part.

### What changed in the app

- Added `/healthz` (liveness) and `/ready` (readiness).
- Each Redis call has short socket timeouts, no client retries, and an
  overall deadline enforced from a worker thread.
- A failed vote returns HTTP 503 with a clear message and an error log
  line, and "Recorded vote" is logged only after a successful write.

## 7. What happens when Redis disappears

1. `vote` keeps running. `GET /` still serves the page.
2. Votes cannot be saved. They are not queued: the user gets HTTP 503 in
   about 3 seconds, and the log shows `vote for X NOT recorded`.
3. About 10 seconds later the Compose health check marks `vote` unhealthy.
4. Nothing restarts automatically. Redis (if it only stopped) is restarted by
   its own policy, and `vote` recovers by itself once Redis answers.
5. Votes accepted before the outage survive if Redis restarts, because of the
   volume. A deleted volume loses them.

## 8. Troubleshooting a failing multi-container stack

Work from the outside in, and change one thing at a time:

```
docker compose -f compose/docker-compose.yml ps
docker compose -f compose/docker-compose.yml logs --tail 50 vote redis
docker inspect --format '{{json .State.Health}}' vote-lab-vote-1
docker compose -f compose/docker-compose.yml exec vote getent hosts redis
docker compose -f compose/docker-compose.yml exec vote python -c "import socket; print(socket.gethostbyname('redis'))"
docker network inspect vote-lab_back
curl -i http://localhost:8080/ready
```

1. Is each container running, and what is its health state?
2. What do the logs of the failing service say?
3. Can the failing container resolve the other service's name?
4. Is the other service attached to the same network?
5. Can the failing container open a connection to its port?

Compare `GET /` with `GET /ready`. If only `/ready` fails, the web process
is fine and a dependency is not.

## 9. Development and staging configuration

- This file is a staging-style setup: it builds the production Dockerfile,
  has no bind mounts, sets memory limits, and sets restart policies.
- A development setup would add bind mounts for live reload, debug mode, and
  a published Redis port for inspection.
- Secrets: none are used today. If Redis gets a password, it should come from
  Compose `secrets` or an untracked env file, never from the YAML.

## 10. Limitations

- Redis has no authentication. The internal network is the only protection.
- There is one replica of each service and no failover.
- Votes during an outage are rejected, not buffered.
- `/ready` checks that Redis answers a ping, not that writes succeed.
- A call that hits its deadline abandons a worker thread, and a hung name
  lookup can hold it for 40 seconds or more. A long outage with heavy
  traffic could fill the 8 thread pool per gunicorn worker. The drill ran
  only briefly and did not test this.
- The `vote` container is not restarted when it becomes unhealthy.
- The drill measures one request per probe, not sustained load.

## 11. Reproduce

```
docker compose -f compose/docker-compose.yml up -d --build
bash tests/compose-failure-drill.sh
docker compose -f compose/docker-compose.yml down
```
