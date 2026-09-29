#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
  Shared/*.swift App/PrivilegedHelperClient.swift App/AppState.swift \
  App/Settings.swift App/LaunchAtLogin.swift App/HelperService.swift App/Watchdog.swift App/ProcessScope.swift App/AgentTask.swift App/DisplayAwake.swift App/MenuCopy.swift \
  Tests/HelperClientCheck.swift Tests/FeatureCheck.swift -o "$CHECK_DIR/helper-check"
"$CHECK_DIR/helper-check"
xcrun swiftc -swift-version 5 -parse-as-library \
  Shared/Constants.swift Helper/KeepAwakeController.swift App/Watchdog.swift \
  Tests/KeepAwakeCheck.swift -o "$CHECK_DIR/power-check"
"$CHECK_DIR/power-check"
