#!/usr/bin/env python3
"""Draws Sources/NOOPExtras/Resources/sample_meal.png: a simple plate of rice, chicken and broccoli on a
table. Used only by the AI provider "Test" button (proves the key, model and network work)."""
import math, random, struct, sys, zlib

W, H = 640, 480
random.seed(7)
px = [[(150, 105, 70)] * W for _ in range(H)]          # wooden table
for y in range(H):
    for x in range(W):
        g = int(12 * math.sin(y / 9.0 + math.sin(x / 70.0) * 2))
        r, gg, b = px[y][x]
        px[y][x] = (r + g, gg + g // 2, b + g // 3)

def disc(cx, cy, rx, ry, color, jitter=0):
    for y in range(max(0, cy - ry), min(H, cy + ry)):
        for x in range(max(0, cx - rx), min(W, cx + rx)):
            if ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1:
                j = random.randint(-jitter, jitter) if jitter else 0
                px[y][x] = tuple(max(0, min(255, c + j)) for c in color)

disc(320, 245, 250, 200, (235, 235, 230))               # plate rim
disc(320, 245, 215, 170, (250, 250, 247))               # plate
disc(250, 230, 100, 75, (245, 240, 220), jitter=12)     # rice
for (cx, cy) in [(390, 190), (430, 240), (380, 265), (420, 300)]:
    disc(cx, cy, 42, 26, (176, 112, 52), jitter=14)     # chicken pieces
for (cx, cy) in [(300, 330), (340, 345), (270, 315), (320, 365)]:
    disc(cx, cy, 24, 20, (52, 120, 48), jitter=18)      # broccoli florets
    disc(cx, cy + 22, 7, 12, (120, 170, 90))

raw = b"".join(b"\x00" + bytes(c for p in row for c in p) for row in px)
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)) \
      + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
print(len(png), "bytes")
