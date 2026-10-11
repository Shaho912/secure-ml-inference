import io

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.config import Settings
from app.main import create_app
from app.model import Prediction

TEST_KEY = "test-key-0123456789abcdef"


class FakeClassifier:
    name = "fake"

    def __init__(self) -> None:
        self.calls = 0

    def predict(self, image: Image.Image, top_k: int) -> list[Prediction]:
        self.calls += 1
        return [Prediction(label=f"class_{i}", score=1.0 / (i + 1)) for i in range(top_k)]


@pytest.fixture
def settings() -> Settings:
    # _env_file=None: tests must not depend on a developer's local .env
    return Settings(_env_file=None, api_key=TEST_KEY, max_upload_bytes=64 * 1024, top_k=3)


@pytest.fixture
def client(settings: Settings):
    app = create_app(settings=settings, load_model=lambda s: FakeClassifier())
    with TestClient(app) as c:  # context manager runs the lifespan (model load)
        yield c


def make_image_bytes(fmt: str = "PNG", size: tuple[int, int] = (64, 64)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", size, color=(200, 30, 30)).save(buf, format=fmt)
    return buf.getvalue()


@pytest.fixture
def auth() -> dict[str, str]:
    return {"X-API-Key": TEST_KEY}
