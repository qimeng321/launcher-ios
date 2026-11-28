# B156 测试报告

Windows 微端 1.0.10 仅静态提取、未执行：发现内置 doorConfig.xml、资源端口 32400、登录端口 1863、默认主机 103.236.79.37，以及 ServerR/ServerOfficial/ip.txt 解析流程。B163 connectionParameters 为字符串映射。

GitHub Actions 将执行 B156 静态契约、URL/path/XML Swift smoke test、Swift 语法解析、macOS Xcode Release 构建和无签名 IPA 元数据检查。本报告创建时 Actions 尚未运行，不声称已通过真机或新纪元在线端到端测试。

待验证：resourceBaseURL 在线可用性、ServerR/ServerOfficial/dll.xml/SailCore.swf 源站响应、新纪元登录及 Ruffle 完整兼容性。
