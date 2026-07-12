#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Nebula contributors
# Run SwiftPM with full Xcode even when the machine-wide xcode-select points to
# Command Line Tools. Usage: scripts/swift-xcode.sh build|test [arguments...]
set -euo pipefail

if [ "$(xcode-select -p 2>/dev/null || true)" = "/Library/Developer/CommandLineTools" ]; then
  for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [ -d "$candidate/Contents/Developer" ]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      break
    fi
  done
fi

if ! xcrun --find xcodebuild >/dev/null 2>&1; then
  echo "error: full Xcode is required; install Xcode or set DEVELOPER_DIR" >&2
  exit 1
fi

command swift "$@"
