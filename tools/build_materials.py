"""Bake AI Sims' tileable material library and original nonverbal sound cues."""

import math
import random
import struct
import wave
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets/release/textures"
N = 1024
TAU = 2 * math.pi
X, Y = np.meshgrid(np.arange(N, dtype=np.float32) / N, np.arange(N, dtype=np.float32) / N)


def field(seed, bands):
    """Periodic, isotropic noise with controlled grain at each octave."""
    rng = np.random.default_rng(seed)
    result = np.zeros_like(X)
    for frequency, amplitude in bands:
        for _ in range(5):
            angle, phase = rng.uniform(0, TAU, 2)
            fx = round(frequency * math.cos(angle))
            fy = round(frequency * math.sin(angle))
            result += np.sin(TAU * (fx * X + fy * Y) + phase) * amplitude / 3
    return result


def seam(coordinate, count, radius):
    distance = np.abs((coordinate * count + .5) % 1 - .5) * N / count
    t = np.clip(1 - distance / radius, 0, 1)
    return t * t * (3 - 2 * t)


def courses(columns, rows, mortar, stagger):
    row = np.floor(Y * rows).astype(int)
    shift = (row % stagger) / (stagger * columns)
    column = np.floor(((X + shift) % 1) * columns).astype(int)
    joint = np.maximum(seam(X + shift, columns, mortar), seam(Y, rows, mortar))
    return column, row, joint


