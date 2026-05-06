"""Sentry init shared between server.py (image pod) and video_server.py.

No-op when SENTRY_DSN_POD is unset, so local runs and dev pods stay quiet.
RUNPOD_POD_ID is auto-injected by RunPod into every pod's environment.
"""
from __future__ import annotations

import logging
import os
from contextlib import contextmanager
from contextvars import ContextVar
from typing import Iterator

import sentry_sdk
from sentry_sdk.integrations.logging import LoggingIntegration


# Cross-stack phase vocabulary (shared with backend + iOS):
#   preparing | drawing | animating | reconnecting | session_ending
# Pods set: preparing, session_ending, drawing, animating.
# reconnecting is iOS/backend only — pod can't tell fresh boot from reconnect.
_phase: ContextVar[str | None] = ContextVar("kiki_phase", default=None)


@contextmanager
def phase(name: str) -> Iterator[None]:
    """Tag every log emitted within this block with `phase=<name>`.

    Propagates through asyncio tasks and `asyncio.to_thread` calls (Python 3.9+
    copies the context into worker threads). Nested blocks override their parent
    and restore on exit.
    """
    token = _phase.set(name)
    try:
        yield
    finally:
        _phase.reset(token)


# Cosmetic: suppress the per-boot transformers warning
# `Using a slow image processor as use_fast is unset and a slow processor
# was saved with this model.` It fires once on every video pod boot from
# transformers' image-processor loader and adds noise to Sentry Logs
# without surfacing actionable signal. Set in module scope so it applies
# regardless of whether SENTRY_DSN_POD is set (the noise exists locally
# too). Lifting back to INFO would re-enable all transformers.utils.logging
# output if needed.
logging.getLogger("transformers.utils.logging").setLevel(logging.ERROR)


def init(pod_kind: str) -> None:
    dsn = os.environ.get("SENTRY_DSN_POD")
    if not dsn:
        return

    pod_id = os.environ.get("RUNPOD_POD_ID")
    # KIKI_USER_ID / KIKI_STREAM_ID are set by the orchestrator's BOOT_ENV
    # for each freshly-provisioned pod (see backend `bootEnvFor`). Constant
    # for the pod's lifetime — pods are 1:1 with users (idle-reaped after
    # 30 min). When a user reconnects within the same pod's lifetime they
    # may receive a new stream_id on iOS; the pod-side stream_id reflects
    # the BOOT_ENV value, i.e. the *initial* connection. Cross-reference by
    # user_id + timestamp if you need to discriminate. Empty string falls
    # back to None so we don't tag empty values.
    user_id = os.environ.get("KIKI_USER_ID") or None
    stream_id = os.environ.get("KIKI_STREAM_ID") or None

    # Scope tags don't propagate to Logs-product entries — only to errors/spans.
    # Inject pod_kind / pod_id / user_id / stream_id / phase as log attributes
    # via before_send_log so they're queryable in the Sentry UI Logs explorer
    # (e.g. `pod_kind:image`, `phase:preparing`, `user_id:<X>`).
    def before_send_log(log, _hint):
        log["attributes"]["pod_kind"] = pod_kind
        if pod_id:
            log["attributes"]["pod_id"] = pod_id
        if user_id:
            log["attributes"]["user_id"] = user_id
        if stream_id:
            log["attributes"]["stream_id"] = stream_id
        active_phase = _phase.get()
        if active_phase is not None:
            log["attributes"]["phase"] = active_phase
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
    # set_user attaches user.id to errors/spans (the Errors product covers it
    # via scope; the Logs product gets it via before_send_log above).
    if user_id:
        sentry_sdk.set_user({"id": user_id})
    if stream_id:
        sentry_sdk.set_tag("stream_id", stream_id)
