"""Shared deploy-version helper for both image and video pods."""

from __future__ import annotations

import json
import logging

logger = logging.getLogger(__name__)


def load_app_version() -> dict[str, str | bool]:
    """Read /workspace/app/.version.json — written by sync-flux-app.ts at deploy
    time. Returns a flat dict that gets spread into /health so telemetry sees
    per-DC version skew on every cold start. Empty dict on missing/unreadable
    file (dev environments, manual pod boots)."""
    path = "/workspace/app/.version.json"
    try:
        with open(path, "r") as f:
            data = json.load(f)
        return {f"app_{k}": v for k, v in data.items() if isinstance(v, (str, int, float, bool))}
    except (OSError, json.JSONDecodeError) as e:
        logger.info(
            f"No app version file at {path} ({type(e).__name__}); reporting empty",
            extra={"path": path, "error_type": type(e).__name__},
        )
        return {}
