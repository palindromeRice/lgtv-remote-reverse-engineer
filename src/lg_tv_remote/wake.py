"""Local Wake-on-LAN setup and confirmed power-on. No TV identifiers in builds."""

import asyncio
import ipaddress
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile


DATA_DIR = Path(os.environ.get("LGTV_DATA_DIR", Path.home() / "Library" / "Application Support" / "lg-tv-remote"))
CONFIG = DATA_DIR / "wake.json"


def normalize_mac(value: str) -> str:
    value = value.strip()
    if re.fullmatch(r"[0-9a-fA-F]{12}", value):
        parts = [value[i:i + 2] for i in range(0, 12, 2)]
    else:
        parts = re.split("[:-]", value)
    if len(parts) != 6 or any(not re.fullmatch(r"[0-9a-fA-F]{1,2}", p) for p in parts):
        raise ValueError("Enter the TV network MAC address as six hexadecimal pairs")
    raw = bytes(int(p, 16) for p in parts)
    if raw == bytes(6) or raw[0] & 1:
        raise ValueError("Use the TV's unicast Wi-Fi or Ethernet MAC address")
    return ":".join(f"{octet:02x}" for octet in raw)


def magic_packet(mac: str) -> bytes:
    return b"\xff" * 6 + bytes.fromhex(normalize_mac(mac).replace(":", "")) * 16


def macs_from_tv(info: dict) -> list[str]:
    addresses = []
    for field in ("wifiInfo", "wiredInfo"):
        network = info.get(field)
        if not isinstance(network, dict):
            continue
        value = network.get("macAddress")
        if isinstance(value, str) and value:
            try:
                addresses.append(normalize_mac(value))
            except ValueError:
                pass
    if not addresses:
        raise ValueError("TV did not supply a usable network MAC address")
    return list(dict.fromkeys(addresses))


def read_config(path: Path = CONFIG) -> dict:
    if not path.exists():
        return {}
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise ValueError("Wake configuration is invalid; run Set Up Power On again")
    return data


def local_broadcast(host: str) -> str:
    route = subprocess.run(["/sbin/route", "-n", "get", host], capture_output=True, text=True, timeout=3)
    interface = re.search(r"interface:\s+([a-zA-Z0-9]+)", route.stdout)
    if interface:
        info = subprocess.run(["/sbin/ifconfig", interface[1]], capture_output=True, text=True, timeout=3)
        address = re.search(r"inet (\S+) netmask (0x[0-9a-f]+)", info.stdout)
        if address:
            prefix = int(address[2], 16).bit_count()
            network = ipaddress.IPv4Network(f"{address[1]}/{prefix}", strict=False)
            if ipaddress.IPv4Address(host) in network:
                return str(network.broadcast_address)
    return "255.255.255.255"


def configure(host: str, mac: str | None = None, broadcast: str | None = None, path: Path = CONFIG, *, alternate_macs=()) -> str:
    host = str(ipaddress.IPv4Address(host))
    if mac is None:
        # Populate only this selected TV's neighbor entry; never scan other devices.
        try:
            with socket.create_connection((host, 3001), timeout=2):
                pass
        except OSError:
            pass
        neighbor = subprocess.run(["/usr/sbin/arp", "-n", host], capture_output=True, text=True, timeout=3)
        match = re.search(r" at ([0-9a-fA-F:]+) ", neighbor.stdout)
        if not match:
            raise ValueError("TV network address unavailable. Turn the TV on and retry, or choose Set Wake MAC manually.")
        mac = match[1]
    record = {"mac": normalize_mac(mac), "broadcast": str(ipaddress.IPv4Address(broadcast or local_broadcast(host)))}
    record["alternate_macs"] = list(dict.fromkeys(normalize_mac(value) for value in alternate_macs))
    data = read_config(path)
    data[host] = record
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.parent.chmod(0o700)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as output:
            temporary = output.name
            json.dump(data, output)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)
    return "Power-on setup saved privately. Enable TV On With Mobile / Turn on via Wi-Fi on the TV."


def send_magic(mac: str, broadcast: str, port: int = 9):
    packet = magic_packet(mac)
    destination = str(ipaddress.IPv4Address(broadcast))
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender:
        sender.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sender.sendto(packet, (destination, port))


async def wake_and_confirm(host, confirm, path: Path = CONFIG, timeout: float = 35):
    host = str(ipaddress.IPv4Address(host))
    record = read_config(path).get(host)
    if not isinstance(record, dict) or not record.get("mac"):
        raise ValueError("Run Set Up Power On while the TV is on first. Its network MAC is needed to wake it from standby.")
    mac = normalize_mac(record["mac"])
    addresses = list(dict.fromkeys([mac] + [normalize_mac(value) for value in record.get("alternate_macs", [])]))
    broadcast = str(ipaddress.IPv4Address(record.get("broadcast", "255.255.255.255")))
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    next_packet = 0
    while loop.time() < deadline:
        if loop.time() >= next_packet:
            for address in addresses:
                send_magic(address, broadcast)
            next_packet = loop.time() + 5
        try:
            if await asyncio.wait_for(confirm(), min(3, max(0.001, deadline - loop.time()))):
                return "TV is on; confirmed by its authenticated local response"
        except (OSError, TimeoutError):
            pass
        await asyncio.sleep(min(0.5, max(0, deadline - loop.time())))
    raise TimeoutError("Wake packets sent; power-on not confirmed. Check TV On With Mobile / Turn on via Wi-Fi and the saved network MAC.")
