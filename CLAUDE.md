# 给 AI 助手和改代码的人

iOS App「多功能媒体下载器」。目标：从常用网站取**尽可能高清、尽可能全**的图片和视频，存进相册并**按作者归类**。
结构、每个网站的清晰度、隐式状态机见 [docs/architecture.md](docs/architecture.md)；安装和使用见 [README.md](README.md)。

## 谁来维护

这个仓库的代码由你（AI 助手）长期维护：结构怎么组织由你决定。改到某处时，顺手合并重复代码、修掉相关的小问题，不要只是提一句。

但 App 做什么、不做什么由用户决定，下面「不能做的事」一节不在此列。整理的范围限于这次任务碰到的代码，不借机大改；汇报时说明哪些改动没在真机上验证过。

## 怎么验证

- **Swift 只能在 GitHub Actions 上编译**（macOS）。推送到 main → 自动编译（约 5 分钟）→ 成功后覆盖 release「latest」的 `XHSSaver.ipa`。编译错误会成为运行页面上的注释。
- **`app/dlcore.py` 可以在任何电脑上测**：`python tools/test_dlcore.py`（需要 `pip install yt-dlp gallery-dl`；不访问外网）。CI 也会跑，不通过不发布。
- 打进安装包的 Python 库必须是纯 Python（iOS 上加载不了编译好的模块），CI 会检查。
- **解析逻辑的原型**：`tools/parse_proto.py`、`tools/douyin_proto.py` 可以离线检查保存下来的网页。
- 真机上的效果只有装到手机上才能确认。没验证过的东西在汇报时要明说。

## 改动前必须知道

- 增删 `XHSSaver/` 里的源文件后运行 `python tools/gen_project.py`：工程文件是这个脚本生成的，不要手改。
- Swift 5 模式。`@Sendable` 闭包里不要改外面的 `var`（用 `PhotoSaver.swift` 里的 `Box`）；不要写 `guard let (a, b) = 可选元组`。
- `Info.plist` 的基础名必须是纯英文，中文名写在 `zh-Hans.lproj/InfoPlist.strings`；`NSPhotoLibraryUsageDescription` 不能删（申请完整相册权限时会闪退）。
- release 标题格式「最新版（日期 · 7 位提交号）」不能变，仓库外的脚本靠它判断新包是否就绪。
- 版本号由 CI 定：`1.2.运行序号`（`gen_project.py` 里的 `MARKETING_VERSION` 是前两段）。release 里的 `apps.json` 是 AltStore 的源，由 `tools/make_source.py` 从打好的 ipa 生成；AltStore 会核对包里的版本号、Bundle ID 和源里写的是否一致，所以不要手写。
- 新增一种「等用户回答」的界面时，必须在 `SaveService.cancel()` 里加上收掉它的那一行（见 architecture.md 第 2 节）。
- 进度信息默认算细节：`service.say(…, detail: true)`。只有「解析到了什么、存了什么、哪里失败」才不带 `detail`。
- 登录、cookie 相关的界面只放在设置页，不要在下载流程里弹登录页。

## 不能做的事

- 不用第三方合成模块，不依赖别人的服务器。
- **不加内容审查类的功能和预期之外的限制**：不按内容类型、敏感标记、年龄分级筛选或拦截，不设网站黑名单，不悄悄丢掉或截断内容。yt-dlp、gallery-dl 里默认会跳过内容的选项要关掉。确实需要的技术性上限要做成设置、能改成不限，并写进 architecture.md 的「不过滤内容」一节。
- 不伪造签名、不伪装浏览器、不绕过风控。需要登录的网站只走「用户自己登录的内置浏览器 + 复制网页自己拿到的数据」。
- cookie 绝不能进仓库或安装包（仓库和 ipa 都是公开的），也不要打印 cookie 的值。
- 不改这些默认行为：小红书游客优先、默认 HEIC 原图、发布时间开关默认关。
- 原图 / 原片 / 最高清晰度拿不到时，**必须先问用户**再改用替代版本（放进 `NoteMedia.fallback`，SaveService 会问）。
- 不擅自往用户已有的相册里放东西或给相册改名，都要用户确认。
- 界面文字、日志、注释、文档用中文。

## 给操作手机界面的自动化

界面上有固定的辅助功能标识，优先用它们而不是坐标或文字：

| 标识 | 是什么 |
|---|---|
| `input` | 下载页的输入框 |
| `parse` | 「解析」按钮：先预览、选相册再保存 |
| `quick-save` | 「快速保存」按钮：不预览、不选相册，全部保存 |
| `clear` | 清空输入框 |
| `links`、`links-copy` | 「下载直链」一栏（点开 / 复制全部），下载页和预览页都有 |
| `cancel` | 保存过程中的「取消」按钮（只在保存时出现） |
| `phase` | 当前阶段。它的「值」是固定的英文代号：`idle`、`parsing`、`waiting-user`、`downloading`、`saving-3-of-9`、`finished`、`failed`、`cancelled` |
| `capture-cancel`、`capture-reload` | 内置浏览器读取页（Instagram、X、微博、快手）的「取消」「重新加载」 |
| `login-status`、`login-reload` | 设置里登录页底部的提示和「重新加载」。`login-status` 的「值」：`logged-in`（浏览器里已有登录 cookie，可以点「完成」）、`not-logged-in`、`unknown` |
| `preview-save`、`preview-cancel`、`preview-quality` | 预览页的「保存到相册（N 项）」「取消」和视频清晰度选择（只有多种清晰度可选时出现） |
| `stages` | 步骤列表：走过的每一步，进行中的右边是进度（`3 / 9`、百分比） |
| `accounts-export`、`accounts-import` | 设置页「导出全部账号」「从文件导入」（会弹出系统的文件选择） |
| `latest` | 保存过程中「正在做什么」的那一行 |
| `details` | 「过程」，点开是全部日志 |

`phase` 是 `waiting-user` 时，流程在等人回答（弹窗、预览页、选相册或浏览器读取页），不会自己往下走。点 `parse` 之后会停在预览页，要点 `preview-save` 才继续，接着是选相册页；点 `quick-save` 则没有这两步。

登录和 cookie 相关的界面只在「设置」页（第三个标签）。
