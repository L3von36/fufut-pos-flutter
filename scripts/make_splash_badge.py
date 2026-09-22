#!/usr/bin/env python3
"""Extract the white FU FUT badge from assets/icon/app_icon.png.

The launcher icon (cut from the PWA's pwa-icon-*.png) renders the seal as a
WHITE disc with teal art on a flat brand-teal field. For the splash hero we
want exactly that badge floating on the splash gradient — same mark the user
already knows from the home-screen icon.

The badge is a near-perfect circle (fitted from its white pixels); alpha is
an anti-aliased circular mask — everything inside stays as painted, the teal
field outside drops to transparent. Output: assets/branding/splash_badge.png
at native crop resolution (badge diameter ~432px, enough for 140px @3x).
"""
from PIL import Image
import numpy as np

SRC = "/home/z/my-project/fufut/fufut-pos-flutter/assets/icon/app_icon.png"
OUT = "/home/z/my-project/fufut/fufut-pos-flutter/assets/branding/splash_badge.png"

img = Image.open(SRC).convert("RGBA")
rgb = np.asarray(img).astype(np.float32)
H, W = rgb.shape[:2]

white = rgb[..., :3].min(axis=2) > 150
ys, xs = np.where(white)
cx, cy = xs.mean(), ys.mean()
r = np.percentile(np.hypot(xs - cx, ys - cy), 99)
print(f"badge circle: center=({cx:.1f},{cy:.1f}) r={r:.1f}")

# Anti-aliased circular alpha: 1 inside, 1.5px feather at the rim.
Y, X = np.meshgrid(np.arange(H), np.arange(W), indexing="ij")
dist = np.hypot(X - cx, Y - cy)
alpha = np.clip((r - 0.5 - dist) / 1.5 + 1.0, 0.0, 1.0)

out = rgb.copy()
out[..., 3] = alpha * 255.0

rr = int(np.ceil(r)) + 2
x0, x1 = max(0, int(cx) - rr), min(W, int(cx) + rr)
y0, y1 = max(0, int(cy) - rr), min(H, int(cy) + rr)
out = out[y0:y1, x0:x1]

# 3% transparent padding so shadows/glow have room in the asset itself.
h, w = out.shape[:2]
pad = int(max(h, w) * 0.03)
canvas = np.zeros((h + pad * 2, w + pad * 2, 4), dtype=np.uint8)
canvas[pad:pad + h, pad:pad + w] = out.astype(np.uint8)

res = Image.fromarray(canvas)
res.save(OUT)
print(f"saved {OUT} size={res.size} crop=({x0},{y0},{x1},{y1})")
