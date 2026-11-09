#!/usr/bin/env python3
# parse_proto.py —— App 解析逻辑的 Python 原型（只用标准库，步骤与 Swift 版一一对应）
# 用法：python parse_proto.py "分享文案或链接" [--download 目录]
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1")
XHS_HOSTS = ("xhslink.com", "xhslink.cn", "rednote.com", "xiaohongshu.com")
ORIG_IMG = "https://sns-img-bd.xhscdn.com/"
ORIG_VIDEO = "https://sns-video-bd.xhscdn.com/"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def extract_url(text):
    m = re.search(r"https?://[^\s，。！]+", text)
    return m.group(0) if m else None


def note_ref(url):
    """返回 (noteId, xsec_token)；rednote 登录页的 redirectPath 里也能取到"""
    p = urllib.parse.urlparse(url)
    q = urllib.parse.parse_qs(p.query)
    if "redirectPath" in q:
        p = urllib.parse.urlparse(q["redirectPath"][0])
        q = urllib.parse.parse_qs(p.query)
    m = re.search(r"/(?:explore|discovery/item)/([0-9a-f]{24})", p.path)
    if not m:
        return None
    return m.group(1), q.get("xsec_token", [""])[0]


def resolve(url):
    opener = urllib.request.build_opener(NoRedirect)
    for _ in range(8):
        ref = note_ref(url)
        if ref:
            return ref
        try:
            opener.open(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=15)
            break
        except urllib.error.HTTPError as e:
            loc = e.headers.get("Location")
            if not loc:
                break
            url = urllib.parse.urljoin(url, loc)
    raise RuntimeError("链接里找不到笔记 ID：" + url)


def page_url(note_id, token):
    u = f"https://www.xiaohongshu.com/discovery/item/{note_id}"
    if token:
        u += "?" + urllib.parse.urlencode({"xsec_token": token, "xsec_source": "app_share"})
    return u


def initial_state(html):
    m = re.search(r"window\.__INITIAL_STATE__\s*=\s*(.+?)</script>", html, re.S)
    if not m:
        raise RuntimeError("页面里没有 __INITIAL_STATE__（可能被跳到登录页或验证页）")
    s = m.group(1).strip().rstrip(";")
    s = re.sub(r"\bundefined\b", "null", s)
    s = re.sub(r"new (?:Set|Map)\((\[.*?\])?\)", lambda m: m.group(1) or "[]", s)
    return json.loads(s)


def https(u):
    return "https://" + u[len("http://"):] if u and u.startswith("http://") else u


# 请求笔记页时用的请求头，与 yt-dlp 默认请求头一致（dl.py 在手机上就是这样拿到笔记数据的）
PAGE_HEADERS = {
    "User-Agent": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                   "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-us,en;q=0.5",
    "Sec-Fetch-Mode": "navigate",
}


def parse(text):
    url = extract_url(text)
    if not url:
        raise RuntimeError("没找到链接")
    note_id, token = resolve(url)
    req = urllib.request.Request(page_url(note_id, token), headers=PAGE_HEADERS)
    with urllib.request.urlopen(req, timeout=20) as r:
        html = r.read().decode("utf-8", "replace")
    return parse_html(html, note_id)


def parse_html(html, note_id):
    note = ((initial_state(html).get("note") or {}).get("noteDetailMap") or {}).get(note_id, {}).get("note")
    if not note:
        raise RuntimeError("页面里没有这篇笔记的数据")
    items = []
    if note.get("type") == "video":
        v = note.get("video") or {}
        key = (v.get("consumer") or {}).get("originVideoKey")
        streams = [s for lst in ((v.get("media") or {}).get("stream") or {}).values() for s in lst]
        h264 = [s for s in streams if s.get("masterUrl") and (s.get("videoCodec") or "").startswith("h264")]
        fallback = [https(s["masterUrl"]) for s in (h264 or streams) if s.get("masterUrl")]
        items.append({"kind": "video", "urls": ([ORIG_VIDEO + key] if key else []) + fallback})
    else:
        for img in note.get("imageList") or []:
            fid = img.get("fileId")
            urls = ([ORIG_IMG + fid] if fid else []) + [https(img.get("urlDefault"))]
            item = {"kind": "image", "urls": [u for u in urls if u]}
            if img.get("livePhoto"):
                h = ((img.get("stream") or {}).get("h264") or [])
                if h and h[0].get("masterUrl"):
                    item["kind"] = "live"
                    item["video"] = [https(h[0]["masterUrl"])] + [https(u) for u in h[0].get("backupUrls") or []]
            items.append(item)
    return {"id": note_id, "type": note.get("type"), "title": note.get("title"), "items": items}


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": "https://www.xiaohongshu.com/"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read(), r.headers.get("Content-Type", "")


if __name__ == "__main__":
    args = sys.argv[1:]
    out = None
    if "--download" in args:
        i = args.index("--download")
        out = args[i + 1]
        args = args[:i] + args[i + 2:]
    if "--html" in args:  # 离线：解析已保存的网页，用法 --html 文件 笔记ID
        i = args.index("--html")
        info = parse_html(open(args[i + 1], encoding="utf-8").read(), args[i + 2])
    else:
        info = parse(" ".join(args))
    print(json.dumps(info, ensure_ascii=False, indent=1))
    if out:
        os.makedirs(out, exist_ok=True)
        for n, it in enumerate(info["items"], 1):
            for key in ("urls", "video"):
                for u in it.get(key) or []:
                    try:
                        data, ct = fetch(u)
                        name = f"{info['id']}_{n:02d}_{key}"
                        open(os.path.join(out, name), "wb").write(data)
                        print(name, len(data), ct, u)
                        break
                    except Exception as e:
                        print("失败", u, e)
