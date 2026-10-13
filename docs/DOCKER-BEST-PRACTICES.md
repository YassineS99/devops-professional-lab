# Docker Best Practices: Vote Service

Service: the `vote` Flask app from `example-voting-app`, served by gunicorn and backed by Redis.
Tooling: Docker Desktop (BuildKit), Docker Scout for scanning.

## 1. Summary

I rebuilt the `vote` image for production use and measured it against the original. The original image and a deliberately bad variant are used as comparison points.

| Metric | Original (`vote:before`) | Improved (`vote:after`) | Bad demo (`vote:bad`) |
|---|---|---|---|
| Disk size | 241MB | **206MB** | 1.66GB |
| Compressed size | 58.6MB | **49.5MB** | 428MB |
| User running the app | root (uid 0) | **app (uid 10001)** | root (uid 0) |
| Packages indexed by Scout | 193 | **136** | not measured |
| `curl` / `pip` in final image | both present | **both removed** | not measured |
| Python packages installed | 13 (incl. pip, setuptools, wheel) | **10 (app dependencies only)** | not measured |
| Vulnerabilities (C/H/M/L) | 0 / 4 / 7 / 49 (60 total) | **0 / 1 / 1 / 26 (28 total)** | 0 / 31 / 62 / 220, plus 16 unrated (329 total) |
| Base image reference | floating tag `python:3.11-slim` | **tag pinned by digest** | `python:latest` |
| Dependency versions | unpinned | **pinned** | unpinned |
| `.dockerignore` | none | **present** | none |
| Healthcheck | none in production stage | **built in, no curl needed** | none |
| Secrets in image | not tested | **none** | `.env` readable inside the image |
| Rebuild after a one-line code change | n/a | **3.5s** | 11.5s |

Filesystem layers added by the Dockerfile: 5 before, 6 after. Layer count was not an optimization goal. What matters is what each layer contains and how well it caches.

## 2. The final Dockerfile

```dockerfile
# syntax=docker/dockerfile:1.7

FROM python:3.11-slim@sha256:e88e9763f943ec1834f992a4b51e0f24500486803e8bc534e5767af9ea65f6ce AS builder
WORKDIR /build
COPY requirements.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --prefix=/install -r requirements.txt

FROM python:3.11-slim@sha256:e88e9763f943ec1834f992a4b51e0f24500486803e8bc534e5767af9ea65f6ce AS final
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    WEB_CONCURRENCY=2
RUN pip uninstall -y pip setuptools wheel \
 && groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --create-home --shell /usr/sbin/nologin app
WORKDIR /app
COPY --from=builder /install /usr/local
COPY --chown=app:app app.py ./
COPY --chown=app:app templates ./templates
COPY --chown=app:app static ./static
USER app
EXPOSE 8000
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/', timeout=2)"]
ENTRYPOINT ["gunicorn"]
CMD ["app:app", "-b", "0.0.0.0:8000", "--log-file", "-", "--access-logfile", "-", "--keep-alive", "0"]
```

`.dockerignore`:

```
.git
.github
.vscode
__pycache__
*.pyc
.env
docs
tests
compose
Dockerfile*
README.md
```

`requirements.txt` (pinned to the versions the original image resolved):

```
Flask==3.1.3
redis==8.1.0
gunicorn==26.2.0
```

## 3. Every change, and why

| Change | What it does | Why |
|---|---|---|
| Base image pinned by digest | `python:3.11-slim@sha256:...` | The same bytes are used on every build. A floating tag can change under you between builds. |
| Pinned dependencies | exact versions in `requirements.txt` | Reproducible builds and no surprise upgrades. |
| Multi-stage build | dependencies are installed in `builder`, only the result is copied into `final` | pip's tooling and caches never reach the runtime image. |
| `pip uninstall pip setuptools wheel` in the final stage | removes the install tooling | These packages carried 1 HIGH and 6 MEDIUM findings between them, plus a bundled `jaraco-context` HIGH. The running app does not need them, and nobody can `pip install` into a live container. |
| `curl` removed | the original image installed it only to support the dev healthcheck | Fewer binaries, less attack surface, 6 fewer findings, and a faster build (the apt step took ~35s). |
| Non-root user, uid 10001 | `USER app` | A compromised process does not get root inside the container. |
| Fixed numeric uid/gid | `--uid 10001` | Predictable ownership on volumes and in Kubernetes security contexts. |
| Port 8000 instead of 80 | unprivileged port | A non-root process should not need a privileged port. Compose maps it as `8080:8000`. |
| Selective `COPY` | only `app.py`, `templates`, `static` | The image contains only what the app needs. |
| Dependencies copied and installed before app code | in the `builder` stage | Code edits do not invalidate the dependency layer. |
| BuildKit cache mount for pip | `--mount=type=cache` | Faster rebuilds when dependencies do change, with no cache left in the image. |
| `.dockerignore` | excludes `.git`, `.env`, docs and similar | Smaller build context and no secrets or history leaking into build steps. |
| `HEALTHCHECK` using Python | probes `/` every 10s | Distinguishes "container running" from "service ready" without needing curl. |
| `ENTRYPOINT` + `CMD` | gunicorn is the fixed executable, arguments are overridable defaults | Operators can change arguments without replacing the program. |
| `WEB_CONCURRENCY` env var | worker count is configurable | Tunable at run time without editing the image. The original hard-coded 4 workers. |
| `PYTHONUNBUFFERED=1` | unbuffered output | Logs appear immediately in `docker logs`. |
| `PYTHONDONTWRITEBYTECODE=1` | no `.pyc` files | Keeps the filesystem clean. |
| Dropped the `dev` stage | production image only | The lab targets production behavior. The development stage remains in the original repo. |

