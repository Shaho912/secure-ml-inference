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
