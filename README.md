# 小红书保存（XHSSaver）

一个完全由你自己掌控的 iOS App，替代已失效的「小红书助手pro」和 HyperTaps：

- **下载**：小红书笔记的原图、原视频，实况图自动存成**真正可以长按播放的实况照片**；其它网站（B 站、抖音、微博、X、Instagram、YouTube 等）用内置的 **yt-dlp** 下载。
- **实况工具**：视频转实况（截取最长 5 秒、可选封面帧）、实况拆分（拆成照片 + 视频）。
- **号池**：电脑上整理好的 cookies 文件放进 App 的 `cookies` 文件夹即可使用，换 cookie 不用重新安装。
- **原图优先**：原图 / 原片拿不到时会先问你，同意后才改存网页压缩版。

实况照片在手机本地合成：图片写入 Apple MakerNote 配对 ID，视频写入 QuickTime content identifier 和 still-image-time 元数据轨道，再用 PhotoKit 作为同一个项目导入相册。不依赖任何第三方合成模块或服务器。

## 目录

| 路径 | 内容 |
|---|---|
| `XHSSaver/NoteParser.swift` | 小红书：跟随短链、请求笔记页、解析 `__INITIAL_STATE__` |
| `XHSSaver/CookiePool.swift` | 号池：读取 Netscape cookies、按网站挑账号轮换（与 `dl.py` 规则相同） |
| `XHSSaver/YtDlp.swift`、`app/dlcore.py` | 内嵌 Python 3.13 上的 yt-dlp |
| `XHSSaver/PythonBridge.m` | Swift ↔ Python 的桥接（Python 官方嵌入接口） |
| `XHSSaver/LivePhotoMaker.swift` | 写入实况配对标记（不重新编码视频） |
| `XHSSaver/LiveTools.swift` | 视频转实况、实况拆分、音视频合并（代替 ffmpeg） |
| `XHSSaver/SaveService.swift` | 保存流程、替代版本确认、进度显示 |
| `XHSSaver/SaveNoteIntent.swift` | 快捷指令操作「保存小红书笔记」 |
| `tools/gen_project.py` | 生成 Xcode 工程文件（增删源文件后运行一次） |
| `tools/parse_proto.py` | 小红书解析逻辑的 Python 原型，可离线检查已保存的网页 |
| `.github/workflows/build.yml` | 在 GitHub 的 macOS 机器上编译未签名 .ipa |

编译时 CI 会下载固定版本的 Python iOS 支持包（BeeWare 打包的 CPython 3.13，校验 SHA-256），并用 pip 装入 yt-dlp 和 certifi。安装包因此约几十 MB。

---|---|
| `XHSSaver/NoteParser.swift` | 跟随短链、请求笔记页、解析 `__INITIAL_STATE__` |
| `XHSSaver/Downloader.swift` | 下载，按顺序尝试原图/原片和备用地址 |
| `XHSSaver/LivePhotoMaker.swift` | 写入实况配对标记（不重新编码视频） |
| `XHSSaver/PhotoSaver.swift` | PhotoKit 入库（只申请「添加照片」权限） |
| `XHSSaver/SaveService.swift` | 整个保存流程和进度显示 |
| `XHSSaver/SaveNoteIntent.swift` | 快捷指令操作「保存小红书笔记」 |
| `tools/parse_proto.py` | 解析逻辑的 Python 原型，可离线检查已保存的网页 |
| `.github/workflows/build.yml` | 在 GitHub 的 macOS 机器上编译未签名 .ipa |

---

## 一、编译（GitHub Actions）

iOS App 只能在 macOS 上编译，所以借用 GitHub 提供的 macOS 机器。

1. 在 GitHub 上新建一个仓库，把本目录（`ios-app`）里的全部内容作为仓库根目录推上去。
   - **公开仓库**：macOS 编译完全免费，不限分钟数。代码别人能看到，但里面没有任何账号、密码或密钥。
   - **私有仓库**：免费账号每月 2000 分钟额度，macOS 按 **10 倍**消耗，相当于每月约 200 分钟；一次编译大约 3–5 分钟，够用。
2. 每次推送代码都会自动编译。也可以在仓库的 **Actions → Build unsigned IPA → Run workflow** 手动运行。
3. 编译完成后，main 分支的 ipa 会自动发布到仓库的 **Releases → latest**，直接下载 `XHSSaver.ipa` 即可，不用登录：
   `https://github.com/SyahaAlice/rednote-saver/releases/download/latest/XHSSaver.ipa`
   - 每次运行记录页面底部的 **Artifacts** 里也有一份（需要登录 GitHub 才能下载）。

## 二、第一次安装（只需做一次，约 30–40 分钟）

> 所有需要输入 Apple ID 密码的步骤都由你本人操作。建议**专门注册一个 Apple ID 小号**，因为它的密码会保存在 AltServer 里。

### 电脑（Windows）

1. 从 **Apple 官网**下载安装 **iTunes** 和 **iCloud**。
   - 不能用微软商店版，否则 AltServer 识别不到手机。如果已经装了商店版，先卸载再装官网版。
2. 从 altstore.io 下载安装 **AltServer**。
   - 运行后它会常驻在任务栏右下角。
   - 把它加入开机自启：按 `Win + R` 输入 `shell:startup`，把 AltServer 的快捷方式放进去。
3. 用数据线连接 iPhone，在手机上点「信任此电脑」。
4. 打开 iTunes，点手机图标，在「摘要」里勾选 **「通过 Wi‑Fi 与此 iPhone 同步」**，然后点「应用」。
   - 这一步决定了以后能不能**无线自动续签**。
5. 点任务栏的 AltServer 图标 → **Install AltStore** → 选择你的 iPhone，然后输入 Apple ID 小号和密码（你本人输入）。

