#!/usr/bin/env python3
"""Draws App/Icon/AppIcon.png (1024 px), the source of the app icon. make-app.sh turns it into
AppIcon.icns with sips and iconutil. Needs Pillow: python3 -m pip install pillow"""
import os
from PIL import Image, ImageDraw, ImageFilter

S = 4  # supersampling
N = 1024 * S

def box(x0, y0, x1, y1):
    return [x0 * S, y0 * S, x1 * S, y1 * S]

icon = Image.new("RGBA", (N, N), (0, 0, 0, 0))

# Body: the macOS grid's 824 px rounded square, a top-to-bottom blue gradient
mask = Image.new("L", (N, N), 0)
ImageDraw.Draw(mask).rounded_rectangle(box(100, 100, 924, 924), radius=185 * S, fill=255)
gradient = Image.new("RGBA", (N, N))
top, bottom = (86, 156, 255), (28, 70, 196)
draw = ImageDraw.Draw(gradient)
for y in range(N):
    t = min(max((y / S - 100) / 824, 0), 1)
    draw.line([(0, y), (N, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle(box(100, 112, 924, 936), radius=185 * S, fill=(0, 0, 0, 90))
icon.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14 * S)))
icon.paste(gradient, (0, 0), mask)

# A page with a folded corner and lines of text
px0, py0, px1, py1, fold = 250, 215, 640, 735, 105
page_mask = Image.new("L", (N, N), 0)
pm = ImageDraw.Draw(page_mask)
pm.rounded_rectangle(box(px0, py0, px1, py1), radius=30 * S, fill=255)
pm.polygon([((px1 - fold) * S, (py0 - 1) * S), ((px1 + 1) * S, (py0 - 1) * S), ((px1 + 1) * S, (py0 + fold) * S)], fill=0)
page_shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
page_shadow.paste((10, 30, 90, 110), (0, 0), page_mask)
page_shadow = page_shadow.transform((N, N), Image.AFFINE, (1, 0, 0, 0, 1, -14 * S))
icon.alpha_composite(page_shadow.filter(ImageFilter.GaussianBlur(16 * S)))
layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
layer.paste((255, 255, 255, 255), (0, 0), page_mask)
d = ImageDraw.Draw(layer)
d.polygon([((px1 - fold) * S, py0 * S), ((px1 - fold) * S, (py0 + fold - 12) * S),
           ((px1 - fold + 12) * S, (py0 + fold) * S), (px1 * S, (py0 + fold) * S)], fill=(205, 222, 250, 255))
lines = [(305, 330, 520), (305, 385, 585), (305, 440, 560), (305, 495, 585), (305, 550, 470), (305, 605, 540)]
for x0, y, x1 in lines:
    d.rounded_rectangle(box(x0, y, x1, y + 22), radius=11 * S, fill=(150, 176, 222, 255))
icon.alpha_composite(layer)

# A magnifying glass over the lower right of the page
glass = Image.new("RGBA", (N, N), (0, 0, 0, 0))
g = ImageDraw.Draw(glass)
cx, cy, r, ring = 600, 590, 150, 44
# Handle: a thick rounded bar at 45 degrees
hx0, hy0, hx1, hy1 = cx + (r - 10) * 0.707, cy + (r - 10) * 0.707, 830, 820
g.line([(hx0 * S, hy0 * S), (hx1 * S, hy1 * S)], fill=(255, 196, 64, 255), width=70 * S)
g.ellipse(box(hx1 - 35, hy1 - 35, hx1 + 35, hy1 + 35), fill=(255, 196, 64, 255))
g.ellipse(box(cx - r, cy - r, cx + r, cy + r), fill=(255, 255, 255, 255))
g.ellipse(box(cx - r + ring, cy - r + ring, cx + r - ring, cy + r - ring), fill=(218, 234, 255, 255))
# Highlight on the lens
g.arc(box(cx - r + 70, cy - r + 70, cx + r - 70, cy + r - 70), start=200, end=255, fill=(255, 255, 255, 255), width=16 * S)
glass_shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
glass_shadow.paste((10, 30, 90, 120), (0, 0), glass.split()[3])
glass_shadow = glass_shadow.transform((N, N), Image.AFFINE, (1, 0, 0, 0, 1, -12 * S))
icon.alpha_composite(glass_shadow.filter(ImageFilter.GaussianBlur(14 * S)))
icon.alpha_composite(glass)

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "App", "Icon", "AppIcon.png")
icon.resize((1024, 1024), Image.LANCZOS).save(out, optimize=True)
print("wrote", os.path.normpath(out))
