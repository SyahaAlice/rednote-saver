# dlcore.py —— App 内嵌的通用下载器（yt-dlp），逻辑来自 phone/dl.py
# Swift 通过 PythonBridge 调用这里的函数，参数和返回值都是 JSON 字符串。
#
# 与 dl.py 的区别：iOS 上没有 ffmpeg，所以视频和音频分开的网站（B 站、YouTube 等）
# 会把两条流分别下载下来，由 Swift 端用 AVFoundation 合并。
#
# 下载分两步：probe 只解析（拿到标题、作者、作品 ID），fetch 才真正下载。
# 这样 App 可以在下载之前先查重、选相册。两步之间的解析结果存在 _PENDING 里。
# 多图 / 多视频帖子、合集里的每一项都会下载（最多 MAX_ENTRIES 项）。

import copy
import json
import os
import sys
import traceback

# iPhone 能直接播放、AVFoundation 能合并的视频编码：H.264 和 HEVC。
# VP9 / AV1 相册不认，也合并不了，只在没有别的选择时才用
_OK = "vcodec~='^(avc|hvc|hev)'"

# 清晰度优先：先比分辨率，再比帧率；分辨率和帧率都一样时选 H.264（兼容性最好），
# 所以只有在 HEVC 能给出更高清晰度时才会用 HEVC（比如 B 站的 4K）
FORMAT_SORT = ["res", "fps", "vcodec:h264"]


def _format(max_h):
    """max_h 是清晰度上限（画面高度），0 / None = 不限，取网站给的最高清晰度"""
    h = f"[height<={int(max_h)}]" if max_h else ""
    return (
        f"bv*[{_OK}]{h}+ba[ext=m4a]/"   # 视频和音频分开的网站（B 站、YouTube）：最高清的视频 + m4a 音频
        f"b[{_OK}]{h}/"                 # 音视频在一个文件里的
        f"b[ext=mp4]{h}/"
        f"bv*{h}+ba/"                   # 其它编码：能下载，但 iPhone 多半合并不了或相册不收
        "b"
    )


class _Log:
    """把 yt-dlp 的输出写进日志文件，Swift 端每隔半秒读一次显示进度"""

    def __init__(self, path):
        self.fp = open(path, "a", encoding="utf-8") if path else None

    def write(self, msg):
        if self.fp:
            self.fp.write(msg.rstrip() + "\n")
            self.fp.flush()

    # yt-dlp logger 接口
    def debug(self, msg):
        if not msg.startswith("[debug] "):
            self.write(msg)

    def info(self, msg):
        self.write(msg)

    def warning(self, msg):
        self.write("警告：" + msg)

    def error(self, msg):
        self.write("错误：" + msg)

    def close(self):
        if self.fp:
            self.fp.close()


class _Cancel:
    """取消标志：Swift 端在用户点「取消」时建一个空文件。
    Python 调用没法从外面打断，只能在进度回调和各步骤之间自己检查"""

    def __init__(self, path):
        self.path = path

    def hit(self):
        return bool(self.path) and os.path.exists(self.path)


def _progress(log, cancel):
    last = {"pct": -10}

    def hook(d):
        if cancel.hit():
            import yt_dlp
            raise yt_dlp.utils.DownloadCancelled("已取消")
        if d.get("status") == "downloading":
            total = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
            done = d.get("downloaded_bytes") or 0
            if total:
                pct = int(done * 100 / total)
                if pct >= last["pct"] + 10:
                    last["pct"] = pct
                    log.write(f"下载中 {pct}%（{done // 1048576} / {total // 1048576} MB）")
        elif d.get("status") == "finished":
            last["pct"] = -10
            log.write("一条流下载完成")

    return hook


def version(_=None):
    import yt_dlp
    return json.dumps({
        "yt_dlp": yt_dlp.version.__version__,
        "python": sys.version.split()[0],
        "source": os.path.dirname(os.path.dirname(yt_dlp.__file__)),
    }, ensure_ascii=False)


