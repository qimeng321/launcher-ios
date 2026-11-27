# 启动器 iOS — B150

> iOS / iPadOS 本地游戏启动器（1.0 Build 150；主界面不展示版本）。

本工程提供：游戏服 `IP:端口` 与资源服 URL 独立配置、资源包导入、根据远程资源清单（`/_overlay/manifest.json` 或 `/manifest.json`）按 SHA-256 校验并下载差分资源、Ruffle WebAssembly 引擎、用户提供的新图标。**远程资源清单与真实游戏服务器的兼容性仍需实测**。

## GitHub Actions 编译

新建 GitHub 仓库后，必须把本目录内**所有文件及隐藏目录 `.github`** 上传至仓库根目录，确保 `ShiguangLauncher.xcodeproj` 位于仓库根目录，并保留 `ThirdParty/EngineParts/` 中的全部引擎分块（Actions 会自动校验并还原引擎备份）。

推送至 `main` 后，GitHub Actions 自动触发 `启动器 - 可配置服务器与版本感知热更新 B150`；也可进入 **Actions** → 选择工作流 → **Run workflow** 手动触发。成功后，在对应运行记录的 **Artifacts** 下载 `Launcher-1.0-B150-unsigned-IPA`，解压后得到未签名 `.ipa`。

**无需 Apple 开发者证书即可编译未签名 IPA**；如需安装真机，需使用符合条件的签名方式。

如果 Actions 显示计费、macOS runner 无法使用或限额提示，请检查 GitHub 账号的 Actions 权限和计费设置；该问题不能通过修改 Swift 源码解决。

## 本地检查

```bash
python3 Tests/VersionAware/check_artifact_sources.py
node Patches/test-frame-cap.js
node Patches/test-direct-touch.js
node Patches/test-precision-no-hover.js
python3 Patches/test-incremental-archive.py
swiftc -frontend -parse Sources/*.swift
swiftc -frontend -parse Sources/RuntimeServerSettings.swift Sources/TinplateClient.swift
```

小铁皮客户端接入说明：`Docs/Tinplate-Client-Integration.md`。

注意：这不是已经通过真机测试的正式构建，热更新回退、实际服务器清单及游戏内功能尚待联机验证。上传至公开仓库前请确认拥有相关代码、游戏资源与第三方内容的发布权限。首次上传建议选私有仓库。


## 独立安装与网络检查
本版本 Bundle ID 为 cn.qimeng321.independentlauncher，与旧版分别安装、分别存储数据。首次安装后游戏服和资源服均为空，须由用户自己填写。游戏服未设置时无法进入游戏。服务器设置新增“测试连接”：检查 HTTP 连通性及可识别的远程 manifest。连接成功不等于 Windows 端的私有热更新协议已经兼容。
