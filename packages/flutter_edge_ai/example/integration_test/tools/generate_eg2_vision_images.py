"""The EmbeddingGemma 2 vision test images (R5 §10.2), drawn here — no third-party
pictures, so nothing to license. The text uses Pillow's bundled default font
(Aileron Regular, CC0). The ten scenes and their captions are the X2
measurement's (eg2_design_backup/measurements/scripts/x2_vision.py); with
Pillow 12.3.0 the PNGs come out byte-identical to the measured ones.

Writes into example/assets/eg2_vision/ (Flutter assets: the image-search
screen's sample photos, and what the device suites read on a phone):
- <name>.png              the 10 scenes (640x480; receipts 420x640)
- <name>_dup.jpg          near-duplicate: resized to 75 %, JPEG quality 70
- small_circle.{png,gif,bmp}  a 160x120 circle in three formats LiteRT-LM
                          decodes (small, so the BMP stays small)
- small_circle.{webp,tiff}  formats it does not decode (refused in Dart)
- small_circle.heic       with macOS `sips` (Pillow cannot write HEIC)
- portrait_upright.jpg    a 480x640 portrait scene (a lighthouse), stored upright
- portrait_exif6.jpg      the same scene as a phone camera stores it: pixels
                          rotated 90 degrees counter-clockwise, EXIF Orientation
                          6 (display rotated 90 clockwise) — EXIF-aware viewers
                          show it upright, a decoder that ignores EXIF does not
- large_12mp.jpg          a 4032x3024 (12.2 MP) photo-sized JPEG of the house
                          scene, for decode cost

usage: python3 -I generate_eg2_vision_images.py
       (needs Pillow 12.3.0 and numpy; macOS for the HEIC)
"""
import io
import math
import os
import subprocess

from PIL import Image, ImageDraw, ImageFont

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "eg2_vision")


def font(size):
    return ImageFont.load_default(size=size)


def canvas(bg="white", size=(640, 480)):
    im = Image.new("RGB", size, bg)
    return im, ImageDraw.Draw(im)


def circle():
    im, d = canvas()
    d.ellipse((170, 90, 470, 390), fill=(220, 30, 30))
    return im


def square():
    im, d = canvas()
    d.rectangle((170, 90, 470, 390), fill=(30, 60, 220))
    return im


def triangle():
    im, d = canvas()
    d.polygon([(320, 70), (540, 410), (100, 410)], fill=(30, 170, 60))
    return im


def bar_chart():
    im, d = canvas()
    d.text((180, 20), "Quarterly revenue", fill="black", font=font(32))
    for i, v in enumerate([120, 200, 160, 280]):
        x = 100 + i * 120
        d.rectangle((x, 430 - v, x + 70, 430), fill=(40, 90, 200))
        d.text((x + 15, 440), f"Q{i+1}", fill="black", font=font(24))
    d.line((80, 430, 600, 430), fill="black", width=3)
    return im


def pie_chart():
    im, d = canvas()
    d.text((200, 15), "Market share", fill="black", font=font(32))
    box = (170, 90, 470, 390)
    d.pieslice(box, 0, 160, fill=(230, 120, 30))
    d.pieslice(box, 160, 280, fill=(40, 160, 90))
    d.pieslice(box, 280, 360, fill=(90, 70, 200))
    return im


def line_chart():
    import numpy as np

    im, d = canvas()
    d.text((170, 15), "Temperature by month", fill="black", font=font(30))
    pts = [(80 + i * 45, 400 - int(25 * i + 30 * np.sin(i))) for i in range(12)]
    d.line((70, 420, 600, 420), fill="black", width=3)
    d.line((70, 420, 70, 80), fill="black", width=3)
    d.line(pts, fill=(200, 30, 30), width=5)
    for p in pts:
        d.ellipse((p[0] - 6, p[1] - 6, p[0] + 6, p[1] + 6), fill=(200, 30, 30))
    return im


def receipt(lines, title):
    im, d = canvas(bg=(250, 250, 245), size=(420, 640))
    d.text((40, 30), title, fill="black", font=font(34))
    y = 110
    for name, price in lines:
        d.text((40, y), name, fill="black", font=font(26))
        d.text((300, y), price, fill="black", font=font(26))
        y += 44
    d.line((40, y + 10, 380, y + 10), fill="black", width=2)
    total = f"{sum(float(p) for _, p in lines):.2f}"
    d.text((40, y + 25), "TOTAL", fill="black", font=font(30))
    d.text((290, y + 25), total, fill="black", font=font(30))
    return im