def reload(args_json):
    """更新 yt-dlp 之后重新加载：清掉已导入的模块，按新的 sys.path 重新导入"""
    a = json.loads(args_json or "{}")
    zip_path = a.get("zip")
    sys.path[:] = [p for p in sys.path if not p.endswith("yt-dlp.zip")]
    if zip_path and os.path.exists(zip_path):
        sys.path.insert(0, zip_path)
    for name in list(sys.modules):
        if name == "yt_dlp" or name.startswith("yt_dlp."):
            del sys.modules[name]
    return version()


# 一个链接最多保存多少项。多图 / 多视频帖子远小于这个数（Instagram 最多 20、微博 18）；
# 只是防止贴了一个几百集的合集链接时一口气全下
MAX_ENTRIES = 100

# probe 解析好、等 fetch 来下载的内容（同一个解释器里，两次调用之间一直在）
_PENDING = None


def _fail(msg):
    return json.dumps({"ok": False, "error": msg}, ensure_ascii=False)


def _cancelled():
    return json.dumps({"ok": False, "error": "已取消", "cancelled": True}, ensure_ascii=False)


def _opts(a, log, cancel, ck, out_dir=None):
    opts = {
        "outtmpl": os.path.join(out_dir or a["out_dir"], "%(extractor_key)s_%(id)s.f%(format_id)s.%(ext)s"),
        "format": a.get("format") or _format(a.get("max_height")),
        "format_sort": FORMAT_SORT,
        "noplaylist": True,  # 链接同时指向一个视频和它所在的合集时，只要这个视频
        "playlistend": MAX_ENTRIES,
        "restrictfilenames": True,
        "overwrites": True,
        "logger": log,
        "progress_hooks": [_progress(log, cancel)],
        "noprogress": True,  # 进度由 _progress 每 10% 写一行
        "cachedir": a.get("cache_dir") or False,
    }
    if ck:
        opts["cookiefile"] = ck
    return opts


def _strip(info):
    """去掉上一次选格式 / 下载留下的字段，得到可以重新处理的原始信息"""
    raw = dict(info)
    for k in ("requested_formats", "requested_downloads"):
        raw.pop(k, None)
    return raw


def _extract(url, opts):
    """只解析不下载。返回（[(原始信息, 选好格式的信息), ...]，帖子 / 合集本身的信息或 None）。
    多图 / 多视频帖子、合集里的每一项都在列表里"""
    import yt_dlp
    with yt_dlp.YoutubeDL(opts) as ydl:
        top = ydl.extract_info(url, download=False, process=False)
        if top.get("_type") in ("playlist", "multi_video"):
            done = ydl.process_ie_result(top, download=False)
            entries = [e for e in (done.get("entries") or []) if e]
            if not entries:
                raise Exception("这个链接里没有可下载的视频")
            return [(_strip(e), e) for e in entries], done
        return [(top, ydl.process_ie_result(copy.deepcopy(top), download=False))], None


def _download(raw, chosen, opts):
    """把选好的每条流分别下载下来（音视频分开的由 Swift 端合并）"""
    import yt_dlp
    parts = chosen.get("requested_formats") or [chosen]
    streams = []
    for f in parts:
        one = dict(opts, format=f["format_id"])
        with yt_dlp.YoutubeDL(one) as ydl:
            res = ydl.process_ie_result(_strip(copy.deepcopy(raw)), download=True)
            dl = (res.get("requested_downloads") or [{}])[0]
            path = dl.get("filepath") or ydl.prepare_filename(res)
        streams.append({
            "path": path,
            "ext": f.get("ext"),
            "vcodec": f.get("vcodec") or "none",
            "acodec": f.get("acodec") or "none",
        })
    return streams


def _account(ck):
    return "使用账号：" + (os.path.basename(ck) if ck else "无（游客）")


def _meta(items, top):
    """作品信息。多项时作品 ID 和标题用帖子本身的（查重按帖子算），作者等信息以第 1 项为准"""
    first = items[0][1]
    multi = top if (top and len(items) > 1) else {}

    def g(*keys):
        for src in (first, top or {}):
            for k in keys:
                if src.get(k):
                    return src[k]
        return None

    ident = multi.get("id") or first.get("id")
    key = g("extractor_key") or ""
    return {
        "id": ident,
        "title": multi.get("title") or first.get("title") or ident,
        "extractor": key,
        # 作者：昵称可能重复，ID 通常唯一（相册归类用）
        "uploader": g("uploader", "channel", "creator"),
        "uploader_ids": [str(x) for x in (g("uploader_id"), g("channel_id")) if x],
        # Instagram 的 uploader_id 是数字，用户名（@ 后面那个）在 channel 里
        "handle": g("channel") if key.startswith("Instagram") else None,
        "timestamp": g("timestamp", "release_timestamp"),
        "upload_date": g("upload_date"),
    }


