# syntax=docker/dockerfile:1
# Final production image. Build from the repo root:
#   docker build -f docker/Dockerfile -t secure-ml-inference:final .

# Pinned by digest for reproducible builds; Dependabot (docker ecosystem) proposes updates.
ARG PYTHON_IMAGE=python:3.12-slim@sha256:a6e34c598f2467ed0e9a8d349809fcd8b5c603269512df273a0bb1784edc11b1

# ---------- builder: install deps + fetch model weights ----------
FROM ${PYTHON_IMAGE} AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    TORCH_HOME=/opt/torch

RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH

COPY requirements.txt .
# --require-hashes: every wheel must match the lock's SHA-256, so a tampered or substituted
# package fails the build. --no-deps: the lock is complete; nothing unlisted gets pulled in.
RUN pip install --require-hashes --no-deps -r requirements.txt

# Download weights at build time so the container never needs internet access at runtime.
# torchvision verifies the checkpoint's hash (encoded in its filename) on download.
RUN python -c "from torchvision.models import MobileNet_V3_Small_Weights as W; \
W.IMAGENET1K_V1.get_state_dict(progress=False, check_hash=True)"

# Strip what inference never uses (after the hash-verified install, so integrity checks still ran):
# torch's C++ headers (only for compiling extensions) and its test suite, plus pip itself
# (nothing installs packages at runtime). Saves ~160 MB unpacked.
RUN SP=/opt/venv/lib/python3.12/site-packages \
 && rm -rf "$SP/torch/include" "$SP/torch/test" \
 && python -m pip uninstall -y -q pip

# ---------- runtime: only what's needed to serve ----------
FROM ${PYTHON_IMAGE} AS runtime

ENV PATH=/opt/venv/bin:$PATH \
    TORCH_HOME=/opt/torch \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Fixed non-root uid/gid (10001) with no home dir and no login shell.
RUN groupadd --system --gid 10001 appuser \
 && useradd --system --uid 10001 --gid appuser --no-create-home --shell /usr/sbin/nologin appuser

# Copied as root-owned: the app user can read the code/weights but not modify them.
COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /opt/torch /opt/torch
COPY app/ /srv/app/

# /tmp is the only writable path (the root filesystem is read-only in ECS). torch needs a usable
# temp dir at import time. ECS creates the task's /tmp volume as root:root 0755 unless the
# image declares a VOLUME at the same path, in which case it copies this directory's ownership
# and permissions into the volume. Owned by appuser, mode 0700: only the app can use it.
# (Must come before VOLUME: changes to a path after its VOLUME line are discarded.)
RUN chown 10001:10001 /tmp && chmod 0700 /tmp
VOLUME ["/tmp"]

WORKDIR /srv
USER 10001:10001
EXPOSE 8000

# Python stdlib instead of curl: no extra package (and its CVEs) in the image.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4)"]

# --no-server-header: don't advertise the server software/version in responses.
CMD ["uvicorn", "--factory", "app.main:app_factory", "--host", "0.0.0.0", "--port", "8000", \
     "--no-server-header", "--workers", "1"]