def aggregate(seed, count, span):
    rng = np.random.default_rng(seed)
    canvas = Image.new("L", (N, N), 128)
    draw = ImageDraw.Draw(canvas)
    for _ in range(count):
        u, v = rng.integers(0, N, 2)
        radius = int(rng.integers(1, span + 1))
        color = int(rng.choice([89, 108, 116, 147, 166, 192]))
        for ox in ([-N, 0] if u > N - radius * 2 else ([0, N] if u < radius else [0])):
            for oy in ([-N, 0] if v > N - radius else ([0, N] if v < radius else [0])):
                px, py = u + ox, v + oy
                draw.polygon([(px - radius, py), (px, py - radius), (px + radius * 2, py + radius // 2),
                              (px, py + radius)], fill=color)
    return np.asarray(canvas, dtype=np.float32) - 128


def write_material(name, color, shade, height, roughness):
    albedo = np.clip(np.asarray(color, dtype=np.float32) + shade[..., None], 0, 255).astype("uint8")
    dx = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * .5
    dy = (np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) * .5
    normal = np.stack((-dx, dy, np.ones_like(dx)), axis=2)
    normal /= np.linalg.norm(normal, axis=2, keepdims=True)
    normal = np.clip(128 + normal * 127, 0, 255).astype("uint8")
    roughness = np.broadcast_to(roughness, X.shape).clip(0, 255).astype("uint8")
    Image.fromarray(albedo).save(OUT / f"{name}_color.png", optimize=True)
    Image.fromarray(normal).save(OUT / f"{name}_normal.png", optimize=True)
    roughness_image = Image.fromarray(roughness).resize((N // 2, N // 2), Image.Resampling.BOX)
    roughness_image.save(OUT / f"{name}_roughness.png", optimize=True)


def build_materials():
    OUT.mkdir(parents=True, exist_ok=True)
    stone = field(81, [(3, 2), (11, 2), (31, 1.2), (119, .8)])
    mottling = field(117, [(2, 3.4), (7, 2.5), (19, 1)])
    sand = field(522, [(51, 2), (127, 1.3), (194, .9)])
    chips = aggregate(660, 5100, 3)

    joint = np.maximum(seam(X, 2, 2.8), seam(Y, 2, 2.8))
    write_material("floor", (215, 213, 203), stone + chips * .32 - joint * 22,
                   stone * .025 + chips * .021 - joint * .52, 185 + stone + joint * 40)

    horizontal = seam(Y, 2, 3.5)
    vertical = seam(X + np.floor(Y * 2) * .125, 2, 3.5)
    joint = np.maximum(horizontal, vertical)
    traffic = field(93, [(2, 3), (5, 3), (13, 1.5)]).clip(-8, 0)
    write_material("concrete_slab", (204, 203, 194), stone + traffic + chips * .16 - joint * 17,
                   sand * .017 - joint * .52, 218 + traffic * 1.6 + joint * 20)

    x_cell, y_cell, joint = courses(8, 12, 2.8, 2)
    rng = np.random.default_rng(510)
    paver_colors = rng.integers(-15, 12, size=(12, 8))[y_cell, x_cell]
    write_material("courtyard_pavers", (200, 181, 159),
                   paver_colors + stone + sand * .8 - joint * 32,
                   sand * .04 - joint * .7, 191 + paver_colors * .7 + joint * 43)

    granules = aggregate(991, 14800, 4)
    write_material("compacted_gravel", (167, 171, 168), mottling + granules * .29 + sand * .94,
                   granules * .014 + sand * .024, 228 + granules * .17)

    column, row, joint = courses(2, 13, 2.6, 3)
    rng = np.random.default_rng(211)
    board_colors = rng.integers(-8, 10, size=(13, 2))[row, column]
    run = Y + .007 * np.sin(TAU * (3 * X + 2 * Y)) + .002 * np.sin(TAU * 13 * X)
    knot_x = np.sin(TAU * (X - .14)) / 6
    knot_y = np.sin(TAU * (Y - .29)) * 1.3
    knot = np.exp(-200 * (knot_x ** 2 + knot_y ** 2)) * np.sin(170 * np.hypot(knot_x, knot_y))
    wood = np.sin(TAU * run * 56) * 2 + np.cos(TAU * run * 43) * 3 + knot * 6 + mottling * .6
    write_material("wood", (194, 157, 119), wood + board_colors - joint * 32,
                   wood * .044 - joint * .85, 161 + board_colors - wood * 1.6 + joint * 42)

    plaster = mottling * .82 + sand * 1.2 + chips * .045
    write_material("wall", (229, 225, 213), plaster, plaster * .038, 214 + plaster * 1.1)

    column, row, joint = courses(16, 32, 2.5, 2)
    rng = np.random.default_rng(71)
    brick_colors = rng.integers(-5, 7, size=(32, 16))[row, column]
    write_material("painted_brick", (218, 206, 193), brick_colors + plaster - joint * 14,
                   plaster * .055 - joint * .48, 221 + brick_colors + sand + joint * 10)

    warp = np.cos(TAU * 136 * X)
    weft = np.cos(TAU * 136 * Y)
    direction = np.sin(TAU * (34 * X - 34 * Y))
    cloth = 2.6 * np.where(direction > 0, warp, weft) + 2.2 * direction + mottling * .46
    write_material("fabric", (202, 201, 193), cloth, cloth * .09, 213 + cloth * 1.5)

    brush = np.sin(TAU * (151 * Y + .08 * np.cos(TAU * 3 * X))) * 1.1
    plate = np.maximum(seam(X, 4, 3.2), seam(Y, 2, 3.2))
    row = np.floor(Y * 16)
    lx = ((X + (row % 2) / 64) * 32) % 1 - .5
    ly = (Y * 16) % 1 - .5
    grip = np.clip((1 - (lx * 3.2) ** 2 - (ly * 6.8) ** 2) * 2, 0, 1)
    write_material("metal", (171, 178, 182), stone + brush + grip * 11 - plate * 24,
                   sand * .015 + grip * .37 - plate * .74, 145 + stone * 2 + grip * 18 + plate * 24)

    panel = np.maximum(seam(X, 4, 4.0), seam(Y, 2, 3.2))
    offsets = np.arange(4, dtype=np.float32) / 4
    fasteners = np.zeros_like(X)
    for offset in offsets:
        radial_x = ((X - offset - .023 + .5) % 1) - .5
        radial_y = ((Y - .035 + .25) % .5) - .25
        screw = np.clip(1 - (radial_x * 222) ** 2 - (radial_y * 222) ** 2, 0, 1)
        fasteners = np.maximum(fasteners, screw)
    write_material("enamel_panel", (192, 203, 208), stone * .8 + brush - panel * 31 - fasteners * 45,
                   sand * .012 - panel * .78 - fasteners * .32, 151 + mottling + panel * 43)

    cell_x, cell_y, joint = courses(8, 8, 3.8, 1)
    tile_var = ((cell_x + cell_y) % 2) * 4 - 2
    glaze = stone * .7 + tile_var
    write_material("tile", (226, 226, 213), glaze - joint * 37,
                   sand * .017 - joint * .67, 127 + glaze + joint * 70)

    for preset in OUT.glob("*.png.import"):
        imported = preset.read_text(encoding="utf8")
        if "mipmaps/generate=false" in imported:
            preset.write_text(imported.replace("mipmaps/generate=false", "mipmaps/generate=true"), encoding="utf8")
    print("Baked eleven tileable material families.")


def build_audio():
    # Retain the original deterministic cue waveforms.
    random.seed(41)
    for _ in range(6 * 512 * 512):
        random.random()
    audio = ROOT / "assets/release/audio"
    audio.mkdir(parents=True, exist_ok=True)
    for name, frequency, length in [("click", 660, .055), ("success", 880, .13), ("door", 150, .25),
                                    ("step", 90, .07), ("message", 1046, .18), ("impact", 70, .15)]:
        samples = bytearray()
        rate = 22050
        for index in range(int(rate * length)):
            time = index / rate
            envelope = (1 - time / length) ** 2
            value = math.sin(2 * math.pi * frequency * time) * .18 * envelope
            if name in ["door", "step", "impact"]:
                value += (random.random() * 2 - 1) * .12 * envelope
            samples.extend(struct.pack("<h", int(value * 32767)))
        with wave.open(str(audio / f"{name}.wav"), "wb") as file:
            file.setnchannels(1)
            file.setsampwidth(2)
            file.setframerate(rate)
            file.writeframes(samples)


if __name__ == "__main__":
    build_materials()
    build_audio()
