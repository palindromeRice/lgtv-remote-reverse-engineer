"""Small command line proof of concept for a user-owned webOS TV."""

import argparse
import asyncio
import os
from pathlib import Path
import sys

from bscpylgtv import WebOsClient
from bscpylgtv.exceptions import PyLGTVCmdError

from .discovery import discover
from .pointer import pointer_session
from .wake import DATA_DIR, configure, macs_from_tv, wake_and_confirm


BUTTONS = ("UP", "DOWN", "LEFT", "RIGHT", "ENTER", "HOME", "BACK", "MENU", "INFO")


def parser() -> argparse.ArgumentParser:
    cli = argparse.ArgumentParser(description="Control your paired LG webOS TV on the local network")
    commands = cli.add_subparsers(dest="command", required=True)
    scan = commands.add_parser("discover", help="Find nearby webOS TVs via SSDP")
    scan.add_argument("--timeout", type=float, default=3.0)
    setup = commands.add_parser("wake-setup", help="Save the selected TV's wake address privately")
    setup.add_argument("host")
    setup.add_argument("mac", nargs="?", help="TV Wi-Fi/Ethernet MAC; learn from its neighbor entry if omitted")
    setup.add_argument("--broadcast", help="Local subnet broadcast address; detected automatically if omitted")
    for name in (
        "pair", "volume-up", "volume-down", "mute", "unmute", "button", "apps", "launch",
        "play", "pause", "rewind", "fast-forward", "inputs", "set-input",
        "channel-up", "channel-down", "power-off", "power-on", "status", "wake-screen", "pointer",
    ):
        command = commands.add_parser(name)
        command.add_argument("host", help="TV IP address from discover or its network settings")
        if name == "button":
            command.add_argument("argument", choices=BUTTONS)
        if name == "launch":
            command.add_argument("argument", help="Installed app ID from the apps command")
        if name == "set-input":
            command.add_argument("argument", help="Input ID from the inputs command")
    return cli


async def execute(client, command: str, argument: str | None) -> str:
    if command == "power-state":
        return (await client.get_power_state()).get("state", "unknown")
    if command == "status":
        app = await client.get_current_app()
        volume = await client.get_volume()
        muted = await client.get_muted()
        mute = "on" if muted is True else "off" if muted is False else "unknown"
        return f"TV connected · App: {app or 'unknown'} · Volume: {volume if volume is not None else 'unknown'} · Mute: {mute}"
    if command == "wake-screen":
        power = await client.get_power_state()
        if power.get("state") == "Active":
            return "Screen is already active; confirmed by TV"
        try:
            result = await client.turn_screen_on()
        except PyLGTVCmdError:
            # Another remote may have woken the screen between the check and request.
            if (await client.get_power_state()).get("state") == "Active":
                return "Screen is already active; confirmed by TV"
            raise
        if not isinstance(result, dict) or result.get("returnValue") is not True:
            raise RuntimeError("TV did not confirm the wake request")
        power = await client.get_power_state()
        if power.get("state") == "Active":
            return "Screen is active; confirmed by TV"
        return f"TV accepted wake request; reported state: {power.get('state', 'unknown')}"
    if command == "pair":
        result = await client.get_system_info()
        if not isinstance(result, dict) or result.get("returnValue") is not True:
            raise RuntimeError("TV did not confirm authorization")
        return "TV authorized this client"
    if command == "volume-up":
        result = await client.volume_up()
    elif command == "volume-down":
        result = await client.volume_down()
    elif command in ("mute", "unmute"):
        result = await client.set_mute(command == "mute")
    elif command == "button":
        await client.button(argument)
        if client.input_connection is None:
            raise RuntimeError("Could not establish the TV's input socket")
        return f"{argument.title()} sent"
    elif command == "apps":
        apps = await client.get_apps()
        return "\n".join(f"{app.get('id', '?')}\t{app.get('title', '')}" for app in apps)
    elif command == "inputs":
        inputs = await client.get_inputs()
        return "\n".join(f"{item.get('id', '?')}\t{item.get('label') or item.get('name') or ''}" for item in inputs)
    elif command == "launch":
        result = await client.launch_app(argument)
    elif command == "set-input":
        result = await client.set_input(argument)
    elif command in ("play", "pause", "rewind", "fast-forward"):
        method = command.replace("-", "_")
        result = await getattr(client, method)()
    elif command in ("channel-up", "channel-down"):
        method = command.replace("-", "_")
        result = await getattr(client, method)()
    elif command == "power-off":
        await client.power_off()
        return "Power off sent"
    else:
        raise ValueError(f"Unknown command: {command}")
    if not isinstance(result, dict) or result.get("returnValue") is not True:
        raise RuntimeError("TV did not confirm the command")
    return f"TV accepted {command}"


