"""Frozen backend entry point; no repository or external Python dependency."""

from lg_tv_remote.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
