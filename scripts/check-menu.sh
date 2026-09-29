#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT
OUT="${1:?Pass an output directory for the rendered previews}"
mkdir -p "$OUT"
xcrun swiftc -swift-version 5 -parse-as-library \
  Shared/*.swift App/PrivilegedHelperClient.swift App/AppState.swift \
  App/Settings.swift App/LaunchAtLogin.swift App/HelperService.swift App/Watchdog.swift \
  App/ProcessScope.swift App/AgentTask.swift App/DisplayAwake.swift App/MenuCopy.swift App/Views/MenuContentView.swift \
  Tests/MenuPreview.swift -o "$CHECK_DIR/menu-preview"
"$CHECK_DIR/menu-preview" "$OUT"

# Every state the menu can be in has to render, including the one the review
# called out: an eleventh state with screenWarning set. A missing render is a
# silent skip, so the count is asserted rather than globbed.
expected=(idle permission timer agent-empty agent-ready working error active warning dark overflow)
for state in "${expected[@]}"; do
  [[ -s "$OUT/$state.png" ]] || { echo "FAIL: $state rendered no menu"; exit 1; }
done
extra=$(find "$OUT" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ')
[[ "$extra" == "${#expected[@]}" ]] || { echo "FAIL: expected ${#expected[@]} renders, found $extra"; exit 1; }
echo "PASS: all ${#expected[@]} menu states rendered"

# The banner is proved from the pixels, not from a constant. check-menu.sh is
# the only thing that can see that the report describes an inserted block of a
# real height with real ink in it.
report="$OUT/warning.render.txt"
[[ -s "$report" ]] || { echo "FAIL: no render report at $report"; exit 1; }
grep -qE 'warning banner on screen: [0-9]+ points inserted at row [0-9]+, [0-9]+ pixels of it drawn, the rows above untouched and the rows below moved down by exactly [0-9]+' "$report" \
  || { echo "FAIL: the render report does not describe an inserted block: $(cat "$report")"; exit 1; }
# The pixels above prove a banner was drawn where the warning branch sits. The
# words inside it are pinned here instead, because the render is the only place
# the two facts meet: the branch must draw MenuCopy.screenWarningTitle, and that
# constant must be exactly 「合盖后仍可能熄屏」. A hand-typed title in the view, or
# a reworded constant, fails one half or the other.
title=$(sed -n 's/^ *static let screenWarningTitle = "\(.*\)" *$/\1/p' App/MenuCopy.swift)
[[ "$title" == "合盖后仍可能熄屏" ]] \
  || { echo "FAIL: the banner's title is now \"$title\", not 「合盖后仍可能熄屏」"; exit 1; }
grep -q 'failureNotice(title: MenuCopy.screenWarningTitle' App/Views/MenuContentView.swift \
  || { echo "FAIL: the warning banner is no longer drawn from MenuCopy.screenWarningTitle"; exit 1; }
echo "PASS: $(cat "$report")"
