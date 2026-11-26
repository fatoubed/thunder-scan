"""雷霆扫描 图标 v2：macOS 26 风格方圆形 + 取景框四角 + 闪电，白天版 / 黑夜版

用法（需要 Pillow）：python3 make_icon_v2.py
产物：
  AppIcon.icns       白天版，打进 .app（访达、启动台显示）
  AppIcon-light.png  白天版 1024，运行时浅色模式给 Dock 用
  AppIcon-dark.png   黑夜版 1024，运行时深色模式给 Dock 用

黑夜版仿系统图标：底板几乎纯黑，品牌靛紫色转移到取景框上，闪电保持金色。
"""
import os
import shutil
import subprocess

import math
from PIL import Image, ImageChops, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
SS = 4
N = 1024 * SS
U = N / 1024

THEMES = {
    "light": dict(
        bg_top=(118, 112, 255, 255), bg_bottom=(64, 44, 214, 255),
        sheen=24, edge=0.30, shadow=0.32,
        frame_top=(255, 255, 255, 250), frame_bottom=(236, 236, 255, 250), frame_glow=None,
        bolt_top=(255, 244, 150, 255), bolt_bottom=(255, 150, 20, 255), glow=(120, 60, 0), glow_op=0.28,
    ),
    "dark": dict(
        bg_top=(44, 44, 47, 255), bg_bottom=(22, 22, 24, 255),
        sheen=10, edge=0.16, shadow=0.45,
        frame_top=(150, 146, 255, 255), frame_bottom=(104, 86, 246, 255), frame_glow=(110, 96, 255),
        bolt_top=(255, 242, 150, 255), bolt_bottom=(255, 146, 14, 255), glow=(255, 170, 30), glow_op=0.45,
    ),
}


def px(v):
    return int(round(v * U))


def squircle(cx, cy, half, n=5.0, steps=720):
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        pts.append((cx + half * math.copysign(abs(c) ** (2 / n), c),
                    cy + half * math.copysign(abs(s) ** (2 / n), s)))
    return pts


def blank_mask():
    return Image.new("L", (N, N), 0)


def gradient(top, bottom):
    g = Image.linear_gradient("L").resize((N, N))
    return Image.composite(Image.new("RGBA", (N, N), bottom), Image.new("RGBA", (N, N), top), g)


def colored(mask, color):
    layer = Image.new("RGBA", (N, N), color[:3] + (0,))
    layer.putalpha(mask)
    return layer


def fill(mask, top, bottom):
    """渐变只铺在图形自身的范围内（上→下），并直接用遮罩当透明度，边缘不会发黑"""
    box = mask.getbbox() or (0, 0, N, N)
    h = max(1, box[3] - box[1])
    g = Image.linear_gradient("L").resize((N, h))
    band = Image.composite(Image.new("RGBA", (N, h), bottom), Image.new("RGBA", (N, h), top), g)
    out = Image.new("RGBA", (N, N), top)
    out.paste(Image.new("RGBA", (N, box[1]), top), (0, 0)) if box[1] > 0 else None
    out.paste(band, (0, box[1]))
    out.paste(Image.new("RGBA", (N, N - box[3]), bottom), (0, box[3])) if box[3] < N else None
    out.putalpha(ImageChops.multiply(mask, out.getchannel("A")))
    return out


def rounded(mask, r):
    """把多边形的尖角磨圆：模糊后再取阈值"""
    return mask.filter(ImageFilter.GaussianBlur(r)).point(lambda v: 255 if v >= 128 else 0)


def build(theme):
    P = THEMES[theme]
    canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))

    # 1. 底板
    body = blank_mask()
    ImageDraw.Draw(body).polygon(squircle(N / 2, N / 2, px(412)), fill=255)
    sh = body.filter(ImageFilter.GaussianBlur(px(18))).point(lambda v: int(v * P["shadow"]))
    canvas.alpha_composite(colored(ImageChops.offset(sh, 0, px(14)), (0, 0, 0)))
    canvas.alpha_composite(fill(body, P["bg_top"], P["bg_bottom"]))

    sheen = blank_mask()
    ImageDraw.Draw(sheen).ellipse([px(-200), px(-700), px(1224), px(430)], fill=P["sheen"])
    sheen = ImageChops.multiply(sheen.filter(ImageFilter.GaussianBlur(px(170))), body)
    canvas.alpha_composite(colored(sheen, (255, 255, 255)))
    edge = ImageChops.subtract(body, body.filter(ImageFilter.MinFilter(px(5) | 1)))
    canvas.alpha_composite(colored(edge.point(lambda v: int(v * P["edge"])), (255, 255, 255)))

    # 2. 取景框四角：离边缘留足空间，线条比旧版细
    frame = blank_mask()
    fd = ImageDraw.Draw(frame)
    lo, hi = px(258), px(766)          # 取景框外沿
    arm, lw = px(118), px(40)
    r = lw // 2
    for (x, y, dx, dy) in [(lo, lo, 1, 1), (hi, lo, -1, 1), (lo, hi, 1, -1), (hi, hi, -1, -1)]:
        # 一笔画出 L 形：竖臂 → 拐角 → 横臂，拐角用圆弧连接，两端加圆头
        pts = [(x, y + dy * arm), (x, y), (x + dx * arm, y)]
        fd.line(pts, fill=255, width=lw, joint="curve")
        for (ex, ey) in (pts[0], pts[2]):
            fd.ellipse([ex - r, ey - r, ex + r, ey + r], fill=255)
    frame = rounded(frame, px(10))
    if P["frame_glow"]:
        g = frame.filter(ImageFilter.GaussianBlur(px(8))).point(lambda v: int(v * 0.35))
        canvas.alpha_composite(colored(g, P["frame_glow"]))
    canvas.alpha_composite(fill(frame, P["frame_top"], P["frame_bottom"]))

    # 3. 闪电：经典折线闪电，尖角磨圆
    bolt = blank_mask()
    # 以 (512, 512) 为中心放大 1.12 倍
    base = [(600, 236), (352, 560), (500, 560), (426, 790), (680, 462), (530, 462), (600, 236)]
    pts = [(512 + (x - 512) * 1.12, 512 + (y - 512) * 1.12) for x, y in base]
    ImageDraw.Draw(bolt).polygon([(px(x), px(y)) for x, y in pts], fill=255)
    bolt = rounded(bolt, px(14))
    glow = bolt.filter(ImageFilter.GaussianBlur(px(14))).point(lambda v: int(min(255, v * P["glow_op"])))
    glow = ImageChops.offset(glow, 0, px(6)) if theme == "light" else glow   # 白天版是贴身投影，黑夜版是贴身光
    canvas.alpha_composite(colored(glow, P["glow"]))
    canvas.alpha_composite(fill(bolt, P["bolt_top"], P["bolt_bottom"]))

    return canvas.resize((1024, 1024), Image.LANCZOS)


def main():
    light = build("light")
    light.save(os.path.join(HERE, "AppIcon-light.png"))
    build("dark").save(os.path.join(HERE, "AppIcon-dark.png"))

    iconset = os.path.join(HERE, "AppIcon.iconset")
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset)
    for size in (16, 32, 128, 256, 512):
        light.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}.png"))
        light.resize((size * 2, size * 2), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}@2x.png"))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(HERE, "AppIcon.icns")], check=True)
    shutil.rmtree(iconset)
    print("done")


if __name__ == "__main__":
    main()
