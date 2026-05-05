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
    )
    sentry_sdk.set_tag("pod_kind", pod_kind)
    pod_id = os.environ.get("RUNPOD_POD_ID")
    if pod_id:
        sentry_sdk.set_tag("pod_id", pod_id)
