# 给 AI 助手和改代码的人

iOS App「多功能媒体下载器」。目标：从常用网站取**尽可能高清、尽可能全**的图片和视频，存进相册并**按作者归类**。
结构、每个网站的清晰度、隐式状态机见 [docs/architecture.md](docs/architecture.md)；安装和使用见 [README.md](README.md)。

## 怎么验证

- **Swift 只能在 GitHub Actions 上编译**（macOS）。推送到 main → 自动编译（约 5 分钟）→ 成功后覆盖 release「latest」的 `XHSSaver.ipa`。编译错误会成为运行页面上的注释。
- **`app/dlcore.py` 可以在任何电脑上测**：`python tools/test_dlcore.py`（需要 `pip install yt-dlp`；不访问外网）。CI 也会跑，不通过不发布。
- **解析逻辑的原型**：`tools/parse_proto.py`、`tools/douyin_proto.py` 可以离线检查保存下来的网页。
- 真机上的效果只有装到手机上才能确认。没验证过的东西在汇报时要明说。

## 改动前必须知道

- 增删 `XHSSaver/` 里的源文件后运行 `python tools/gen_project.py`：工程文件是这个脚本生成的，不要手改。
- Swift 5 模式。`@Sendable` 闭包里不要改外面的 `var`（用 `PhotoSaver.swift` 里的 `Box`）；不要写 `guard let (a, b) = 可选元组`。
- `Info.plist` 的基础名必须是纯英文，中文名写在 `zh-Hans.lproj/InfoPlist.strings`；`NSPhotoLibraryUsageDescription` 不能删（申请完整相册权限时会闪退）。
- release 标题格式「最新版（日期 · 7 位提交号）」不能变，仓库外的脚本靠它判断新包是否就绪。
- 新增一种「等用户回答」的界面时，必须在 `SaveService.cancel()` 里加上收掉它的那一行（见 architecture.md 第 2 节）。

## 不能做的事

- 不用第三方合成模块，不依赖别人的服务器。
- 不伪造签名、不伪装浏览器、不绕过风控。需要登录的网站只走「用户自己登录的内置浏览器 + 复制网页自己拿到的数据」。
- cookie 绝不能进仓库或安装包（仓库和 ipa 都是公开的），也不要打印 cookie 的值。
- 不改这些默认行为：小红书游客优先、默认 HEIC 原图、发布时间开关默认关、保存前选相册默认开。
- 原图 / 原片 / 最高清晰度拿不到时，**必须先问用户**再改用替代版本（放进 `NoteMedia.fallback`，SaveService 会问）。
- 不擅自往用户已有的相册里放东西或给相册改名，都要用户确认。
- 界面文字、日志、注释、文档用中文。

## 给操作手机界面的自动化

界面上有固定的辅助功能标识，优先用它们而不是坐标或文字：

| 标识 | 是什么 |
|---|---|
| `input` | 下载页的输入框 |
| `save` | 「保存到相册」按钮 |
| `cancel` | 保存过程中的「取消」按钮（只在保存时出现） |
| `phase` | 当前阶段。它的「值」是固定的英文代号：`idle`、`parsing`、`waiting-user`、`downloading`、`saving-3-of-9`、`finished`、`failed`、`cancelled` |
| `capture-cancel`、`capture-reload` | 内置浏览器读取页（Instagram、X、微博）的「取消」「重新加载」 |

`phase` 是 `waiting-user` 时，流程在等人回答（弹窗、选相册、登录页或浏览器读取页），不会自己往下走。
