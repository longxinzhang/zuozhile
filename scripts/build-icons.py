"""Derive launcher and startup resources from the supplied logo, without its dark matte."""
from collections import deque
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
source = Image.open(ROOT / "assets/logo.png").convert("RGBA")
width, height = source.size
pixels = source.load()
queue = deque([(0, 0)])
seen = set()
while queue:
    x, y = queue.popleft()
    if (x, y) in seen or not (0 <= x < width and 0 <= y < height):
        continue
    seen.add((x, y))
    r, g, b, a = pixels[x, y]
    if max(r, g, b) > 105:
        continue
    pixels[x, y] = (r, g, b, 0)
    queue.extend(((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)))

mark = source.crop(source.getbbox()).resize((512, 512), Image.Resampling.LANCZOS)
background = Image.new("RGBA", (512, 512), (213, 232, 192, 255))
flat = Image.alpha_composite(background, mark)
for folder in (ROOT / "AppScope/resources/base/media", ROOT / "entry/src/main/resources/base/media"):
    background.save(folder / "background.png")
    mark.save(folder / "foreground.png")
    flat.save(folder / "brand_mark.png")
flat.save(ROOT / "entry/src/main/resources/base/media/startIcon.png")
print("Generated launcher layers, brand mark and startup icon from assets/logo.png")
