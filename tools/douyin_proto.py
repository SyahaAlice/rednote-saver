#!/usr/bin/env python3
"""douyin_proto.py —— 抖音分享页解析原型（纯 Python 标准库，a-Shell 里也能跑）

⚠️ 2026-11-10 实测已失效：分享页的 _ROUTER_DATA 里不再带作品数据；作品详情接口对未登录访问
直接返回 403。App 改为在内置浏览器里用登录过的抖音账号打开作品页读取数据（见 XHSSaver/Douyin.swift）。
这个脚本只保留作参考：短链跳转、作品 ID 提取的逻辑仍然有效。

原思路：抖音的公开分享页 iesdouyin.com/share/video/<id>/ 里直接带着作品数据
（window._ROUTER_DATA），不需要签名参数。视频播放地址里的 playwm 换成 play 一般就是无水印版。

用法：
  python douyin_proto.py "分享文案或链接"                 # 只解析，打印结果
  python douyin_proto.py "分享文案或链接" --download 目录  # 解析并下载
  python douyin_proto.py --html 已保存的分享页.html        # 离线解析
"""
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def extract_url(text):
    m = re.search(r"https?://[^\s，。！]+", text)
    return m.group(0) if m else None


def aweme_id(url):
    """从各种抖音链接里取作品 ID"""
    p = urllib.parse.urlparse(url)
    m = re.search(r"/(?:share/)?(?:video|note|slides)/(\d+)", p.path)
    if m:
        return m.group(1)
    q = urllib.parse.parse_qs(p.query)
    for k in ("modal_id", "aweme_id", "item_id"):
        if q.get(k):
            return q[k][0]
    return None


def resolve(url):
    """手动一跳一跳地跟短链 v.douyin.com 跳转，拿到作品 ID 就停"""
    opener = urllib.request.build_opener(NoRedirect)
    for _ in range(8):
        aid = aweme_id(url)
        if aid:
            return aid
        try:
            opener.open(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=15)
            break
        except urllib.error.HTTPError as e:
            loc = e.headers.get("Location")
            if not loc:
                break
            url = urllib.parse.urljoin(url, loc)
    raise RuntimeError("链接里找不到抖音作品 ID：" + url)


def router_data(html):
    m = re.search(r"window\._ROUTER_DATA\s*=\s*(\{.+?\})\s*</script>", html, re.S)
    if not m:
        raise RuntimeError("分享页里没有作品数据（可能作品已删除、私密，或者被跳到了验证页）")
    return json.loads(m.group(1))


def first_item(data):
    for key, page in (data.get("loaderData") or {}).items():
        res = (page or {}).get("videoInfoRes") if isinstance(page, dict) else None
        items = (res or {}).get("item_list") or []
        if items:
            return items[0]
    raise RuntimeError("分享页里没有作品数据（作品可能已删除或设为私密）")


def no_watermark(u):
    return u.replace("/playwm/", "/play/") if u else u


def https(u):
    return "https://" + u[len("http://"):] if u and u.startswith("http://") else u


def pick_image(urls):
    """同一张图有多个地址（webp / jpeg），优先 jpeg，相册兼容最好"""
    urls = [https(u) for u in urls or [] if u]
    jpeg = [u for u in urls if ".jpeg" in u or ".jpg" in u]
    return jpeg + [u for u in urls if u not in jpeg]


def parse_item(item):
    out = {"id": item.get("aweme_id"), "desc": item.get("desc"), "items": []}
    images = item.get("images") or []
    if images:  # 图文作品；有的图带一段动态视频（实况）
        out["type"] = "images"
        for img in images:
            entry = {"kind": "image", "urls": pick_image(img.get("url_list"))}
            clip = ((img.get("video") or {}).get("play_addr") or {}).get("url_list") or []
            if clip:
                entry["kind"] = "live"
                entry["video"] = [https(no_watermark(u)) for u in clip]
            if entry["urls"]:
                out["items"].append(entry)
    else:
        out["type"] = "video"
        play = ((item.get("video") or {}).get("play_addr") or {})
        urls = [https(no_watermark(u)) for u in play.get("url_list") or []]
        # 有的地址带 ratio=720p，试一下 1080p，不行再退回原地址
        hd = [re.sub(r"ratio=\d+p", "ratio=1080p", u) for u in urls if "ratio=" in u]
        out["items"].append({"kind": "video", "urls": hd + urls,
                             "uri": play.get("uri"), "width": play.get("width"), "height": play.get("height")})
    return out


def parse(text):
    url = extract_url(text)
    if not url:
        raise RuntimeError("没找到链接")
    aid = resolve(url)
    page = f"https://www.iesdouyin.com/share/video/{aid}/"
    req = urllib.request.Request(page, headers={"User-Agent": UA, "Accept-Language": "zh-CN,zh;q=0.9"})
    with urllib.request.urlopen(req, timeout=20) as r:
        html = r.read().decode("utf-8", "replace")
    return parse_item(first_item(router_data(html)))


def fetch(url, path):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": "https://www.douyin.com/"})
    with urllib.request.urlopen(req, timeout=60) as r:
        data = r.read()
        ctype = r.headers.get("Content-Type", "")
    with open(path, "wb") as f:
        f.write(data)
    return len(data), ctype


if __name__ == "__main__":
    args = sys.argv[1:]
    if "--html" in args:
        info = parse_item(first_item(router_data(open(args[args.index("--html") + 1], encoding="utf-8").read())))
        print(json.dumps(info, ensure_ascii=False, indent=1))
        sys.exit()
    out = None
    if "--download" in args:
        i = args.index("--download")
        out = args[i + 1]
        args = args[:i] + args[i + 2:]
    info = parse(" ".join(args))
    print(json.dumps(info, ensure_ascii=False, indent=1))
    if out:
        os.makedirs(out, exist_ok=True)
        for n, it in enumerate(info["items"], 1):
            for key in ("urls", "video"):
                for u in it.get(key) or []:
                    try:
                        name = os.path.join(out, f"{info['id']}_{n:02d}_{key}")
                        size, ct = fetch(u, name)
                        if size < 10000:
                            print("太小，换下一个地址", size, ct, u[:90])
                            continue
                        print(os.path.basename(name), size, ct)
                        break
                    except Exception as e:
                        print("失败", u[:90], e)
