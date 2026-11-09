# dlcore.py —— App 内嵌的通用下载器（yt-dlp），逻辑来自 phone/dl.py
# Swift 通过 PythonBridge 调用这里的函数，参数和返回值都是 JSON 字符串。
#
# 与 dl.py 的区别：iOS 上没有 ffmpeg，所以视频和音频分开的网站（B 站、YouTube 等）
# 会把两条流分别下载下来，由 Swift 端用 AVFoundation 合并。

import copy
import json
import os
import sys
import traceback

MAX_H = 1080
# 优先 H.264 + AAC（iPhone 相册兼容最好），其次 HEVC，最后才是其它格式
FORMAT = (
    f"bv*[vcodec^=avc][height<={MAX_H}]+ba[ext=m4a]/"
    f"b[vcodec^=avc][height<={MAX_H}]/"
    f"bv*[vcodec~='^(hvc|hev)'][height<={MAX_H}]+ba[ext=m4a]/"
    f"b[ext=mp4][height<={MAX_H}]/"
    f"bv*[height<={MAX_H}]+ba/"
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


def _progress(log):
    last = {"pct": -10}

    def hook(d):
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


def _single(raw, ydl):
    """播放列表/合集只取第一项（与 dl.py 的 noplaylist 一致）"""
    if raw.get("_type") in ("playlist", "multi_video"):
        done = ydl.process_ie_result(copy.deepcopy(raw), download=False)
        entries = [e for e in (done.get("entries") or []) if e]
        if not entries:
            raise Exception("这个链接里没有可下载的视频")
        entry = dict(entries[0])
        for k in ("requested_formats", "requested_downloads"):
            entry.pop(k, None)
        return entry
    return raw


def download(args_json):
    """参数：url, out_dir, cookies（按顺序尝试的 cookies 文件列表，null 表示游客）, log, cache_dir, format
    返回：{"ok": true, "title", "extractor", "streams": [{"path", "vcodec", "acodec", "ext"}]}"""
    a = json.loads(args_json)
    log = _Log(a.get("log"))
    try:
        import yt_dlp
        base = {
            "outtmpl": os.path.join(a["out_dir"], "%(extractor_key)s_%(id)s.f%(format_id)s.%(ext)s"),
            "format": a.get("format") or FORMAT,
            "noplaylist": True,
            "restrictfilenames": True,
            "overwrites": True,
            "logger": log,
            "progress_hooks": [_progress(log)],
            "noprogress": True,  # 进度由 _progress 每 10% 写一行
            "cachedir": a.get("cache_dir") or False,
        }
        last_err = None
        for ck in a.get("cookies") or [None]:
            opts = dict(base)
            if ck:
                opts["cookiefile"] = ck
            log.write("使用账号：" + (os.path.basename(ck) if ck else "无（游客）"))
            try:
                with yt_dlp.YoutubeDL(opts) as ydl:
                    raw = _single(ydl.extract_info(a["url"], download=False, process=False), ydl)
                    chosen = ydl.process_ie_result(copy.deepcopy(raw), download=False)
                parts = chosen.get("requested_formats") or [chosen]
                streams = []
                for f in parts:
                    one = dict(opts, format=f["format_id"])
                    with yt_dlp.YoutubeDL(one) as ydl:
                        info = copy.deepcopy(raw)
                        for k in ("requested_formats", "requested_downloads"):
                            info.pop(k, None)
                        res = ydl.process_ie_result(info, download=True)
                        dl = (res.get("requested_downloads") or [{}])[0]
                        path = dl.get("filepath") or ydl.prepare_filename(res)
                    streams.append({
                        "path": path,
                        "ext": f.get("ext"),
                        "vcodec": f.get("vcodec") or "none",
                        "acodec": f.get("acodec") or "none",
                    })
                return json.dumps({
                    "ok": True,
                    "id": chosen.get("id"),
                    "title": chosen.get("title") or chosen.get("id"),
                    "extractor": chosen.get("extractor_key"),
                    # 作者：昵称可能重复，ID 通常唯一（相册归类用）
                    "uploader": chosen.get("uploader") or chosen.get("channel") or chosen.get("creator"),
                    "uploader_ids": [str(x) for x in (chosen.get("uploader_id"), chosen.get("channel_id")) if x],
                    "timestamp": chosen.get("timestamp") or chosen.get("release_timestamp"),
                    "upload_date": chosen.get("upload_date"),
                    "streams": streams,
                }, ensure_ascii=False)
            except Exception as e:  # 这个账号不行就换下一个，全部失败再报错
                last_err = e
                log.write(f"失败：{e}")
        return json.dumps({"ok": False, "error": str(last_err)}, ensure_ascii=False)
    except Exception as e:
        log.write(traceback.format_exc())
        return json.dumps({"ok": False, "error": f"{type(e).__name__}: {e}"}, ensure_ascii=False)
    finally:
        log.close()
