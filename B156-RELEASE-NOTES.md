# Tinplate Launcher B156

- 增加适配器 connectionParameters.resourceBaseURL 可选按需资源回源；未配置时完全不访问远程资源。
- 本地补丁和本地底包优先，缺失时才回源；仅允许游戏资源路径。
- builtinDoorConfig=true 时，远程 config/doorConfig.xml 不可用后提供 Windows 1.0.10 微端内置默认配置。
- ServerR.xml / ServerOfficial.xml 支持回源，并按当前登录地址重写 Email、DirSer、Visitor、SubServer、RegistSer 的 ip/port。
- ip.txt 继续由客户端生成。远程下载使用临时文件、单文件 80 MiB 限制、无 Cookie/Authorization、最终 URL 同源校验，按游戏/资源/适配器版本缓存。
- Windows 微端静态代码的默认候选值为资源端口 32400、登录端口 1863、主机 103.236.79.37；未经在线验证，不硬编码到客户端，管理员须确认。
- 最低 iOS/iPadOS 16.0，不恢复全量热更新。
