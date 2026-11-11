# 给 AI 助手和改代码的人

iOS App「多功能媒体下载器」。目标：从常用网站取**尽可能高清、尽可能全**的图片和视频，存进相册并**按作者归类**。
结构、每个网站的清晰度、隐式状态机见 [docs/architecture.md](docs/architecture.md)；安装和使用见 [README.md](README.md)。

## 谁来维护

这个仓库的代码由你（AI 助手）长期维护：结构怎么组织由你决定。改到某处时，顺手合并重复代码、修掉相关的小问题，不要只是提一句。

但 App 做什么、不做什么由用户决定，下面「不能做的事」一节不在此列。整理的范围限于这次任务碰到的代码，不借机大改；汇报时说明哪些改动没在真机上验证过。

## 什么时候推送

**等用户这一轮的要求都提完、确认之后，再推送编译。** 改动先留在本地（可以本地提交），全部改完后汇报改了什么并问一句，用户确认了才 `git push`。不要每提一条要求就推一次：推送会触发编译并覆盖公开的安装包，用户每次都得重新装。确认之后编译失败，接着修、接着推，不用再问。

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
- 「相册」页（`AlbumsView.swift`、`AlbumLibrary.swift`）的合并、移出、移动、删除相册都只动相册这层关系，**不删照片本身**；每一个都要用户点了才做，合并和删除相册还要再确认一次。不要加删除照片的功能。
- 不擅自往用户已有的相册里放东西或给相册改名，都要用户确认。唯一的例外是用户要求的：「快速保存」在恰好有一个**完全匹配**的相册（名字里有按规则写的「前缀 + ID」）时直接放入；没有或不止一个就不放相册。快速保存不新建相册、不改名。匹配的三档见 `Albums.Match.Level`，不要把「含有 ID」「仅用户名」当成完全匹配。
- 界面文字、日志、注释、文档用中文。

## 给操作手机界面的自动化

界面上有固定的辅助功能标识，优先用它们而不是坐标或文字：

| 标识 | 是什么 |
|---|---|
| `input` | 下载页的输入框 |
| `auto-paste` | 输入框下面最右边的「自动粘贴」开关（默认关），在「粘贴 / 清空」的右侧。开着时，打开 App、从别处切回来，剪贴板里有新的文字会自动替换输入框里的内容（系统可能先弹「允许粘贴」） |
| `parse` | 「解析」按钮：先预览、选相册再保存 |
| `quick-save` | 「快速保存」按钮：不预览、不问相册，全部保存（有完全匹配的相册会自动放入） |
| `album-confirm`、`album-search` | 「放进哪个相册」页底部的主按钮（文字随当前选择变）和「搜索全部相册」输入框（输入后列表换成搜索结果） |
| `album-rename` | 主按钮旁边的「改名…」，选中一个已有相册后才能点（放入已有相册本身不问改名） |
| `album-merge-name`、`album-merge-confirm` | 「给相册改名」页里可以改的相册名，和「改名并放入」按钮 |
| `view-album` | 保存完成后进度卡片里的「查看相册」（这次放进了相册才出现），在 App 里打开那个相册 |
| `albums-search`、`albums-filter`、`albums-select`、`albums-merge` | 「相册」页底部：搜索框、筛选（全部 / 手写的名字 / 可能重复）、「多选」、多选后的「合并选中的 N 个相册」 |
| `album-detail-rename`、`album-detail-merge`、`album-detail-select`、`album-detail-delete` | 相册内容页底部：改名、合并到…、选择照片、删除相册 |
| `album-remove`、`album-move` | 相册内容页选了照片之后：移出相册、移到… |
| `clear` | 清空输入框。它和系统的「粘贴」按钮共用输入框下面、「自动粘贴」开关左边的一个位置：输入框空着时那里是「粘贴」，有内容时是「清空」；刚换过来的 0.6 秒内不接受点按 |
| `links`、`links-copy` | 「下载直链」一栏（点开 / 复制全部），下载页和预览页都有 |
| `cancel` | 保存过程中的「取消」按钮（只在保存时出现） |
| `phase` | 当前阶段。它的「值」是固定的英文代号：`idle`、`parsing`、`waiting-user`、`downloading`、`saving-3-of-9`、`finished`、`failed`、`cancelled` |
| `capture-cancel`、`capture-reload` | 内置浏览器读取页（抖音、Instagram、X、微博、快手）的「取消」「重新加载」。读取平时在后台进行、不弹页面；等了约 25 秒还没读到，会先弹窗问「要不要打开页面自己处理」，选了「打开页面」这一页才出现 |
| `login-status`、`login-reload` | 设置里登录页底部的提示和「重新加载」。`login-status` 的「值」：`logged-in`（浏览器里已有登录 cookie，可以点「完成」）、`not-logged-in`、`unknown` |
| `preview-save`、`preview-cancel`、`preview-quality` | 预览页的「保存到相册（N 项）」「取消」和视频清晰度选择（只有多种清晰度可选时出现） |
| `stages` | 步骤列表：走过的每一步，进行中的右边是进度（`3 / 9`、百分比） |
| `offline-accounts` | 下载页顶上「账号已掉线」卡片里的账号名单（自动续期发现掉线时才出现） |
| `accounts-export`、`accounts-import` | 设置页「导出全部账号」「从文件导入」（会弹出系统的文件选择） |
| `animation-style` | 设置页「界面」里的「下载页顶部动画」：简洁（默认）/ 丰富 |
| `latest` | 保存过程中「正在做什么」的那一行 |
| `details` | 「过程」，点开是全部日志 |

`phase` 是 `waiting-user` 时，流程在等人回答（弹窗、预览页、选相册或浏览器读取页），不会自己往下走。点 `parse` 之后会停在预览页，要点 `preview-save` 才继续，接着是选相册页；点 `quick-save` 则没有这两步。

标签页从左到右：下载、相册、实况工具、设置。登录和 cookie 相关的界面只在「设置」页（第四个标签）。

提问（合集要不要全存、要不要用替代版本等）是从底部弹出的系统操作列表，不是屏幕中间的弹窗。
