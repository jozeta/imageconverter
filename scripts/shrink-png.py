"""Shrinks a screenshot: at most 1300 px wide (the window's size in points), then the fewest palette colours (256, 192,
128, 96, 64) that bring the file to 400 KB or less. Usage: python3 shrink-png.py <file.png>. Needs Pillow; without
it scripts/screenshots.sh falls back to sips (bigger files)."""
import os
import sys

from PIL import Image

LIMIT = 400 * 1024
path = sys.argv[1]
image = Image.open(path).convert("RGB")
if image.width > 1300:
    image = image.resize((1300, round(image.height * 1300 / image.width)), Image.LANCZOS)
for colours in (256, 192, 128, 96, 64):
    image.quantize(colours, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE).save(path, optimize=True)
    if os.path.getsize(path) <= LIMIT:
        break
