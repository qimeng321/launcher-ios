回归测试（需 Swift 编译器，macOS 或 Linux）:
cd 项目源码根目录
swiftc -Onone Sources/RuntimeServerSettings.swift Sources/ResourceHotUpdater.swift Tests/RuntimeServer/runtime_smoketest.swift -o /tmp/runtime_smoketest && /tmp/runtime_smoketest
swiftc -Onone Sources/RuntimeServerSettings.swift Sources/ResourceHotUpdater.swift Tests/RuntimeServer/resource_integration.swift -o /tmp/resource_integration
最后一个脚本 test_server.py 需要把 source 中 runtime_integration 可执行路径改为 /tmp/resource_integration，或使用随附回归逻辑编写同等 LAN / 本地 HTTP fixture。
以上测试只验证配置、HTTP 补齐/缓存及 SWF 签名。iOS 真机 UI 和频道连接仍需要 Xcode 完整测试。
