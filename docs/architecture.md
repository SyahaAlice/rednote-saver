# 结构说明

这份文档写给改代码的人（包括 AI 助手）。使用说明在 [README](../README.md)，改动前必须知道的规矩在 [CLAUDE.md](../CLAUDE.md)。

## 目标

从常用网站（小红书、抖音、Instagram、X、微博、B 站）和偶尔用到的其它网站，取**尽可能高清、尽可能全**的图片和视频，存进相册并**按作者归类**。判断一个改动好不好，先看这三条：

1. 清晰度有没有变高或保持最高（原图、原片、最高码率）。
2. 一个作品里的内容有没有存全（多图、多视频、实况图、图片视频混排）。
3. 存下来的东西是不是更好找（相册归类、命名、日期、下载记录）。

## 一条链接怎么变成相册里的照片

```
输入文字 ──▶ NoteParser.extractURL ──▶ Extractors.pick(for:)
                                            │  按顺序问每个解析器 canHandle，第一个说「能」的接手
                                            ▼
        ┌──────────────┬──────────────┬──────────────┬───────────────┐
   小红书 / 快手       抖音         Instagram        X / 微博            其它网站
   App 自己请求   DouyinCapture    WebCapture    gallery-dl → yt-dlp    gallery-dl →
   作品网页       （内置浏览器 +   （内置浏览器 +    → WebCapture          yt-dlp
  （游客优先）     登录账号）       登录账号）    （前一个不行才用后一个）  （dlcore.py）
        └──────────────┴──────────────┴──────────────┴───────────────┘
                                            ▼
                              ParsedNote（所有网站统一的结果）
                                            ▼
        SaveService：「解析」= 预览（勾选、选清晰度）─▶ 选相册；「快速保存」= 跳过这两步、全部保存
                     ─▶ 查重 ─▶（yt-dlp 的作品在这里才下载）
                     ─▶ 逐项下载 / 实况合成 ─▶ 存进相册 ─▶ 记下载记录
```

| 文件 | 作用 |
|---|---|
| `Extractors.swift` | 解析器列表和选择顺序；每个网站怎么组合 yt-dlp 和内置浏览器 |
| `NoteParser.swift` | 小红书：短链、笔记网页、`__INITIAL_STATE__` |
| `Douyin.swift` | 抖音：解析 + 它自己的内置浏览器读取（最早写的一套） |
| `WebCapture.swift` | 通用的内置浏览器读取，Instagram、X、微博共用 |
| `Instagram.swift`、`XPost.swift`、`Weibo.swift` | 各自的「怎么认出要的那份数据」和「怎么解析」 |
| `YtDlp.swift`、`app/dlcore.py`、`PythonBridge.m` | 内嵌 Python 上的 yt-dlp |
| `SaveService.swift` | 整个保存流程、所有提问、取消 |
| `PreviewView.swift` | 预览页：下载之前列出作品里的每一项，勾选、选视频清晰度；下载直链（`LinksSection`） |
| `BackgroundRun.swift` | 保存期间不自动锁屏、切走后多要一点时间、iOS 26 起申请后台继续下载 |
| `Downloader.swift` | 下载单个文件，按文件头决定扩展名 |
| `StatusAnimation.swift`、`StatusAnimationSimple.swift` | 下载页顶上的状态动画：纯色平面图形，Canvas 实时画，跟着 `SavePhase` 和进度变；不在眼前时停。只是装饰，不接受点按。两种样式在设置页「界面」里选：简洁（默认，三块色片变形；空闲时轮换四个构图）和丰富（备用，多层图形） |
| `AlbumLibrary.swift`、`AlbumsView.swift` | 「相册」标签页：列出、搜索、找可能重复的相册；相册内容页；合并、移出、移动、删除相册（都不删照片）。选相册页里的搜索、相册行和它共用 |
| `LivePhotoMaker.swift`、`LiveTools.swift` | 实况照片配对、视频转实况、实况拆分、音视频合并 |
| `PhotoSaver.swift` | PhotoKit 入库、相册匹配和命名 |
| `CookiePool.swift`、`WebAccounts.swift` | 账号：cookies 文件、登录状态判断、App 内登录 |
| `Models.swift` | `ParsedNote`、`NoteMedia`、`Author`、`XHSError`、设置项、下载记录 |

