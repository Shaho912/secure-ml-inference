# Measured results log

Raw numbers recorded as each milestone is verified. The README results table is built from this.

## M1: code and dependency scans (2026-10-11)

| Check | Result |
|---|---|
| ruff check / format | pass |
| pytest (18 tests incl. real-model integration) | 18 passed, 99% coverage |
| Bandit (`-r app`, all severities) | 0 issues |
| pip-audit, final lock | 0 known vulnerabilities |

### Found and fixed: stale packages from the PyTorch mirror index
The first lock was generated with uv's default `first-index` strategy plus `--extra-index-url` for
CPU torch. download.pytorch.org also hosts old copies of common packages, and those won:

| Package | Stale (first-index) | Fixed (best-match) | Advisories |
|---|---|---|---|
| idna | 3.4 | 3.20 | PYSEC-2024-60, PYSEC-2026-215 |
| setuptools | 78.1.0 | 84.0.0 | PYSEC-2025-49 (CVE-2025-47273, path traversal), PYSEC-2026-3447 |

pip-audit failed the stale lock (4 advisories, 2 packages). Fix: pin torch/torchvision to `+cpu`
explicitly and resolve with `--index-strategy unsafe-best-match`.

### Limitation found: pip-audit skips `+cpu` torch
pip-audit reported `torch (2.14.1+cpu)` / `torchvision (0.29.1+cpu)` as "not found on PyPI, could not
be audited". Mitigation in `scripts/audit_deps.sh`: a second pass with `+cpu` stripped (same source
release). Positive control: `torch==2.2.0` → 23 advisories detected, so the second pass really works.
Trivy's image scan covers the installed packages as a further layer (M2).

## M2: container (2026-10-11)

### Final image runtime hardening (verified locally)
Run as ECS will run it: `--read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges`.
- `id` → `uid=10001(appuser)`. Writes to `/srv/app` and `/opt/torch` fail (read-only), `/tmp` works.
- `/predict` with key → 200 (top-5, ~45 ms inference on a laptop CPU). Without key → 401.
- No `server` response header. All log lines are JSON, including uvicorn's own.
- Model load at startup: ~4.9 s (mostly `import torch`). This sets the ECS health-check grace period.

### Final image Trivy breakdown (HIGH/CRITICAL, Trivy 0.74.0)
- 0 CRITICAL. 0 fixable HIGH, so the CI gate (`--ignore-unfixed`) passes.
- 0 findings in Python packages (torch, torchvision, pillow, fastapi, ...).
- All remaining HIGHs are Debian 13 base OS packages with no fix released yet
  (`affected` / `fix_deferred`): util-linux family, ncurses, libsystemd/libudev, libacl, perl-base.
  These are Debian "Essential" packages, so they can't be cleanly apt-removed.
  Next step: a distroless or Wolfi-based Python runtime image.

### Baseline vs final (scripts/image_report.sh, identical Trivy flags, HIGH/CRITICAL)
| Image | Compressed MB (ECR/pull) | Unpacked MB | Gate (fixable) H/C | Total H/C | User | OS pkgs | CUDA pkgs |
|---|---|---|---|---|---|---|---|
| baseline (`Dockerfile.single`) | 6555 | 9587 | 0 / 0 | 314 / 16 | root | 469 | 15 |
| final (`Dockerfile`) | 297 | 988 | 0 / 0 | 44 / 0 | 10001 | 87 | 0 |

- 95% smaller compressed (lower ECR storage cost, faster Fargate pulls). 86% fewer HIGH, CRITICAL 16 → 0.
- Honest note: the baseline also passes a fixable-only gate today, because Docker Hub base
  images are freshly patched. The improvement is attack surface, not the gate result.
  That's why both counts are reported.
- Size steps: CPU-only torch + slim base + multi-stage = 336 MB. Stripping torch/include,
  torch/test and pip after the hash-verified install = 297 MB.
- "Size" gotcha: with Docker Desktop's containerd store, `docker image ls` shows disk usage
  (16.6 GB / 1.54 GB), which differs from both numbers above. The table uses compressed
  (`inspect .Size`) and unpacked (`du -sxm /`) and labels which is which.
- Trivy needed `--timeout 20m` for the 6.5 GB baseline (default 5m hit "context deadline exceeded").
  The same flag is used for both images.

## M3: CI pipeline (2026-10-11)

