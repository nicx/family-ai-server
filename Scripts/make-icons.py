"""Renders Resources/AppIcon.svg (two overlapping circles) to the PNG sizes the app needs.
Usage: python3 Scripts/make-icons.py   (macOS: uses qlmanage for the SVG, Pillow for resizing)"""
import os, subprocess, tempfile
from PIL import Image

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
with tempfile.TemporaryDirectory() as tmp:
    subprocess.run(["qlmanage", "-t", "-s", "1024", "-o", tmp, f"{root}/Resources/AppIcon.svg"], check=True, capture_output=True)
    big = Image.open(os.path.join(tmp, "AppIcon.svg.png")).convert("RGB")
assert big.size == (1024, 1024), big.size
for size, name in [(512, "icon-512.png"), (192, "icon-192.png"), (180, "apple-touch-icon.png"), (32, "favicon-32.png")]:
    big.resize((size, size), Image.LANCZOS).save(f"{root}/Web/{name}", optimize=True)
big.save(f"{root}/Resources/AppIcon-1024.png")
print("ok")
