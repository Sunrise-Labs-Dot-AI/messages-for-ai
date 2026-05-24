#!/usr/bin/env python3
"""Render Spotify Wrapped style 9:16 mock story cards."""

from __future__ import annotations

import json
import math
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent
W = 1080
H = 1920
STAMP = "sunriselabs.ai · messagesfor.ai"

FONT_BLACK = "/System/Library/Fonts/Supplemental/Arial Black.ttf"
FONT_BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
FONT_REGULAR = "/System/Library/Fonts/Supplemental/Arial.ttf"
FONT_NARROW = "/System/Library/Fonts/Supplemental/Arial Narrow Bold.ttf"


def font(size: int, face: str = "black") -> ImageFont.FreeTypeFont:
    path = {
        "black": FONT_BLACK,
        "bold": FONT_BOLD,
        "regular": FONT_REGULAR,
        "narrow": FONT_NARROW,
    }.get(face, FONT_BLACK)
    return ImageFont.truetype(path, size)


def rgb(hex_value: str) -> tuple[int, int, int]:
    hex_value = hex_value.strip("#")
    return tuple(int(hex_value[i : i + 2], 16) for i in (0, 2, 4))


def gradient(top: str, bottom: str) -> Image.Image:
    c1 = rgb(top)
    c2 = rgb(bottom)
    img = Image.new("RGB", (W, H))
    px = img.load()
    for y in range(H):
        t = y / (H - 1)
        row = tuple(round(c1[i] * (1 - t) + c2[i] * t) for i in range(3))
        for x in range(W):
            px[x, y] = row
    return img.convert("RGBA")


def add_grain(img: Image.Image, seed: int, opacity: int = 30) -> Image.Image:
    rnd = random.Random(seed)
    noise = Image.new("L", img.size)
    noise.putdata([rnd.randrange(256) for _ in range(W * H)])
    layer = Image.new("RGBA", img.size, (255, 255, 255, 0))
    layer.putalpha(noise.point(lambda p: int(p * opacity / 255)))
    return Image.alpha_composite(img, layer)


def text_width(draw: ImageDraw.ImageDraw, text: str, fnt: ImageFont.FreeTypeFont) -> int:
    box = draw.textbbox((0, 0), text, font=fnt)
    return box[2] - box[0]


def fit_font(text: str, max_width: int, start: int, minimum: int = 54, face: str = "black") -> ImageFont.FreeTypeFont:
    probe = ImageDraw.Draw(Image.new("RGB", (10, 10)))
    for size in range(start, minimum - 1, -4):
        fnt = font(size, face)
        widest = max(text_width(probe, line, fnt) for line in text.split("\n"))
        if widest <= max_width:
            return fnt
    return font(minimum, face)


def wrap_lines(text: str, fnt: ImageFont.FreeTypeFont, max_width: int) -> list[str]:
    probe = ImageDraw.Draw(Image.new("RGB", (10, 10)))
    words = text.split()
    lines: list[str] = []
    current = ""
    for word in words:
        trial = word if not current else f"{current} {word}"
        if text_width(probe, trial, fnt) <= max_width:
            current = trial
        else:
            if current:
                lines.append(current)
            current = word
    if current:
        lines.append(current)
    return lines


def draw_wrapped(draw: ImageDraw.ImageDraw, xy: tuple[int, int], text: str, fnt: ImageFont.FreeTypeFont, fill: str, max_width: int, gap: int = 10) -> int:
    x, y = xy
    line_height = fnt.getbbox("Ag")[3] - fnt.getbbox("Ag")[1]
    for line in wrap_lines(text, fnt, max_width):
        draw.text((x, y), line, font=fnt, fill=fill)
        y += line_height + gap
    return y


def draw_support_badge(draw: ImageDraw.ImageDraw, x: int, y: int, text: str, fill: str, ink: str, max_width: int = 830) -> int:
    fnt = font(38, "black")
    lines = wrap_lines(text, fnt, max_width - 64)
    line_height = fnt.getbbox("Ag")[3] - fnt.getbbox("Ag")[1]
    height = 44 + len(lines) * line_height + max(0, len(lines) - 1) * 6
    draw.rounded_rectangle((x, y, x + max_width, y + height), radius=38, fill=fill)
    yy = y + 22
    for line in lines:
        draw.text((x + 32, yy), line, font=fnt, fill=ink)
        yy += line_height + 6
    return y + height


def blob(draw: ImageDraw.ImageDraw, cx: int, cy: int, rx: int, ry: int, color: str, seed: int, points: int = 30) -> None:
    rnd = random.Random(seed)
    coords = []
    for i in range(points):
        angle = math.tau * i / points
        jitter = 0.72 + rnd.random() * 0.54
        coords.append((cx + math.cos(angle) * rx * jitter, cy + math.sin(angle) * ry * jitter))
    draw.polygon(coords, fill=color)


