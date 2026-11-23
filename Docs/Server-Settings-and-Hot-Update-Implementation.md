# iOS 动态服务器设置与资源缺失自动补齐 — 源码交接说明

## Windows 2.3.0 安装包中实际提取到的资料

对用户上传的 `拾光号Flash极速版_2.3.0_win-setup.exe` 作静态解压，不执行 EXE。
内置 Windows 客户端的可读字符串中包含 `resBaseUrl`、`loginHost`、`loginPort`、`gamePortBase`，
以及 `ip.txt`、`config/ServerR.xml`、`_overlay/manifest.json`、`overlayFiles` 等关键字。
还存在 `http://202.189.23.85:29380/` 等地址。这些地址只是**程序中的候选值**，不代表当前服务可用。

⚠️ 没有服务器 API 文档/网络抓包，因此**无法确认 Windows 的完整热更新协议**。
当前 iOS 实现的是「按需缺失资源补齐」，不是声称已经兼容 Windows 全量 overlay 清单同步。

## iOS 改动

1. 首页增加 **服务器设置** 按钮。游戏服输入 `IPv4:端口`；资源服输入 `http(s)://host:port/`。
2. 保存至 `UserDefaults`，无需修改 SWF 或 IPA 内硬编码地址。新建游戏会话时读取。
3. `GameSocketBridge` TCP 登录代理读取动态游戏服地址；登录端口可编辑。频道仍以 CMD105/106 实际返回的地址端口为准。
4. `GameServer` 返回的 `ip.txt`、`config/ServerR.xml` 以及 Ruffle 生成的 socketProxy 映射使用该配置。
5. 资源服 URL 独立保存，可留空关闭热更新；不会因为 Windows 二进制里出现某个地址就默认自动访问它。
6. 游戏请求资源时顺序：**移动补丁覆盖层 → 当前底包 → 独立热更新缓存 → 配置的资源服务器下载**。
7. 缺失资源的 GET/HEAD 从资源服下载到缓存后，经本机 HTTP 代理回送，支持既有的 HTTP Range 发送逻辑。
8. 仅补齐允许的游戏资源目录，拒绝目录穿越、非法 URL、过大文件和伪造的 SWF；HTTPS 也支持。
9. 缓存按底包资源修订号、资源服地址分组，切换服务器不会复用旧服务器缓存。首页可清理缓存。
10. 对原始 `.srom` 底包与补丁不做修改；下一次进入游戏后新设置生效。

## 说明及待验证项

- **未打包/未安装 IPA**：当前仅是代码改动；已安装旧版 IPA 不会凭空出现此按钮。新功能最终仍需在 Mac + Xcode 完整编译，并在 iOS 真机确认。
- 热更新是**游戏按需请求触发的缺失资源补齐**；不会自动对 2.7GB 底包进行全量比对、替换已存在文件、自动下载所有新文件。
- 如果后续需要 Windows 完全一致的 `_overlay/manifest.json` 全量热更新，请提供资源服的实际清单格式、响应样本和路径规则后，再补充清单解析及增量校验。不能仅根据安装程序中的字符串猜测 API。
- 热更新服务器未填时，游戏与此前一样仅访问本地底包资源。
- 默认游戏登录为用户最新提供的 `202.189.23.85:22973`；资源服为空。
- 当前最多补齐单文件 80 MiB（可按资源统计调整）。
- 同步 `config/ServerR.xml` 时只替换既有已知历史游戏服务器 IP 与对应 22973 登录端口；如果实际服务端 XML 结构不同，还需要实机检查。
- 真实资源服务器、游戏频道、Ruffle 与 SwiftUI 的**iOS 端到端功能尚未实测**。

## 文件位置

- `Sources/RuntimeServerSettings.swift` —— 配置解析、校验和保存
- `Sources/ResourceHotUpdater.swift` —— 资源下载、校验、独立缓存与按需补齐
- `Sources/GameSocketBridge.swift` —— TCP 登录与频道映射读取配置
- `Sources/GameServer.swift` —— 生成网页代理、`ip.txt`、`ServerR.xml`、HTTP 资源缺失回退
- `Sources/ShiguangLauncherApp.swift` —— 首页入口及设置表单
- `ShiguangLauncher.xcodeproj/project.pbxproj` —— 新源码已加入编译目标

## 已完成检查

- `swiftc -frontend -parse Sources/*.swift` 全文件语法检查通过。
- `plutil -lint -- ShiguangLauncher.xcodeproj/project.pbxproj` 通过。
- Swift Foundation 端点校验与恶意路径案例测试通过。
- 在本地 HTTP 测试服务器上完成 SWF 补齐、缓存复用、无效 SWF 拒绝案例。
- 没有执行 Windows 用户上传的 EXE；仅作静态解压和字符串分析。
