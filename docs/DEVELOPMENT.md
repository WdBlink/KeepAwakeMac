# 开发与排障

## 代码地图

| 路径 | 职责 |
| --- | --- |
| `App/Views/MenuContentView.swift` | 原生 SwiftUI 菜单面板与选择器 |
| `App/AppState.swift` | 两个独立开关、共用停止条件和状态协调 |
| `App/DisplayAwake.swift` | 闲置系统 / 显示器保活请求，合盖优先级 |
| `App/AgentTask.swift` | 本地 Agent 会话发现与完成状态解析 |
| `App/Watchdog.swift` | 电池、充电与温度保护 |
| `App/PrivilegedHelperClient.swift` | 有界超时的 XPC 客户端 |
| `Helper/` | root helper、会话归属、恢复与电源命令 |
| `Shared/` | 固定 XPC 协议与常量 |
| `project.yml` | XcodeGen 项目配置的源文件 |
| `Tests/`、`scripts/check-*.sh` | 无第三方测试框架的可运行回归检查 |

改动项目结构后运行 `xcodegen generate`，一并提交生成的 Xcode 项目。不要提交构建产物、签名证书、会话记录或个人本地路径。

## 电源生命周期

合盖模式通过 `SMAppService.daemon` 登记嵌入 App 的 LaunchDaemon。root helper 校验连接方的代码签名要求，只接受固定的开启、关闭与查询操作，不接受调用方指定的命令或路径。屏幕模式直接持有本进程的 IOKit 请求。

helper 每秒检查合盖状态，确认合盖后请求显示器休眠；每次合盖成功请求一次，失败会重试。开盖与未知状态不发出熄屏命令。屏幕模式每 0.5 秒采样，合盖或未知状态释放屏幕请求，保留系统闲置保活请求。

App 每 5 秒发出心跳，helper 的会话租期为 20 秒，同时监视 App 进程退出。root 所有的恢复标记位于 `/Library/Application Support/KeepAwakeMac/session-active`；helper 重启时尝试恢复残留的睡眠设置。其他工具已禁用睡眠时拒绝接管；这不能阻止其他工具在之后覆盖设置。

电源命令超时为 8 秒，之后最多等待 1 秒确认内核状态；XPC 截止时间为 32 秒，覆盖队列等待、命令执行和回退。状态直接读取 IOKit `SleepDisabled`，不运行完整 `pmset -g` 查询。读取失败不会假装成“已关闭”。

## 检查

先按 README 构建 Debug 版本。`scripts/check-helper.sh` 使用匿名 XPC、模拟电源命令、固定电池快照和临时 Agent 记录，不需要后台授权，也不改变真实睡眠设置。`scripts/check-menu.sh` 渲染 10 种状态，模拟菜单窗口给出 720 点高度的布局提议，确认内容不会被拉高、默认状态高度不超过 350 点；不捕获桌面、不执行真实电源操作。导出的布局 PNG 使用中性底色便于阅读，不能代替 Liquid Glass 透色的实机验收。

macOS 26+ 使用 `glassEffect(.regular)`，并通过 `containerBackground(.clear, for: .window)` 清除窗口原有背景，避免材质叠加。较早系统保留标准菜单材质；需要 Xcode 26+ 编译，CI 使用 Xcode 26.3。

以下 Debug 诊断无需批准 root helper：

```bash
/Applications/KeepAwakeMac.app/Contents/MacOS/KeepAwakeMac --check-agent-status
/Applications/KeepAwakeMac.app/Contents/MacOS/KeepAwakeMac --check-screen-awake
```

第一项读取本地任务状态；第二项短暂创建真实电源请求、确认后释放。运行前先退出通常运行的 App，避免混淆实例。

下面的诊断会注册系统服务或改变实际睡眠状态，要求 App 已安装且后台服务获批。Debug 更新后服务未加载新 helper 时，才使用重新注册命令；重新注册可能要求再次批准。

```bash
/Applications/KeepAwakeMac.app/Contents/MacOS/KeepAwakeMac --reload-helper
/Applications/KeepAwakeMac.app/Contents/MacOS/KeepAwakeMac --check-keep-awake
/Applications/KeepAwakeMac.app/Contents/MacOS/KeepAwakeMac --check-crash-cleanup
pmset -g
launchctl print system/com.local.KeepAwakeMac.Helper
```

`--check-keep-awake` 开启、读回、关闭并再次读回；`--check-crash-cleanup` 开启后模拟突然退出，需要另行检查系统已恢复睡眠。它们均不替代物理合盖、外接屏幕和长时间运行测试。

## 本地打包

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
VERSION=0.1.0 bash scripts/build-dmg.sh
```

输出为 `build/KeepAwakeMac-0.1.0-arm64.dmg` 和校验和。默认 ad-hoc 构建仅用于本地测试；脚本不上传、不创建 GitHub Release。`BUILD_DIR` 可指定输出目录；`ARCH=universal` 可构建双架构，但 Intel 运行行为尚未验证。正式分发参见[发布清单](../RELEASE_CHECKLIST.md)。

## 提交贡献

- UI 调整保持 macOS 原生控件、系统字体、键盘与辅助功能支持，验证浅色 / 深色和长内容。
- 电源和解析改动应补充能复现问题的最小回归；不能把读取失败当成任务完成。
- PR 描述给出问题、改动后的行为、检查结果。涉及实机行为时注明 macOS 版本和芯片。
- 贴日志前移除对话、令牌、用户名和项目路径；无需上传真实 Agent 会话来复现解析问题。