async def control(host: str, command: str, argument: str | None) -> str:
    key_dir = DATA_DIR
    key_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    key_dir.chmod(0o700)
    old_umask = os.umask(0o077)
    try:
        client = await WebOsClient.create(
            ip=host,
            key_file_path=str(key_dir / "keys.sqlite"),
            states=[],
            ping_interval=None,
        )
        try:
            if command == "pointer":
                await asyncio.wait_for(client.connect(), 20)
                await pointer_session(client)
                return ""
            await client.connect()
            if command == "wake-setup":
                info = await client.request("com.webos.service.connectionmanager/getinfo")
                addresses = macs_from_tv(info)
                return configure(host, addresses[0], argument, alternate_macs=addresses[1:])
            return await execute(client, command, argument)
        finally:
            await client.disconnect()
    finally:
        os.umask(old_umask)


async def bounded_control(host: str, command: str, argument: str | None, timeout: float | None = None) -> str:
    # Pairing needs time for normal on-TV authorization; remote actions should fail promptly.
    limit = timeout if timeout is not None else (60.0 if command == "pair" else 5.0 if command in ("apps", "inputs") else 20.0)
    try:
        return await asyncio.wait_for(control(host, command, argument), limit)
    except TimeoutError as exc:
        raise TimeoutError("TV did not respond in time; check power and Wi-Fi, then retry") from exc


def main() -> int:
    args = parser().parse_args()
    if args.command == "discover":
        if args.timeout <= 0:
            print("Timeout must be positive", file=sys.stderr)
            return 2
        try:
            hosts = discover(args.timeout)
        except OSError as exc:
            print(f"Discovery failed: {exc}", file=sys.stderr)
            return 1
        if not hosts:
            print("No webOS TV responded; confirm it is on and on the same network")
            return 1
        print("\n".join(hosts))
        return 0
    try:
        if args.command == "wake-setup":
            if args.mac:
                print(configure(args.host, args.mac, args.broadcast))
            else:
                try:
                    print(asyncio.run(bounded_control(args.host, "wake-setup", args.broadcast, timeout=6)))
                except Exception:
                    # Older TVs can reject getinfo; use only the selected TV's neighbor entry.
                    print(configure(args.host, broadcast=args.broadcast))
            return 0
        if args.command == "power-on":
            print(asyncio.run(power_on(args.host)))
            return 0
        operation = control if args.command == "pointer" else bounded_control
        print(asyncio.run(operation(args.host, args.command, getattr(args, "argument", None))))
    except TimeoutError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except Exception as exc:
        print(f"TV command failed ({type(exc).__name__}): {exc}", file=sys.stderr)
        return 1
    return 0


async def power_on(host: str) -> str:
    async def confirm():
        try:
            state = await bounded_control(host, "power-state", None, timeout=3)
            if state == "Active":
                return True
            if state in ("Screen Saver", "Screen Off"):
                await bounded_control(host, "wake-screen", None, timeout=3)
                return await bounded_control(host, "power-state", None, timeout=3) == "Active"
        except Exception:
            # Offline/refused/unpaired responses are not confirmation of power-on.
            pass
        return False

    if await confirm():
        return "TV is already on; confirmed by its authenticated local response"
    return await wake_and_confirm(host, confirm)


if __name__ == "__main__":
    raise SystemExit(main())