## 4. A bug my hardening introduced, and how I found it

After the first hardened build the container was healthy and returned HTTP 200, but the logs contained:

```
[ERROR] Control server error: [Errno 13] Permission denied: '/home/app'
```

Cause: I created the user with `--no-create-home`, but this gunicorn version wants to create a control socket under the user's home directory. The directory did not exist and the `app` user could not create it.

Fix: create the home directory (`--create-home`). After rebuilding, the log line became:

```
[INFO] Control socket listening at /home/app/.gunicorn/gunicorn.ctl
```

Lesson: a passing healthcheck is not the same as a clean start. I read the logs after every change.

## 5. Deliberate bad practice and its consequences

`bad-demo/Dockerfile`:

```dockerfile
FROM python:latest
WORKDIR /app
COPY . .
RUN pip install -r requirements.txt
EXPOSE 8000
CMD ["gunicorn", "app:app", "-b", "0.0.0.0:8000"]
```

with no `.dockerignore` and a fake `.env` file containing `FAKE_API_KEY=this-is-a-fake-secret-for-demo`.

What went wrong, with evidence:

1. **Secret leak.** `docker run --rm --entrypoint cat vote:bad /app/.env` printed the secret. Anyone who can pull or run the image can read it. It also stays in the image layers even if a later step deletes the file.
2. **Size.** 1.66GB on disk and 428MB compressed, about 8x the improved image, because `python:latest` is the full Debian-based image with compilers and tooling.
3. **Runs as root.** `id` returned `uid=0(root)`.
4. **Slow rebuilds.** `COPY . .` comes before `pip install`, so adding one comment line to `app.py` re-ran the dependency install. The rebuild took **11.5s**, against **3.5s** for the improved image with the same change.
5. **Not reproducible.** `latest` moves. The same Dockerfile can produce a different Python version next month.
6. **Known vulnerabilities.** Docker Scout found 329 vulnerabilities (31 HIGH) in the bad image against 28 (1 HIGH) in the improved one, because the full `python:latest` image ships far more packages than the app needs.

## 6. Production-readiness checklist

- [x] Base image pinned by digest
- [x] Dependencies pinned
- [x] Multi-stage build, no build tooling in the final image
- [x] Runs as a non-root user with a fixed uid
- [x] Unprivileged port
- [x] `.dockerignore` present, no secrets in the image
- [x] Built-in healthcheck, verified `(healthy)` in `docker ps`
- [x] Clean startup logs
- [x] Scanned with Docker Scout, with findings analyzed

## 7. Known limitations

- **Remaining vulnerabilities (1 HIGH, 1 MEDIUM, 26 LOW)** are in Debian base packages (zlib, tar, glibc and others) and Scout reports them as "not fixed" upstream. I removed everything within my control and cannot patch the rest. Mitigation: rebuild regularly so fixed packages are picked up, and monitor.
- **Digest pinning needs maintenance.** A pinned digest never receives security updates by itself. A tool such as Dependabot or Renovate should bump it.
- **Image size gain is modest** (241MB to 206MB) because the Python slim base is most of the size. Going smaller means Alpine (musl compatibility risks) or distroless (no shell for debugging), each with trade-offs.

- **Healthcheck checks `/` only.** It proves the web server answers, not that Redis is reachable. Readiness against dependencies is covered in the Compose topic.

## 8. Reproduce

```powershell
docker build -t vote:after .
docker images vote:after
docker run --rm --entrypoint id vote:after
docker scout cves vote:after
docker run -d --name vote-after -p 8080:8000 vote:after
docker ps
curl.exe -s -o NUL -w "%{http_code}" http://localhost:8080/
docker logs vote-after
docker rm -f vote-after
```