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
     小红书           抖音         Instagram        X / 微博         其它网站
   NoteParser    DouyinCapture    WebCapture    yt-dlp → 不行再      yt-dlp
  （App 自己请求  （内置浏览器 +   （内置浏览器 +    WebCapture        （dlcore.py）
    笔记网页）     登录账号）       登录账号）
        └──────────────┴──────────────┴──────────────┴───────────────┘
                                            ▼
                              ParsedNote（所有网站统一的结果）
                                            ▼
        SaveService：查重 ─▶ 选相册 ─▶（yt-dlp 的作品在这里才下载）─▶ 逐项下载 / 实况合成 ─▶ 存进相册 ─▶ 记下载记录
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
| `Downloader.swift` | 下载单个文件，按文件头决定扩展名 |
| `LivePhotoMaker.swift`、`LiveTools.swift` | 实况照片配对、视频转实况、实况拆分、音视频合并 |
| `PhotoSaver.swift` | PhotoKit 入库、相册匹配和命名 |
| `CookiePool.swift`、`WebAccounts.swift` | 账号：cookies 文件、登录状态判断、App 内登录 |
| `Models.swift` | `ParsedNote`、`NoteMedia`、`Author`、`XHSError`、设置项、下载记录 |

## 每个网站取到的清晰度

| 网站 | 图片 | 视频 | 实况 | 需要登录 |
|---|---|---|---|---|
| 小红书 | 原图（HEIC） | 原片（`originVideoKey`） | 有 | 不需要（游客优先） |
| 抖音 | 最高分辨率 JPEG（没有原图） | `bit_rate` 里面积最大、码率最高的 mp4 | 有 | 必须 |
| Instagram | `image_versions2` 里面积最大的 | `video_versions` 里面积最大的 | 无 | 必须（否则只有 yt-dlp 的视频） |
| X | `name=orig` 原图 | mp4 里码率最高的 | 无 | 图片必须 |
| 微博 | `largest` → `original` → `mw2000` | `playback_list` 里面积最大的 | 有（实况图） | 图片建议登录 |
| 其它（yt-dlp） | 不支持 | 清晰度优先，见下 | 无 | 看网站 |

yt-dlp 的选格式规则在 `dlcore.py` 的 `_format` 和 `FORMAT_SORT`：只在 iPhone 能合并和播放的编码（H.264、HEVC）里选，先比分辨率、再比帧率，都一样时选 H.264。所以只有 HEVC 能给出更高清晰度时才用 HEVC。上限由「设置 → 其它网站视频清晰度」控制，默认不限。

**已知的不足**（改进时优先看这里）：

- X、微博的图片和视频混排帖子：yt-dlp 能拿到视频就不会再走内置浏览器，图片会漏掉。等内置浏览器这条路在真机上验证稳定后，可以改成内置浏览器优先。
- 快手、B 站动态图片等没有自己的解析器，只有 yt-dlp 的视频。
- 实况照片的封面图为了写入配对标记会重新编码一次（质量 0.95）。
- 下载是逐项串行的，没有断点续传；切到后台会中断。

## 新增一个网站

1. 视频为主的网站什么都不用做：yt-dlp 兜底。
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

`SaveService` 里五个可空变量各对应一种界面：`prompt`（弹窗）、`albumRequest`（选相册）、`loginAccount`（登录页）、`capture`（抖音浏览器）、`webCapture`（通用浏览器）；前三个各配一个 continuation。

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
| 占位（yt-dlp 还没下载） | `original`、`fallback` 为空，`localFile`、`error` 为空 |
| 待下载 | `original` 或 `fallback` 有地址 |
| 已在本地 | `localFile` 有值 |
| 已失败 | `error` 有值（保存时直接算失败） |

`fileFor` 按 `error` → `localFile` → `original` → `fallback` 的顺序判断。`kind == .live` 时 `liveVideoURLs` 必须有值。

### 5. 先解析后下载（隐式，跨 Swift 和 Python）

`ParsedNote.fetch` 不为空 = 还没下载。Python 那边对应模块级变量 `dlcore._PENDING`：`probe` 写入，`fetch` 取走并清空。

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

`gStarted` / `gStartError`：没启动 → 启动成功，或启动失败。**启动失败是永久的**（同一次 App 运行里不会重试）。yt-dlp 用哪一份由 `Documents/ytdlp/yt-dlp.zip` 存不存在决定，更新或恢复后要调 `dlcore.reload` 清掉已导入的模块。

### 10. 内置浏览器读取（隐式：`DouyinCapture`、`WebCapture`）

`continuation` 不为空 = 还在等数据。20 秒没等到只改提示文字，不会自动失败；结束（拿到数据或取消）时移除消息处理器并停止加载。`finish` 保证只恢复一次。

### 11. 相册权限（隐式）

系统的两种授权互相独立：「添加照片」够用来保存；「完整访问」才能读已有相册名、才有相册归类和实况回读检查。没有完整访问时保存流程照常，只是跳过归类。

### 12. 下载记录（隐式）

`history.json` 里有这个作品的键 = 保存过。只在「存了东西而且没有失败项」时写入；用户主动跳过的项不算失败。

### 13. 日志文字当作事件（隐式，脆弱）

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

`Extractors.all` 的顺序就是优先级，`YtDlpExtractor` 必须在最后（它什么都接）。Instagram 没登录时退回 yt-dlp、X 和微博先 yt-dlp 后内置浏览器，这两种组合写在各自的解析器里。