## 每个网站取到的清晰度

| 网站 | 图片 | 视频 | 实况 | 需要登录 |
|---|---|---|---|---|
| 小红书 | 原图（HEIC） | 原片（`originVideoKey`）；预览页里可以改选转码出来的某一档（`NoteMedia.byHeight`，按画面短边分档，同档 H.264 优先），默认和快速保存仍是原片 | 有 | 不需要（游客优先） |
| 抖音 | 最高分辨率 JPEG（没有原图） | `bit_rate` 里面积最大、码率最高的 mp4 | 有 | 必须 |
| Instagram | `image_versions2` 里面积最大的 | `video_versions` 里面积最大的 | 无 | 必须（否则只有 yt-dlp 的视频） |
| X | `name=orig` 原图 | mp4 里码率最高的 | 无 | 图片必须 |
| 微博 | `largest` → `original` → `mw2000` | `playback_list` 里面积最大的 | 有（实况图） | 图片建议登录 |
| 快手 | 图集每张图（`atlas.cdn` + `atlas.list`）、单图用封面 | `videoResource` 里面积最大的，没有就 `photoUrl` | 无 | 不需要（游客优先，要验证时才用账号） |
| B 站（yt-dlp） | 封面图（yt-dlp 的 `thumbnail`，原始尺寸） | 清晰度优先，见下 | 无 | 高清晰度需要登录 |
| 其它（gallery-dl → yt-dlp） | gallery-dl 支持的网站：它给出的原图 | 清晰度优先，见下 | 无 | 看网站 |

X 和微博现在先走 gallery-dl：图片和视频一起拿，清晰度和上表相同（X 原图、微博 `largest`、视频最高码率）。

**两个开源提取器的分工**（都在 `app/dlcore.py`）：

- **yt-dlp** 管视频：`probe`（解析）→ `fetch`（下载，音视频分开的交给 Swift 合并）。
- **gallery-dl** 管图片和图文混排：`gallery` 只**列出**每一项的地址和作品信息，不下载；文件由 `SaveService` 和 `Downloader` 下载，所以原图失败先问、实况合成、相册归类这些规则对它同样生效。它给出的分段视频（`ytdl:` 开头）自己不下载：全是这种时整条链接交给 yt-dlp。
- `GenericExtractor` 先问 gallery-dl，它说不支持（视频网站）就交给 yt-dlp。

快手的字段位置参考开源项目 KS-Downloader（GPL-3.0），代码是按同样的字段重新写的，没有照搬；它用的浏览器伪装这里不用。

yt-dlp 的选格式规则在 `dlcore.py` 的 `_format` 和 `FORMAT_SORT`：只在 iPhone 能合并和播放的编码（H.264、HEVC）里选，先比分辨率、再比帧率，都一样时选 H.264。所以只有 HEVC 能给出更高清晰度时才用 HEVC。上限由「设置 → 其它网站视频清晰度」控制，默认不限。

**已知的不足**（改进时优先看这里）：

- X 基本都要账号：号池里没有 X 的 cookie 时 gallery-dl 拿不到内容，会退回 yt-dlp（只有视频）和内置浏览器。
- gallery-dl 给出「图片 + 分段视频」的少见帖子：图片照存，视频记成失败（没有接到 yt-dlp 上）。
- Instagram 帖子以外的链接（主页、快拍）不走 gallery-dl（容易触发验证），只有 yt-dlp。
- B 站动态（图文）没有自己的解析器；快手的网页数据结构没有拿真实网页核对过。
- 实况照片的封面图为了写入配对标记会重新编码一次（质量 0.95）。
- 下载是逐项串行的，没有断点续传；切到后台会中断。

