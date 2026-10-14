# GitHub Actions Security

Files: `.github/workflows/pull-request.yml`, `.github/workflows/security.yml`, `.github/dependabot.yml`, plus repository settings.

## 1. The questions

1. What could an attacker do if they submitted a malicious pull request to this repository?
2. What permissions does my workflow give that code?

## 2. Threat model

```
Attacker --> Pull Request --> GitHub Runner --> Workflow --> Docker --> Application
```

| Stage | What the attacker controls or reaches | What could be abused | Mitigation in this repo | Residual risk |
|---|---|---|---|---|
| Pull request | Every file in the PR: Dockerfile, app code, scripts, even the workflow file itself | Running arbitrary code in CI | Workflows use `pull_request`, never `pull_request_target`. Approval is required for all external contributors | PRs from collaborators run without approval, so a compromised collaborator account is a risk |
| Trigger and token | The PR's own version of the workflow runs. Fork PRs get a read-only token and no secrets | Token abuse, secret theft | No secrets are referenced by any workflow. `permissions: {}` at workflow level, `contents: read` per job | If secrets are added later, same-repo PRs could read them |
| GitHub runner | An ephemeral GitHub-hosted VM, one job per VM | Crypto-mining, network egress, reading anything in the job environment | `timeout-minutes` of 10 and 15, concurrency cancels superseded runs, hosted runners only | Network egress is unrestricted. A self-hosted runner must never run PR code, because it persists |
| Workflow and actions | Third-party action code runs inside the job | A compromised or retagged action steals the token or secrets | Every action pinned to a full commit SHA, enforced by a repo setting. `persist-credentials: false`. Dependabot proposes updates with a 14-day cooldown. Trivy binary pinned to v0.69.3 | Actions called by actions (setup-trivy, actions/cache) are pinned by the action's author, not by me |
| Docker | `docker build` executes PR-controlled `RUN` steps and `docker run` executes PR code | Code execution on the runner, access to the Docker daemon | Ephemeral VM, no registry credentials, image is never pushed | If push credentials are ever added, untrusted PR builds must not receive them |
| Application and artifacts | Uploaded logs and SBOM contain output influenced by PR code | A privileged workflow that trusts artifacts could be tricked | No workflow consumes artifacts. Retention is 7 and 30 days | A future `workflow_run` consumer must treat artifacts as untrusted |

Cache note: the scan job restores the Trivy binary and vulnerability database from the Actions cache. Caches written by a pull request run are scoped to that PR, so they should not be able to poison the caches used on `main`.

## 3. Permissions the workflow grants

| Scope | Setting |
|---|---|
| Workflow level | `permissions: {}` (nothing by default) |
| Each job | `contents: read` only |
| Repository default token | Read repository contents and packages |
| Actions may create or approve PRs | Off |
| Secrets referenced | None |
| Fork PR approval | Required for all external contributors |
| Unpinned actions | Rejected by the "require full-length commit SHA" setting |

## 4. Assessment workflow compared with the hardened one

| Aspect | Assessment workflow | Hardened workflows |
|---|---|---|
| Trigger | `pull_request` | `pull_request` (kept) |
| Token permissions | `contents: read` on the job | `{}` at workflow level, `contents: read` per job |
| Action reference | `actions/checkout@v4` (movable tag) | Full commit SHA with a version comment |
| Credentials after checkout | Left in `.git/config` | `persist-credentials: false` |
| Job timeout | None (default 360 minutes) | 10 and 15 minutes |
| Concurrency | None | Superseded runs are cancelled |
| Smoke test | 15 retries, no per-request timeout | `reliable-smoke-test.sh`, bounded (see CI-RELIABILITY.md) |
| Image scan | None | Trivy, gating on fixable HIGH and CRITICAL |
| SBOM | None | CycloneDX, uploaded as an artifact |
| Updating pins | Manual | Dependabot, weekly, 14-day cooldown |

## 5. Action pinning decisions

Rule: pin to a full commit SHA, never a tag. A tag is a pointer that can be moved, and a SHA cannot.

Method: `git ls-remote --tags <repo>` gives the SHA. For annotated tags the SHA on the `^{}` line is the real commit. Release dates come from the GitHub releases API, and I only pin versions that are at least 14 days old.

Pinned versions at the time of writing:

