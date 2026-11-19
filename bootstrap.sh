#!/bin/bash
# Generates FrameCast.xcodeproj and opens it in Xcode.
#   ./bootstrap.sh            full build incl. virtual camera (needs a paid Apple Developer team)
#   ./bootstrap.sh --no-vcam  everything except the virtual camera
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "Installing XcodeGen with Homebrew…"
    brew install xcodegen
  else
    echo "XcodeGen is required: https://github.com/yonaskolb/XcodeGen (brew install xcodegen)"
    exit 1
  fi
fi

SPEC="project.yml"
if [[ "${1:-}" == "--no-vcam" ]]; then SPEC="project-novcam.yml"; fi
xcodegen generate --spec "$SPEC"

if ! command -v ideviceinfo >/dev/null 2>&1; then
  echo ""
  echo "Tip: install libimobiledevice so FrameCast can read the exact device model over USB:"
  echo "     brew install libimobiledevice"
fi

open FrameCast.xcodeproj