- Full CI job sequence simulated in a clean `python:3.12-slim` container (git-tracked files only):
  hashed install of both locks OK, ruff OK, Bandit OK, pip-audit (both passes) 0 vulns,
  pytest 18 passed / 98.6% coverage (gate: 90%).
- Workflow linting: **actionlint** caught a YAML-breaking colon in a step name (GitHub would have
  rejected the whole workflow). **zizmor** (Actions security audit) flagged 2 template-injection
  sinks (`${{ vars.* }}` inside `run:`), now moved to `env:`, and missing Dependabot cooldowns,
  now 14 days. Final zizmor: 0 high / 0 medium / 0 low.
- All 9 third-party actions pinned to full commit SHAs. Each SHA was verified against the GitHub
  API, and each release is ≥14 days old (e.g. ECS deploy v2.6.3, not v2.6.4 from 2 days ago).
- Trivy runs from a digest-pinned image rather than `aquasecurity/trivy-action`
  (tag hijack, March 2026).
- Scan once, deploy that artifact: build-scan saves the scanned image, and deploy loads it.
  Nothing is rebuilt between the scan and the push.

## M4: billing guardrails (infra/bootstrap, 2026-10-11)

- `terraform fmt -check`, `init -backend=false`, `validate`: pass (Terraform 1.16.3 via Docker,
  hashicorp/aws 6.66.0). Lock file has hashes for linux_amd64, windows_amd64, darwin_arm64.
- Trivy config: 0 findings at all severities, with one justified inline ignore:
  **AWS-0095 (HIGH), SNS topic not encrypted.** Accepted for the billing-alert topic only:
  CloudWatch alarms can't publish to a topic encrypted with the AWS-managed `aws/sns` key (its key
  policy can't grant CloudWatch access), and a customer-managed KMS key costs $1/month for a topic
  that carries only "bill exceeded $X" messages. Verified the ignore is effective: removing it
  makes the scan fail with exactly this finding.
- Cost: $0 (10 CloudWatch alarms free, 2 budgets free, SNS email free tier).

## M5: main stack (infra/main, 2026-10-11)

- `terraform validate` OK. `terraform plan`: 32 to add, 0 errors (read-only; nothing created).
  Live us-east-1 prices from the AWS Price List API; cost table in README.
- Trivy config (built-in): 0 HIGH/CRITICAL after 3 scoped inline ignores. Each was verified needed
  by rescanning without it: AWS-0053 (public ALB, by design), AWS-0054 (HTTP listener, no domain),
  AWS-0104 (task egress 443 to 0.0.0.0/0, no NAT/VPC endpoints). Remaining non-gating findings:
  LOW AWS-0033/0017/0098 (customer-managed KMS keys, $1/mo each), LOW AWS-0034 (Container Insights),
  MEDIUM AWS-0178 (VPC flow logs).
- **Scanner gap found:** a 4th ignore (AWS-0107 on the ALB's public ingress) turned out to be
  dead. Investigating showed Trivy 0.74's AWS-0107 only fires for ports 22/3389. A rule opening
  the app port 8000 to 0.0.0.0/0 produced only LOW findings, so it would have **passed** the CI
  gate. Fix: custom Rego check `policies/no_public_ingress_non_web.rego` (SMI-0001, CRITICAL),
  public ingress only on 80/443. Tested: 0 findings on the real infra; 3/3 caught across
  `aws_vpc_security_group_ingress_rule`, `aws_security_group_rule`, and inline `ingress {}`
  (including `::/0`). Wired into CI. Dead ignore removed.
- gitignore fixes: plan files saved as `tfplan` (no extension) weren't ignored and can contain
  sensitive values; `results/*.json` would have hidden load-test results. Both fixed and tested.

### Local load test (final image capped to Fargate size: --cpus 0.5 --memory 1g, hardened flags)
| Concurrency | Requests | OK | p50 ms | p95 ms | p99 ms | req/s |
|---|---|---|---|---|---|---|
| 1 | 100 | 100 | 78.4 | 144.6 | 396.9 | 11.6 |
| 4 | 100 | 100 | 308.9 | 479.8 | 534.0 | 12.4 |

Service time is about 78 ms. Throughput saturates at about 12 req/s on 0.5 vCPU, so extra
concurrency only adds queueing. Scale out (more tasks), not up (threads). Peak memory 302 MiB of 1 GiB.