def star(draw: ImageDraw.ImageDraw, cx: int, cy: int, outer: int, inner: int, color: str, points: int = 16, rot: float = 0) -> None:
    coords = []
    for i in range(points * 2):
        r = outer if i % 2 == 0 else inner
        a = rot + math.pi * i / points
        coords.append((cx + math.cos(a) * r, cy + math.sin(a) * r))
    draw.polygon(coords, fill=color)


def orbital(draw: ImageDraw.ImageDraw, color: str, offset: int, width: int = 58) -> None:
    for i in range(5):
        box = (-360 + i * 55, 150 + offset + i * 22, W + 260 - i * 25, 1420 + offset + i * 18)
        draw.arc(box, start=195 + i * 8, end=338 + i * 6, fill=color, width=width)


def liquid_band(draw: ImageDraw.ImageDraw, color: str, y: int, seed: int) -> None:
    rnd = random.Random(seed)
    top = [(0, y)]
    for x in range(0, W + 90, 90):
        top.append((x, y + rnd.randint(-95, 95)))
    bottom = [(W, y + 360)]
    for x in range(W, -90, -90):
        bottom.append((x, y + 330 + rnd.randint(-85, 105)))
    draw.polygon(top + bottom, fill=color)


def crown(draw: ImageDraw.ImageDraw, x: int, y: int, scale: float, fill: str, outline: str | None = None) -> None:
    pts = [
        (x, y + 130 * scale),
        (x + 70 * scale, y + 10 * scale),
        (x + 150 * scale, y + 120 * scale),
        (x + 245 * scale, y),
        (x + 330 * scale, y + 120 * scale),
        (x + 420 * scale, y + 15 * scale),
        (x + 500 * scale, y + 130 * scale),
        (x + 475 * scale, y + 230 * scale),
        (x + 25 * scale, y + 230 * scale),
    ]
    draw.polygon(pts, fill=fill, outline=outline)


def progress(draw: ImageDraw.ImageDraw, card: int, fill: str, track: str) -> None:
    gap = 10
    w = (W - 120 - gap * 6) // 7
    for i in range(7):
        x = 60 + i * (w + gap)
        color = fill if i < card else track
        draw.rounded_rectangle((x, 54, x + w, 65), radius=6, fill=color)


