"""The Multimodal RAG screen's own sample photo: an airport taxi receipt whose
TOTAL is large and plain, so the amount can be read off the picture (and
only there: no note or memo carries it). Drawn with Pillow and Pillow's
bundled default font, so nothing to license.

Writes example/assets/knowledge/photos/taxi_receipt.png (600 x 860).

usage: python3 -I generate_knowledge_photos.py   (needs Pillow >= 10.1)
"""
import os

from PIL import Image, ImageDraw, ImageFont

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "knowledge", "photos")


def font(size):
    return ImageFont.load_default(size=size)


def bold(draw, xy, text, size, fill="black"):
    x, y = xy
    for dx in (0, 1, 2):
        draw.text((x + dx, y), text, fill=fill, font=font(size))


def right(draw, x_right, y, text, size, fill="black", heavy=False):
    width = draw.textlength(text, font=font(size))
    if heavy:
        bold(draw, (x_right - width - 2, y), text, size, fill)
    else:
        draw.text((x_right - width, y), text, fill=fill, font=font(size))


def taxi_receipt():
    im = Image.new("RGB", (600, 860), (250, 249, 244))
    d = ImageDraw.Draw(im)
    left, edge = 48, 552
    bold(d, (left, 50), "LONDON CABS", 46)
    d.text((left, 112), "Taxi receipt  No. 0412", fill=(90, 90, 90), font=font(26))
    d.text((left, 170), "Heathrow Airport", fill="black", font=font(30))
    d.text((left, 210), "to Shoreditch", fill="black", font=font(30))
    d.text((left, 260), "12 Oct 2026, 08:41", fill=(90, 90, 90), font=font(26))
    d.line((left, 320, edge, 320), fill=(60, 60, 60), width=2)
    for i, (label, amount) in enumerate([("Fare", "18.50"), ("Tolls", "5.00"), ("Tip", "3.00")]):
        y = 350 + i * 58
        d.text((left, y), label, fill="black", font=font(34))
        right(d, edge, y, amount, 34)
    d.line((left, 540, edge, 540), fill="black", width=4)
    bold(d, (left, 572), "TOTAL", 56)
    right(d, edge, 572, "26.50", 56, heavy=True)
    d.text((left, 680), "Paid by card", fill=(90, 90, 90), font=font(26))
    d.text((left, 760), "Thank you for riding with us", fill=(120, 120, 120), font=font(24))
    return im


def main():
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, "taxi_receipt.png")
    taxi_receipt().save(path, "PNG", optimize=True)
    print(path)


if __name__ == "__main__":
    main()
