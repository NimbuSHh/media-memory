#!/usr/bin/env python3
"""JSON-lines MLX worker for Media Memory.

Only paths below the configured oMLX model root and Media Memory work root are
accepted. The two distinct direct-loaded models may remain resident during one
build session, while all inference requests stay serialized by the Swift lane.
"""

from __future__ import annotations

import contextlib
import base64
import gc
import json
import mimetypes
import os
from pathlib import Path
import sys
from typing import Any


PROTOCOL_STDOUT = sys.stdout
MODEL_ROOT = Path(os.environ["MEDIA_MEMORY_MODEL_ROOT"]).expanduser().resolve()
WORK_ROOT = Path(os.environ["MEDIA_MEMORY_WORK_ROOT"]).expanduser().resolve()


def emit(payload: dict[str, Any]) -> None:
    PROTOCOL_STDOUT.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
    PROTOCOL_STDOUT.flush()


def require_below(path_value: str, root: Path, kind: str) -> Path:
    path = Path(path_value).expanduser().resolve()
    try:
        path.relative_to(root)
    except ValueError as exc:
        raise ValueError(f"{kind} path is outside its allowed root") from exc
    if not path.exists():
        raise FileNotFoundError(f"{kind} path does not exist")
    return path


class Worker:
    def __init__(self) -> None:
        self.aligner = None
        self.embedding_model = None
        self.embedding_processor = None

    def unload(self) -> None:
        self.aligner = None
        self.embedding_model = None
        self.embedding_processor = None
        gc.collect()
        try:
            import mlx.core as mx

            mx.synchronize()
            mx.clear_cache()
        except Exception:
            pass

    def activate_aligner(self, model_path: Path) -> None:
        if self.aligner is not None:
            return
        from mlx_audio.stt.utils import load

        self.aligner = load(str(model_path), lazy=False)

    def activate_embedding(self, model_path: Path) -> None:
        if self.embedding_model is not None:
            return
        from omlx.models.mlx_embeddings_compat import (
            patch_qwen3_vl_processor_for_torch_free_image_loading,
        )

        patch_qwen3_vl_processor_for_torch_free_image_loading()
        from mlx_embeddings import load

        self.embedding_model, self.embedding_processor = load(str(model_path), lazy=False)

    @staticmethod
    def image_data_uri(path: Path) -> str:
        mime_type = mimetypes.guess_type(path.name)[0] or "image/jpeg"
        encoded = base64.b64encode(path.read_bytes()).decode("ascii")
        return f"data:{mime_type};base64,{encoded}"

    def align(self, request: dict[str, Any]) -> dict[str, Any]:
        model_path = require_below(request["model_path"], MODEL_ROOT, "model")
        audio_path = require_below(request["audio_path"], WORK_ROOT, "audio")
        text = str(request["text"]).strip()
        if not text:
            return {"items": []}
        language = str(request.get("language") or "English")
        self.activate_aligner(model_path)
        result = self.aligner.generate(
            audio=str(audio_path),
            text=text,
            language=language,
        )
        return {
            "items": [
                {
                    "text": item.text,
                    "start_ms": int(round(item.start_time * 1000)),
                    "end_ms": int(round(item.end_time * 1000)),
                }
                for item in result.items
            ]
        }

    def embed(self, request: dict[str, Any]) -> dict[str, Any]:
        model_path = require_below(request["model_path"], MODEL_ROOT, "model")
        image_paths = [
            require_below(value, WORK_ROOT, "image")
            for value in request.get("image_paths", [])
        ]
        self.activate_embedding(model_path)
        item: dict[str, Any] = {
            "text": str(request.get("text") or ""),
            "instruction": str(
                request.get("instruction")
                or "Represent this video moment for retrieval."
            ),
        }
        if image_paths:
            item["image"] = [self.image_data_uri(path) for path in image_paths]

        import mlx.core as mx
        import numpy as np

        # mlx-embeddings accepts a batch here. Passing the item dictionary
        # directly makes the processor treat dictionary fields as samples.
        output = self.embedding_model.process([item], self.embedding_processor)
        # The model output is bfloat16. Convert it inside MLX before crossing
        # the Python buffer boundary; NumPy cannot consume MLX bfloat16 via
        # PEP 3118 directly.
        output = output.astype(mx.float32)
        mx.eval(output)
        vector = np.array(output.tolist(), dtype=np.float32).reshape(-1)
        norm = float(np.linalg.norm(vector))
        if not np.isfinite(vector).all() or norm <= 0:
            raise ValueError("embedding output is not a finite non-zero vector")
        if abs(norm - 1.0) > 1e-3:
            vector = vector / norm
            norm = float(np.linalg.norm(vector))
        return {"dimension": int(vector.size), "norm": norm, "vector": vector.tolist()}

    def handle(self, request: dict[str, Any]) -> dict[str, Any]:
        operation = request.get("operation")
        if operation == "ping":
            return {"status": "ready"}
        if operation == "unload":
            self.unload()
            return {"status": "unloaded"}
        if operation == "align":
            return self.align(request)
        if operation == "embed":
            return self.embed(request)
        raise ValueError(f"unsupported operation: {operation}")


def main() -> None:
    worker = Worker()
    for line in sys.stdin:
        try:
            request = json.loads(line)
            with contextlib.redirect_stdout(sys.stderr):
                result = worker.handle(request)
            emit({"ok": True, "result": result})
        except Exception as exc:
            emit({"ok": False, "error": f"{type(exc).__name__}: {exc}"})


if __name__ == "__main__":
    main()
