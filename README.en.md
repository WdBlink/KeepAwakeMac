<p align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="96" height="96" alt="KeepAwakeMac icon">
</p>
<h1 align="center">KeepAwakeMac</h1>
<p align="center">Close the lid. Keep working. Restore sleep when the task ends.</p>
<p align="center"><a href="README.md">简体中文</a> · <strong>English</strong></p>
<p align="center">
  <a href="https://github.com/WdBlink/KeepAwakeMac/actions/workflows/build.yml"><img src="https://github.com/WdBlink/KeepAwakeMac/actions/workflows/build.yml/badge.svg" alt="macOS checks"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License"></a>
</p>

A native menu bar utility for **Apple Silicon MacBooks**. Control lid-closed keep-awake and display wake locks separately, or stop automatically when a selected Codex, Claude Code, or MiniMax Code task finishes. Built with SwiftUI and system controls, with no third-party runtime dependencies. **The application UI is currently in Chinese**; this document translates its controls and usage.

**v0.1.0 is a source-only prerelease.** Download versioned source from [Releases](https://github.com/WdBlink/KeepAwakeMac/releases) and build it below. There is no Developer ID signed and notarized installer, Homebrew cask, or Mac App Store version. The deployment target is macOS 13+; development has been checked on Apple Silicon / macOS 27.0.1. Other macOS versions and Intel Macs have not been tested on hardware.

## Features and the two modes

| Switch | Lid open | Lid closed | Permission |
| --- | --- | --- | --- |
| Lid keep-awake — 合盖保活 | Work continues; the display follows system idle settings | Keeps the system running; when enabled alone, requests display sleep, including external displays | Background service approval required |
| Screen awake — 屏幕常亮 | Prevents idle display and system sleep | Does not override macOS lid behavior; alone, it does not guarantee lid-closed keep-awake | Local power assertions need no administrator privileges |
| Both enabled | Prevents idle display and system sleep | Keeps the system running; once the helper confirms the screen hold, this tool stops requesting lid-triggered display sleep | Background service approval required |

The two switches are independent. Screen awake uses local power assertions. If its optional coordination with the helper fails, idle prevention still works, but lid mode may continue requesting display sleep. The menu then warns **“合盖后仍可能熄屏”** (“The display may still sleep after lid closure”).

macOS 26+ uses system Clear Liquid Glass; earlier systems use the standard menu material. Reduced transparency, increased contrast, and reduced motion are respected. The menu fits its contents and scrolls when needed.

### Stop conditions and safeguards

| Stop condition | How to use it |
| --- | --- |
| Manual — 手动关闭 | Turn off a switch to end that mode, or quit to stop both |
| Timer — 倒计时结束 | Select 1–24 hours, measured from the start of this awake session |
| Agent task finished — Agent 任务完成 | Select an agent, refresh, and choose a running task; see below |
| Application exits — 指定应用退出 | Enter a GUI application name or bundle ID; start it before enabling keep-awake |
| Power adapter disconnected — 断开电源适配器 | Enable while connected to external power; stop when it is unplugged |

- Automatic stop conditions turn off both modes. Enabling the second switch does not reset an existing timer or task monitor.
- Set the battery floor to **5–80%**. Reaching it, or losing access to battery status, stops both modes.
- Thermal protection is enabled by default and stops at the system's `critical` thermal state, not a configured temperature in degrees.
- Both switches must be off before changing stop conditions or safeguards.
- **Launch at login — 登录时启动** opens the menu bar app at login; it does not restore the previous awake switches. A failed login-item change restores the previous switch state and shows an error; check Login Items in System Settings. Use **Quit — 退出**, or `⌘Q` while the menu is open, to exit.

Lid keep-awake changes system-wide sleep settings. Keep the MacBook ventilated, do not put it in a bag while running, and avoid using multiple lid keep-awake tools together. Battery and thermal guards do not replace adequate cooling.

## Build and install

Requires full **Xcode 26+**, a macOS version that can run it, and XcodeGen. Command Line Tools alone are insufficient.

```bash
git clone https://github.com/WdBlink/KeepAwakeMac.git
cd KeepAwakeMac
brew install xcodegen
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -project KeepAwakeMac.xcodeproj -scheme KeepAwakeMac \
  -configuration Release -derivedDataPath build \
  ENABLE_HARDENED_RUNTIME=NO CODE_SIGN_IDENTITY=- build
```

The app is built at `build/Build/Products/Release/KeepAwakeMac.app`. Turn off both switches and quit an older instance before installing and launching:

```bash
ditto build/Build/Products/Release/KeepAwakeMac.app /Applications/KeepAwakeMac.app
open /Applications/KeepAwakeMac.app
```

Alternatively, extract a version's source archive from Releases and run the build steps in that directory. This produces a local ad-hoc signed app, not an Apple signed and notarized distribution. Keep it in `/Applications`; rebuilding or upgrading may require renewed background service approval.

## First use

1. Click the moon icon in the menu bar. Choose the stop condition, battery floor, and thermal protection.
2. For idle prevention alone, enable **Screen awake — 屏幕常亮**.
3. For work with the lid closed, enable **Lid keep-awake — 合盖保活**. If prompted, use the adjacent arrow to open **System Settings → General → Login Items & Extensions → App Background Activity**, allow KeepAwakeMac, and authenticate as requested by macOS. Labels vary by macOS version.
4. Return to the app and enable lid keep-awake again. The switch turns on only after the helper confirms success.
5. Enable lid keep-awake alone to request display sleep on lid closure. Also enable screen awake when you want this tool to stop issuing those requests.
6. Turn off the switches or quit when finished. Disabling screen awake releases its assertions. With the lid open or lid keep-awake off, normal display timeouts resume. If lid keep-awake remains on with the lid closed, the helper resumes requesting display sleep, including external displays.

### Wait for an agent task

Start a task in the agent first. Choose **Stop condition — 停止条件 → Agent task finished — Agent 任务完成**, select the agent, click **Refresh — 刷新**, choose the task, and enable the required awake switches. Titles or working directory names and a session ID suffix distinguish sessions.

| Agent | Local status source | Completion evidence |
| --- | --- | --- |
| Codex | `~/.codex/sessions` | `task_complete` / `task_completed` |
| Claude Code | `~/.claude/projects` | `turn_duration` with no pending background agents or workflows |
| MiniMax Code / mcode | `~/.minimax/v2/sqlite/runtime-state.sqlite` | The selected session changes from `started` to `idle` |

Status is sampled every two seconds. Two consecutive completed samples stop both modes. Tool calls, approval waits, temporary silence, and unfinished log writes do not count as completion. Aborted, failed, or unreadable tasks also stop keep-awake and show a reason.

This tracks **the current task in the selected session**, not completion of an entire project. Remote tasks, other sessions, and external background commands are outside its scope. It parses at most the 100 most recent sessions. A force-killed session without a terminal record may remain listed. Adapters rely on local records and regression fixtures; historical adapter environments include Claude Code 2.1.282 and mcode 0.5.3. Custom data directories, different database layouts, and future record formats are not guaranteed to work.

## Limits and troubleshooting

**Why can the display still turn off with screen awake enabled?** The switch prevents idle display sleep and asks this tool's helper to stop issuing lid-triggered display sleep. It does not override macOS lid behavior or wake an already sleeping display. When lid mode is enabled first, a display sleep request can occur before the helper confirms the screen hold. Coordination failures show a warning. See the timing details in the [development guide (Chinese)](docs/DEVELOPMENT.md).

**Will the display stay off continuously?** With lid keep-awake alone, the helper makes one successful display sleep request per observed lid closure, retrying failures. A new session has a five-second settling window. Later keyboard or mouse activity can wake displays; this tool does not intercept those events or guarantee continuous darkness.

**Permission or timeout errors?** Install in `/Applications`, allow background activity, and expand error details. Updates check the running helper version and may require re-registration and approval; the same build awaiting approval is not repeatedly re-registered. Retry later and consult [development and diagnostics (Chinese)](docs/DEVELOPMENT.md). Do not disable SIP or globally disable Gatekeeper as a workaround.

**Can it watch arbitrary commands?** The application-exit condition watches GUI applications visible to `NSWorkspace`. Use the agent task option for CLI agents. There is no HTTP API, generic shell-command completion detection, or automatic updater.

**Why not just use caffeinate?** Idle prevention and lid-triggered sleep are different paths. An approved root helper uses `pmset -a disablesleep 1/0` for lid keep-awake. `disablesleep` is not an Apple-guaranteed public interface; future system behavior needs verification.

**How do I uninstall?** Turn off both switches, confirm no sleep-restoration error remains, and quit. Disable KeepAwakeMac's background activity and login item in System Settings, then move `/Applications/KeepAwakeMac.app` to Trash.

**Still unable to sleep after a crash?** The helper watches app exit and attempts restoration after roughly 20 seconds without a heartbeat; it also checks a recovery marker on restart. If recovery fails, quit other keep-awake tools first, then restore manually if necessary:

```bash
sudo pmset -a disablesleep 0
```

This changes a system-wide setting and is only for confirmed recovery failures. See the [security notes (Chinese)](SECURITY.md).

## Privacy, validation, and development

No telemetry, task uploads, hooks, or agent configuration changes. Task detection reads local logs and databases only. Error details may contain local paths; redact them before filing an issue.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# Simulated power/XPC, switch coordination, agent completion, and safeguards;
# does not change real sleep settings.
bash scripts/check-helper.sh
# Offscreen rendering of 12 menu states and warning layout checks.
bash scripts/check-menu.sh /tmp/keepawakemac-menu-previews
```

Checks cover timeouts, helper version skew, approval retries, both switch orderings, recovery, task parsing, and battery/thermal guards. Offscreen checks do not verify real glass compositing or physical lid behavior; outdated screenshots have been removed. Historical development-machine tests do not establish full hardware acceptance for this combined version. Continuous display sleep, fresh-machine approval, upgrades, and the full physical lid test matrix still need confirmation.

[Development (Chinese)](docs/DEVELOPMENT.md) · [Release checklist (Chinese)](RELEASE_CHECKLIST.md) · [v0.1.0 release notes](docs/releases/v0.1.0.md) · [Issues](https://github.com/WdBlink/KeepAwakeMac/issues)

## License and acknowledgments

Code and bundled icons use the [MIT License](LICENSE). Icons were made with assistance from a generative image tool; no code or images from other projects were reused. Documentation organization draws on [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake) for installation and limits, and [Lunar](https://github.com/alin23/Lunar) for presentation order. Codex, Claude Code, and MiniMax Code are names of their respective projects; this utility is not affiliated with them.
