def test_health_ok(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok", "model_loaded": True}


def test_health_needs_no_api_key(client):
    # The ALB health check sends no credentials.
    assert client.get("/health").status_code == 200


def test_request_id_header_is_returned(client):
    resp = client.get("/health", headers={"x-request-id": "abc123"})
    assert resp.headers["x-request-id"] == "abc123"
