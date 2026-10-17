<p align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="96" height="96" alt="KeepAwakeMac 图标">
</p>
<h1 align="center">KeepAwakeMac</h1>
<p align="center">合盖继续工作，任务结束后恢复休眠。</p>
<p align="center"><strong>简体中文</strong> · <a href="README.en.md">English</a></p>
<p align="center">
  <a href="https://github.com/WdBlink/KeepAwakeMac/actions/workflows/build.yml"><img src="https://github.com/WdBlink/KeepAwakeMac/actions/workflows/build.yml/badge.svg" alt="macOS checks"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License"></a>
</p>

面向 **Apple Silicon MacBook** 的原生 macOS 菜单栏工具。分别控制合盖保活和屏幕常亮，也可以在所选 Codex、Claude Code 或 MiniMax Code 任务完成后自动停止。使用 SwiftUI 和系统控件，无第三方运行时依赖；当前 App 界面为中文。

**v0.1.0 为源码预发布。** 从 [Releases](https://github.com/WdBlink/KeepAwakeMac/releases) 获取对应版本的源码，按下文构建。当前没有签名公证的安装包、Homebrew cask 或 Mac App Store 版本。运行目标为 macOS 13+；开发验证环境为 Apple Silicon / macOS 27.0.1，其他系统和 Intel Mac 尚未实机验证。

## 功能与两种模式

| 开关 | 开盖时 | 合盖时 | 权限 |
| --- | --- | --- | --- |
| 合盖保活 | 任务继续，屏幕按系统设置自动熄灭 | 保持系统运行；仅此开关开启时，本工具请求显示器休眠，包含外接屏幕 | 需要批准后台服务 |
| 屏幕常亮 | 防止闲置熄屏和系统闲置睡眠 | 不改变 macOS 自身的合盖行为；单独使用不能保证合盖保活 | 本地电源请求无需管理员权限 |
| 两者同时开启 | 防止闲置熄屏和系统闲置睡眠 | 保持系统运行；后台服务确认屏幕常亮后，本工具不再请求合盖熄屏 | 需要批准后台服务 |

两个开关可以独立开启和关闭。屏幕常亮使用本地电源请求；与 helper 的可选协调失败时仍可防止闲置熄屏，但合盖模式可能继续发出熄屏请求，此时菜单会显示 **“合盖后仍可能熄屏”**。

macOS 26+ 使用系统 Clear Liquid Glass，早期系统使用标准菜单材质；减少透明度、增强对比度和减少动态效果均有对应处理。菜单按内容收紧，内容过长时滚动。

### 停止条件与保护

| 停止条件 | 使用方法 |
| --- | --- |
| 手动关闭 | 使用开关结束对应模式，或退出 App 结束两者 |
| 倒计时结束 | 选择 1–24 小时；从本次保活会话开始计时 |
| Agent 任务完成 | 选择 Agent、刷新列表并选择运行中的任务，详见下文 |
| 指定应用退出 | 输入图形应用名称或 Bundle ID；先启动该应用，再开启保活 |
| 断开电源适配器 | 接通外部电源后开启，断开时自动停止 |

- 自动停止条件同时关闭两种保活。后开启第二个开关不会重置已有倒计时或任务监控。
- 最低电量可设为 **5–80%**，达到下限即停止；电池状态无法读取时也停止。
- 默认开启过热保护，系统报告 `critical` 时停止；它不按某个摄氏温度触发。
- 两个开关都关闭后才能调整停止条件和保护设置。
- **登录时启动** 可让 App 随登录进入菜单栏；不会自动恢复上次的保活开关。切换登录启动失败时会恢复原开关状态并显示错误，可在系统设置的登录项中检查。退出可使用菜单中的“退出”或菜单展开时按 `⌘Q`。

合盖保活会改变系统级睡眠设置。请保持通风，不要把运行中的 MacBook 放进背包，也不要同时使用其他合盖保活工具。电量和温度保护不能替代散热。

## 从源码安装

需要完整的 **Xcode 26+**、能运行该 Xcode 的 macOS，以及 XcodeGen。仅安装 Command Line Tools 不足以构建 App。

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

构建产物为 `build/Build/Products/Release/KeepAwakeMac.app`。先关闭旧 App 的两个开关并退出，再安装和启动：

```bash
ditto build/Build/Products/Release/KeepAwakeMac.app /Applications/KeepAwakeMac.app
open /Applications/KeepAwakeMac.app
```

也可从 Releases 解压某个版本的源码后，在其目录中执行上述构建步骤。构建采用本机 ad-hoc 签名，并非 Apple 签名公证的发行包。请保持安装位置为 `/Applications`；重新构建或升级后，macOS 可能要求重新批准后台服务。

## 第一次使用

1. 点击菜单栏月亮图标，选择停止条件、最低电量和过热保护。
2. 只需要防止闲置熄屏时，开启 **屏幕常亮** 即可。
3. 需要合盖继续工作时，开启 **合盖保活**。如果出现权限提示，点击旁边的箭头进入 **系统设置 → 通用 → 登录项与扩展 → 后台 App 活动**，允许 KeepAwakeMac，并按系统提示完成管理员认证。不同 macOS 版本的栏目名称可能不同。
4. 返回 App，再次开启。合盖开关确认开启才表示服务已确认保活成功。
5. 需要合盖时请求屏幕休眠，只开启合盖保活；需要本工具停止发出熄屏请求，再开启屏幕常亮。
6. 使用结束后关闭开关或退出。关闭屏幕常亮会释放请求；开盖或合盖保活已关闭时，恢复系统熄屏超时。若合盖保活仍开启且盖子关闭，helper 会恢复主动请求显示器休眠，包含外接屏幕。

### 等待 Agent 任务完成

先在 Agent 中开始一项任务，再选择 **停止条件 → Agent 任务完成**，选择 Agent，点击 **刷新**，选择任务，然后开启需要的保活开关。列表使用任务标题或工作目录和会话 ID 后缀，帮助区分不同会话。

| Agent | 本地状态来源 | 完成依据 |
| --- | --- | --- |
| Codex | `~/.codex/sessions` | `task_complete` / `task_completed` |
| Claude Code | `~/.claude/projects` | `turn_duration`，且无待完成后台 Agent / workflow |
| MiniMax Code / mcode | `~/.minimax/v2/sqlite/runtime-state.sqlite` | 所选会话由 `started` 变为 `idle` |

每 2 秒检查一次，连续两次确认完成后关闭两种保活。工具调用、等待批准、暂时无输出和未完成的记录写入都不视为完成。任务中止、失败或状态不可读取时也停止，并显示原因。

这里跟踪的是**所选会话的本轮任务**，并不判断整个项目是否完成；不覆盖远程任务、其他会话或外部后台命令。最多解析最近 100 个会话。强制退出但未留下终止记录的会话可能仍出现在列表中。适配基于本地记录和回归样例；历史适配环境包括 Claude Code 2.1.282、mcode 0.5.3，自定义数据目录、其他数据库布局及未来记录格式不保证兼容。

## 使用边界与排障

**为什么合盖后屏幕仍可能熄灭？** 屏幕常亮阻止闲置熄屏，并协调本工具不发出合盖熄屏请求；它不会改变 macOS 自身的合盖显示行为，也不会主动唤醒已熄灭的屏幕。合盖保活先开、屏幕常亮后开时，服务确认之前仍可能发出一次熄屏请求。协调失败会显示警告；详细时序见[开发说明](docs/DEVELOPMENT.md)。

**屏幕能一直保持关闭吗？** 仅合盖保活开启时，每次确认合盖后成功请求一次显示器休眠，失败会重试；新会话有 5 秒静默期。后续键鼠输入等仍可能唤醒显示器，本工具不拦截这些事件，也不保证持续黑屏。

**提示权限不足或操作超时？** 确认 App 已安装在 `/Applications` 并获准后台活动，展开错误详情查看原因。升级会检查后台服务的版本，可能触发重新登记与授权；尚待批准的同一构建不会反复登记。稍后重试；进一步诊断见[开发与排障](docs/DEVELOPMENT.md)。不要为此关闭 SIP 或全局关闭 Gatekeeper。

**能监控任意命令吗？** “指定应用退出”仅监视 `NSWorkspace` 可见的图形应用。CLI Agent 应使用 Agent 任务选项。本工具不提供 HTTP API、通用 shell 命令完成检测或自动更新。

**为什么不直接使用 caffeinate？** 闲置保活和合盖睡眠是不同路径。本项目通过获批的 root helper 调用 `pmset -a disablesleep 1/0`。`disablesleep` 不属于 Apple 承诺兼容的公开接口，未来系统行为仍需验证。

**如何卸载？** 关闭两个开关，确认没有恢复睡眠失败提示，退出 App。在系统设置中关闭 KeepAwakeMac 的后台活动和登录项，然后将 `/Applications/KeepAwakeMac.app` 移到废纸篓。

**异常退出后仍无法睡眠？** helper 监视 App 退出，并在失去心跳约 20 秒后尝试恢复；helper 重启时也检查恢复标记。如果恢复失败，先退出其他保活工具，再按需手动恢复：

```bash
sudo pmset -a disablesleep 0
```

此命令改变全系统设置，仅用于确认异常后的恢复。详见[安全说明](SECURITY.md)。

## 隐私、验证与开发

不收集遥测、不上传任务内容、不安装 hooks、不修改 Agent 配置。任务检测只读访问本地日志和数据库；错误详情可能包含本地路径，提交 Issue 前请脱敏。

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# 模拟电源、XPC、开关协调、Agent 完成与保护规则，不改变真实睡眠设置
bash scripts/check-helper.sh
# 12 种菜单状态的离屏渲染与警告布局检查
bash scripts/check-menu.sh /tmp/keepawakemac-menu-previews
```

检查覆盖超时、版本落差、授权重试、两种开关顺序、错误恢复、Agent 解析、电量与温度保护。离屏预览检查不能替代真实玻璃效果和物理合盖验证；旧截图已移除。开发机的历史实测不代表当前组合版本已完成所有实机验收，持续熄屏、全新机器授权、升级和完整物理合盖矩阵仍待确认。

[开发说明](docs/DEVELOPMENT.md) · [发布清单](RELEASE_CHECKLIST.md) · [v0.1.0 版本说明](docs/releases/v0.1.0.md) · [问题反馈](https://github.com/WdBlink/KeepAwakeMac/issues)

## 许可与致谢

代码与随附图标采用 [MIT License](LICENSE)。图标由生成式图像工具辅助制作；未复用其他项目的代码或图片。文档组织参考 [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake) 的安装与边界说明，以及 [Lunar](https://github.com/alin23/Lunar) 的展示顺序。Codex、Claude Code 和 MiniMax Code 的名称属于各自项目，本工具与它们无官方关联。
