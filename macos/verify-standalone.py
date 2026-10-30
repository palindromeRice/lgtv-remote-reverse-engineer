"""Verify a copied bundle while denying access to the source and external Python.

Run with the build environment: uv run --group build python macos/verify-standalone.py APP
Uses only loopback TV fixtures and a temporary private data directory.
"""

import asyncio
import json
import os
from pathlib import Path
import plistlib
import ssl
import subprocess
import sys
import tempfile

import websockets


def audit_libraries(app):
    checked = set()
    for path in app.rglob("*"):
        if not path.is_file() or path.resolve() in checked:
            continue
        checked.add(path.resolve())
        kind = subprocess.check_output(["/usr/bin/file", "-b", str(path)], text=True)
        if "Mach-O" not in kind:
            continue
        if "arm64" not in kind:
            raise RuntimeError(f"Non-arm64 Mach-O in app: {path.name}")
        linked = subprocess.check_output(["/usr/bin/otool", "-L", str(path)], text=True)
        for line in linked.splitlines()[1:]:
            library = line.strip().split(" (", 1)[0]
            if not library.startswith(("@", "/usr/lib/", "/System/Library/")):
                raise RuntimeError(f"External library dependency: {library}")


async def verify(original):
    source = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="LG TV standalone check ") as scratch:
        root = Path(scratch)
        app = root / "LG TV Remote.app"
        subprocess.run(["/usr/bin/ditto", str(original), str(app)], check=True)
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        audit_libraries(app)
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        assert "LGTVCLIPath" not in info
        profile = '(version 1)(allow default)'
        for denied in (source, Path(sys.base_prefix).resolve()):
            profile += f'(deny file-read* (subpath {json.dumps(str(denied))}))'
        env = {key: value for key, value in os.environ.items()
               if key not in ("PYTHONPATH", "PYTHONHOME", "VIRTUAL_ENV", "LGTV_CLI_PATH")}
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["LGTV_DATA_DIR"] = str(root / "private-tv-fixture")
        helper = app / "Contents/Resources/Backend/lg-tv/lg-tv"

        async def command(*args, stdin=None):
            child = await asyncio.create_subprocess_exec(
                "/usr/bin/sandbox-exec", "-p", profile, str(helper), *args,
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE, env=env, cwd=str(root))
            try:
                out, err = await asyncio.wait_for(child.communicate(stdin), 12)
            except BaseException:
                if child.returncode is None:
                    child.kill()
                    await child.wait()
                raise
            if child.returncode:
                raise RuntimeError(f"Frozen {args[0]} failed: {err.decode()}")
            return out.decode().strip()

        assert "power-on" in await command("--help")
        subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", str(root / "fixture.key"), "-out", str(root / "fixture.crt"),
                        "-days", "1", "-subj", "/CN=127.0.0.1"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(root / "fixture.crt", root / "fixture.key")
        pointer_messages = []

        async def pointer(socket):
            async for wire in socket:
                pointer_messages.append(wire)

        async with websockets.serve(pointer, "127.0.0.1", 0, ssl=tls) as input_server:
            port = input_server.sockets[0].getsockname()[1]

            async def tv(socket):
                async for wire in socket:
                    request = json.loads(wire)
                    if request["type"] == "register":
                        await socket.send(json.dumps({"type": "response", "payload": {"pairingType": "PROMPT"}}))
                        await socket.send(json.dumps({"type": "registered", "payload": {"client-key": "fixture-only"}}))
                    else:
                        await socket.send(json.dumps({"id": request["id"], "type": "response", "payload": {
                            "returnValue": True, "state": "Active", "socketPath": f"wss://127.0.0.1:{port}",
                            "wifiInfo": {"macAddress": "02:11:22:33:44:55"},
                            "wiredInfo": {"macAddress": "02:11:22:33:44:56"},
                        }}))

            async with websockets.serve(tv, "127.0.0.1", 3001, ssl=tls):
                assert "authorized" in await command("pair", "127.0.0.1")
                assert "accepted" in await command("volume-up", "127.0.0.1")
                assert "saved privately" in await command("wake-setup", "127.0.0.1", "--broadcast", "127.0.0.1")
                assert "already on" in await command("power-on", "127.0.0.1")
                stream = b'{"type":"move","dx":2,"dy":-2}\n{"type":"click"}\n{"type":"scroll","dy":1}\n'
                output = await command("pointer", "127.0.0.1", stdin=stream)
                replies = [json.loads(line) for line in output.splitlines() if line]
                assert replies == [{"ready": True}] + [{"sent": True}] * 3
                assert len(pointer_messages) == 4

        print("Standalone checks passed: copied path with spaces, source/external Python denied,")
        print("arm64 library audit, signature, TLS pairing/control, private wake setup, power-state confirmation, pointer stream.")


if __name__ == "__main__":
    asyncio.run(verify(Path(sys.argv[1]).resolve()))
