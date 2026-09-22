#!/usr/bin/env python3
"""Extract the FU FUT seal artwork from logo.webp as a transparent PNG.

logo.webp: dark-gray square whose background drifts teal-tinted toward the
right (G-R ~48 there), with the seal art printed at G-R ~100+. Luminance
can't separate art from that background, but saturation can:

  1. alpha ramps with "greenness" (G-R) from 55 (bg ceiling) to 100 (art floor)
  2. a radial guard zeroes everything outside the seal's fitted circle, so
     residual background tint and edge halos can't survive outside the ring

The result is an OPENWORK emblem — ring, Amharic lettering, barista figure —
with the dark interior transparent, ready to float on the splash gradient.
Output: assets/branding/splash_seal.png, 1024px, 4% padding.
"""
from PIL import Image
import numpy as np
from scipy import ndimage

SRC = "/home/z/my-project/fufut/fufut-pos-flutter/assets/images/logo.webp"
OUT = "/home/z/my-project/fufut/fufut-pos-flutter/assets/branding/splash_seal.png"

TEAL = (0x1F, 0x8A, 0x85)

img = Image.open(SRC).convert("RGB")
rgb = np.asarray(img).astype(np.float32)
H, W = rgb.shape[:2]

greenness = rgb[..., 1] - rgb[..., 0]
# The disc interior is dark TEAL (G-R 40-100, compression-banded), the art
# solid sits at 100-120. The ramp floor therefore sits just under the art
# floor, NOT at the background ceiling — the despeckle pass below mops up
# the disc blotches that still cross it.
alpha = np.clip((greenness - 94.0) / (104.0 - 94.0), 0.0, 1.0)

# Despeckle: webp compression leaves blotches whose greenness sneaks over the
# ramp floor. Real art strokes are large connected structures; keep only
# components of the alpha>0.35 mask with area >= 500px (dilated 1px so the
# anti-aliased edges of kept strokes survive).
solid = alpha > 0.35
labels, n = ndimage.label(solid)
sizes = ndimage.sum(solid, labels, np.arange(1, n + 1))
keep = np.zeros(n + 1, dtype=bool)
keep[1:] = sizes >= 500
mask = ndimage.binary_dilation(keep[labels], iterations=1)
alpha *= mask
print(f"components: {n} total, {int(keep.sum())} kept")

# Fit the seal circle from solid art pixels (alpha > 0.85).
ys, xs = np.where(alpha > 0.85)
cx, cy = xs.mean(), ys.mean()
r = np.percentile(np.hypot(xs - cx, ys - cy), 98.5)
print(f"seal circle: center=({cx:.0f},{cy:.0f}) r={r:.0f}")

# Radial guard: feathered cutoff just outside the fitted radius.
dist = np.hypot(*np.meshgrid(np.arange(W) - cx, np.arange(H) - cy))
guard = np.clip((r * 1.012 - dist) / (r * 0.03), 0.0, 1.0)
alpha *= guard

# Drop near-empty margins, then crop to the guard circle bounding box.
alpha[alpha < 0.05] = 0.0
rr = int(np.ceil(r * 1.03))
x0, x1 = max(0, int(cx) - rr), min(W, int(cx) + rr)
y0, y1 = max(0, int(cy) - rr), min(H, int(cy) + rr)

out = np.zeros((y1 - y0, x1 - x0, 4), dtype=np.uint8)
out[..., 0] = TEAL[0]
out[..., 1] = TEAL[1]
out[..., 2] = TEAL[2]
out[..., 3] = (alpha[y0:y1, x0:x1] * 255).astype(np.uint8)

rgba = Image.fromarray(out)
side = max(rgba.size)
pad = int(side * 0.04)
canvas_side = side + pad * 2
canvas = Image.new("RGBA", (canvas_side, canvas_side), (0, 0, 0, 0))
canvas.paste(rgba, (pad + (side - rgba.size[0]) // 2, pad + (side - rgba.size[1]) // 2))
canvas = canvas.resize((1024, 1024), Image.LANCZOS)
canvas.save(OUT)
print(f"saved {OUT} size={canvas.size} crop=({x0},{y0},{x1},{y1}) "
      f"coverage={(out[..., 3] > 8).mean():.2%}")
