# CLAUDE.md

FastAPI service serving a pretrained PyTorch image classifier (torchvision MobileNetV3-Small,
ImageNet-1k), packaged as a hardened container. GitHub Actions lints, tests, and security-scans it
(Bandit, pip-audit, Trivy image + IaC), then pushes it to ECR and deploys it to ECS Fargate behind an ALB
using GitHub OIDC (no long-lived AWS keys). Terraform owns all AWS resources. The API key lives in
Secrets Manager. Logs and latency go to CloudWatch. Portfolio project: README results must be real
measurements, and limitations must be stated honestly.

## Layout
- `app/` — `main.py` (`create_app` factory, routes, access-log middleware), `model.py` (`TorchClassifier`),
  `config.py` (pydantic-settings; the only place env vars are read), `logging_config.py` (JSON logs)
- `tests/` — `conftest.py` has `FakeClassifier` + fixtures; `@pytest.mark.integration` = real model
- `scripts/` — `audit_deps.sh` (pip-audit, two-pass for `+cpu` torch), `image_report.sh`, `loadtest.py`
- `docker/` — `Dockerfile` (multi-stage, final), `Dockerfile.single` (naive baseline for comparison)
- `infra/bootstrap/` — billing alarm + budget (apply first). `infra/main/` — everything else.
- `policies/` — custom Trivy Rego checks (SMI-xxxx) for project invariants that built-in checks miss
- `results/` — measured numbers that feed the README results table

## Commands (Git Bash; on Linux/CI use `.venv/bin`)
```bash
python -m venv .venv && .venv/Scripts/python -m pip install uv
# Local (Windows) dev installs from the .in files; CI/Docker install the hashed Linux lock.
.venv/Scripts/uv pip install --python .venv/Scripts/python.exe --index-strategy unsafe-best-match \
  -r requirements.in -r requirements-dev.in

.venv/Scripts/ruff check . && .venv/Scripts/ruff format --check .
.venv/Scripts/python -m pytest -m "not integration"     # fast unit tests
.venv/Scripts/python -m pytest --cov                    # includes real-model test
.venv/Scripts/bandit -c pyproject.toml -r app --severity-level high
PATH="$PWD/.venv/Scripts:$PATH" bash scripts/audit_deps.sh
```
Docker / scans (Git Bash: prefix `MSYS_NO_PATHCONV=1` so container paths aren't rewritten):
```bash
docker build -f docker/Dockerfile -t secure-ml-inference:final .
# ECS-like: an empty volume at /tmp (NOT --tmpfs, which is 1777 and hid a Fargate bug)
docker run --rm -p 8000:8000 -e API_KEY=... --read-only --mount type=volume,dst=/tmp --cap-drop ALL secure-ml-inference:final
bash scripts/image_report.sh           # needs :baseline too (docker/Dockerfile.single, ~13 min, ~16 GB)
# Workflow lint + GitHub Actions security audit (run after editing .github/):
docker run --rm -v "$(pwd -W):/repo" -w /repo rhysd/actionlint:1.7.7
docker run --rm -v "$(pwd -W):/repo:ro" ghcr.io/zizmorcore/zizmor:1.16.0 --offline --persona=auditor /repo/.github
```
CI (`.github/workflows/pipeline.yml`): lint → (test ‖ security: Bandit, pip-audit, Trivy config) →
build-scan (Trivy image gate, SARIF, SBOM, save image) → deploy (production env approval, OIDC).
Action pins: full SHA + `# vX.Y.Z`, release ≥14 days old. Repo vars, never `${{ }}` inside `run:`.

Regenerating locks: see the header comments in `requirements.in` / `requirements-dev.in`.
Always pass `--upgrade` (uv otherwise keeps pins from the existing output file) and
`--index-strategy unsafe-best-match` (otherwise stale copies on the PyTorch mirror win).

## Conventions
- Pinned, hashed deps. torch/torchvision pinned to `+cpu` builds. Never install CUDA wheels.
- Config only via `app/config.py`. Secrets are `SecretStr` and must never be logged.
- Logs: one JSON object per line with `event`, `latency_ms`, `request_id`. `/health` is not logged.
- Unit tests use `FakeClassifier` (no torch import). Only `integration` tests load real weights.
- Terraform split by concern (`vpc.tf`, `ecs.tf`, `iam.tf`, …). Every resource gets `project`/`env` tags.
- GitHub Actions pinned to full commit SHAs (version in a trailing comment). Dependabot keeps them current.

## Guardrails
- Never run `terraform apply`/`destroy`, push images, push to GitHub, or change GitHub/AWS settings.
  The user does these. Write the code and tell them the exact command.
- Before adding any AWS resource, state what it is and what it costs, and update the README cost table.
- Stay in the free tier where possible. No NAT gateway (see README known limitations).
- Never commit secrets, `.env`, `*.tfstate`, or `*.tfvars`. Secret values go into Secrets Manager via
  the CLI only, never through Terraform (it would land in state).
- IAM least privilege: `Resource = "*"` only where AWS requires it, with a comment saying so.
- Never weaken a scanner to get CI green. Fix the finding, or add a commented `.trivyignore`
  entry AND list it under README "Known limitations".
- Baseline vs final image comparisons must use identical Trivy flags.
- Every `#trivy:ignore` must be verified needed (rescan without it). Test custom policies against a
  deliberately bad example before trusting them.
- Work in small steps and explain each choice.
