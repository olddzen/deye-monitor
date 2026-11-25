import math, sys, numpy as np
from PIL import Image, ImageDraw, ImageFilter
S = 2048
OUT = sys.argv[1] if len(sys.argv) > 1 else "."  # python render_icon.py <out-dir>
def hexrgb(h): return np.array([(h >> 16) & 255, (h >> 8) & 255, h & 255], float)
def background(top, bottom, glow, ga):
    y = np.linspace(0, 1, S)[:, None, None]
    img = np.broadcast_to(hexrgb(top) * (1 - y) + hexrgb(bottom) * y, (S, S, 3)).copy()
    if glow is not None:
        yy, xx = np.mgrid[0:S, 0:S] / S
        a = ga * np.exp(-((np.sqrt((xx - .5) ** 2 + (yy - .5) ** 2)) / .30) ** 2)
        img = img * (1 - a[..., None]) + hexrgb(glow) * a[..., None]
    return Image.fromarray(img.clip(0, 255).astype(np.uint8))
def arc(color, frac, width, radius, start=135, sweep=270, to=None):
    L = Image.new("RGBA", (S, S), (0, 0, 0, 0)); d = ImageDraw.Draw(L); c = S / 2
    box = [c - radius, c - radius, c + radius, c + radius]; end = start + sweep * frac; n = max(2, int(sweep * frac * 2))
    for i in range(n):
        t = i / n; col = color if to is None else tuple(int(color[k] * (1 - t) + to[k] * t) for k in range(4))
        d.arc(box, start + (end - start) * i / n, start + (end - start) * (i + 1) / n + .6, fill=col, width=width)
    for ang, col in ((start, color), (end, to or color)):
        r = math.radians(ang); x, y = c + (radius - width / 2) * math.cos(r), c + (radius - width / 2) * math.sin(r)
        d.ellipse([x - width / 2, y - width / 2, x + width / 2, y + width / 2], fill=col)
    return L
def bolt(fill, glow=None, scale=0.84):
    pts = [(0.585, 0.215), (0.345, 0.545), (0.485, 0.545), (0.425, 0.785), (0.665, 0.455), (0.522, 0.455)]
    pts = [((0.5 + (x - 0.505) * scale) * S, (0.5 + (y - 0.5) * scale) * S) for x, y in pts]
    m = Image.new("L", (S, S), 0); ImageDraw.Draw(m).polygon(pts, fill=255)
    m = m.filter(ImageFilter.GaussianBlur(S * 0.007)).point(lambda v: 255 if v > 95 else 0)  # rounded corners
    m = m.filter(ImageFilter.GaussianBlur(1.2))
    L = Image.new("RGBA", (S, S), fill[:3] + (0,)); L.putalpha(m)
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    if glow:
        g = Image.new("RGBA", (S, S), (0, 0, 0, 0)); ImageDraw.Draw(g).polygon(pts, fill=glow)
        out = Image.alpha_composite(out, g.filter(ImageFilter.GaussianBlur(S * 0.05)))
    return Image.alpha_composite(out, L)
def render(v):
    if v == "tinted":
        bg = background(0, 0, None, 0); tr, r1, r2, bc, gc = (255,255,255,40), (200,200,200,255), (255,255,255,255), (255,255,255,255), None
    elif v == "dark":
        bg = background(0x0c1210, 0x020303, 0x23b866, .30); tr, r1, r2, bc, gc = (255,255,255,22), (30,190,105,255), (150,245,190,255), (246,255,249,255), (52,210,123,150)
    else:
        bg = background(0x1a2621, 0x080b0a, 0x2fd37a, .38); tr, r1, r2, bc, gc = (255,255,255,26), (36,200,112,255), (168,245,200,255), (246,255,249,255), (52,210,123,170)
    img = bg.convert("RGBA"); R, W = S * .335, int(S * .030)
    for layer in (arc(tr, 1, W, R), arc(r1, .78, W, R, to=r2), bolt(bc, gc)):
        img = Image.alpha_composite(img, layer)
    return img.convert("RGB").resize((1024, 1024), Image.LANCZOS)
for v in ("light", "dark", "tinted"):
    render(v).save(f"{OUT}/icon-{v}.png", optimize=True)
sheet = Image.new("RGB", (1240, 440), (235, 235, 230)); mask = Image.new("L", (360, 360), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, 359, 359], radius=81, fill=255)
for i, v in enumerate(("light", "dark", "tinted")):
    sheet.paste(Image.open(f"{OUT}/icon-{v}.png").resize((360, 360), Image.LANCZOS), (40 + i * 400, 40), mask)
sheet.save(f"{OUT}/preview.png"); print("ok")
