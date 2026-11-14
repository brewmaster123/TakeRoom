#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
xcrun --sdk macosx clang -O2 -c Audio/StudioDSP.c -o "$work/dsp.o"
xcrun --sdk macosx swiftc -swift-version 5 -O -parse-as-library \
  -import-objc-header Audio/StudioDSP.h App/Project.swift App/Render.swift Tests/RenderSmoke.swift \
  "$work/dsp.o" -lz -o "$work/smoke"
"$work/smoke" Tests/Fixtures/pulse.mov
