"""All runtime configuration comes from environment variables (or a local .env file).

In AWS, API_KEY is injected by ECS from Secrets Manager; it is never baked into the image.
"""

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    api_key: SecretStr = Field(min_length=16)
    log_level: str = "INFO"
    max_upload_bytes: int = Field(default=5 * 1024 * 1024, gt=0)
    max_image_pixels: int = Field(default=40_000_000, gt=0)  # decompression-bomb guard
    top_k: int = Field(default=5, ge=1, le=20)
    # Fargate reports 2 CPUs for a 0.5 vCPU task; more torch threads than real cores hurts latency.
    torch_threads: int = Field(default=1, ge=1)
