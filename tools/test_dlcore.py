#!/usr/bin/env python3
"""app/dlcore.py 的离线测试：不访问外网，本机起一个小网站，用真的 yt-dlp 跑一遍。

用法（需要能 import yt_dlp；CI 里 yt-dlp 装在 app_packages/）：
    python tools/test_dlcore.py                 # yt_dlp 已经装在当前 Python 里
    python tools/test_dlcore.py app_packages    # 指定 yt-dlp（和 gallery-dl）所在的文件夹

覆盖的行为（App 的 Swift 端依赖这些约定，改 dlcore.py 之后务必跑一遍）：
- 选格式：清晰度优先，同清晰度选 H.264，只有更高清时才用 HEVC；上限生效；VP9 / AV1 只做最后退路
- probe 只解析不下载；fetch 才下载；fetch 之后不能再 fetch
- 一个链接里的多项全部下载，各放各的子文件夹；limit 只下前几项
- 某一项失败不影响其它项
- 取消：下载前、下载途中都返回 cancelled
- 解析失败时错误原样返回
- gallery-dl（装了才测）：只列出不下载、不支持的网址交还给 yt-dlp、微博实况图配对、不过滤内容
"""
import functools
import http.server
import json
import os
import shutil
import sys
import tempfile
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
for extra in sys.argv[1:]:
    sys.path.insert(0, os.path.abspath(extra))
sys.path.insert(0, os.path.join(ROOT, "app"))
sys.dont_write_bytecode = True

import dlcore  # noqa: E402
import yt_dlp  # noqa: E402

failures = []


def check(name, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + name + (f"  ← {detail}" if detail and not cond else ""))
    if not cond:
        failures.append(name)


# ---------------------------------------------------------------- 选格式

def fmt(fid, vcodec, acodec, height=None, fps=30, ext="mp4", tbr=1000):
    f = {"format_id": fid, "url": f"http://example.invalid/{fid}", "ext": ext, "protocol": "https",
         "vcodec": vcodec, "acodec": acodec, "tbr": tbr}
    if height:
        f.update(height=height, width=height * 16 // 9, fps=fps)
    return f


def pick(formats, max_h=0):
    """返回 dlcore 的选格式规则在这组格式里选中的 format_id 列表"""
    opts = {"format": dlcore._format(max_h), "format_sort": dlcore.FORMAT_SORT, "quiet": True,
            "simulate": True, "no_warnings": True}
    info = {"id": "x", "title": "x", "extractor": "test", "extractor_key": "Test", "webpage_url": "http://example.invalid/",
            "formats": [dict(f) for f in formats]}
    with yt_dlp.YoutubeDL(opts) as ydl:
        chosen = ydl.process_ie_result(info, download=False)
    return [f["format_id"] for f in (chosen.get("requested_formats") or [chosen])]


print("选格式")
split = [
    fmt("avc1080", "avc1.640028", "none", 1080), fmt("hevc1080", "hev1.1.6.L120.90", "none", 1080, tbr=800),
    fmt("hevc2160", "hev1.1.6.L153.90", "none", 2160, tbr=8000), fmt("av1-2160", "av01.0.12M.08", "none", 2160),
    fmt("vp9-2160", "vp9", "none", 2160, ext="webm"), fmt("avc720", "avc1.64001F", "none", 720),
    fmt("m4a", "none", "mp4a.40.2", ext="m4a", tbr=128), fmt("opus", "none", "opus", ext="webm", tbr=160),
]
check("不限：4K 只有 HEVC 时选 HEVC 4K + m4a", pick(split) == ["hevc2160", "m4a"], pick(split))
check("上限 1080：同清晰度选 H.264", pick(split, 1080) == ["avc1080", "m4a"], pick(split, 1080))
check("上限 720", pick(split, 720) == ["avc720", "m4a"], pick(split, 720))
no_hevc = [f for f in split if not f["format_id"].startswith("hevc")]
check("没有 HEVC：不用 VP9 / AV1 的 4K，选 H.264 1080", pick(no_hevc) == ["avc1080", "m4a"], pick(no_hevc))
only_new = [f for f in split if f["format_id"] in ("av1-2160", "vp9-2160", "opus")]
check("只有 VP9 / AV1：仍然能选出格式（最后退路）", len(pick(only_new)) == 2, pick(only_new))
merged = [fmt("sd", "avc1.42001E", "mp4a.40.2", 480), fmt("hd", "avc1.64001F", "mp4a.40.2", 720)]
check("音视频合一的网站：选最高清的那个", pick(merged) == ["hd"], pick(merged))
fps = [fmt("1080p30", "avc1.640028", "none", 1080, fps=30), fmt("1080p60", "avc1.64002A", "none", 1080, fps=60),
       fmt("m4a", "none", "mp4a.40.2", ext="m4a", tbr=128)]
check("同清晰度选高帧率", pick(fps) == ["1080p60", "m4a"], pick(fps))


# ---------------------------------------------------------------- 本机小网站

site = tempfile.mkdtemp()
for name in ("a.mp4", "b.mp4"):
    with open(os.path.join(site, name), "wb") as f:
        f.write(os.urandom(300_000))  # 内容随便：这里只测下载流程，不解码


def page(name, videos):
    with open(os.path.join(site, name), "w", encoding="utf-8") as f:
        f.write("<html><head><title>multi post</title></head><body>"
                + "".join(f'<video src="{v}"></video>' for v in videos) + "</body></html>")


page("two.html", ["a.mp4", "b.mp4"])
page("partial.html", ["a.mp4", "missing.mp4", "b.mp4"])


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=site))
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_address[1]}/"


