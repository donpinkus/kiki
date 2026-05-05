"""Sentry init shared between server.py (image pod) and video_server.py.

No-op when SENTRY_DSN_POD is unset, so local runs and dev pods stay quiet.
RUNPOD_POD_ID is auto-injected by RunPod into every pod's environment.
"""
from __future__ import annotations

import logging
import os

import sentry_sdk
from sentry_sdk.integrations.logging import LoggingIntegration


def init(pod_kind: str) -> None:
    dsn = os.environ.get("SENTRY_DSN_POD")
    if not dsn:
        return

    pod_id = os.environ.get("RUNPOD_POD_ID")

    # Scope tags don't propagate to Logs-product entries — only to errors/spans.
    # Inject pod_kind / pod_id as log attributes via before_send_log so they're
    # queryable in the Sentry UI Logs explorer (e.g. `pod_kind:image`).
    def before_send_log(log, _hint):
        log["attributes"]["pod_kind"] = pod_kind
        if pod_id:
            log["attributes"]["pod_id"] = pod_id
        return log

    sentry_sdk.init(
        dsn=dsn,
        enable_logs=True,
        traces_sample_rate=1.0,
        profiles_sample_rate=1.0,
        send_default_pii=True,
        attach_stacktrace=True,
        environment=os.environ.get("SENTRY_ENVIRONMENT", "production"),
        integrations=[
            LoggingIntegration(
                level=logging.DEBUG,
                event_level=logging.ERROR,
                sentry_logs_level=logging.DEBUG,
            ),
        ],
        # before_send_log lives under _experiments in sentry-sdk 2.59.x; will
        # graduate to a top-level option in a future release.
        _experiments={"before_send_log": before_send_log},
    )
    sentry_sdk.set_tag("pod_kind", pod_kind)
    if pod_id:
        sentry_sdk.set_tag("pod_id", pod_id)
