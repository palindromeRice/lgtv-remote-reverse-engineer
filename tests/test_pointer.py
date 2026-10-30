import asyncio
import json
from types import SimpleNamespace
import unittest

from lg_tv_remote.pointer import pointer_event, pointer_session


class PointerTests(unittest.IsolatedAsyncioTestCase):
    async def test_stream_orders_movement_click_and_scroll_on_one_client(self):
        calls, replies = [], []

        class Client:
            input_connection = SimpleNamespace(state=SimpleNamespace(name="OPEN"))

            async def move(self, dx, dy):
                calls.append(("move", dx, dy))

            async def click(self):
                calls.append(("click",))

            async def scroll(self, dx, dy):
                calls.append(("scroll", dx, dy))

        lines = iter([json.dumps(v) for v in [
            {"type": "move", "dx": 12, "dy": -4}, {"type": "click"},
            {"type": "scroll", "dy": 2},
        ]] + [""])

        async def reader():
            return next(lines)

        await pointer_session(Client(), reader, replies.append)
        self.assertEqual(calls, [("move", 0, 0), ("move", 12, -4), ("click",), ("scroll", 0, 2)])
        self.assertEqual(replies, [{"ready": True}] + [{"sent": True}] * 3)

    async def test_invalid_events_are_rejected_before_dispatch(self):
        for event in [None, {"type": "power"}, {"type": "move", "dx": float("nan")},
                      {"type": "move", "dy": 1001}, {"type": "move", "dx": True}]:
            with self.assertRaises(ValueError):
                await pointer_event(object(), event)

    async def test_dependency_suppressed_socket_failure_is_not_reported_as_sent(self):
        class Client:
            input_connection = None

            async def click(self):
                pass

        with self.assertRaises(ConnectionError):
            await pointer_event(Client(), {"type": "click"})
