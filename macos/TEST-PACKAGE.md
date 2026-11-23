# Kitty Tools 自用测试包

这是用于测试剪贴板改动的独立版本，不是原项目的正式发行包。

## 在 GitHub Actions 打包

1. 将包含 `macos/` 源码及 `.github/workflows/macos-test-package.yml` 的 `codex/clipboard-cards` 分支推送到自己的 fork；首次推送会自动构建 Apple 芯片版。
2. 手动运行需要默认分支也有这份 workflow 文件。在 Actions 选择「macOS 自用测试包」→ Run workflow，`source_ref` 填源码分支或提交；Apple 芯片选 `arm64`，Intel 选 `x86_64`。
3. 运行成功后，在该次运行的 Artifacts 下载 `Kitty-Tools-Test-架构-运行编号`。解压后任选 DMG 或 ZIP 安装；`BUILD-INFO.txt` 记录源码提交和编译器版本，`.sha256` 用于核对下载文件。

无需配置 Secrets、开发者证书或翻译密钥。工作流只有仓库读取权限，不打 tag、不创建 Release、不更新官网。
安装包保留 14 天，构建日志保留 7 天。可以再次手动构建。

本地已有完整 Xcode 时，也可以运行 `ARCH=arm64 bash macos/build-test-package.sh`；输出在 `macos/build/test-package/`。

## 安装与首次运行

- 将 `Kitty Tools Test.app` 拖到「应用程序」。它有独立的 Bundle ID、设置、数据目录和钥匙串服务，不会替换正式版或读取正式版的剪贴板历史。
- 这是没有开发者证书、没有公证的 ad-hoc 签名包，macOS 可能阻止首次启动。先尝试打开，再到「系统设置 → 隐私与安全性」查看是否有「仍要打开」。
- 如果系统仍报告「已损坏」，先确认下载的是自己这次 Actions 的产物、校验和相符，再只移除这个测试 App 的下载隔离标记：

  ```bash
  xattr -dr com.apple.quarantine "/Applications/Kitty Tools Test.app"
  ```

  不需要关闭 Gatekeeper、SIP 或系统安全设置。
- 直接粘贴回其他 App 需要单独给测试版「辅助功能」权限；截图、录制也需要对应授权。重新构建后签名会变，macOS 可能要求重新授权。
- 测试时建议退出正式版，避免两份 App 使用相同的全局快捷键。

## 这份包的差异

- 不含内置智谱翻译密钥。智谱服务需自行填密钥；也可以选择不需要密钥的翻译服务。剪贴板不依赖翻译密钥。
- 不嵌入访达右键扩展：原实现要求原作者签名才能与 App 通信。此次没有放宽那套校验，不建议在测试版添加访达右键插件。
- 不支持原版的应用内自动更新。更新测试版时重新下载 Actions 产物。
- 云端编译、架构及签名校验成功不等于所有交互已验证。安装后仍需检查粘贴目标、中文输入法、多选、空格预览、拖出图片和多屏定位。

## English

This personal test build uses the separate name **Kitty Tools Test** and bundle ID `com.yy.kitty-tools.native.test`. Its settings, history and keychain service are separate from the original app.

It is ad-hoc signed, not notarized, and contains no built-in translation API key. The Finder Menu extension is omitted because its communication requires the original developer’s signature. In-app updates from the original project are disabled for this bundle ID.

Download the artifact from your own Actions run, extract it, then install the app from the DMG or ZIP. If macOS blocks it, check **System Settings → Privacy & Security → Open Anyway**. If it still reports damage, verify the artifact and checksum before removing quarantine from this specific test app using the command above. Do not disable system-wide security settings.

Grant the test app Accessibility access for direct pasting. A new build may need authorization again. Quit the original app while testing to avoid shortcut conflicts. Build success does not replace testing real paste targets, input methods or multiple displays.
