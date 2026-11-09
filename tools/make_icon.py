#!/usr/bin/env python3
"""生成 App 图标（1024×1024，无透明通道）和品牌色，写进 XHSSaver/Assets.xcassets。

图案：玫红→紫的斜向渐变底；实况照片的光圈（外圈虚线、内圈实线）；
中间白色圆盘上一个「向下存进托盘」的箭头。只用几何图形，不含文字。
用法：python tools/make_icon.py [--preview 输出预览.png]
"""
import json
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "XHSSaver", "Assets.xcassets")

ROSE = (255, 94, 126)
VIOLET = (106, 61, 240)
GLYPH = (140, 70, 230)
S = 4          # 超采样倍数，画完缩小得到平滑边缘
N = 1024 * S


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def background():
    img = Image.new("RGB", (N, N))
    px = img.load()
    for y in range(0, N, S):
        for x in range(0, N, S):
            t = (x + y) / (2 * N)                 # 左上 → 右下
            c = lerp(ROSE, VIOLET, t)
            for dy in range(S):
                for dx in range(S):
                    px[x + dx, y + dy] = c
    # 左上角柔和高光
    glow = Image.new("L", (N, N), 0)
    ImageDraw.Draw(glow).ellipse((-N * 0.35, -N * 0.45, N * 0.75, N * 0.55), fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(N * 0.12))
    img.paste(Image.new("RGB", (N, N), (255, 255, 255)), (0, 0), glow)
    return img


def thick_line(d, pts, w, color):
    """带圆头圆角的折线"""
    d.line(pts, fill=color, width=w, joint="curve")
    r = w / 2
    for (x, y) in pts:
        d.ellipse((x - r, y - r, x + r, y + r), fill=color)


def draw():
    img = background()
    d = ImageDraw.Draw(img)
    c = N / 2
    white = (255, 255, 255)

    # 外圈：虚线光圈（实况照片的标志）
    r_out, w_out, dashes = 0.375 * N, int(0.024 * N), 40
    for i in range(dashes):
        a0 = 2 * math.pi * i / dashes
        a1 = a0 + 2 * math.pi / dashes * 0.55
        d.arc((c - r_out, c - r_out, c + r_out, c + r_out),
              math.degrees(a0), math.degrees(a1), fill=white, width=w_out)
    # 中圈：实线
    r_mid, w_mid = 0.30 * N, int(0.028 * N)
    d.ellipse((c - r_mid, c - r_mid, c + r_mid, c + r_mid), outline=white, width=w_mid)
    # 内部白色圆盘
    r_in = 0.235 * N
    d.ellipse((c - r_in, c - r_in, c + r_in, c + r_in), fill=white)

    # 向下的箭头 + 托盘
    w = int(0.043 * N)
    u = N / 1024
    thick_line(d, [(c, c - 120 * u), (c, c + 45 * u)], w, GLYPH)                      # 竖线
    thick_line(d, [(c - 78 * u, c - 25 * u), (c, c + 50 * u), (c + 78 * u, c - 25 * u)], w, GLYPH)  # 箭头
    thick_line(d, [(c - 125 * u, c + 45 * u), (c - 125 * u, c + 120 * u),
                   (c + 125 * u, c + 120 * u), (c + 125 * u, c + 45 * u)], w, GLYPH)  # 托盘

    return img.resize((1024, 1024), Image.LANCZOS)


def write_assets(icon):
    icon_dir = os.path.join(ASSETS, "AppIcon.appiconset")
    accent_dir = os.path.join(ASSETS, "AccentColor.colorset")
    os.makedirs(icon_dir, exist_ok=True)
    os.makedirs(accent_dir, exist_ok=True)
    icon.save(os.path.join(icon_dir, "icon-1024.png"), optimize=True)
    info = {"author": "xcode", "version": 1}
    with open(os.path.join(ASSETS, "Contents.json"), "w") as f:
        json.dump({"info": info}, f, indent=2)
    with open(os.path.join(icon_dir, "Contents.json"), "w") as f:
        json.dump({"images": [{"filename": "icon-1024.png", "idiom": "universal",
                               "platform": "ios", "size": "1024x1024"}], "info": info}, f, indent=2)
    # 品牌色（玫红与紫之间），浅色 / 深色模式各一份
    def color(r, g, b):
        return {"color-space": "srgb", "components": {
            "red": f"{r / 255:.3f}", "green": f"{g / 255:.3f}", "blue": f"{b / 255:.3f}", "alpha": "1.000"}}
    with open(os.path.join(accent_dir, "Contents.json"), "w") as f:
        json.dump({"colors": [
            {"idiom": "universal", "color": color(196, 64, 170)},
            {"idiom": "universal", "appearances": [{"appearance": "luminosity", "value": "dark"}],
             "color": color(226, 110, 200)},
        ], "info": info}, f, indent=2)


if __name__ == "__main__":
    icon = draw()
    write_assets(icon)
    if "--preview" in sys.argv:
        icon.save(sys.argv[sys.argv.index("--preview") + 1])
    print("图标已写入", os.path.join(ASSETS, "AppIcon.appiconset", "icon-1024.png"))