## 不过滤内容

App 不做内容审查：不按内容类型、敏感标记、年龄分级筛选或拦截，没有网站黑名单。具体到代码：

- yt-dlp 不设 `age_limit`、`match_filter` 之类的选项。
- gallery-dl 里默认会跳过内容的开关在 `dlcore._gdl_setup` 里全部打开（被标成不可用的媒体、转发、微博「电影」类视频），不设任何 `*-filter`、黑白名单。`tools/test_dlcore.py` 会检查这一点。
- 没有数量上限（传给 dlcore 的 `max_entries` 固定是 0）：一个链接里有多少项都列出来，由用户在预览页勾选。视频清晰度默认最高，在预览页里可以改。
- 超过 20 项先问、原图失败先问，是确认，不是限制：用户点了就照做。

- 不限制网站：没有专门解析器的网址（`GenericExtractor`）一律先交给 gallery-dl、再交给 yt-dlp（包括它的「通用」提取器，短链也由它跟随跳转），不事先按域名判断支不支持。曾经加过一步「先看有没有专门的提取器」的验证，结果把 B 站短链（最后跳到手机版 m.bilibili.com）误判成不支持，按用户要求去掉了，不要加回来。`dlcore.supports` 还留着但没有地方调用。唯一的检查是 `SaveService.attempt` 里的「确实解析到了能保存的东西」。

新增功能时不要引入上面没列出的筛选或上限；确实需要的技术性限制要做成设置，并写进这一节。

## 新增一个网站

1. 先看 gallery-dl 和 yt-dlp 支不支持：支持就什么都不用做，`GenericExtractor` 兜底。
2. 要存图片或 yt-dlp 不支持时，照 `XPost.swift` 写一个文件，三样东西：
   - `isPost(_ url:)`：哪些链接归它管（只认单个作品的链接，主页之类的留给 yt-dlp）。
   - `capture(account:start:)`：一份 `WebCaptureSpec`——网页数据里出现哪些关键词才看（`keywords`）、看哪些接口的返回（`apiHints`）、怎么从一块数据里认出网址指向的那个作品（`match`，用 `JSONTree.first` 按特征找，不要写死外层路径）。
   - `parse(...)`：把那份数据变成 `ParsedNote`。每个媒体项 `original` 放最高清的地址，`fallback` 放次一档（用之前 SaveService 会先问用户）。
3. 在 `Extractors.swift` 里加一个解析器并放进 `all`（在 `YtDlpExtractor` 之前）。视频走得通 yt-dlp 的网站用 `ytDlpThenWeb`。
4. 在 `WebAccounts.swift` 的 `SitePreset.all` 里加登录入口；能判断登录状态的话在 `CookiePool.loginCookieNames` 里加它的登录 cookie 名。
5. 运行 `python tools/gen_project.py`，更新 README 和上面的表。

## 隐式状态机

下面是代码里所有「靠几个变量的组合来表示状态」的地方。标了**已显式化**的有专门的类型；其余的仍然是隐式的，改相关代码时要守住写在这里的规则。

### 1. 保存流程（已显式化：`SavePhase`）

`SaveService.phase`，界面的进度卡片和辅助功能标识 `phase` 都读它。

```
idle ──save(text:)──▶ parsing ──▶ downloading ──▶ saving(i, n) ──▶ finished
                         │  ▲          │               │
                         ▼  │          ▼               ▼
                     waitingUser ◀─────┴───────────────┘        任何一步出错 ──▶ failed
                    （回答后回到之前的阶段）                      点取消 ──────▶ cancelled
```

