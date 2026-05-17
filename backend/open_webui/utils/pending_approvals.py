"""
Server-side pending tool approval tracking.

Survives WebSocket disconnects so that a pending approval can be
re-presented when the client reconnects. Also adds a configurable
timeout to auto-deny stale approvals.
"""

import asyncio
import os
import time
import logging

from open_webui.env import SRC_LOG_LEVELS

log = logging.getLogger(__name__)
log.setLevel(SRC_LOG_LEVELS.get("APPROVAL", "INFO"))

APPROVAL_TIMEOUT = int(os.getenv("TOOL_APPROVAL_TIMEOUT", "300"))

PENDING_APPROVALS: dict = {}


def add_pending_approval(call_id: str, data: dict) -> asyncio.Event:
    event = asyncio.Event()
    PENDING_APPROVALS[call_id] = {
        "name": data.get("name"),
        "arguments": data.get("arguments"),
        "user_id": str(data.get("user_id", "")),
        "chat_id": data.get("chat_id"),
        "event": event,
        "result": {},
        "created_at": time.time(),
    }
    log.info(f"Pending approval registered: {call_id}")
    return event


def resolve_approval(call_id: str, approved: bool) -> bool:
    pending = PENDING_APPROVALS.get(call_id)
    if pending:
        pending["result"]["approved"] = approved
        pending["event"].set()
        log.info(f"Approval resolved: {call_id} approved={approved}")
        return True
    log.warning(f"Attempt to resolve unknown approval: {call_id}")
    return False


async def wait_for_approval(call_id: str, timeout: int = None) -> dict:
    pending = PENDING_APPROVALS.get(call_id)
    if not pending:
        return {"approved": False, "error": "No pending approval found"}

    timeout = timeout or APPROVAL_TIMEOUT
    try:
        await asyncio.wait_for(pending["event"].wait(), timeout=timeout)
    except asyncio.TimeoutError:
        pending["result"]["approved"] = False
        pending["result"]["error"] = "Approval timed out"
        log.info(f"Approval timed out: {call_id}")

    return pending.get("result", {"approved": False})


def get_pending_for_user(user_id: str) -> dict:
    return {
        call_id: {
            "name": p["name"],
            "arguments": p["arguments"],
            "chat_id": p.get("chat_id"),
        }
        for call_id, p in PENDING_APPROVALS.items()
        if str(p.get("user_id")) == str(user_id)
    }


def remove_pending_approval(call_id: str):
    PENDING_APPROVALS.pop(call_id, None)
    log.info(f"Pending approval removed: {call_id}")


def cleanup_expired():
    now = time.time()
    expired = []
    for call_id, pending in list(PENDING_APPROVALS.items()):
        if now - pending["created_at"] > APPROVAL_TIMEOUT:
            pending["event"].set()
            expired.append(call_id)
    for call_id in expired:
        PENDING_APPROVALS.pop(call_id, None)
        log.info(f"Expired approval cleaned up: {call_id}")