def probe(d, name):
    return json.loads(dlcore.probe(json.dumps({
        "url": BASE + name, "out_dir": d, "cookies": [None], "log": os.path.join(d, "probe.log"),
        "cache_dir": None, "cancel": os.path.join(d, "cancel"), "max_height": 0})))


def fetch(d, **extra):
    return json.loads(dlcore.fetch(json.dumps(dict(
        {"log": os.path.join(d, "fetch.log"), "cancel": os.path.join(d, "cancel")}, **extra))))


def media_files(d):
    return [f for _, _, fs in os.walk(d) for f in fs if f.endswith(".mp4")]


print("解析和下载")
d = tempfile.mkdtemp()
r = probe(d, "a.mp4")
check("单个视频：probe 成功，1 项", r.get("ok") and r.get("entries") == 1, r)
check("probe 的结果里带封面字段（没有封面时为空）", "thumbnail" in r, r)
check("probe 不下载", media_files(d) == [])
r = fetch(d)
check("fetch 下载到 1 个文件", r.get("ok") and len(r["items"]) == 1 and os.path.getsize(r["items"][0]["streams"][0]["path"]) == 300_000, r)
check("fetch 之后不能再 fetch", fetch(d).get("ok") is False)
shutil.rmtree(d)

d = tempfile.mkdtemp()
r = probe(d, "two.html")
check("两个视频的网页：2 项，标题和 ID 取网页本身的", r.get("entries") == 2 and r.get("id") == "two" and r.get("title") == "multi post", r)
r = fetch(d)
paths = [it["streams"][0]["path"] for it in r.get("items", []) if "streams" in it]
check("两项都下载到，各在各的子文件夹", len(paths) == 2 and len({os.path.dirname(p) for p in paths}) == 2, r)
shutil.rmtree(d)

d = tempfile.mkdtemp()
probe(d, "partial.html")
r = fetch(d)
kinds = ["ok" if "streams" in it else "error" for it in r.get("items", [])]
check("中间一项失败不影响其它项", r.get("ok") and kinds == ["ok", "error", "ok"], kinds)
shutil.rmtree(d)

d = tempfile.mkdtemp()
probe(d, "two.html")
r = fetch(d, limit=1)
check("limit=1 只下第 1 项", r.get("ok") and len(r["items"]) == 1 and len(media_files(d)) == 1, r)
shutil.rmtree(d)

d = tempfile.mkdtemp()
probe(d, "partial.html")
r = fetch(d, only=[3])
check("only=[3] 只下第 3 项（预览页勾选），放在它自己的子文件夹", r.get("ok") and len(r["items"]) == 1
      and os.path.basename(os.path.dirname(r["items"][0]["streams"][0]["path"])) == "003" and len(media_files(d)) == 1, r)
shutil.rmtree(d)

print("取消")
d = tempfile.mkdtemp()
probe(d, "two.html")
open(os.path.join(d, "cancel"), "w").close()
r = fetch(d)
check("下载前取消", r.get("ok") is False and r.get("cancelled") is True, r)
shutil.rmtree(d)

d = tempfile.mkdtemp()
probe(d, "two.html")
original_progress = dlcore._progress


def cancel_on_first_callback(log, cancel):
    hook = original_progress(log, cancel)

    def wrapped(info):
        hook(info)
        open(cancel.path, "w").close()  # 第一次进度回调之后「点取消」
    return wrapped


dlcore._progress = cancel_on_first_callback
r = fetch(d)
dlcore._progress = original_progress
check("下载途中取消", r.get("ok") is False and r.get("cancelled") is True, r)
shutil.rmtree(d)

d = tempfile.mkdtemp()
open(os.path.join(d, "cancel"), "w").close()
r = probe(d, "a.mp4")
check("解析前取消", r.get("ok") is False and r.get("cancelled") is True, r)
shutil.rmtree(d)

print("出错")
d = tempfile.mkdtemp()
r = probe(d, "nothing-here.mp4")
check("链接不存在：错误原样返回，不算取消", r.get("ok") is False and "404" in r.get("error", "") and not r.get("cancelled"), r)
shutil.rmtree(d)