def probe(args_json):
    """第一步：只解析。
    参数：url, out_dir, cookies（按顺序尝试的 cookies 文件列表，null 表示游客）, log, cache_dir, cancel,
          max_height（清晰度上限，0 = 不限）, format（直接指定 yt-dlp 的格式串，一般不用）
    返回：{"ok": true, "id", "title", "extractor", "uploader", ...,
           "entries": 链接里的项数, "more": 是否可能还有超出 MAX_ENTRIES 的没算进来}"""
    global _PENDING
    _PENDING = None
    a = json.loads(args_json)
    log = _Log(a.get("log"))
    cancel = _Cancel(a.get("cancel"))
    try:
        cookies = a.get("cookies") or [None]
        last_err = None
        for i, ck in enumerate(cookies):
            if cancel.hit():
                return _cancelled()
            log.write(_account(ck))
            try:
                items, top = _extract(a["url"], _opts(a, log, cancel, ck))
            except Exception as e:  # 这个账号不行就换下一个，全部失败再报错
                last_err = e
                log.write(f"失败：{e}")
                continue
            _PENDING = {"args": a, "cookies": cookies, "index": i, "items": items}
            return json.dumps(dict(_meta(items, top), ok=True, entries=len(items),
                                   more=len(items) >= MAX_ENTRIES), ensure_ascii=False)
        return _fail(str(last_err))
    except Exception as e:
        log.write(traceback.format_exc())
        return _fail(f"{type(e).__name__}: {e}")
    finally:
        log.close()


def fetch(args_json):
    """第二步：下载 probe 解析好的内容，链接里的每一项都下载。
    参数：log, cancel, limit（只下载前几项；不传就是全部）
    返回：{"ok": true, "items": [{"streams": [{"path", "vcodec", "acodec", "ext"}]} 或 {"error": "..."}, ...]}
    每一项放在各自的子文件夹里。某一项失败不影响其它项，失败的那一项带 error。
    用解析成功的那个账号下载；一项都没成功就按顺序换后面的账号，重新解析再下载"""
    global _PENDING
    p, _PENDING = _PENDING, None
    if not p:
        return _fail("没有待下载的内容")
    b = json.loads(args_json or "{}")
    a = p["args"]
    log = _Log(b.get("log") or a.get("log"))
    cancel = _Cancel(b.get("cancel") or a.get("cancel"))
    limit = b.get("limit")
    try:
        cookies = p["cookies"]
        items = p["items"]
        last_err = None
        for i in range(p["index"], len(cookies)):
            if cancel.hit():
                return _cancelled()
            if i > p["index"]:
                log.write(_account(cookies[i]))
                try:
                    items, _ = _extract(a["url"], _opts(a, log, cancel, cookies[i]))
                except Exception as e:
                    last_err = e
                    log.write(f"失败：{e}")
                    continue
            todo = items[:limit] if limit else items
            out = []
            for n, (raw, chosen) in enumerate(todo, 1):
                if cancel.hit():
                    return _cancelled()
                if len(todo) > 1:
                    log.write(f"第 {n} / {len(todo)} 项")
                sub = os.path.join(a["out_dir"], f"{n:03d}")
                os.makedirs(sub, exist_ok=True)
                try:
                    out.append({"streams": _download(raw, chosen, _opts(a, log, cancel, cookies[i], sub))})
                except Exception as e:
                    if cancel.hit():
                        return _cancelled()
                    last_err = e
                    log.write(f"失败：{e}")
                    out.append({"error": str(e)})
            if any("streams" in o for o in out):
                return json.dumps({"ok": True, "items": out}, ensure_ascii=False)
        return _fail(str(last_err))
    except Exception as e:
        log.write(traceback.format_exc())
        return _fail(f"{type(e).__name__}: {e}")
    finally:
        log.close()
