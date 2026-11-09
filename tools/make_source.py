#!/usr/bin/env python3
"""生成 AltStore 的「源」文件 apps.json（CI 在打包 ipa 之后运行，和 ipa 一起发布）。

在 AltStore 里添加一次源的地址之后，每次有新版，AltStore 的更新列表里会出现它，点 Update 就能装，
不用再把 ipa 传到手机上。

用法：python tools/make_source.py XHSSaver.ipa apps.json [这一版的说明]

版本号、Bundle ID、权限说明都直接从 ipa 里的 Info.plist 读：
AltStore 安装时会核对下载到的包和源里写的是否一致，手写容易对不上。
"""
import datetime
import json
import os
import plistlib
import sys
import zipfile

REPO = os.environ.get("GITHUB_REPOSITORY") or "SyahaAlice/rednote-saver"
NAME = "多功能媒体下载器"
SUBTITLE = "把链接里的图片、视频和实况照片存进相册"
DESCRIPTION = ("从小红书、抖音、B 站、微博、X、Instagram、快手等网站保存原图、原片和实况照片，按作者归类到相册。"
               "视频用内置的 yt-dlp，图片和图文混排用内置的 gallery-dl。")
TINT = "6A3DF0"


def info_plist(ipa):
    with zipfile.ZipFile(ipa) as z:
        names = [n for n in z.namelist() if n.count("/") == 2 and n.endswith(".app/Info.plist")]
        if not names:
            raise SystemExit("ipa 里没有找到 Info.plist")
        return plistlib.loads(z.read(names[0]))


def build(ipa, notes=""):
    info = info_plist(ipa)
    version = str(info["CFBundleShortVersionString"])
    build_version = str(info["CFBundleVersion"])
    base = f"https://github.com/{REPO}"
    download = f"{base}/releases/download/latest/XHSSaver.ipa"
    icon = (f"https://raw.githubusercontent.com/{REPO}/main/"
            "XHSSaver/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
    size = os.path.getsize(ipa)
    date = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()
    notes = notes.strip() or f"版本 {version}"
    # 系统会弹窗询问的权限（NS…UsageDescription），照 Info.plist 里的原样列出
    privacy = {k: str(v) for k, v in sorted(info.items()) if k.startswith("NS") and k.endswith("UsageDescription")}
    app = {
        "name": NAME,
        "bundleIdentifier": info["CFBundleIdentifier"],
        "developerName": REPO.split("/")[0],
        "subtitle": SUBTITLE,
        "localizedDescription": DESCRIPTION,
        "iconURL": icon,
        "tintColor": TINT,
        "category": "utilities",
        "screenshots": [],
        "versions": [{
            "version": version,
            "buildVersion": build_version,
            "date": date,
            "localizedDescription": notes,
            "downloadURL": download,
            "size": size,
            "minOSVersion": str(info.get("MinimumOSVersion", "17.0")),
        }],
        # 安装包没有签名，不带任何特殊权限（entitlements）
        "appPermissions": {"entitlements": [], "privacy": privacy},
        # 旧版 AltStore 读的是下面这几项
        "version": version,
        "versionDate": date,
        "versionDescription": notes,
        "downloadURL": download,
        "size": size,
    }
    return {
        "name": NAME,
        "identifier": info["CFBundleIdentifier"] + ".source",
        "subtitle": SUBTITLE,
        "description": DESCRIPTION,
        "iconURL": icon,
        "website": base,
        "tintColor": TINT,
        "apps": [app],
        "news": [],
    }


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    source = build(sys.argv[1], sys.argv[3] if len(sys.argv) > 3 else "")
    with open(sys.argv[2], "w", encoding="utf-8", newline="\n") as f:
        json.dump(source, f, ensure_ascii=False, indent=2)
        f.write("\n")
    v = source["apps"][0]["versions"][0]
    print(f"{sys.argv[2]}：{source['apps'][0]['bundleIdentifier']} {v['version']}（{v['buildVersion']}），{v['size']} 字节")