def grocery_receipt():
    return receipt([("Milk", "1.99"), ("Bread", "2.49"), ("Eggs", "3.29"), ("Apples", "4.70")], "GROCERY MART")


def taxi_receipt():
    return receipt([("Fare", "18.50"), ("Airport fee", "5.00"), ("Tip", "3.00")], "CITY TAXI")


def stop_sign():
    import numpy as np

    im, d = canvas(bg=(200, 220, 240))
    cx, cy, r = 320, 240, 170
    pts = [(cx + r * np.cos(np.pi / 8 + k * np.pi / 4), cy + r * np.sin(np.pi / 8 + k * np.pi / 4)) for k in range(8)]
    d.polygon(pts, fill=(200, 20, 20))
    d.text((cx - 110, cy - 45), "STOP", fill="white", font=font(90))
    return im


def house_scene():
    im, d = canvas(bg=(120, 180, 250))
    d.rectangle((0, 330, 640, 480), fill=(60, 160, 60))
    d.ellipse((450, 50, 570, 170), fill=(255, 210, 0))
    for k in range(12):
        a = k * math.pi / 6
        d.line((510 + 70 * math.cos(a), 110 + 70 * math.sin(a), 510 + 100 * math.cos(a), 110 + 100 * math.sin(a)),
               fill=(255, 210, 0), width=6)
    d.rectangle((120, 230, 260, 330), fill=(150, 80, 40))
    d.polygon([(105, 230), (190, 160), (275, 230)], fill=(170, 30, 30))
    return im


SCENES = [circle, square, triangle, bar_chart, pie_chart, line_chart, grocery_receipt, taxi_receipt, stop_sign,
          house_scene]


def save(im, name, fmt, **kw):
    b = io.BytesIO()
    im.save(b, fmt, **kw)
    with open(os.path.join(OUT, name), "wb") as f:
        f.write(b.getvalue())


for scene in SCENES:
    im = scene()
    save(im, f"{scene.__name__}.png", "PNG")
    dup = im.resize((int(im.width * 0.75), int(im.height * 0.75)), Image.BICUBIC)
    save(dup, f"{scene.__name__}_dup.jpg", "JPEG", quality=70)

small = circle().resize((160, 120), Image.BICUBIC)
save(small, "small_circle.png", "PNG")
save(small, "small_circle.gif", "GIF")
save(small, "small_circle.bmp", "BMP")
save(small, "small_circle.webp", "WEBP", quality=80)
save(small, "small_circle.tiff", "TIFF", compression="tiff_lzw")
subprocess.run(["sips", "-s", "format", "heic", os.path.join(OUT, "small_circle.png"), "--out",
                os.path.join(OUT, "small_circle.heic")], check=True, capture_output=True)


def lighthouse():
    im, d = canvas(bg=(135, 190, 240), size=(480, 640))
    d.rectangle((0, 470, 480, 640), fill=(30, 90, 170))  # sea
    d.polygon([(0, 470), (180, 400), (300, 470)], fill=(110, 100, 90))  # rock
    for k, color in enumerate([(220, 30, 30), (245, 245, 245)] * 3):
        top = 150 + k * 45
        d.rectangle((200, top, 280, top + 45), fill=color)  # striped tower
    d.rectangle((190, 120, 290, 150), fill=(60, 60, 60))  # lantern room
    d.polygon([(185, 120), (240, 70), (295, 120)], fill=(200, 30, 30))  # roof
    d.ellipse((380, 40, 450, 110), fill=(255, 210, 0))  # sun
    return im


upright = lighthouse()
save(upright, "portrait_upright.jpg", "JPEG", quality=90)
exif = Image.Exif()
exif[0x0112] = 6  # Orientation: rotate 90 clockwise to display
save(upright.transpose(Image.ROTATE_90), "portrait_exif6.jpg", "JPEG", quality=90, exif=exif.tobytes())

save(house_scene().resize((4032, 3024), Image.BICUBIC), "large_12mp.jpg", "JPEG", quality=85)
