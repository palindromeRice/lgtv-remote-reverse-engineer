"""Find webOS TVs advertised on the local network via SSDP."""

import socket
import time


SERVICE = "urn:lge-com:service:webos-second-screen:1"
MULTICAST = ("239.255.255.250", 1900)


def parse_ssdp_response(data: bytes, address: str) -> str | None:
    lines = data.decode("ascii", errors="ignore").splitlines()
    if not lines or not lines[0].startswith("HTTP/1.1 200"):
        return None
    headers = {}
    for line in lines[1:]:
        name, separator, value = line.partition(":")
        if separator:
            headers[name.lower()] = value.strip().lower()
    if SERVICE in (headers.get("st", ""), headers.get("nt", "")) or SERVICE in headers.get("usn", ""):
        return address
    return None


def discover(timeout: float = 3.0) -> list[str]:
    request = (
        "M-SEARCH * HTTP/1.1\r\n"
        "HOST: 239.255.255.250:1900\r\n"
        'MAN: "ssdp:discover"\r\n'
        "MX: 2\r\n"
        f"ST: {SERVICE}\r\n\r\n"
    ).encode("ascii")
    found = set()
    deadline = time.monotonic() + timeout
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("", 0))
        sock.sendto(request, MULTICAST)
        while (remaining := deadline - time.monotonic()) > 0:
            sock.settimeout(remaining)
            try:
                data, sender = sock.recvfrom(8192)
            except socket.timeout:
                break
            if address := parse_ssdp_response(data, sender[0]):
                found.add(address)
    return sorted(found)