- `isRunning` 仍然单独存在（`save(text:)` 进入到返回之间为真），`phase` 在它之内细分。
- `finished / failed / cancelled` 会一直留到下一次保存开始。
- `downloading` 只有 yt-dlp 的作品会经过（`ParsedNote.fetch` 不为空）。

### 2. 等用户回答（隐式）

`SaveService` 里五个可空变量各对应一种界面：`prompt`（弹窗）、`previewRequest`（预览）、`albumRequest`（选相册）、`capture`（抖音浏览器）、`webCapture`（通用浏览器）；前三个各配一个 continuation。

登录页不在这里：登录和 cookie 相关的界面都在设置页。保存失败需要登录时，流程**结束**（不等待），同时设置 `loginRequest` 和 `selectedTab`，由 `SettingsView.openRequestedLogin` 打开登录页；用户登录后自己再保存一次。

规则：
- 同一时间最多一个不为空（流程是串行的，没有类型保证）。
- 每个 continuation **必须恰好恢复一次**。新增一种等待时，一定要在 `cancel()` 里加上收掉它的那一行，否则取消后流程会永远卡住。
- 所有等待都要包在 `waiting { }` 里，阶段才会变成 `waitingUser`。

### 3. 「本次全部改存替代版本」（隐式）

`SaveService.useFallbackForAll`：每次保存开始时为假；用户在「拿不到原图」的弹窗里选了「本次全部改存」后变真，之后这一次保存不再问。只在 `fileFor` 里读写。

### 4. 媒体项的状态（隐式：`NoteMedia`）

没有状态字段，靠哪些属性有值来区分：

| 状态 | 特征 |
|---|---|
| 占位（yt-dlp 还没下载） | `original`、`fallback` 为空，`localFile`、`error` 为空（`preview` 可能有封面） |
| 待下载 | `original` 或 `fallback` 有地址 |
| 已在本地 | `localFile` 有值 |
| 已失败 | `error` 有值（保存时直接算失败） |

`fileFor` 按 `error` → `localFile` → `original` → `fallback` 的顺序判断。`kind == .live` 时 `liveVideoURLs` 必须有值。

### 5. 先解析后下载（隐式，跨 Swift 和 Python）

`ParsedNote.fetch` 不为空 = 还没下载。Python 那边对应模块级变量 `dlcore._PENDING`：`probe` 写入，`fetch` 取走并清空。

`fetch` 的参数是预览页选中的下标（`items` 里的位置）：不为空时只下载选中的，而且不再问「超过 20 项要不要全部保存」；为空表示没有经过预览。不用 `fetch` 的作品（地址已经在 `items` 里）由 `SaveService` 直接筛掉没选的项。

规则：`probe` 和 `fetch` 必须成对、按顺序、同一时间只有一组（Python 调用都排在 `YtDlp.queue` 这一个串行队列上，加上 `isRunning` 保证了这一点）。`fetch` 之后不能再 `fetch`，要换清晰度就重新 `probe`。

### 6. 取消（隐式，三处要同步）

Swift 的任务取消标志、工作目录里的 `cancel` 空文件（给 Python 看）、`XHSError.kind == .cancelled`。

规则：`SaveService.cancel()` 是唯一入口；Python 只在进度回调和各步骤之间检查，解析阶段停不下来；流程里每个「等待之后」「出错之后」都要 `try checkCancelled()`，否则取消会被当成普通失败继续问用户。

### 7. 账号的登录状态（部分显式：`CookiePool.Health`）

`Health` 有四种：正常、已过期、未登录、无法判断。设置页的一行还叠加了两样：`onlineResults`（在线验证：没验过 / 通过 / 没通过）和 `WebAccount.lastExport`（为空 = App 内账号还没登录过）。三者合起来才决定图标和文字，逻辑在 `SettingsView.accountRow`。

规则：只有「已过期」和「未登录」算 `needsLogin`；「无法判断」不提示补登。

### 8. 账号轮换（隐式）

