import io
import logging
import secrets
import time
import uuid
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, File, Header, HTTPException, Request, UploadFile, status
from fastapi.concurrency import run_in_threadpool
from PIL import Image, UnidentifiedImageError
from pydantic import BaseModel

from app.config import Settings
from app.logging_config import configure_logging
from app.model import Classifier, TorchClassifier

logger = logging.getLogger("app")

ALLOWED_CONTENT_TYPES = {"image/jpeg", "image/png", "image/webp"}
UNLOGGED_PATHS = {"/health"}  # ALB polls every 30s; logging it is noise and CloudWatch cost


class PredictionOut(BaseModel):
    label: str
    score: float


class PredictResponse(BaseModel):
    model: str
    predictions: list[PredictionOut]
    inference_ms: float


class HealthResponse(BaseModel):
    status: str
    model_loaded: bool


def create_app(
    settings: Settings | None = None,
    load_model: Callable[[Settings], Classifier] | None = None,
) -> FastAPI:
    settings = settings or Settings()
    load_model = load_model or (lambda s: TorchClassifier(torch_threads=s.torch_threads))
    configure_logging(settings.log_level)
    Image.MAX_IMAGE_PIXELS = settings.max_image_pixels

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        start = time.perf_counter()
        app.state.classifier = load_model(settings)
        load_ms = round((time.perf_counter() - start) * 1000, 1)
        logger.info("model loaded", extra={"fields": {"event": "startup", "load_ms": load_ms}})
        yield
        app.state.classifier = None

    app = FastAPI(title="secure-ml-inference", version="0.1.0", lifespan=lifespan)
    app.state.settings = settings
    app.state.classifier = None

    @app.middleware("http")
    async def access_log(request: Request, call_next):
        request_id = request.headers.get("x-request-id") or uuid.uuid4().hex
        start = time.perf_counter()
        status_code = 500
        try:
            response = await call_next(request)
            status_code = response.status_code
            response.headers["x-request-id"] = request_id
            return response
        finally:
            if request.url.path not in UNLOGGED_PATHS:
                fields = {
                    "event": "request",
                    "request_id": request_id,
                    "method": request.method,
                    "path": request.url.path,
                    "status": status_code,
                    "latency_ms": round((time.perf_counter() - start) * 1000, 2),
                }
                logger.info("request", extra={"fields": fields})

    def require_api_key(x_api_key: str | None = Header(default=None)) -> None:
        expected = settings.api_key.get_secret_value()
        # compare_digest avoids leaking the key through response-timing differences
        if x_api_key is None or not secrets.compare_digest(x_api_key, expected):
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid or missing API key")

    @app.get("/health", response_model=HealthResponse)
    async def health(request: Request) -> HealthResponse:
        return HealthResponse(status="ok", model_loaded=request.app.state.classifier is not None)

    @app.post("/predict", response_model=PredictResponse, dependencies=[Depends(require_api_key)])
    async def predict(request: Request, file: UploadFile = File(...)) -> PredictResponse:
        if file.content_type not in ALLOWED_CONTENT_TYPES:
            raise HTTPException(
                status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
                f"content type must be one of {sorted(ALLOWED_CONTENT_TYPES)}",
            )
        data = await file.read(settings.max_upload_bytes + 1)
        if len(data) > settings.max_upload_bytes:
            raise HTTPException(status.HTTP_413_CONTENT_TOO_LARGE, "file too large")
        try:
            image = Image.open(io.BytesIO(data))
            image.load()
        except (UnidentifiedImageError, Image.DecompressionBombError, OSError) as exc:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "invalid image") from exc

        classifier: Classifier = request.app.state.classifier
        start = time.perf_counter()
        # Model inference is CPU-bound; keep it off the event loop so /health stays responsive.
        preds = await run_in_threadpool(classifier.predict, image, settings.top_k)
        inference_ms = round((time.perf_counter() - start) * 1000, 2)
        return PredictResponse(
            model=classifier.name,
            predictions=[PredictionOut(label=p.label, score=p.score) for p in preds],
            inference_ms=inference_ms,
        )

    return app


def app_factory() -> FastAPI:
    """Entry point for `uvicorn --factory app.main:app_factory`."""
    return create_app()
