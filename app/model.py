"""Pretrained MobileNetV3-Small (ImageNet-1k) wrapped behind a small interface.

Weights are downloaded at image build time into $TORCH_HOME, so the container needs no internet
access at runtime. torchvision verifies the checkpoint's SHA-256 prefix when it loads it.
"""

from dataclasses import dataclass
from typing import Protocol

from PIL import Image


@dataclass(frozen=True)
class Prediction:
    label: str
    score: float


class Classifier(Protocol):
    name: str

    def predict(self, image: Image.Image, top_k: int) -> list[Prediction]: ...


class TorchClassifier:
    name = "mobilenet_v3_small/IMAGENET1K_V1"

    def __init__(self, torch_threads: int = 1) -> None:
        # Imported here so unit tests that use a fake classifier never import torch.
        import torch
        from torchvision.models import MobileNet_V3_Small_Weights, mobilenet_v3_small

        torch.set_num_threads(torch_threads)
        weights = MobileNet_V3_Small_Weights.IMAGENET1K_V1
        self._torch = torch
        self._model = mobilenet_v3_small(weights=weights).eval()
        self._preprocess = weights.transforms()
        self._categories: list[str] = weights.meta["categories"]

    def predict(self, image: Image.Image, top_k: int) -> list[Prediction]:
        batch = self._preprocess(image.convert("RGB")).unsqueeze(0)
        with self._torch.inference_mode():
            probs = self._model(batch).softmax(dim=1)[0]
        scores, indices = probs.topk(top_k)
        return [
            Prediction(label=self._categories[i], score=round(s, 6))
            for s, i in zip(scores.tolist(), indices.tolist(), strict=True)
        ]
