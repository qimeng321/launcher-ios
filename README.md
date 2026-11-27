# 启动器 iOS — B152

> iOS / iPadOS 本地游戏启动器（1.0 Build 152；主界面不展示版本）。

本工程提供：本地 ZIP/SROM 资源包导入、Ruffle WebAssembly 游戏运行、游戏服务器 IP:端口设置，以及小铁皮服务端账号、游戏库和默认连接配置接入。**资源服务器与游戏资源热更新已从客户端移除；游戏资源仅使用用户本地导入的资源包。**

## GitHub Actions 编译

新建 GitHub 仓库后，必须把本目录内**所有文件及隐藏目录 `.github`** 上传至仓库根目录，确保 `ShiguangLauncher.xcodeproj` 位于仓库根目录，并保留 `ThirdParty/EngineParts/` 中的全部引擎分块（Actions 会自动校验并还原引擎备份）。

推送至 `main` 或 `tinplate-b150-integration` 后，GitHub Actions 自动执行小铁皮 B152 构建；也可进入 **Actions** → 选择工作流 → **Run workflow** 手动触发。成功后，在对应运行记录的 **Artifacts** 下载 `Launcher-1.0-B152-unsigned-IPA`，解压后得到未签名 `.ipa`。

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

注意：这不是已经通过真机测试的正式构建；小铁皮在线补丁、诊断日志及工单模块仍在后续开发。上传至公开仓库前请确认拥有相关代码、游戏资源与第三方内容的发布权限。首次上传建议选私有仓库。


## 独立安装与网络检查
本版本 Bundle ID 为 cn.qimeng321.independentlauncher，与旧版分别安装、分别存储数据。首次安装后游戏服务器地址为空。用户可从小铁皮游戏库选择游戏并读取后台默认地址，也可按游戏单独设置自定义 IPv4:端口。小铁皮服务端地址在游戏库页面配置，正式账号通信必须使用 HTTPS。客户端不再配置资源服务器，也不执行资源热更新。
