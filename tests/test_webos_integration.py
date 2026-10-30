"""Exercise the pinned webOS client against a small local protocol fixture."""

import asyncio
import json
from pathlib import Path
import tempfile
import unittest

from bscpylgtv import WebOsClient
import websockets

from lg_tv_remote.cli import execute
from lg_tv_remote.pointer import pointer_session


class WebOsIntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def test_pointer_uses_one_input_socket_for_move_click_and_scroll(self):
        messages, requests, replies = [], [], []
        received = asyncio.Event()

        async def pointer(socket):
            async for wire in socket:
                messages.append(wire)
                if len(messages) == 4:
                    received.set()

        async with websockets.serve(pointer, "127.0.0.1", 0) as pointer_server:
            pointer_port = pointer_server.sockets[0].getsockname()[1]

            async def tv(socket):
                async for wire in socket:
                    message = json.loads(wire)
                    if message["type"] == "register":
                        await socket.send(json.dumps({"type": "response", "payload": {"pairingType": "PROMPT"}}))
                        await socket.send(json.dumps({"type": "registered", "payload": {"client-key": "fixture-only"}}))
                    else:
                        requests.append(message["uri"])
                        await socket.send(json.dumps({"id": message["id"], "type": "response", "payload": {
                            "returnValue": True, "socketPath": f"ws://127.0.0.1:{pointer_port}",
                        }}))

            async with websockets.serve(tv, "127.0.0.1", 0) as server:
                with tempfile.TemporaryDirectory() as directory:
                    client = await WebOsClient.create(ip="127.0.0.1", states=[], ping_interval=None,
                        without_ssl=True, key_file_path=str(Path(directory) / "keys.sqlite"))
                    client.port = server.sockets[0].getsockname()[1]
                    lines = iter(['{"type":"move","dx":10,"dy":-6}', '{"type":"click"}',
                                  '{"type":"scroll","dy":2}', ''])

                    async def reader():
                        return next(lines)

                    await asyncio.wait_for(client.connect(), 3)
                    try:
                        await pointer_session(client, reader, replies.append)
                        await asyncio.wait_for(received.wait(), 3)
                    finally:
                        await client.disconnect()

        self.assertEqual(requests, ["ssap://com.webos.service.networkinput/getPointerInputSocket"])
        self.assertEqual(messages, ["type:move\ndx:0\ndy:0\ndown:0\n\n",
            "type:move\ndx:10\ndy:-6\ndown:0\n\n", "type:click\n\n", "type:scroll\ndx:0\ndy:2\n\n"])
        self.assertEqual(replies, [{"ready": True}] + [{"sent": True}] * 3)

    async def test_pair_and_volume_request_over_websocket(self):
        requests = []

        async def tv(socket):
            async for wire in socket:
                message = json.loads(wire)
                requests.append(message.get("uri", message["type"]))
                if message["type"] == "register":
                    await socket.send(json.dumps({"type": "response", "payload": {"pairingType": "PROMPT"}}))
                    await socket.send(json.dumps({"type": "registered", "payload": {"client-key": "fixture-only"}}))
                else:
                    payload = {"returnValue": True}
                    await socket.send(json.dumps({
                        "id": message["id"],
                        "type": "response",
                        "payload": payload,
                    }))

        async with websockets.serve(tv, "127.0.0.1", 0) as server:
            port = server.sockets[0].getsockname()[1]
            with tempfile.TemporaryDirectory() as directory:
                client = await WebOsClient.create(
                    ip="127.0.0.1",
                    key_file_path=str(Path(directory) / "keys.sqlite"),
                    states=[],
                    ping_interval=None,
                    without_ssl=True,
                )
                client.port = port
                await asyncio.wait_for(client.connect(), timeout=3)
                try:
                    self.assertEqual(await execute(client, "pair", None), "TV authorized this client")
                    self.assertEqual(await execute(client, "volume-up", None), "TV accepted volume-up")
                finally:
                    await client.disconnect()

        self.assertEqual(requests, [
            "register",
            "ssap://system/getSystemInfo",
            "ssap://audio/volumeUp",
        ])
