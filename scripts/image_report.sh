#!/usr/bin/env bash
# Compare the baseline and final images: size + Trivy HIGH/CRITICAL vulnerability counts.
#
# Both images are scanned with IDENTICAL flags so the before/after numbers are comparable.
# Two counts per image:
#   gate  = with --ignore-unfixed (what CI fails on: CVEs that have a fix available)
#   total = without it (full exposure, including CVEs with no fix released yet)
#
# Usage: scripts/image_report.sh [baseline_tag] [final_tag]
set -euo pipefail
export MSYS_NO_PATHCONV=1  # Git Bash on Windows: don't rewrite the /var/run/docker.sock path

BASELINE="${1:-secure-ml-inference:baseline}"
FINAL="${2:-secure-ml-inference:final}"
# Pinned by version AND digest (Trivy's release channel was compromised in March 2026).
TRIVY_IMAGE="aquasec/trivy:0.74.0@sha256:62b1e65e8869bc4b4c6aa4fa2b21595256c7c2f6018a9d9ad61caf87187c1969"
OUT="results"
mkdir -p "$OUT"

trivy() {
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
    -v trivy-cache:/root/.cache/trivy "$TRIVY_IMAGE" "$@"
}

PY=python3; "$PY" -c "" 2>/dev/null || PY=python  # Windows: python3 may be a Store stub
count() {  # count <trivy-json> -> "HIGH CRITICAL" (unique CVE+package pairs)
  "$PY" -c '
import json, sys
vulns = [v for r in json.load(open(sys.argv[1])).get("Results", []) for v in r.get("Vulnerabilities") or []]
uniq = {(v["VulnerabilityID"], v["PkgName"], v["Severity"]) for v in vulns}
print(sum(s == "HIGH" for *_, s in uniq), sum(s == "CRITICAL" for *_, s in uniq))
' "$1"
}

for img in "$BASELINE" "$FINAL"; do
  docker image inspect "$img" >/dev/null 2>&1 || { echo "error: image $img not found; build it first" >&2; exit 1; }
done

COMMON=(image --quiet --timeout 20m --scanners vuln --severity HIGH,CRITICAL --format json)

printf '| Image | Compressed MB (ECR/pull) | Unpacked MB | Gate HIGH/CRIT (fixable) | Total HIGH/CRIT |\n' \
  | tee "$OUT/image_report.md"
printf '|---|---|---|---|---|\n' | tee -a "$OUT/image_report.md"
for img in "$BASELINE" "$FINAL"; do
  name="${img##*:}"
  # With Docker's containerd image store, inspect .Size is the compressed size (what ECR stores).
  size_mb=$(( $(docker image inspect "$img" --format '{{.Size}}') / 1000000 ))
  unpacked_mb=$(docker run --rm --entrypoint sh "$img" -c 'du -sxm / 2>/dev/null | cut -f1')
  trivy "${COMMON[@]}" --ignore-unfixed "$img" > "$OUT/trivy-$name-gate.json"
  trivy "${COMMON[@]}" "$img" > "$OUT/trivy-$name-total.json"
  read -r gh gc < <(count "$OUT/trivy-$name-gate.json")
  read -r th tc < <(count "$OUT/trivy-$name-total.json")
  printf '| %s | %s | %s | %s / %s | %s / %s |\n' \
    "$name" "$size_mb" "$unpacked_mb" "$gh" "$gc" "$th" "$tc" \
    | tee -a "$OUT/image_report.md"
done