`cookies/.next` 文件里一个数字，每次 `CookiePool.candidates(for:)`（`rotate: true`）加一。所有网站共用这一个计数，所以不同网站之间会互相推进。只想看候选不想推进时传 `rotate: false`。

### 9. Python 运行时（隐式：`PythonBridge.m`）

`gStarted` / `gStartError`：没启动 → 启动成功，或启动失败。**启动失败是永久的**（同一次 App 运行里不会重试）。yt-dlp 用哪一份由 `Documents/ytdlp/yt-dlp.zip` 存不存在决定，更新或恢复后要调 `dlcore.reload` 清掉已导入的模块。gallery-dl 同理：`Documents/ytdlp/gallery-dl.zip` 和 `dlcore.gdl_reload`；它的 zip 不是启动时加进搜索路径的，而是每次调用由 `dlcore._gdl_path` 调整。gallery-dl 的配置是模块级的全局状态，每次调用开头由 `_gdl_setup` 整个重设。

### 10. 内置浏览器读取（隐式：`DouyinCapture`、`WebCapture`）

`continuation` 不为空 = 还在等数据。20 秒没等到只改提示文字，不会自动失败；结束（拿到数据或取消）时移除消息处理器并停止加载。`finish` 保证只恢复一次。

### 11. 相册权限（隐式）

系统的两种授权互相独立：「添加照片」够用来保存；「完整访问」才能读已有相册名、才有相册归类和实况回读检查。没有完整访问时保存流程照常，只是跳过归类。

### 12. 下载记录（隐式）

`history.json` 里有这个作品的键 = 保存过。只在「存了东西而且没有失败项」时写入；用户主动跳过的项不算失败。

### 13. 日志文字当作事件（隐式，脆弱）

进度分三份：`log` 是关键节点（下载页默认显示），`details` 是完整过程（点开才显示），`latest` 是最新的一行（保存时显示在进度下面）。`say(_:detail:)` 的 `detail: true` 表示这一行只是细节。新加的进度默认算细节，只有「解析到了什么、存了什么、哪里失败」才算关键节点。

`SaveService.log` 是纯文字，界面靠开头判断样式（`✅`、`❌`、`⚠️`、`失败`、`下载中`，见 `ContentView.LogRow`）；补登提示靠在错误说明里找「登录」「403」等字样（`looksLikeAuth`）。

规则：自己代码里抛的错误用 `XHSError.kind` 分类，不要靠文字；改日志文字的开头前先看 `LogRow`。

### 14. 选相册页（隐式：`AlbumChoiceView`）

`albumName` 跟着账号信息自动生成（`generated` 一变就覆盖手改的内容）；`searched` 记录点过「重新查找」；`confirming` 是待确认的已有相册；`working` 是正在重命名。

### 15. yt-dlp 日志读取位置（隐式）

`YtDlp.logged` 里的 `shown`：已经显示到日志文件的第几行。每次调用用自己的日志文件，不能复用。

### 16. 实况工具页（隐式：`LiveToolsView`）

`video` 为空 = 还没选视频；`busy` = 正在生成；`status` 文字兼作结果显示。互相独立，没有跨页面的状态。

### 17. 发布（隐式，仓库外的脚本依赖它）

`build.yml` 更新 release「latest」的顺序是：移动标签 → 覆盖 ipa → **最后**改标题。标题「最新版（日期 · 7 位提交号）」变了就表示新包已经就绪，等待脚本靠它判断，格式不能变。

### 18. 解析器的选择（隐式）

`Extractors.all` 的顺序就是优先级，`GenericExtractor` 必须在最后（它什么都接：先 gallery-dl，再 yt-dlp）。Instagram 没登录时退回 yt-dlp，X 和微博依次试 gallery-dl、yt-dlp、内置浏览器，快手依次试直接请求、内置浏览器、yt-dlp，这些组合写在各自的解析器里。`galleryNote` 返回空表示「这条路不通，接着用下一种」，不是出错。
