# 安装包发布清单

源码公开不代表安装包已适合正式分发。当前没有正式签名公证的二进制发行版或 Homebrew cask；不要用占位下载地址或校验和发布安装说明。

## 构建与检查

- [ ] 确认 README 的机型、系统版本和未验证边界与实际结果一致。
- [ ] 设置 `project.yml` 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`，再生成 Xcode 项目。
- [ ] 运行 `scripts/check-helper.sh` 和 `scripts/check-menu.sh`，检查浅色、深色、权限、错误和任务列表。
- [ ] CI 构建与回归通过。检查本次变更未包含证书、会话记录和个人路径。

## Apple 签名与公证

需要 Developer ID Application 签名身份，以及预先保存的 notarytool keychain profile。不要将私钥或认证材料提交到仓库。

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
KEYCHAIN_PROFILE="your-notary-profile" \
NOTARIZE=1 VERSION=0.1.0 bash scripts/build-dmg.sh
```

脚本签名 App 和 helper，创建并签名 DMG，提交公证、装订票据，再生成 SHA256。输出位于 `build/`。未设置签名、公证时生成的本地测试包不能当成正式发行版。

- [ ] 在未参与开发的用户账户 / Mac 上从下载的 DMG 安装，验证 Gatekeeper、首次启动和后台服务授权。
- [ ] 核对 App 和 helper 的签名、版本号、DMG 公证状态与校验和。
- [ ] 更新已安装的上一版本，确认 helper 与主 App 一致，记录是否需要重新批准。

## 实机验收

- [ ] 开启 / 关闭合盖保活，多次确认系统状态最终恢复。
- [ ] 电池与外接电源下物理合盖，后台工作继续、显示器熄灭；验证外接屏幕。
- [ ] 两开关同时开启，合盖熄屏优先，开盖恢复；单独关闭任一开关不误关另一个。
- [ ] Agent 完成、失败、权限等待、后台任务和日志不可读分别正确处理。
- [ ] 电量下限、温度保护、拔电、倒计时能同时停止两种模式。
- [ ] 正常退出、突然退出与 helper 重启后无残留保活。
- [ ] 卸载后 App 不再启动或保持电源请求。

## 发布

全部适用检查通过后，再创建与版本对应的 Git tag / GitHub Release，附上签名公证的 DMG、校验和、测试过的系统与机型，以及已知限制。Apple 签名公证流程必须以实际成功结果为准，不能以脚本存在代替验证。

仅在真实 Release 下载地址和 SHA256 已存在时新增 Homebrew cask。Mac App Store 上架是单独的分发与审核工作，当前 root helper / 系统睡眠设置方案未按其要求验收。
