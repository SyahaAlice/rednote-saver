# 小红书保存（XHSSaver）

一个完全由你自己掌控的 iOS App：把小红书笔记里的**原图、原视频和实况图**存进相册，实况图存成**真正可以长按播放的实况照片**。

- 只用 Apple 系统框架（URLSession、AVFoundation、PhotoKit、App Intents），没有第三方库，也不连接任何第三方服务器。
- 以游客身份请求笔记页，和 `phone/dl.py` 的做法一致。
- 实况照片在手机本地合成：先给图片写入 Apple MakerNote 配对 ID，再给视频写入 QuickTime content identifier 和 still-image-time 元数据轨道，最后用 PhotoKit 把两者作为同一个项目导入相册。

## 目录

| 路径 | 内容 |
|---|---|
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
3. 编译完成后，打开那次运行记录，在页面底部 **Artifacts** 下载 `XHSSaver-ipa`，解压得到 `XHSSaver.ipa`。

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

- **App 里**：复制小红书分享文案或链接 → 打开「小红书保存」→ 点 **粘贴** → **保存到相册**。
- **分享菜单一键保存**：
  1. 打开「快捷指令」，新建一个快捷指令。
  2. 点底部 **ⓘ（简介）**，打开 **在共享表单中显示**，接收类型勾选 **URL** 和 **文本**。
  3. 添加操作 **保存小红书笔记**（来自「小红书保存」），把参数设成「快捷指令输入」。
  4. 在小红书里点分享 → 复制链接 → 也可以在其他 App 的分享菜单里直接选这个快捷指令。
- 保存时 App 会被打开到前台，进度会显示在页面上。

| 笔记类型 | 保存结果 |
|---|---|
| 图文笔记 | 每张图的原图（通常是 HEIC） |
| 含实况图的笔记 | 实况图存成实况照片；普通图存原图 |
| 视频笔记 | 原视频，拿不到时改存网页版视频 |

## 五、离线检查解析逻辑

```bash
python tools/parse_proto.py --html 已保存的笔记网页.html 笔记ID
```
