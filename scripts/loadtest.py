"""Load test for POST /predict: client-side p50/p95/p99 latency and throughput.

Usage (the API key comes from the environment, so it never lands in shell history):
    API_KEY=... python scripts/loadtest.py --url http://localhost:8000 -n 300 -c 4
    API_KEY=... python scripts/loadtest.py --url http://<alb-dns> -n 300 -c 4 --label aws

Client-side latency includes the network round trip, so it's what a caller actually sees.
"""

import argparse
import asyncio
import io
import json
import os
import statistics
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

import httpx
from PIL import Image


def make_jpeg(seed: int = 7) -> bytes:
    """A deterministic 224x224 noise JPEG (realistic size for an encoded photo)."""
    import random

    rng = random.Random(seed)
    img = Image.new("RGB", (224, 224))
    img.putdata(
        [(rng.randrange(256), rng.randrange(256), rng.randrange(256)) for _ in range(224 * 224)]
    )
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=85)
    return buf.getvalue()


def pct(sorted_vals: list[float], p: float) -> float:
    """Nearest-rank percentile."""
    k = max(0, min(len(sorted_vals) - 1, round(p / 100 * len(sorted_vals) + 0.5) - 1))
    return sorted_vals[k]


async def run(url: str, n: int, concurrency: int, warmup: int, key: str) -> dict:
    payload = make_jpeg()
    headers = {"X-API-Key": key}
    latencies: list[float] = []
    statuses: dict[int, int] = {}
    errors = 0
    sem = asyncio.Semaphore(concurrency)

    async with httpx.AsyncClient(base_url=url, timeout=30, headers=headers) as client:

        async def one(record: bool) -> None:
            nonlocal errors
            async with sem:
                start = time.perf_counter()
                try:
                    r = await client.post(
                        "/predict", files={"file": ("x.jpg", payload, "image/jpeg")}
                    )
                except httpx.HTTPError:
                    if record:
                        errors += 1
                    return
                elapsed_ms = (time.perf_counter() - start) * 1000
                if record:
                    statuses[r.status_code] = statuses.get(r.status_code, 0) + 1
                    if r.status_code == 200:
                        latencies.append(elapsed_ms)

        await asyncio.gather(*(one(False) for _ in range(warmup)))
        wall_start = time.perf_counter()
        await asyncio.gather(*(one(True) for _ in range(n)))
        wall_s = time.perf_counter() - wall_start

    lat = sorted(latencies)
    return {
        "url": url,
        "requests": n,
        "concurrency": concurrency,
        "ok": len(lat),
        "statuses": statuses,
        "transport_errors": errors,
        "p50_ms": round(pct(lat, 50), 1) if lat else None,
        "p95_ms": round(pct(lat, 95), 1) if lat else None,
        "p99_ms": round(pct(lat, 99), 1) if lat else None,
        "mean_ms": round(statistics.fmean(lat), 1) if lat else None,
        "throughput_rps": round(len(lat) / wall_s, 2) if wall_s else None,
        "payload_bytes": len(payload),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--url", default="http://localhost:8000")
    ap.add_argument("-n", "--requests", type=int, default=300)
    ap.add_argument("-c", "--concurrency", type=int, default=4)
    ap.add_argument("--warmup", type=int, default=10)
    ap.add_argument("--label", default="local", help="name for the saved result file")
    args = ap.parse_args()

    key = os.environ.get("API_KEY")
    if not key:
        print("error: set the API_KEY environment variable", file=sys.stderr)
        return 2

    result = asyncio.run(
        run(args.url.rstrip("/"), args.requests, args.concurrency, args.warmup, key)
    )
    result["label"] = args.label
    result["measured_at"] = datetime.now(UTC).isoformat(timespec="seconds")
    print(json.dumps(result, indent=2))

    out = Path("results") / f"loadtest-{args.label}.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(result, indent=2) + "\n")
    print(f"saved {out}", file=sys.stderr)
    return 0 if result["ok"] == args.requests else 1


if __name__ == "__main__":
    sys.exit(main())
