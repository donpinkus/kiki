"""Which fleet bundle is this server running? Read by /health on both servers.

The backend's deploy packs model-servers/ into a content-hashed bundle
(backend/src/modules/lambda/fleetBundle.ts) and each instance's cloud-init
bootstrap writes the bundle's manifest next to this package as
`.manifest.json` (+ `.manifest` = the bare content hash) when it refreshes
the region filesystem. Surfacing it on /health lets the pool's `ready` event
(Insights → Boots) record exactly which code every boot ran.
"""

from __future__ import annotations

import json
import logging
from pathlib import Path

logger = logging.getLogger(__name__)

_PACKAGE_ROOT = Path(__file__).resolve().parents[1]


def load_app_version() -> dict[str, str | int | float | bool]:
    """Flat dict spread into /health: app_manifest (content hash),
    app_git_sha, app_built_at. Empty when the filesystem was populated by
    hand (setup scripts / sync-fs) and no bundle has landed yet."""
    path = _PACKAGE_ROOT / ".manifest.json"
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        bare = _PACKAGE_ROOT / ".manifest"
        try:
            return {"app_manifest": bare.read_text().strip()}
        except OSError:
            return {}
    out: dict[str, str | int | float | bool] = {}
    if isinstance(data.get("sha256"), str):
        out["app_manifest"] = data["sha256"]
    for k in ("git_sha", "built_at"):
        if isinstance(data.get(k), str):
            out[f"app_{k}"] = data[k]
    return out