### 手机

6. **设置 → 隐私与安全性 → 开发者模式**：打开，手机会重启，重启后确认开启。
7. **设置 → 通用 → VPN 与设备管理**：点你的 Apple ID，选「信任」。
8. 现在主屏幕上应该有 AltStore 了。

### 安装小红书保存

9. 两种方式，任选一种：
   - **电脑上装**：点任务栏 AltServer 图标，按住 `Shift` 点 **Sideload .ipa…**（新版本直接点 **Sideload .ipa…**），选择你的 iPhone 和 `XHSSaver.ipa`。
   - **手机上装**：把 `XHSSaver.ipa` 存到手机「文件」App 里，打开 AltStore → **My Apps** → 左上角 **+** → 选择这个 ipa。
10. 第一次打开 App、点保存时，会询问「添加照片」权限，选**允许**。

> **安装报错怎么办**
> - `The app could not be found`：ipa 所在路径里有中文。把 ipa 放到纯英文路径（例如 `D:\Apple\XHSSaver.ipa`）再选。
> - `The name for this app is invalid`：旧版本的问题（App 名称是中文），用最新的 ipa 即可。
> - `WinHttpReceiveResponse: 12030`：连接 Apple 服务器时网络中断，重试一次。

> 免费账号最多同时装 3 个侧载 App，AltStore 自己占 1 个。

## 三、每周自动续签

免费证书 **7 天过期**。过期后 App 打不开，但数据和相册里的照片都不受影响，续签后就能恢复。

**AltStore 会自动续签**，只要同时满足：

- 电脑开着，AltServer 在运行（已设开机自启）；
- 手机和电脑连在**同一个 Wi‑Fi**；
- 已经勾选「通过 Wi‑Fi 与此 iPhone 同步」。

系统的后台刷新时间不太可控，建议再加一个**快捷指令自动化**，让续签更可靠：

1. 打开「快捷指令」→ 底部 **自动化** → 右上角 **+**。
2. 触发条件选 **充电器 → 已连接**，或者 **特定时间 → 每天凌晨 3:00**。
3. 选择 **立即运行**，关闭「运行前通知」。
4. 添加操作：搜索 AltStore，选 **Refresh All Apps**。

**手动续签**：打开 AltStore → My Apps → 左上角 **Refresh All**，大约 1 分钟。每个 App 下方会显示还剩几天到期。

**出门在外**：如果 7 天内都连不上家里的电脑，App 会过期。回家连上同一个 Wi‑Fi 后点 Refresh All 就能恢复。

**备用方案**：AltStore 出问题时，可以用 Windows 上的 **Sideloadly** 手动重签同一个 ipa，每周大约 2 分钟。

## 四、使用

### 下载

- **App 里**：复制分享文案或链接 → 打开「小红书保存」→ **粘贴** → **保存到相册**。
- **分享菜单一键保存**：
  1. 打开「快捷指令」，新建一个快捷指令。
  2. 点底部 **ⓘ（简介）**，打开 **在共享表单中显示**，接收类型勾选 **URL** 和 **文本**。
  3. 添加操作 **保存小红书笔记**（来自「小红书保存」），参数设成「快捷指令输入」。
  4. 在小红书、B 站等 App 里点分享，选这个快捷指令。
- 保存时 App 会被打开到前台，进度显示在「下载」页。

| 来源 | 保存结果 |
|---|---|
| 小红书图文 | 每张图的原图（通常是 HEIC） |
| 小红书实况图 | 实况照片；普通图存原图 |
| 小红书视频 | 原视频 |
| 其它网站 | yt-dlp 下载，优先 H.264 + AAC、最高 1080p；音视频分开的自动合并。相册不支持的格式存到「文件 → 小红书保存 → 下载」 |

**原图 / 原片拿不到时**会弹窗询问：改存这一项、本次全部改存替代版本，或跳过。实况合成失败时也会先问你是否只存静态图。

### 实况工具

- **视频转实况**：从相册或「文件」选一段视频，拖动滑块选开始位置、时长（最长 5 秒）和封面帧，生成实况照片存进相册。
- **实况拆分**：选一张实况照片，拆成一张照片 + 一段视频存进相册，并在「文件 → 小红书保存 → 实况拆分」里各留一份。

### 号池（cookies）

App 的文件夹会出现在「文件 → 我的 iPhone → 小红书保存」里，号池就在其中的 `cookies` 文件夹：

1. 电脑上照旧用 Get cookies.txt LOCALLY 导出，再用 `merge_cookies.py` 把同一账号的多个域名合并成一个 `.txt`。
2. 把文件推到手机（Bundle ID 在 App 的「设置」页里能看到，AltStore 会在原 ID 后面加上你的团队 ID）：
   ```bash
   opendevice afc push --app <Bundle ID> --documents cookies/merged/au.txt /cookies/
   ```
   或者用 AirDrop / 「文件」App 直接拷进 `cookies` 文件夹。
3. 「设置」页会列出每个账号文件包含哪些网站、有没有登录凭证（只显示名字，不显示内容）。

规则与 `phone/dl.py` 相同：按网址自动挑出对应网站的账号轮流使用；小红书**先用游客**（游客能拿到原片），失败才用账号；其它网站账号优先、游客垫底。

> cookie 只存在手机上，不会进入仓库或安装包。仓库和 ipa 都是公开的，**不要把 cookies 文件提交到 GitHub**。

### 更新 yt-dlp

网站改版导致下载失败时，打开「设置 → 更新 yt-dlp 到最新版」，App 会从 yt-dlp 官方 GitHub 下载最新版并立即生效，不用重新安装。出问题时可以「恢复内置版本」。

## 五、离线检查解析逻辑

```bash
python tools/parse_proto.py --html 已保存的笔记网页.html 笔记ID
```
