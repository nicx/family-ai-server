"""Renders Resources/AppIcon.svg (two overlapping circles) to the PNG sizes the app needs.
The dark background gets softly rounded corners, straight sides (transparent outside), everywhere except where the platform
rounds by itself: apple-touch-icon.png and icon-maskable-512.png stay full-bleed squares.
Usage: python3 Scripts/make-icons.py   (macOS: uses qlmanage for the SVG; needs Pillow: pip install pillow)"""
import os, subprocess, tempfile
from PIL import Image, ImageDraw

RADIUS = 0.13  # corner radius as share of the edge: straight sides, only the corners softly rounded
INSET = 100 / 1024  # macOS Dock/Finder icons keep a transparent margin (824 px art on a 1024 px canvas)

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
with tempfile.TemporaryDirectory() as tmp:
    subprocess.run(["qlmanage", "-t", "-s", "1024", "-o", tmp, f"{root}/Resources/AppIcon.svg"], check=True, capture_output=True)
    big = Image.open(os.path.join(tmp, "AppIcon.svg.png")).convert("RGB")
assert big.size == (1024, 1024), big.size


def rounded(img, inset=0.0):
    """RGBA copy with rounded corners (mask drawn at 4x for smooth edges); inset = transparent margin share."""
    n = img.size[0]
    n4 = n * 4
    m = Image.new("L", (n4, n4), 0)
    off = round(n4 * inset)
    ImageDraw.Draw(m).rounded_rectangle([off, off, n4 - 1 - off, n4 - 1 - off], radius=(n4 - 2 * off) * RADIUS, fill=255)
    out = img.convert("RGBA")
    out.putalpha(m.resize((n, n), Image.LANCZOS))
    return out


def sized(size, round_it=True):
    img = big.resize((size, size), Image.LANCZOS)
    return rounded(img) if round_it else img


for size, name in [(512, "icon-512.png"), (192, "icon-192.png"), (32, "favicon-32.png")]:
    sized(size).save(f"{root}/Web/{name}", optimize=True)
sized(180, False).save(f"{root}/Web/apple-touch-icon.png", optimize=True)       # iOS rounds it itself
sized(512, False).save(f"{root}/Web/icon-maskable-512.png", optimize=True)      # Android masks it itself
sized(256).save(f"{root}/docs/icon.png", optimize=True)
rounded(big, INSET).save(f"{root}/Resources/AppIcon-1024.png")  # with the Dock margin; the art itself is not shrunk, so the canvas edge cuts nothing
print("ok")
