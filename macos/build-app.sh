#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_dir="$project_root/dist/LGTVRemote.app"
mkdir -p "$app_dir/Contents/MacOS"

cd "$project_root"
uv sync --locked --group build
uv run --locked --group build python -m PyInstaller \
  --noconfirm --clean --onedir --name lg-tv --target-arch arm64 \
  --paths "$project_root/src" --collect-submodules websockets --exclude-module numpy \
  --distpath "$project_root/dist/backend" --workpath "$project_root/dist/pyinstaller" \
  --specpath "$project_root/dist/packaging" "$project_root/macos/backend_entry.py"
mkdir -p "$app_dir/Contents/Resources/Backend"
if [ -d "$app_dir/Contents/Resources/Backend/lg-tv" ]; then
  rm -rf "$app_dir/Contents/Resources/Backend/lg-tv"
fi
ditto "$project_root/dist/backend/lg-tv" "$app_dir/Contents/Resources/Backend/lg-tv"

swiftc -parse-as-library -target arm64-apple-macos26.0 \
  -framework AppKit \
  "$project_root/macos/LGTVRemote.swift" \
  "$project_root/macos/PointerTrackpad.swift" \
  -o "$app_dir/Contents/MacOS/LGTVRemote"

PROJECT_ROOT="$project_root" APP_DIR="$app_dir" python3 - <<'PY'
import os
import plistlib
from pathlib import Path

root = Path(os.environ["PROJECT_ROOT"])
app = Path(os.environ["APP_DIR"])
with (app / "Contents/Info.plist").open("wb") as output:
    plistlib.dump({
        "CFBundleName": "LG TV Remote",
        "CFBundleDisplayName": "LG TV Remote",
        "CFBundleIdentifier": "local.reverseengineer.lgtvremote",
        "CFBundleExecutable": "LGTVRemote",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "2",
        "CFBundleShortVersionString": "0.2.0",
        "LSMinimumSystemVersion": "26.0",
        "LSUIElement": True,
        "NSLocalNetworkUsageDescription": "Discover and control your LG TV on your local network.",
    }, output)
PY

codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$project_root/dist/LGTVRemote-0.2.0-arm64.zip"

printf 'Built %s\n' "$app_dir"
