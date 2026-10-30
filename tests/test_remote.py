import asyncio
from contextlib import redirect_stderr
from io import StringIO
import unittest
from unittest.mock import patch
from bscpylgtv.exceptions import PyLGTVCmdError

from lg_tv_remote.cli import bounded_control, execute, parser
from lg_tv_remote.discovery import parse_ssdp_response


SERVICE = "urn:lge-com:service:webos-second-screen:1"


class DiscoveryTests(unittest.TestCase):
    def test_accepts_matching_ssdp_response_and_rejects_unrelated_devices(self):
        valid = (
            "HTTP/1.1 200 OK\r\n"
            f"ST: {SERVICE}\r\n"
            "LOCATION: http://192.0.2.10:3000/description.xml\r\n\r\n"
        ).encode()
        unrelated = b"HTTP/1.1 200 OK\r\nST: urn:other:service:1\r\n\r\n"
        assert parse_ssdp_response(valid, "192.0.2.10") == "192.0.2.10"
        assert parse_ssdp_response(unrelated, "192.0.2.11") is None
        assert parse_ssdp_response(b"garbage", "192.0.2.12") is None


class CommandTests(unittest.TestCase):
    def test_wake_screen_checks_response_and_reads_back_power_state(self):
        class FakeClient:
            def __init__(self):
                self.states = iter(["Screen Saver", "Active"])

            async def turn_screen_on(self):
                return {"returnValue": True}

            async def get_power_state(self):
                return {"state": next(self.states)}

        assert asyncio.run(execute(FakeClient(), "wake-screen", None)) == "Screen is active; confirmed by TV"

        class RefusingClient(FakeClient):
            async def turn_screen_on(self):
                return {"returnValue": False}

        with self.assertRaisesRegex(RuntimeError, "did not confirm"):
            asyncio.run(execute(RefusingClient(), "wake-screen", None))

        class ActiveClient:
            async def get_power_state(self):
                return {"state": "Active"}

        assert asyncio.run(execute(ActiveClient(), "wake-screen", None)) == "Screen is already active; confirmed by TV"

        class ConcurrentWakeClient(FakeClient):
            async def turn_screen_on(self):
                raise PyLGTVCmdError("Already active")

        assert asyncio.run(execute(ConcurrentWakeClient(), "wake-screen", None)) == "Screen is already active; confirmed by TV"

    def test_operation_timeout_cancels_the_control_task(self):
        cancelled = []

        async def stalled(*args):
            try:
                await asyncio.Event().wait()
            finally:
                cancelled.append(True)

        with patch("lg_tv_remote.cli.control", stalled):
            with self.assertRaisesRegex(TimeoutError, "check power and Wi-Fi"):
                asyncio.run(bounded_control("192.0.2.1", "status", None, timeout=0.001))
        assert cancelled == [True]

    def test_release_rejects_removed_search_and_text_commands(self):
        for command in ("youtube-search", "text", "text-enter", "keyboard-status"):
            with self.subTest(command=command), redirect_stderr(StringIO()):
                with self.assertRaises(SystemExit):
                    parser().parse_args([command, "192.0.2.1"] + (["query"] if command in ("youtube-search", "text") else []))
        with redirect_stderr(StringIO()):
            with self.assertRaises(SystemExit):
                parser().parse_args(["button", "192.0.2.1", "SEARCH"])

    def test_parser_requires_target_for_control_and_accepts_discover(self):
        assert parser().parse_args(["discover"]).command == "discover"
        with redirect_stderr(StringIO()):
            with self.assertRaises(SystemExit):
                parser().parse_args(["volume-up"])

    def test_dispatch_uses_authenticated_client_and_reports_tv_response(self):
        class FakeClient:
            def __init__(self):
                self.calls = []

            async def volume_up(self):
                self.calls.append("volume_up")
                return {"returnValue": True}

        client = FakeClient()
        result = asyncio.run(execute(client, "volume-up", None))
        assert client.calls == ["volume_up"]
        assert result == "TV accepted volume-up"

    def test_pair_requires_a_confirmed_tv_request(self):
        class FakeClient:
            def __init__(self):
                self.called = False

            async def get_system_info(self):
                self.called = True
                return {"returnValue": True}

        client = FakeClient()
        assert asyncio.run(execute(client, "pair", None)) == "TV authorized this client"
        assert client.called

    def test_inputs_and_playback_use_tv_methods(self):
        class FakeClient:
            async def get_inputs(self):
                return [{"id": "HDMI_1", "label": "Game console"}]

            async def set_input(self, input_id):
                assert input_id == "HDMI_1"
                return {"returnValue": True}

            async def pause(self):
                return {"returnValue": True}

        client = FakeClient()
        assert asyncio.run(execute(client, "inputs", None)) == "HDMI_1\tGame console"
        assert asyncio.run(execute(client, "set-input", "HDMI_1")) == "TV accepted set-input"
        assert asyncio.run(execute(client, "pause", None)) == "TV accepted pause"


if __name__ == "__main__":
    unittest.main()
