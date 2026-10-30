import asyncio
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import patch

from lg_tv_remote.wake import configure, macs_from_tv, magic_packet, normalize_mac, read_config, send_magic, wake_and_confirm


class WakeTests(unittest.IsolatedAsyncioTestCase):
    def test_tv_network_response_retains_both_interfaces_without_printing_them(self):
        self.assertEqual(macs_from_tv({"wifiInfo": {"macAddress": "02:11:22:33:44:55"},
                                      "wiredInfo": {"macAddress": "02:11:22:33:44:56"}}),
                         ["02:11:22:33:44:55", "02:11:22:33:44:56"])
        with self.assertRaises(ValueError):
            macs_from_tv({"wifiInfo": {"macAddress": "00:00:00:00:00:00"}})

    def test_packet_and_actual_udp_delivery(self):
        mac = "02:11:22:33:44:55"
        expected = b"\xff" * 6 + bytes.fromhex("021122334455") * 16
        self.assertEqual(magic_packet(mac), expected)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as receiver:
            receiver.bind(("127.0.0.1", 0))
            receiver.settimeout(1)
            send_magic(mac, "127.0.0.1", receiver.getsockname()[1])
            self.assertEqual(receiver.recvfrom(1024)[0], expected)

    def test_private_setup_and_invalid_mac_rejection(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "private" / "wake.json"
            configure("192.0.2.10", "02-11-22-33-44-55", "192.0.2.255", path)
            self.assertEqual(read_config(path)["192.0.2.10"]["mac"], "02:11:22:33:44:55")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        for invalid in ("00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff", "01:11:22:33:44:55", "not-a-mac"):
            with self.assertRaises(ValueError):
                normalize_mac(invalid)

    async def test_packet_sent_is_not_reported_as_power_on(self):
        async def offline():
            return False

        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "wake.json"
            configure("192.0.2.10", "02:11:22:33:44:55", "192.0.2.255", path)
            with patch("lg_tv_remote.wake.send_magic") as send:
                with self.assertRaisesRegex(TimeoutError, "power-on not confirmed"):
                    await wake_and_confirm("192.0.2.10", offline, path, timeout=0.01)
                send.assert_called_once_with("02:11:22:33:44:55", "192.0.2.255")

    async def test_power_on_requires_confirmation_and_saved_setup(self):
        async def online():
            return True

        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "wake.json"
            with self.assertRaisesRegex(ValueError, "Set Up Power On"):
                await wake_and_confirm("192.0.2.10", online, path)
            configure("192.0.2.10", "02:11:22:33:44:55", "192.0.2.255", path)
            with patch("lg_tv_remote.wake.send_magic"):
                self.assertIn("confirmed", await wake_and_confirm("192.0.2.10", online, path))