def footer(draw: ImageDraw.ImageDraw, fill: str) -> None:
    draw.text((W // 2, H - 82), STAMP, font=font(24, "bold"), fill=fill, anchor="mm")


def top_people(draw: ImageDraw.ImageDraw, people: list[dict], x: int, y: int, fill: str, accent: str) -> int:
    for person in people:
        rank = person["rank"]
        name = person["name"]
        yy = y + (rank - 1) * 96
        draw.text((x, yy), str(rank), font=font(44, "black"), fill=accent)
        draw.text((x + 90, yy - 3), name, font=font(62, "black"), fill=fill)
    return y + len(people) * 96


def cards(data: dict) -> list[dict]:
    people = data["mock_top_people"]["people"]
    return [
        {"kind": "cover", "hero": "Your Texting\nWrapped 2026", "verdict": "The receipts are local."},
        {"kind": "hero", "hero": "1,284\ntexts sent", "verdict": "A mock total until the data side ships totals."},
        {"kind": "people", "hero": "Your Top\nPeople", "verdict": "The Top Artists slot, but socially risky.", "people": people},
        {"kind": "reply", "hero": "8.6 min\nvs\n85.5 min", "verdict": "Fast when you reply. The tail tells on you.", "support": "47% within 5 min"},
        {"kind": "ball", "hero": "93%", "verdict": "Almost every active thread is waiting on you."},
        {"kind": "group", "hero": "0.7%", "verdict": "Group chat presence: mostly folklore.", "support": "Silent in 12 of 15 groups. One 1,589-message group got 0 from you."},
        {"kind": "share", "hero": "The Group\nChat Ghost", "verdict": "Left-on-Read Royalty with lurker energy.", "cta": "Share your Texting Wrapped", "secondary": "Replay from beginning"},
    ]


TREATMENTS = {
    "neon-orbit": {
        "bg": ("#4B00FF", "#FF4FD8"),
        "ink": "#F8FFE8",
        "muted": "#D7FFC8",
        "accent": "#C8FF00",
        "accent2": "#00E5FF",
        "track": "#7D43FF",
        "style": "orbit",
    },
    "liquid-pop": {
        "bg": ("#FFE85B", "#FF3A77"),
        "ink": "#101010",
        "muted": "#35122B",
        "accent": "#00E7FF",
        "accent2": "#7CFF2B",
        "track": "#FFB1CA",
        "style": "liquid",
    },
    "blacklight-royalty": {
        "bg": ("#060512", "#25005A"),
        "ink": "#F7FFF0",
        "muted": "#C6B8FF",
        "accent": "#B7FF1A",
        "accent2": "#8A63FF",
        "track": "#392B66",
        "style": "royalty",
    },
}


def background(treatment: dict, card_num: int) -> Image.Image:
    img = gradient(*treatment["bg"])
    img = add_grain(img, seed=900 + card_num, opacity=24)
    draw = ImageDraw.Draw(img)
    style = treatment["style"]
    if style == "orbit":
        blob(draw, 980, 260, 360, 240, treatment["accent"], seed=card_num)
        blob(draw, 120, 1600, 300, 310, treatment["accent2"], seed=card_num + 20)
        orbital(draw, treatment["accent2"], offset=card_num * 22, width=52)
        orbital(draw, treatment["accent"], offset=260 + card_num * 18, width=34)
        star(draw, 900, 1490, 170, 70, "#FF7A00", rot=card_num * 0.2)
    elif style == "liquid":
        liquid_band(draw, treatment["accent"], 120, seed=card_num)
        liquid_band(draw, treatment["accent2"], 760, seed=card_num + 4)
        blob(draw, 840, 1420, 350, 250, "#FFFFFF", seed=card_num + 8)
        star(draw, 170, 260, 150, 68, "#111111", rot=card_num * 0.3)
        star(draw, 920, 690, 120, 45, "#FFFB00", rot=card_num * 0.12)
    else:
        blob(draw, 930, 270, 350, 220, treatment["accent2"], seed=card_num)
        blob(draw, 120, 1650, 360, 250, treatment["accent"], seed=card_num + 20)
        orbital(draw, "#4A1EA1", offset=140 + card_num * 25, width=40)
        if card_num == 7:
            crown(draw, 560, 210, 0.75, treatment["accent"], outline="#101010")
        else:
            crown(draw, 690, 1220, 0.52, treatment["accent"], outline="#101010")
    return img


def draw_card(card: dict, card_num: int, treatment_name: str, treatment: dict, out_path: Path) -> None:
    img = background(treatment, card_num)
    draw = ImageDraw.Draw(img)
    ink = treatment["ink"]
    muted = treatment["muted"]
    accent = treatment["accent"]
    accent2 = treatment["accent2"]

    progress(draw, card_num, accent, treatment["track"])
    draw.text((60, 104), f"{card_num:02d}/07", font=font(34, "black"), fill=ink)
    draw.text((W - 60, 104), "TEXTING WRAPPED", font=font(28, "black"), fill=ink, anchor="ra")

    if card["kind"] == "people":
        hero_font = fit_font(card["hero"], 860, 132, minimum=80, face="black")
        draw_wrapped(draw, (70, 260), card["hero"], hero_font, ink, 850, gap=0)
        top_people(draw, card["people"], 105, 610, ink, accent)
        draw_wrapped(draw, (80, 1265), card["verdict"], font(52, "black"), ink, 880, gap=8)
    elif card["kind"] == "share":
        hero_font = fit_font(card["hero"], 900, 122, minimum=70, face="black")
        draw_wrapped(draw, (70, 280), card["hero"], hero_font, ink, 900, gap=0)
        draw_wrapped(draw, (75, 815), card["verdict"], font(56, "black"), ink, 870, gap=8)
        draw.rounded_rectangle((78, 1110, 880, 1215), radius=52, fill=accent)
        draw.text((479, 1163), card["cta"], font=font(42, "black"), fill="#101010", anchor="mm")
        draw.rounded_rectangle((78, 1245, 650, 1328), radius=42, outline=ink, width=5)
        draw.text((364, 1287), card["secondary"], font=font(34, "black"), fill=ink, anchor="mm")
    else:
        start_size = 180 if card["kind"] in {"ball", "group"} else 132
        if card["kind"] == "cover":
            start_size = 128
        hero_font = fit_font(card["hero"], 930, start_size, minimum=70, face="black")
        y = 325 if card["kind"] != "cover" else 360
        y = draw_wrapped(draw, (70, y), card["hero"], hero_font, ink, 930, gap=8)
        if "support" in card:
            y = draw_support_badge(draw, 74, y + 45, card["support"], accent2, "#101010")
            y += 50
        draw_wrapped(draw, (75, max(y + 70, 1120)), card["verdict"], font(58, "black"), ink, 890, gap=9)

    if treatment_name == "blacklight-royalty":
        footer(draw, muted)
    else:
        footer(draw, ink)
    img.save(out_path)


def load_data() -> dict:
    with open(ROOT / "mock-analysis.json") as f:
        return json.load(f)


def main() -> None:
    data = load_data()
    deck = cards(data)
    out_root = ROOT / "mock-cards"
    for treatment_name, treatment in TREATMENTS.items():
        out_dir = out_root / treatment_name
        out_dir.mkdir(parents=True, exist_ok=True)
        for idx, card in enumerate(deck, 1):
            draw_card(card, idx, treatment_name, treatment, out_dir / f"{idx:02d}-{card['kind']}.png")
    print("Rendered 21 cards.")


if __name__ == "__main__":
    main()