| Action | Version | Published | Reason |
|---|---|---|---|
| `actions/checkout` | v6.0.2 | 2026-01-09 | Old enough to have been used widely. Newer versions exist and Dependabot has proposed them |
| `actions/upload-artifact` | v6.0.0 | 2025-12-12 | Same reasoning |
| `aquasecurity/trivy-action` | v0.35.0 | 2026-03-20 | The first release after the March 2026 compromise that responders named as safe. The commit also matches their published report |
| Trivy binary | v0.69.3 | | Named as safe in the advisory. Pinned through the `version:` input. Dependabot does not track this input, so it is bumped by hand |

Dependabot behaviour observed: after the config was merged, branches for `actions/checkout` 7.0.1, `actions/upload-artifact` 7.0.1 and `trivy-action` 0.36.0 appeared. Each is reviewed before merging.

## 6. Case study: the Trivy compromise (March 2026)

- On March 19, 2026, an attacker used compromised credentials to publish a malicious Trivy v0.69.4, to force-push 76 of the 77 version tags of `aquasecurity/trivy-action`, and to replace all 7 tags of `aquasecurity/setup-trivy`. It is tracked as CVE-2026-33634.
- The malicious code ran before the real scan logic, so a compromised workflow could still finish normally.
- Workflows that referenced a tag ran the attacker's code with access to everything in the job. Workflows pinned to a commit SHA were not affected.
- Safe versions named by responders: Trivy v0.69.2 and v0.69.3, trivy-action 0.35.0, setup-trivy 0.2.6.

Lessons applied here: pin to a SHA, enforce pinning with a repository setting, avoid brand-new releases, pin the tool binary as well as the action, and keep the job's token and secrets minimal so that a compromised step has little to steal.

Sources: https://stack.watch/vuln/CVE-2026-33634/ and https://www.legitsecurity.com/blog/the-trivy-supply-chain-compromise-what-happened-and-playbooks-to-respond and the advisory at https://github.com/aquasecurity/trivy/security/advisories/GHSA-69fq-xp46-6x23

## 7. Image scan and SBOM

Scan: Trivy v0.69.3 against the built image, failing on HIGH or CRITICAL findings that have a fix available (`severity: HIGH,CRITICAL`, `ignore-unfixed: true`).

Result: OS packages (Debian 13.7, 87 packages) 0 findings, and all 10 Python packages 0 findings.

Why this differs from Docker Scout: Scout reported 1 HIGH (zlib) and 1 MEDIUM (tar) in the base image. Both have no upstream fix, so the gate ignores them on purpose. They are documented in DOCKER-BEST-PRACTICES.md and the weekly scheduled run will catch them once a fix exists.

SBOM: CycloneDX JSON, uploaded as the `sbom` artifact (about 11 KB, kept 30 days). It lists every package in the image, so a newly disclosed CVE can be checked against it without rebuilding anything.

## 8. Research notes

- `pull_request` runs the PR's code with a restricted token. For forks the token is read-only and secrets are not provided. `pull_request_target` runs in the context of the base branch with a privileged token and secrets, so it is dangerous whenever it checks out or runs PR code.
- `GITHUB_TOKEN` is a short-lived token created per job, and its scopes are set by `permissions`.
- An SBOM is an inventory of what is inside an artifact.
- Image signing (for example Sigstore cosign) lets a deploy step verify an image digest was produced by a trusted pipeline.
- SLSA is a framework that describes how verifiable a build's provenance is.
- CodeQL is static analysis that finds vulnerable code patterns.
- Dependabot opens PRs to update pinned dependencies, and its cooldown option delays brand-new releases.

## 9. Limitations and what is not done

- No image signing and no SLSA provenance attestation.
- CodeQL is not enabled.
- "Allow all actions" is still selected. The SHA-pinning requirement limits the risk but does not restrict which publishers can be used.
- Actions called by other actions are pinned by their authors, not by me.
- The Trivy binary version needs a manual bump.
- The approval rule does not help if a collaborator's account is compromised.
- The runner's network access is not restricted.

## 10. Evidence

- Pull Request workflow: green in 15 seconds on PR #1, with SHA-pinned downloads and credentials removed at the end of checkout.
- Security workflow: green in about 1 minute on PR #2, with the scan table and the `sbom` artifact.
- Repository settings: read-only workflow permissions, create-and-approve-PRs off, approval for all external contributors, SHA pinning required.
- Dependabot: enabled for github-actions, docker and pip, with three branches opened shortly after the config was merged.
