# 在 GitHub 创建仓库并触发 B148 iOS 编译

当前 ChatGPT 的 GitHub 连接不能执行“创建仓库”，因此仓库本身需要账号所有者创建；源码已准备好且包含可自动编译的 Actions 工作流。

1. 浏览器登录 GitHub：<https://github.com/new>，仓库名建议 `launcher-ios`，选 **Private**，默认分支 `main`。不勾选自动新建 README、.gitignore、License（因为源码已经有 README 和 .gitignore）。
2. 将本交接包解压到自己的电脑，并打开包含 `ShiguangLauncher.xcodeproj` 的文件夹。在该文件夹执行下面的命令（需要安装 Git；Mac 终端或 Windows 的 Git Bash 均可）：

   ```bash
   git init -b main
   git add .
   git commit -m "Initial B148 iOS launcher source"
   git remote add origin https://github.com/qimeng321/launcher-ios.git
   git push -u origin main
   ```

   若使用其他仓库名称，请修改 `git remote add origin` 的 URL。推送会通过 GitHub 登录或凭据管理器鉴权，请勿把 Access Token 粘贴给任何人。
3. 打开 <https://github.com/qimeng321/launcher-ios/actions> 查看自动触发的工作流。GitHub 可能要求首次启用 Actions。
4. 进入成功的运行记录，下载 `Launcher-1.11.1-B148-unsigned-IPA`，解压取出 `ShiguangLauncher-unsigned.ipa`。

特别检查：上传的仓库文件里必须有 `第三方依赖备份/Ruffle_B142_已验证构建产物.zip`。它是编译依赖，不能漏传。

如没有 Git 命令行，也可以通过网页 **Add file → Upload files** 上传解压后的项目文件与目录（**不能上传一个 ZIP 后期待 GitHub 自动解压**）。请确保隐藏的 `.github/workflows` 被一起上传，否则不会出现 Actions 编译任务。
