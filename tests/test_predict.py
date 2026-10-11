import json
import logging

import pytest
from pydantic import ValidationError

from app.config import Settings
from app.logging_config import JsonFormatter
from tests.conftest import TEST_KEY, make_image_bytes


def post_image(client, data: bytes, content_type: str = "image/png", headers=None):
    return client.post(
        "/predict", files={"file": ("img", data, content_type)}, headers=headers or {}
    )


def test_predict_returns_top_k(client, auth):
    resp = post_image(client, make_image_bytes(), headers=auth)
    assert resp.status_code == 200
    body = resp.json()
    assert body["model"] == "fake"
    assert [p["label"] for p in body["predictions"]] == ["class_0", "class_1", "class_2"]
    assert body["inference_ms"] >= 0


@pytest.mark.parametrize("fmt,ctype", [("JPEG", "image/jpeg"), ("WEBP", "image/webp")])
def test_predict_accepts_other_formats(client, auth, fmt, ctype):
    assert post_image(client, make_image_bytes(fmt), ctype, headers=auth).status_code == 200


def test_missing_api_key_rejected(client):
    assert post_image(client, make_image_bytes()).status_code == 401


def test_wrong_api_key_rejected(client):
    resp = post_image(client, make_image_bytes(), headers={"X-API-Key": "wrong-key-wrong-key"})
    assert resp.status_code == 401


def test_unsupported_content_type(client, auth):
    resp = post_image(client, b"hello", "text/plain", headers=auth)
    assert resp.status_code == 415


def test_oversized_upload(client, auth):
    big = make_image_bytes("BMP", size=(200, 200))  # ~120 KB > 64 KB limit in test settings
    resp = post_image(client, big, "image/png", headers=auth)
    assert resp.status_code == 413


def test_corrupt_image(client, auth):
    resp = post_image(client, b"\x89PNG\r\n\x1a\nnot really a png", headers=auth)
    assert resp.status_code == 400


def test_decompression_bomb_rejected(auth):
    from fastapi.testclient import TestClient

    from app.main import create_app
    from tests.conftest import FakeClassifier

    # PIL raises DecompressionBombError above 2x the pixel limit
    s = Settings(_env_file=None, api_key=TEST_KEY, max_image_pixels=100)
    with TestClient(create_app(settings=s, load_model=lambda _: FakeClassifier())) as c:
        resp = post_image(c, make_image_bytes(size=(64, 64)), headers=auth)
    assert resp.status_code == 400


def request_logs(caplog) -> list[dict]:
    return [r.fields for r in caplog.records if getattr(r, "fields", {}).get("event") == "request"]


def test_request_is_logged_with_latency(client, auth, caplog):
    post_image(client, make_image_bytes(), headers=auth)
    entry = request_logs(caplog)[-1]
    assert entry["path"] == "/predict" and entry["status"] == 200
    assert entry["latency_ms"] >= 0


def test_health_is_not_logged(client, caplog):
    client.get("/health")
    assert request_logs(caplog) == []


def test_json_formatter_emits_fields_as_json():
    record = logging.LogRecord("app", logging.INFO, __file__, 1, "request", None, None)
    record.fields = {"event": "request", "latency_ms": 12.5}
    out = json.loads(JsonFormatter().format(record))
    assert out["latency_ms"] == 12.5 and out["level"] == "INFO" and out["message"] == "request"


def test_api_key_never_logged(client, caplog):
    post_image(client, make_image_bytes(), headers={"X-API-Key": TEST_KEY})
    formatter = JsonFormatter()
    assert all(TEST_KEY not in formatter.format(r) for r in caplog.records)


def test_short_api_key_refused_at_startup():
    with pytest.raises(ValidationError):
        Settings(_env_file=None, api_key="short")


@pytest.mark.integration
def test_real_model_end_to_end(auth):
    pytest.importorskip("torchvision")
    from fastapi.testclient import TestClient

    from app.main import create_app

    s = Settings(_env_file=None, api_key=TEST_KEY, top_k=5)
    with TestClient(create_app(settings=s)) as c:
        resp = post_image(c, make_image_bytes("JPEG", size=(224, 224)), "image/jpeg", auth)
    assert resp.status_code == 200
    body = resp.json()
    assert body["model"].startswith("mobilenet_v3_small")
    assert len(body["predictions"]) == 5
    scores = [p["score"] for p in body["predictions"]]
    assert scores == sorted(scores, reverse=True) and 0 < sum(scores) <= 1.0001