# ---------------------------------------------------------------- gallery-dl

try:
    import gallery_dl  # noqa: F401
    HAVE_GDL = True
except ImportError:
    HAVE_GDL = False

if HAVE_GDL:
    print("gallery-dl")
    with open(os.path.join(site, "pic.jpg"), "wb") as f:
        f.write(os.urandom(2000))
    d = tempfile.mkdtemp()

    def gallery(url):
        return json.loads(dlcore.gallery(json.dumps({
            "url": url, "cookies": [None], "log": os.path.join(d, "gallery.log"), "cache_dir": d,
            "cancel": os.path.join(d, "cancel")})))

    r = json.loads(dlcore.gdl_version("{}"))
    check("能读到 gallery-dl 版本", bool(r.get("gallery_dl")), r)
    r = gallery(BASE + "pic.jpg")
    it = (r.get("items") or [{}])[0]
    check("直接指向图片的链接：列出 1 项图片，不下载", r.get("ok") and r.get("entries") == 1
          and it.get("kind") == "image" and it.get("url") == BASE + "pic.jpg" and it.get("ytdl") is False, r)
    check("没有作品 ID 时用网址查重", r.get("id") == BASE + "pic.jpg", r.get("id"))
    check("结果的字段和 probe 对得上", all(k in r for k in ("title", "extractor", "uploader", "uploader_ids", "handle", "timestamp", "more", "referer")), r)
    r = gallery(BASE + "two.html")
    check("不支持的网址：返回 unsupported，不算出错", r.get("ok") is False and r.get("unsupported") is True, r)
    check("视频网站交给 yt-dlp（gallery-dl 说不支持）",
          gallery("https://www.youtube.com/watch?v=abc").get("unsupported") is True
          and gallery("https://www.bilibili.com/video/BV1xx411c7mD").get("unsupported") is True)
    from gallery_dl import extractor as gdl_extractor
    routes = {"https://x.com/user/status/1234567890": "twitter", "https://weibo.com/1234567890/AbCdEfGhI": "weibo",
              "https://m.weibo.cn/status/4912345678901234": "weibo", "https://www.pixiv.net/artworks/123": "pixiv"}
    got = {u: getattr(gdl_extractor.find(u), "category", None) for u in routes}
    check("X、微博、Pixiv 的帖子链接能认出来", got == routes, got)
    # 实况图配对和内容不过滤的开关：不联网，直接检查整理结果和配置
    from gallery_dl import config as gdl_config

    class FakeJob:
        data_urls = ["https://img.example/1.jpg", "https://video.example/1?livephoto=x.mov", "https://img.example/2.jpg",
                     "ytdl:https://video.example/3.m3u8"]
        data_meta = [{"extension": "jpg", "type": "livephoto", "_fallback": iter(["https://img.example/1-large.jpg"])},
                     {"extension": "mov", "type": "livephoto"}, {"extension": "jpg", "type": "pic"},
                     {"extension": "mp4"}]

    items = dlcore._gdl_items(FakeJob)
    check("微博实况图：图片和它的动态视频合成一项", [i["kind"] for i in items] == ["live", "image", "video"]
          and items[0].get("live") == FakeJob.data_urls[1], items)
    check("备用地址保留；分段视频标成要交给 yt-dlp", items[0]["fallback"] == ["https://img.example/1-large.jpg"]
          and items[2]["ytdl"] is True and items[2]["url"] == "https://video.example/3.m3u8", items)
    check("上限：没传用默认 100，传 0 是不限，传别的数照用",
          dlcore._limit({}) == 100 and dlcore._limit({"max_entries": 0}) is None and dlcore._limit({"max_entries": 500}) == 500)
    dlcore._gdl_setup({"cache_dir": d, "max_entries": 0}, None)
    check("不限时 gallery-dl 不设范围", gdl_config.get(("extractor",), "image-range") is None)
    dlcore._gdl_setup({"cache_dir": d}, None)
    check("不过滤内容：被标成不可用的媒体、转发、微博电影类视频都不跳过",
          gdl_config.get(("extractor", "twitter"), "unavailable") is True
          and gdl_config.get(("extractor", "twitter"), "retweets") is True
          and gdl_config.get(("extractor", "weibo"), "retweets") == "original"
          and gdl_config.get(("extractor", "weibo"), "movies") is True)
    check("没有设置任何按内容筛选的规则", not any(
        gdl_config.get(("extractor",), k) for k in ("image-filter", "post-filter", "chapter-filter", "blacklist", "whitelist")))
    shutil.rmtree(d, ignore_errors=True)
else:
    print("gallery-dl 没有安装，跳过它的测试")

srv.shutdown()
shutil.rmtree(site)
print()
if failures:
    print(f"{len(failures)} 项没通过：" + "、".join(failures))
    sys.exit(1)
print("全部通过，yt-dlp", yt_dlp.version.__version__)
