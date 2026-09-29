#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
  Shared/*.swift App/PrivilegedHelperClient.swift App/AppState.swift \
  App/Settings.swift App/LaunchAtLogin.swift App/HelperService.swift App/Watchdog.swift \
  App/ProcessScope.swift App/AgentTask.swift App/DisplayAwake.swift App/MenuCopy.swift App/Views/MenuContentView.swift \
  Tests/MenuPreview.swift -o "$CHECK_DIR/menu-preview"
"$CHECK_DIR/menu-preview" "${1:?Pass an output directory for the rendered previews}"
