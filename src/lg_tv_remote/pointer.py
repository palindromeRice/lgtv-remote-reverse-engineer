"""Persistent, bounded pointer input over the paired TV's input socket."""

import asyncio
import json
import math
import sys


async def pointer_event(client, event):
    if not isinstance(event, dict) or event.get("type") not in ("move", "click", "scroll"):
        raise ValueError("Expected move, click, or scroll")
    kind = event["type"]
    if kind == "click":
        await client.click()
    else:
        values = [event.get(axis, 0) for axis in ("dx", "dy")]
        if any(type(v) not in (int, float) or not math.isfinite(v) or abs(v) > 1000 for v in values):
            raise ValueError("Pointer deltas must be finite numbers between -1000 and 1000")
        await getattr(client, kind)(*values)
    # The dependency suppresses some input socket errors; check it explicitly.
    connection = client.input_connection
    if connection is None or connection.state.name != "OPEN":
        raise ConnectionError("TV pointer disconnected; select Trackpad again to reconnect")


async def pointer_session(client, reader=None, emit=None):
    if reader is None:
        async def reader():
            return await asyncio.to_thread(sys.stdin.readline, 4097)
    if emit is None:
        def emit(value):
            print(json.dumps(value), flush=True)

    await asyncio.wait_for(pointer_event(client, {"type": "move", "dx": 0, "dy": 0}), 5)
    emit({"ready": True})
    while line := await reader():
        if len(line) > 4096:
            raise ValueError("Pointer event too long")
        await asyncio.wait_for(pointer_event(client, json.loads(line)), 5)
        emit({"sent": True})
