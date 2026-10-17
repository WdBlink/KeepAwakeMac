# 发布清单

当前发行目标是 **v0.1.0 源码预发布**。GitHub Release 标记为 prerelease，由 GitHub 提供 tag 对应的源码归档。源码预发布不代表安装包已适合正式分发；没有通过签名、公证和实机验收时，不附加可下载的 App / DMG，也不提供 Homebrew cask。

## 源码预发布门槛

- [ ] 中文 `README.md` 与英文 `README.en.md` 的能力、使用方法和限制一致。
- [ ] 清除过时截图、测试数量和功能优先级说明；检查相对链接。
- [ ] 核对 `project.yml`、生成的 Xcode 项目与发行版本：`0.1.0`，build `1`。
- [ ] 通过 `scripts/check-helper.sh`、`scripts/check-menu.sh` 与 Release 构建。
- [ ] 通过发布审核与当前 commit 的 CI。
- [ ] 只提交项目源码、文档及必要资源；排除 `.multica/`、本地交接、证书和会话数据。
- [ ] 版本说明准确列出未验证的实机项目；创建 tag 后核对 Release 的 commit、prerelease 状态和源码下载。

## 正式二进制发行的额外门槛

以下项目未完成前，维持源码预发布。不要以脚本存在代替 Apple 签名、公证或实机验证结果。

### 签名与公证

需要 Developer ID Application 签名身份，以及预先保存的 notarytool keychain profile。不要提交私钥或认证材料。

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
KEYCHAIN_PROFILE="your-notary-profile" \
NOTARIZE=1 VERSION=0.1.0 bash scripts/build-dmg.sh
```

- [ ] App 与 helper 的签名、版本和 hardened runtime 正确；DMG 完成公证、装订与校验和生成。
- [ ] 在未参与开发的用户账户 / Mac 上从下载的 DMG 安装，验证 Gatekeeper、首次启动和后台服务批准。
- [ ] 更新已安装的上一版本，确认主 App 与实际运行的 helper 协议一致，记录是否需重新批准。

### 实机验收

- [ ] 开启 / 关闭合盖保活，多次确认系统最终恢复正常睡眠。
- [ ] 电池与外接电源下物理合盖，后台工作继续；验证内置与外接屏幕。
- [ ] 两开关同时开启：helper 确认后本工具不再请求合盖熄屏，任一开关关闭不误关另一种模式。
- [ ] 验证两种开关顺序、等待中继、迟到回调、helper 重启及失败警告；不把 macOS 自身行为当成工具保证。
- [ ] Agent 完成、失败、权限等待、后台任务和日志不可读均正确处理。
- [ ] 电量下限、温度保护、拔电与倒计时能同时停止两种模式。
- [ ] 正常退出、突然退出与 helper 重启后无残留保活。
- [ ] 卸载后 App 不再启动或保持电源请求；验证真实玻璃透色与辅助功能设置。

只有真实 Release 下载地址和 SHA256 已存在时，才新增 Homebrew cask。Mac App Store 上架属于单独分发工作，当前 root helper / 系统睡眠设置方案尚未按其要求验收。
