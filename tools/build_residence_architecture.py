"""Author the Residence modular geometry in Blender 4.5 LTS.

blender --background --factory-startup --python tools/build_residence_architecture.py

Model coordinates use the game's metre scale, with Y up and +Z facing out.
The GLB library contains one named node per installable module. The game places
the modules from canonical walls and props, independently of saved snapshots.
"""

import math
import struct
import sys
import zlib
from collections import defaultdict
from pathlib import Path

import bpy
import numpy as np


OUTPUT = Path(__file__).resolve().parents[1] / "assets/release/maps/residence/residence_architecture.glb"

# (sRGB hex, roughness, metalness)
FINISHES = {
    "Plaster": ("D1C8B7", .82, 0),
    "Brick": ("B3846C", .89, 0),
    "Sandstone": ("B4A895", .78, 0),
    "WarmLime": ("E1D7C5", .82, 0),
    "Seal": ("3D433D", .87, 0),
    "GreenPaint": ("66756B", .55, 0),
    "BlackenedSteel": ("424640", .53, .43),
    "Bronze": ("AD9670", .43, .51),
    "GlassGreen": ("58706C", .21, .29),
    "GlassBlue": ("5A6B75", .26, .28),
    "GlassWarm": ("7C7664", .26, .18),
    "Cotton": ("D4CBBA", .95, 0),
    "Paper": ("D7D0BC", .94, 0),
    "Pavement": ("A49B90", .92, 0),
    "PavementWarm": ("AA9C89", .91, 0),
    "PavementCool": ("9D9C94", .89, 0),
    "PavementPale": ("B7A994", .91, 0),
    "Joint": ("76716A", .95, 0),
    "Oak": ("B39472", .65, 0),
    "Walnut": ("8B705B", .69, 0),
    "Upholstery": ("737B6B", .92, 0),
    "UpholsteryDark": ("657269", .93, 0),
    "UpholsteryLight": ("B4A48A", .89, 0),
    "Ceramic": ("C2C0AB", .37, 0),
    "Stainless": ("A3A5A3", .33, .68),
    "MilkGlass": ("DFD8C2", .44, 0),
    "EnameledTile": ("AEAD9E", .48, 0),
    "Forest": ("748267", .91, 0),
    "Umber": ("805E4E", .92, 0),
    "Saffron": ("B69A65", .90, 0),
    "Blue": ("6E8183", .92, 0),
    "ClothRed": ("8C6756", .96, 0),
    "Basalt": ("6C6E69", .92, 0),
    "RoofTile": ("96705D", .85, 0),
    "RugWeave": ("FFFFFF", .96, 0),
    "FarLime": ("A79E8E", .91, 0),
    "FarBrick": ("A48475", .87, 0),
    "FarStone": ("B6AEA0", .82, 0),
    "FarPaint": ("87918A", .83, 0),
    "FarGlass": ("647271", .43, .15),
    "FarRoof": ("626460", .87, 0),
    "Pottery": ("9C7461", .93, 0),
    "LeafLight": ("7A874D", .79, 0),
    "LeafMid": ("5F754D", .81, 0),
    "LeafShade": ("485B3C", .86, 0),
    "CeramicWarm": ("B6B4A3", .44, 0),
    "CeramicCream": ("CDC9B6", .46, 0),
    "CeramicMoss": ("A2AEA0", .47, 0),
    "Grout": ("8C8D80", .93, 0),
    "JamGlass": ("86705D", .26, .14),
    "BottleGlass": ("6B7970", .31, .25),
    "Cardboard": ("ABA285", .92, 0),
    "OvenGlass": ("4D5759", .30, .31),
    "ZincRoof": ("768989", .72, .27),
    "ZincRoofDark": ("677977", .81, .23),
    "SlateRoof": ("59635E", .88, 0),
    "SlateRoofSoft": ("666C65", .92, 0),
    "ClayRoof": ("9F7560", .87, 0),
    "ClayRoofDark": ("876750", .94, 0),
    "OakDark": ("967F66", .75, 0),
    "BrushedBrass": ("A99262", .38, .63),
    "WarmIvory": ("DAD4BF", .79, 0),
    "IndigoInk": ("465D63", .92, 0),
    "PaperDark": ("A79677", .96, 0),
    "DriedLeaf": ("867F56", .95, 0),
    "PaintedTin": ("738E8C", .49, .13),
}


def linear(channel):
    return channel / 12.92 if channel <= .04045 else ((channel + .055) / 1.055) ** 2.4


def make_materials():
    materials = {}
    for name, (hex_color, rough, metal) in FINISHES.items():
        color = tuple(linear(int(hex_color[i:i + 2], 16) / 255) for i in (0, 2, 4)) + (1,)
        mat = bpy.data.materials.new(name)
        mat.diffuse_color = color
        mat.use_nodes = True
        surface = mat.node_tree.nodes.get("Principled BSDF")
        surface.inputs["Base Color"].default_value = color
        surface.inputs["Metallic"].default_value = metal
        surface.inputs["Roughness"].default_value = rough
        if name == "MilkGlass":
            surface.inputs["Emission Color"].default_value = color
            surface.inputs["Emission Strength"].default_value = .32
        materials[name] = mat
    return materials


class Module:
    def __init__(self, name):
        self.name = name
        self.parts = defaultdict(lambda: ([], []))

    def shape(self, material, vertices, faces, bevel=.0):
        verts, polygons = self.parts[(material, bevel)]
        first = len(verts)
        verts.extend((x, -z, y) for x, y, z in vertices)
        polygons.extend(tuple(first + index for index in face) for face in faces)

    def box(self, material, at, size, bevel=.0, yaw=.0):
        x, y, z = at
        w, h, d = (value * .5 for value in size)
        c, s = math.cos(yaw), math.sin(yaw)
        verts = [(x + i * c + k * s, y + j, z - i * s + k * c)
                 for i, j, k in ((-w, -h, -d), (w, -h, -d), (w, h, -d), (-w, h, -d),
                                  (-w, -h, d), (w, -h, d), (w, h, d), (-w, h, d))]
        self.shape(material, verts, [(3, 2, 1, 0), (4, 5, 6, 7), (0, 1, 5, 4),
                                     (7, 6, 2, 3), (4, 7, 3, 0), (1, 2, 6, 5)], bevel)

    def cylinder(self, material, at, radius, height, sides=12, upper=None, bevel=.0):
        x, y, z = at
        top_radius = radius if upper is None else upper
        angles = [index * math.tau / sides for index in range(sides)]
        verts = [(x + math.cos(a) * r, level, z - math.sin(a) * r)
                 for r, level in ((radius, y - height * .5), (top_radius, y + height * .5))
                 for a in angles]
        faces = [tuple(reversed(range(sides))), tuple(range(sides, sides * 2))]
        for index in range(sides):
            next_index = (index + 1) % sides
            faces.append((index, next_index, next_index + sides, index + sides))
        self.shape(material, verts, faces, bevel)

    def tube(self, material, points, radius, sides=8):
        vertices, faces = [], []
        for index, point in enumerate(points):
            prior = np.asarray(points[max(0, index - 1)])
            next_point = np.asarray(points[min(index + 1, len(points) - 1)])
            axis = next_point - prior
            axis /= np.linalg.norm(axis)
            tangent = (0, 0, 1) if abs(axis[0]) > .90 else (1, 0, 0)
            across = np.cross(axis, tangent)
            across /= np.linalg.norm(across)
            rise = np.cross(axis, across)
            for side in range(sides):
                angle = side * math.tau / sides
                vertices.append(point + radius * (across * math.cos(angle) + rise * math.sin(angle)))
        for row in range(len(points) - 1):
            for side in range(sides):
                i = row * sides + side
                j = row * sides + (side + 1) % sides
                faces.append((i, j, j + sides, i + sides))
        self.shape(material, vertices, faces)

    def fold(self, material, at, width, height, phase, side=1):
        x, y, z = at
        count = 25
        verts = []
        for vertical in range(5):
            v = vertical / 4
            for horizontal in range(count):
                u = horizontal / (count - 1)
                wave = math.sin(u * math.tau * 4 + phase + vertical * .15)
                verts.append((x + (u - .5) * width * (1 - .19 * v),
                              y + (v - .5) * height + wave * .018 * (1 - v),
                              z + side * wave * (.023 + v * .013)))
        faces = []
        for row in range(4):
            for column in range(count - 1):
                i = row * count + column
                face = (i, i + 1, i + 1 + count, i + count)
                faces.append(face if side > 0 else face[::-1])
        self.shape(material, verts, faces)

    def export(self, materials):
        group = bpy.data.objects.new(self.name, None)
        bpy.context.collection.objects.link(group)
        by_material = defaultdict(list)
        for (name, bevel), (verts, faces) in self.parts.items():
            mesh = bpy.data.meshes.new(name)
            mesh.from_pydata(verts, [], faces)
            mesh.update()
            obj = bpy.data.objects.new(f"{self.name}_{name}", mesh)
            bpy.context.collection.objects.link(obj)
            obj.parent = group
            mesh.materials.append(materials[name])
            if name == "RugWeave":
                uv_layer = mesh.uv_layers.new(name="Weave")
                for loop in mesh.loops:
                    vertex = mesh.vertices[loop.vertex_index].co
                    uv_layer.data[loop.index].uv = (vertex.x / 4.86 + .5, -vertex.y / 3.22 + .5)
            if bevel:
                bevel_modifier = obj.modifiers.new("BeveledEdges", "BEVEL")
                bevel_modifier.width = bevel
                # Narrow trim and skyline edges affect only subpixel highlights during gameplay.
                bevel_modifier.segments = 2 if bevel >= .010 and not self.name.startswith("skyline_") else 1
                normal = obj.modifiers.new("WeightedCorners", "WEIGHTED_NORMAL")
                normal.keep_sharp = True
                bpy.context.view_layer.objects.active = obj
                for modifier in list(obj.modifiers):
                    bpy.ops.object.modifier_apply(modifier=modifier.name)
            by_material[name].append(obj)
        # Preserve fixed pivots while sharing a single mesh resource per module.
        bpy.ops.object.select_all(action="DESELECT")
        objects = [obj for members in by_material.values() for obj in members]
        for obj in objects:
            obj.select_set(True)
        bpy.context.view_layer.objects.active = objects[0]
        bpy.ops.object.join()
        objects[0].name = f"{self.name}_Mesh"


def wall(name, cladding, kind):
    part = Module(name)
    width, height, thickness = 2.6, 2.8, .20
    for material, y, tall, deep in (("Sandstone", .145, .29, .214), ("WarmLime", 2.702, .196, .222)):
        part.box(material, (0, y, 0), (width, tall, deep), .011)
    part.box("Walnut", (0, .115, -.113), (width, .125, .024), .006)
    if kind == "blind":
        part.box(cladding, (0, 1.418, 0), (width, 2.26, thickness), .006)
        part.box("Sandstone", (.91, 1.4, .108), (.062, 2.22, .018), .003)
        return part

    opening = {"home": 1.42, "shop": 1.83, "civic": 1.61}[kind]
    bottom = {"home": .84, "shop": .53, "civic": .74}[kind]
    top = 2.33 if kind == "shop" else 2.24
    center = (bottom + top) * .5
    part.box(cladding, (0, (.29 + bottom) * .5, 0), (width, bottom - .29, thickness), .007)
    part.box(cladding, (0, (2.604 + top) * .5, 0), (width, 2.604 - top, thickness), .007)
    for side in (-1, 1):
        part.box(cladding, (side * (width + opening) * .25, center, 0),
                 ((width - opening) * .5, top - bottom, thickness), .008)
        # Continuous construction through the canonical wall with light-catching reveals.
        part.box("Sandstone", (side * (opening * .5 - .018), center, 0), (.037, top - bottom, .213), .006)

    casing = {"home": "Oak", "shop": "GreenPaint", "civic": "BlackenedSteel"}[kind]
    part.box("Seal", (0, center, 0), (opening, top - bottom, .025), .004)
    for side in (-1, 1):
        face = side * .034
        for jamb in (-1, 1):
            part.box(casing, (jamb * (opening * .5 - .046), center, face),
                     (.095, top - bottom, .045), .007)
            part.box(casing, (0, center + jamb * ((top - bottom) * .5 - .048), face),
                     (opening - .065, .095, .05), .007)
        panes = 3 if kind == "shop" else 2
        pane_width = (opening - .17) / panes
        for index in range(panes):
            x = (index - (panes - 1) * .5) * pane_width
            tones = ("GlassBlue", "GlassGreen", "GlassWarm")
            for row in (0, 1):
                pane_height = ((top - bottom) - .18) * (.68 if not row else .32)
                y = bottom + .088 + pane_height * .5 if not row else top - .088 - pane_height * .5
                part.box(tones[(index + row + int(side > 0)) % len(tones)], (x, y, side * .023),
                         (pane_width - .049, pane_height - .047, .014), .003)
            if index:
                part.box(casing, (x - pane_width * .5, center, face), (.058, top - bottom - .13, .057), .006)
        part.box(casing, (0, bottom + (top - bottom) * .65, face),
                 (opening - .14, .049, .062), .005)
        part.box("Sandstone", (0, bottom - .027, side * .105), (opening + .21, .092, .27), .012)
        part.box("WarmLime", (0, top + .042, side * .109), (opening + .18, .125, .052), .011)
        part.box("Bronze", (-.09, center - .11, side * .075), (.113, .019, .015), .004)
        if kind == "home":
            for direction in (-1, 1):
                part.fold("Cotton", (direction * (opening * .5 - .14), center, side * .084),
                          .16, top - bottom - .19, direction * .63, side)
        elif kind == "civic":
            for index in range(8):
                part.box("Cotton", (0, top - .12 - index * .048, side * .071),
                         (opening - .20, .020, .024), .002)
    return part


def paving(name, variation):
    part = Module(name)
    square = 2.4
    part.box("Joint", (0, .001, 0), (square, .015, square), 0)
    shades = ["Pavement", "PavementWarm", "PavementCool", "PavementPale"]
    if variation == 2:
        for i in range(6):
            for j in range(6):
                color = "Basalt" if i in (0, 5) or j in (0, 5) else shades[(i * 5 + j) % 4]
                part.box(color, ((i - 2.5) * .4, .013, (j - 2.5) * .4), (.384, .019, .384), .006)
        return part
    if variation == 3:
        # Cut crossover setts are individually laid around the drainage channel.
        for row in range(9):
            z = (row - 4) * .265
            for column in range(7):
                x = (column - 3) * .34
                color = "Basalt" if column == 3 or row in (0, 8) else shades[(row * 7 + column * 3) % 4]
                part.box(color, (x, .013, z), (.324, .019, .250), .004)
        return part
    for j in range(6):
        z = (j - 2.5) * .4
        shift = .30 if (j + variation) % 2 else 0.0
        for i in range(5):
            left = max(-square * .5, -square * .5 + (i - 1) * .60 + shift)
            right = min(square * .5, -square * .5 + i * .60 + shift)
            if right - left < .1:
                continue
            color = shades[(i * 3 + j * 2 + variation) % len(shades)]
            part.box(color, ((left + right) * .5, .013, z), (right - left - .012, .019, .386), .006)
    return part


def court_grates():
    part = Module("court_grates")
    part.box("BlackenedSteel", (0, .002, 0), (.455, .007, .762), .002)
    for rail in (-.207, .207):
        part.box("Stainless", (rail, .006, 0), (.024, .011, .745), .002)
    for index in range(19):
        z = (index - 9) * .0395
        part.box("Stainless", (0, .006, z), (.415, .011, .014), .002)
    return part


def rain_pipe():
    part = Module("rain_pipe")
    part.tube("ZincRoofDark", [(0, .14, .114), (0, .30, .039), (0, 2.49, .039),
                               (0, 2.61, .073), (0, 2.70, .153)], .036, 10)
    for y in (.42, 1.21, 2.02, 2.45):
        part.cylinder("ZincRoof", (0, y, .039), .042, .024, 10, bevel=.002)
        part.box("ZincRoofDark", (0, y, .009), (.139, .031, .037), .005)
    part.box("Basalt", (0, .067, .162), (.166, .095, .207), .008)
    return part


def court_light_span():
    part = Module("court_light_span")
    def drop(x):
        return -.29 * (1.0 - (x / 5.0) ** 2)
    cable = [(x * .5, drop(x * .5), 0) for x in range(-10, 11)]
    part.tube("BlackenedSteel", cable, .011, 6)
    for end in (-1, 1):
        part.box("ZincRoofDark", (end * 4.96, .017, 0), (.16, .085, .09), .016)
    for index in range(-4, 5):
        x = index * 1.05
        y = drop(x)
        part.cylinder("BlackenedSteel", (x, y - .029, 0), .013, .061, 8)
        part.cylinder("BlackenedSteel", (x, y - .079, 0), .062, .045, 10, upper=.035, bevel=.005)
        part.cylinder("MilkGlass", (x, y - .117, 0), .045, .047, 12, upper=.054, bevel=.007)
    return part


def sofa():
    part = Module("seamed_sofa")
    part.box("Walnut", (0, .135, 0), (2.43, .21, .86), .025)
    part.box("UpholsteryDark", (0, .29, .01), (2.52, .286, .91), .075)
    for side in (-1, 1):
        for end in (-1, 1):
            part.box("Walnut", (side * 1.084, .09, end * .333), (.10, .18, .12), .009)
        part.box("Upholstery", (side * 1.16, .48, .04), (.26, .344, .87), .076)
        part.box("UpholsteryDark", (side * 1.16, .616, .04), (.257, .042, .84), .019)
    for index in range(3):
        x = (index - 1) * .681
        part.box("Upholstery", (x, .443, .057), (.654, .159, .697), .068)
        part.box("UpholsteryDark", (x, .451, .406), (.618, .033, .016), .008)
        part.box("Upholstery", (x, .672, -.354), (.656, .368, .235), .067)
    part.box("UpholsteryDark", (0, .605, -.43), (2.46, .58, .18), .061)
    for x, yaw, color in ((-.81, -.13, "UpholsteryLight"), (.84, .25, "Cotton")):
        part.box(color, (x, .652, -.208), (.38, .38, .14), .065, yaw)
    return part


def counter(name, finish, kitchen=False):
    part = Module(name)
    width = 3.2 if kitchen else 3.6
    worktop = .945 if kitchen else 1.0
    part.box("Sandstone" if not kitchen else "Stainless", (0, worktop - .046, 0),
             (width, .092, .89 if kitchen else 1.0), .016)
    part.box("BlackenedSteel", (0, .071, .025), (width - .16, .136, .67), .015)
    part.box(finish, (0, .48, .015), (width - .11, worktop - .21, .76), .017)
    count = 4 if kitchen else 5
    gap = (width - .13) / count
    for panel in range(count):
        x = (panel - (count - 1) * .5) * gap
        for side in (-1, 1):
            part.box("Oak" if side > 0 and not kitchen else finish, (x, .487, side * .404),
                     (gap - .023, worktop - .286, .031), .009)
            part.box("Bronze" if not kitchen else "Stainless", (x, .69, side * .431),
                     (.187, .019, .045), .008)
            if not kitchen and side > 0:
                for index in range(7):
                    part.box("Walnut", (x + (index - 3) * .072, .44, side * .426),
                             (.018, .487, .025), .006)
    return part


def pendant():
    part = Module("pendant")
    part.cylinder("BlackenedSteel", (0, .025, 0), .09, .05, bevel=.009)
    part.cylinder("BlackenedSteel", (0, -.208, 0), .009, .43, 8)
    part.cylinder("BlackenedSteel", (0, -.43, 0), .196, .171, 24, upper=.065, bevel=.009)
    part.cylinder("MilkGlass", (0, -.518, 0), .180, .031, 24, bevel=.005)
    part.cylinder("Bronze", (0, -.499, 0), .196, .021, 24, bevel=.005)
    return part


def rug():
    part = Module("woven_hall")
    part.box("RugWeave", (0, .006, 0), (4.86, .012, 3.22), .003)
    for side in (-1, 1):
        for index in range(95):
            x = (index - 47) * .05
            length = .057 + .038 * (math.sin(index * 1.57 + side) * .5 + .5)
            part.box("Cotton", (x, .004, side * (1.61 + length * .45)), (.016, .007, length),
                     .001, .12 * math.sin(index * 2.3))
    return part


def write_png(file, pixels):
    width, height = pixels.shape[1], pixels.shape[0]

    def chunk(name, payload):
        return struct.pack(">I", len(payload)) + name + payload + struct.pack(">I", zlib.crc32(name + payload))

    scanlines = b"".join(b"\0" + row.tobytes() for row in pixels)
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    file.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(scanlines, 7)) + chunk(b"IEND", b""))


def bake_weave(destination):
    width, height = 1536, 1024
    random = np.random.default_rng(288524)
    x, y = np.meshgrid(np.linspace(-1, 1, width, dtype=np.float32),
                       np.linspace(-1, 1, height, dtype=np.float32))
    abs_x, abs_y = abs(x), abs(y)
    rim = np.minimum(1 - abs_x, (1 - abs_y) * .72)
    palette = np.array([(113, 109, 91), (79, 83, 70), (162, 150, 117), (117, 91, 76),
                        (136, 127, 102), (96, 98, 81)], dtype=np.float32)
    index = np.zeros(x.shape, np.uint8)
    cell_x, cell_y = (x + 1) * 3.5, (y + 1) * 2.5
    diamonds = abs(cell_x % 1 - .5) + abs(cell_y % 1 - .5) * .88
    index[(diamonds < .29) & (rim > .18)] = 5
    index[(diamonds >= .29) & (diamonds < .31) & (rim > .18)] = 4
    index[(diamonds < .105) & (rim > .18)] = 2
    index[(rim >= .096) & (rim < .172)] = 3
    index[(rim >= .078) & (rim < .096)] = 2
    index[(rim >= .031) & (rim < .070)] = 1
    index[(rim >= .043) & (rim < .056)] = 4
    index[rim < .015] = 2
    stitch_band = (rim > .109) & (rim < .151)
    stitch_period = np.maximum(abs_x - abs_y, abs_y - abs_x) * 17 + x * 11 - y * 6
    index[stitch_band & ((stitch_period % 1) < .55)] = 4
    thread = np.sin((x + 1) * math.pi * 265) * np.sin((y + 1) * math.pi * 310)
    fibers = random.normal(0, 3.25, x.shape).astype(np.float32)
    worn = (np.sin(x * 12 + np.sin(y * 11)) + np.cos(y * 12 + np.sin(x * 15))) * 2.2
    shade = thread * 6 + fibers + worn
    image = np.clip(palette[index] + shade[..., np.newaxis], 0, 255).astype(np.uint8)
    write_png(destination / "woven_hall_color.png", image)


def bake_paving_material(destination):
    size = 1024
    rng = np.random.default_rng(445718)

    def noise(cells):
        lattice = rng.standard_normal((cells, cells), dtype=np.float32)
        points = np.arange(size, dtype=np.float32) * (cells / size)
        near = points.astype(np.int32)
        far = (near + 1) % cells
        ratio = points - near
        blend = ratio * ratio * (3 - 2 * ratio)
        top = lattice[near[:, None], near[None, :]] * (1 - blend) + lattice[near[:, None], far[None, :]] * blend
        bottom = lattice[far[:, None], near[None, :]] * (1 - blend) + lattice[far[:, None], far[None, :]] * blend
        return top * (1 - blend[:, None]) + bottom * blend[:, None]

    map_wear = noise(7) * .46 + noise(23) * .20 + noise(70) * .08
    aggregate = noise(185) * .27 + noise(315) * .25 + rng.standard_normal((size, size), dtype=np.float32) * .17
    pits = np.maximum(0, -aggregate - .31) * 1.45
    faded = (map_wear * 24 + aggregate * 15 - pits * 18)[..., None]
    base = np.array((204., 200., 186.), dtype=np.float32)
    albedo = np.clip(base + faded, 82, 245).astype(np.uint8)
    write_png(destination / "courtyard_paver_color.png", albedo)
    roughness = np.clip((.85 + map_wear * .08 + aggregate * .07 + pits * .04) * 255, 145, 255).astype(np.uint8)
    write_png(destination / "courtyard_paver_roughness.png", np.repeat(roughness[..., None], 3, axis=2))
    height = aggregate * .12 + map_wear * .07 - pits * .13
    gx = np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)
    gy = np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)
    normals = np.stack((-gx * 2.2, gy * 2.2, np.ones_like(height)), axis=-1)
    normals /= np.linalg.norm(normals, axis=2, keepdims=True)
    write_png(destination / "courtyard_paver_normal.png", ((normals * .5 + .5) * 255).astype(np.uint8))


def window_basket():
    part = Module("window_basket")
    part.box("Pottery", (0, .073, .01), (1.04, .175, .228), .03)
    part.box("Pottery", (0, .165, .015), (1.12, .049, .256), .011)
    part.box("Umber", (0, .187, .015), (1.04, .012, .199), .015)
    for side in (-1, 1):
        part.box("BlackenedSteel", (side * .395, -.055, -.042), (.041, .14, .118), .005)
    tones = ["LeafLight", "LeafMid", "LeafShade"]
    rng = np.random.default_rng(99713)
    for index in range(42):
        x = (index % 11 - 5) * .086 + rng.uniform(-.021, .021)
        y = .22 + rng.uniform(-.014, .16)
        z = rng.uniform(-.07, .12)
        length, width = rng.uniform(.092, .21), rng.uniform(.034, .058)
        slope = rng.uniform(-.052, .071)
        tip_z = z + rng.uniform(.026, .086)
        verts = [(x, y - .043, z), (x - width, y + .020, z + .032),
                 (x + slope, y + length, tip_z), (x + width, y + .018, z + .039),
                 (x + slope * .31, y + .044, z + .071)]
        part.shape(tones[index % 3], verts, [(0, 1, 4), (1, 2, 4), (2, 3, 4), (3, 0, 4)])
    return part


def tiled_wall():
    part = Module("kitchen_tilecourses")
    width, height = 3.4, 1.26
    part.box("Grout", (0, height * .5, 0), (width, height, .024))
    tones = ["Ceramic", "CeramicWarm", "CeramicCream", "CeramicMoss"]
    for row in range(6):
        stagger = .112 if row % 2 else 0
        for column in range(17):
            left = max(-width / 2, (column - 1) * .226 + stagger - width / 2)
            right = min(width / 2, column * .226 + stagger - width / 2)
            if right - left <= .018:
                continue
            tone = tones[(row * 7 + column * 5 + column // 3) % len(tones)]
            if row == 5:
                tone = "CeramicMoss"
            part.box(tone, ((right + left) * .5, (row + .5) * .21, .018), (right - left - .005, .204, .024), .004)
    part.box("CeramicMoss", (0, height + .016, .021), (width, .063, .050), .007)
    return part


def kitchen_range():
    part = Module("kitchen_range")
    part.box("Stainless", (0, .065, 0), (1.005, .104, .533), .011)
    for side in (-1, 1):
        for depth in (-1, 1):
            x, z = side * .245, depth * .135
            part.cylinder("BlackenedSteel", (x, .124, z), .109, .028, 18, bevel=.004)
            part.cylinder("Seal", (x, .147, z), .069, .028, 16, bevel=.005)
            for bar in (-1, 1):
                part.box("BlackenedSteel", (x + bar * .071, .164, z), (.020, .025, .245), .004)
                part.box("BlackenedSteel", (x, .166, z + bar * .071), (.244, .026, .021), .003)
    for i in range(4):
        part.cylinder("Seal", ((i - 1.5) * .126, .104, .236), .028, .043, 13, bevel=.004)
    return part


def range_hood():
    part = Module("kitchen_hood")
    part.box("Stainless", (0, .31, -.13), (.338, .64, .332), .014)
    bottom = [(-.58, -.13, -.25), (.58, -.13, -.25), (.58, -.13, .236), (-.58, -.13, .236)]
    top = [(-.173, .078, -.24), (.173, .078, -.24), (.173, .078, .05), (-.173, .078, .05)]
    part.shape("Stainless", bottom + top, [(3, 2, 1, 0), (4, 5, 6, 7), (0, 1, 5, 4),
                                           (7, 6, 2, 3), (4, 7, 3, 0), (1, 2, 6, 5)], .009)
    part.box("BlackenedSteel", (0, -.144, 0), (1.05, .038, .43), .008)
    part.box("MilkGlass", (0, -.167, .128), (.47, .018, .064), .004)
    for y in range(7):
        part.box("Stainless", (0, -.169, -.138 + y * .030), (.79, .017, .013), .003)
    return part


def utensil_display():
    part = Module("kitchen_tools")
    part.box("BlackenedSteel", (0, 0, .013), (2.42, .074, .064), .01)
    for index, name in enumerate(("ladle", "turner", "wood", "skimmer", "whisk", "fork", "wood")):
        x = (index - 3) * .327
        z = .075 + (index % 2) * .031
        stop = -.405 + .019 * (index % 3)
        handle = "Oak" if name in ("wood", "turner", "fork") else "Stainless"
        utensil = "BlackenedSteel" if name in ("ladle", "turner", "skimmer") else handle
        part.box("Bronze", (x, -.039, .075), (.039, .123, .035), .008)
        part.box(handle, (x, -.174, z), (.038, .257, .033), .011)
        if name in ("wood", "ladle", "skimmer"):
            # Turn a shallow bowl out from the handle, emulating the edge of the bowl.
            faces = [(x + dx, stop + dy, z + dz) for dx, dy, dz in
                     ((-.068, .02, -.022), (-.047, -.062, .005), (.038, -.063, .008),
                      (.070, .016, -.020), (.040, .059, -.021), (-.041, .059, -.021), (0, 0, .034))]
            part.shape(utensil, faces, [(6, k, (k+1) % 6) for k in range(6)])
        elif name == "whisk":
            for i in range(4):
                part.box("Stainless", (x + (i - 1.5) * .024, stop, z + .016), (.008, .174 - i * .009, .013), .003)
        else:
            part.box(utensil, (x, stop, z), (.106, .128, .027), .012)
            if name == "fork":
                for tip in (-1, 0, 1):
                    part.box("Stainless", (x + tip * .039, stop - .079, z), (.015, .074, .015), .005)
    return part


def packed_jars(part, at, width, number, seed):
    rng = np.random.default_rng(seed)
    x, y, z = at
    for i in range(number):
        t = (i + .5) / number
        position = x + (t - .5) * width + rng.uniform(-.016, .016)
        kind = (i * 5 + seed) % 7
        if kind in (0, 2, 6):
            height = .16 + rng.uniform(.02, .07)
            radius = rng.uniform(.043, .073)
            part.cylinder("JamGlass" if kind == 2 else "BottleGlass", (position, y + height * .5, z), radius, height, 10, bevel=.004)
            part.cylinder("Bronze" if kind == 2 else "GreenPaint", (position, y + height + .007, z), radius * 1.01, .026, 10, bevel=.003)
            part.box("Paper", (position, y + height * .44, z + radius * .93), (radius * 1.08, height * .44, .018), .003)
        elif kind in (1, 4):
            height = .20 + rng.uniform(.01, .07)
            part.box("Cardboard", (position, y + height * .5, z), (.12, height, .087), .006, .075 * (kind - 2))
            part.box("ClothRed" if kind == 1 else "GreenPaint", (position, y + height * .40, z + .05), (.106, .072, .014), .004)
        else:
            height = .18 + rng.uniform(.01, .08)
            part.box("PavementPale", (position, y + height * .47, z), (.114, height, .071), .009, -.11)
            part.box("Walnut", (position, y + .084, z + .041), (.078, .068, .012), .004)


def grocer_shelf():
    part = Module("grocer_shelf")
    part.box("Walnut", (0, .112, 0), (2.07, .21, .642), .021)
    part.box("GreenPaint", (0, 1.018, -.311), (2.09, 1.53, .083), .013)
    for side in (-1, 1):
        part.box("GreenPaint", (side * 1.009, .94, -.025), (.092, 1.70, .63), .015)
    for floor in range(4):
        y = .29 + floor * .465
        part.box("Oak", (0, y, -.027), (2.04, .093, .65), .013)
        part.box("Bronze", (0, y + .014, .304), (1.93, .023, .018), .004)
        packed_jars(part, (0, y + .051, .113), 1.83, 10, 773 + floor)
        packed_jars(part, (.12, y + .052, -.115), 1.56, 8, 111 + 3 * floor)
    part.box("GreenPaint", (0, 1.781, -.024), (2.13, .091, .686), .017)
    return part


def shop_wall_display():
    part = Module("shop_wall_display")
    part.box("GreenPaint", (0, .543, .0), (2.01, 1.174, .042), .012)
    for row in range(3):
        y = .11 + row * .419
        part.box("Oak", (0, y, .066), (2.02, .074, .162), .010)
        part.box("Walnut", (0, y + .064, .153), (2.02, .038, .016), .004)
        packed_jars(part, (0, y + .039, .079), 1.82, 10, 42 + row)
    return part


def market_display(style):
    part = Module(f"market_{style}")
    part.box("OakDark", (0, .562, .009), (2.05, 1.194, .072), .016)
    for edge in (-1, 1):
        part.box("GreenPaint", (edge * .995, .562, .083), (.073, 1.195, .155), .014)
    part.box("GreenPaint", (0, 1.157, .079), (2.09, .117, .180), .015)
    part.box("BrushedBrass", (0, 1.153, .176), (.458, .066, .019), .012)
    for row in range(3):
        y = .105 + row * .367
        part.box("Oak", (0, y, .109), (1.92, .067, .267), .012)
        part.box("Walnut", (0, y + .025, .247), (1.93, .044, .022), .006)
        for tag in (-.62, 0, .62):
            part.box("Paper", (tag, y + .015, .264), (.129, .031, .012), .003)
        if style == "bottles":
            packed_jars(part, (0, y + .039, .133), 1.73, 11, 311 + row * 17)
            continue
        for index in range(8):
            x = (index - 3.5) * .222
            angle = .12 * math.sin(index * 2.8 + row)
            if style == "bread":
                material = ("Saffron", "PavementWarm", "Umber")[(index + row) % 3]
                part.box(material, (x, y + .108, .133), (.171, .135, .160), .058, angle)
                part.box("PaperDark", (x, y + .050, .136), (.184, .030, .168), .003, angle)
                for score in (-.043, .043):
                    part.box("WarmIvory", (x + score, y + .176, .136), (.015, .004, .088), .002, -.32)
            else:
                material = ("PaintedTin", "WarmIvory", "ClothRed")[(index + row * 2) % 3]
                h = .127 + .024 * ((index * 3 + row) % 4)
                part.cylinder(material, (x, y + .039 + h * .5, .136), .072, h, 12, bevel=.006)
                part.cylinder("Stainless", (x, y + h + .044, .136), .068, .013, 12, bevel=.002)
                part.box("Paper", (x, y + h * .47 + .040, .201), (.096, .053, .014), .004)
    return part


def book_row(part, at, length, seed):
    rng = np.random.default_rng(seed)
    x, y, z = at
    while x < at[0] + length - .102:
        width = rng.uniform(.041, .09)
        if x + width > at[0] + length:
            break
        height = rng.uniform(.176, .31)
        color = ("IndigoInk", "ClothRed", "Forest", "PaperDark")[int(rng.integers(4))]
        x += width * .5
        part.box(color, (x, y + height * .5, z), (width, height, .167), .004)
        part.box("Paper", (x, y + height * .5, z - .009), (width * .84, height * .96, .155), .002)
        if rng.random() > .39:
            part.box("BrushedBrass", (x, y + height * .70, z + .087), (width * .70, .012, .005), .001)
        x += width * .5 + rng.uniform(.003, .016)


def hall_archive():
    part = Module("hall_archive")
    part.box("Walnut", (0, .112, -.021), (2.05, .221, .585), .018)
    part.box("OakDark", (0, .983, -.272), (2.08, 1.57, .077), .015)
    for column in (-1, 0, 1):
        part.box("Oak", (column * 1.019, 1.01, -.022), (.069, 1.537, .578), .014)
    for row in range(4):
        y = .226 + row * .489
        part.box("Oak", (0, y, -.009), (2.147, .066, .604), .013)
        if row == 0 or row == 3:
            continue
        for side in (-1, 1):
            book_row(part, (side * .514 - .438, y + .034, .097), .853 - .141 * ((side + row) % 3), 20 + side + row * 13)
    for side in (-1, 1):
        part.box("GreenPaint", (side * .514, .475, .281), (.925, .420, .052), .018)
        part.box("OakDark", (side * .514, .475, .312), (.826, .333, .023), .010)
        part.box("BrushedBrass", (side * .514, .551, .334), (.176, .030, .037), .008)
    return part


def hall_agenda():
    part = Module("hall_agenda")
    part.box("IndigoInk", (0, .017, 0), (.421, .034, .301), .008, -.11)
    part.box("Paper", (.004, .034, -.014), (.384, .011, .251), .005, -.11)
    # A loose page curls above the binding, with ruling legible from the seats.
    for column in (-1, 1):
        vertices = []
        for row in range(5):
            z = -.137 + row * .067
            curl = (row / 4.0) ** 5 * .029
            vertices.extend((column * u, .048 + curl + u * .026, z) for u in (.001, .082, .183))
        faces = []
        for row in range(4):
            for cell in range(2):
                base = row * 3 + cell
                face = (base, base + 3, base + 4, base + 1)
                faces.append(face if column > 0 else face[::-1])
        part.shape("WarmIvory", vertices, faces)
        for row in range(8):
            length = .127 - (row % 3) * .012
            part.box("PaperDark", (column * .09, .052, -.091 + row * .019), (length, .001, .0025))
    part.box("Walnut", (.21, .048, .051), (.174, .01, .012), .004, -.39)
    part.box("BrushedBrass", (.278, .048, .078), (.027, .013, .014), .003, -.39)
    return part


def frame_art():
    part = Module("hall_prints")
    for index, (x, y, w, h) in enumerate(((-.55, .09, .57, .72), (.15, -.02, .64, .79), (.77, .16, .42, .48))):
        part.box("Walnut", (x, y, .025), (w, h, .076), .014)
        part.box("WarmIvory", (x, y, .068), (w - .069, h - .069, .018), .004)
        origin = (x, y + .019, .079)
        for stripe in range(3):
            offset = (stripe - 1) * .031
            part.box("IndigoInk", (x + offset, y - h * .23, .084), (.024, .016, .002))
        # Botanical silhouettes in the print's own plane.
        ox, oy, z = origin
        part.shape("IndigoInk", [(ox - .019, oy - h * .18, z), (ox + .001, oy - h * .18, z),
                                  (ox + .022, oy + h * .235, z), (ox + .012, oy + h * .241, z)], [(0, 1, 2, 3)])
        for leaf in range(7):
            direction = -1 if (leaf + index) % 2 else 1
            y0 = oy + (leaf - 3) * h * .047
            length = w * (.17 - .009 * leaf)
            tip = (ox + direction * length, y0 + h * .068, z)
            vertices = [(ox, y0, z), (ox + direction * length * .68, y0 + h * .018, z), tip,
                        (ox + direction * length * .36, y0 + h * .065, z)]
            part.shape("DriedLeaf" if leaf % 3 else "GreenPaint", vertices, [(0, 1, 2, 3) if direction > 0 else (3, 2, 1, 0)])
    return part


def hall_window_trim():
    part = Module("hall_window_trim")
    part.tube("BlackenedSteel", [(-.96, 2.35, .083), (.96, 2.35, .083)], .016, 8)
    for side in (-1, 1):
        x = side * .76
        part.box("OakDark", (side * .914, 2.352, .049), (.060, .084, .070), .008)
        part.fold("Cotton", (x, 1.480, .087), .34, 1.66, side * .49)
    part.box("PaintedTin", (0, .335, .070), (1.26, .380, .117), .020)
    part.box("WarmIvory", (0, .350, .136), (1.187, .281, .030), .014)
    for louvre in range(11):
        part.box("ZincRoofDark", ((louvre - 5) * .096, .355, .153), (.030, .174, .008), .002)
    part.box("BrushedBrass", (.675, .469, .105), (.078, .039, .053), .009)
    return part


def kitchen_wall_cupboard():
    part = Module("kitchen_wall_cupboard")
    part.box("OakDark", (0, .362, .091), (1.84, .723, .229), .021)
    for side in (-1, 1):
        x = side * .457
        part.box("GreenPaint", (x, .362, .22), (.874, .681, .048), .018)
        part.box("PaintedTin", (x, .362, .247), (.733, .522, .017), .011)
        part.box("BrushedBrass", (x - side * .284, .165, .278), (.038, .132, .042), .009)
    part.box("Oak", (0, .021, .143), (1.86, .056, .278), .010)
    part.box("MilkGlass", (0, -.013, .151), (1.32, .027, .069), .006)
    return part


def secondary_display(style):
    part = Module(f"secondary_{style}")
    part.box("OakDark", (0, .418, .009), (1.68, .789, .062), .013)
    for y in (.1, .502):
        part.box("Oak", (0, y, .133), (1.73, .057, .288), .011)
        if style == "library":
            book_row(part, (-.764, y + .029, .128), 1.53, round(y * 500))
        elif style == "clinic":
            for side in (-1, 1):
                x = side * .36
                part.box("WarmIvory", (x, y + .136, .145), (.48, .21, .232), .027)
                part.box("PaintedTin", (x, y + .143, .271), (.124, .047, .022), .006)
        else:
            for index in range(5):
                x = (index - 2) * .309
                material = "PaintedTin" if (index + round(y * 10)) % 3 else "GreenPaint"
                part.box(material, (x, y + .135, .143), (.27, .216, .25), .017)
                part.box("Paper", (x, y + .129, .277), (.091, .052, .012), .004)
    return part


def dinner_service():
    part = Module("dinner_service")
    for x, z, tone in ((-.91,-.16,"Blue"), (.85,-.13,"Saffron"),(-.02,.16,"Forest")):
        part.box("Cotton",(x-.092,.008,z+.056),(.19,.013,.158),.004,-.19)
        part.cylinder(tone,(x,.023,z),.119,.034,20,bevel=.008)
        part.cylinder("CeramicCream",(x,.038,z),.098,.015,20,bevel=.006)
        part.cylinder("Ceramic",(x+.183,.055,z-.054),.043,.109,16,upper=.052,bevel=.006)
        part.cylinder("Umber",(x+.183,.110,z-.054),.044,.007,16)
        part.box("Stainless",(x-.153,.011,z-.038),(.015,.013,.15),.004,-.11)
    for level, radius in ((.013,.106),(.032,.101),(.124,.076),(.229,.049),(.265,.053)):
        part.cylinder("BottleGlass",(.289,level,-.045),radius,.057 if level < .05 else .095,18,bevel=.007)
    part.box("Oak",(.44,.018,.116),(.362,.033,.196),.013,.29)
    for i in range(5):
        part.box("PavementPale",(.35 + i * .041,.057,.143 - i * .010),(.041,.069,.084),.013,.19)
    return part


def kitchen_sink():
    part = Module("kitchen_sink")
    part.box("GreenPaint",(0,.405,-.024),(.75,.78,.62),.022)
    part.box("BlackenedSteel",(0,.074,.012),(.70,.146,.56),.009)
    part.box("OakDark",(0,.416,.294),(.695,.627,.042),.012)
    part.box("Bronze",(0,.638,.32),(.16,.023,.042),.006)
    for side in [-1,1]:
        part.box("Stainless",(side*.293,.811,0),(.17,.068,.67),.012)
        part.box("Stainless",(0,.811,side*.282),(.59,.068,.11),.011)
        part.box("Stainless",(side*.213,.782,0),(.033,.104,.46),.022)
        part.box("Stainless",(0,.779,side*.229),(.426,.104,.037),.017)
    part.box("Stainless",(0,.737,0),(.428,.038,.46),.012)
    part.cylinder("BlackenedSteel",(0,.759,-.056),.046,.014,18,bevel=.003)
    part.cylinder("Stainless",(0,.856,-.266),.046,.065,16,bevel=.004)
    arch = [(0,.856,-.264), (0,.965,-.260), (0,1.020,-.231), (0,1.047,-.175),
            (0,1.052,-.107), (0,1.043,-.040), (0,1.011,-.001), (0,.992,.005)]
    part.tube("Stainless",arch,.021,12)
    part.box("Bronze",(.08,.864,-.26),(.074,.030,.052),.010)
    return part


def kitchen_pantry():
    part = Module("kitchen_pantry")
    part.box("GreenPaint", (0,.795,-.309),(2.13,1.53,.083),.018)
    part.box("OakDark", (0,.139,0),(2.12,.240,.64),.021)
    for side in (-1,1):
        part.box("GreenPaint",(side*1.025,.865,0),(.105,1.69,.68),.017)
    for level in range(4):
        y = .27 + level*.446
        part.box("Oak",(0,y,0),(2.12,.083,.67),.017)
        for column in range(4):
            x = (column-1.5)*.486
            z = .104 if (column + level) % 2 else -.077
            tone = ["CeramicCream","EnameledTile","Saffron","Blue"][(level+column)%4]
            if level % 2:
                for plate in range(3 + column % 2):
                    part.cylinder(tone,(x, y+.061+plate*.029,z),.127-plate*.009,.029,16,bevel=.008)
            else:
                part.cylinder(tone,(x,y+.088,z),.071,.096,16,upper=.115,bevel=.009)
                part.cylinder("Umber",(x,y+.133,z),.093,.008,16)
                if column % 2:
                    part.cylinder("BottleGlass",(x-.131,y+.117,z-.119),.041,.155,14,bevel=.005)
    return part


def dining_chair():
    part = Module("dining_chair")
    part.box("OakDark",(0,.438,0),(.527,.087,.501),.029)
    part.box("Upholstery",(0,.487,.010),(.483,.056,.446),.024)
    for side in (-1,1):
        for end in (-1,1):
            part.box("OakDark",(side*.214,.216,end*.207),(.048,.428,.051),.009,side*end*.093)
        part.box("OakDark",(side*.223,.713,-.221),(.058,.438,.063),.018)
        part.box("OakDark",(side*.219,.215,0),(.043,.047,.374),.008)
    part.box("OakDark",(0,.891,-.230),(.491,.092,.071),.022)
    part.box("UpholsteryDark",(0,.761,-.215),(.387,.166,.060),.035)
    return part


def crate_stack():
    part = Module("grocer_crates")
    for level in (0,1):
        y = level*.333
        x = .036 if level else -.017
        yaw = -.06 if level else .02
        width = .88 if level else 1.05
        depth = .61 if level else .70
        part.box("OakDark",(x,y+.044,0),(width,.088,depth),.012,yaw)
        for side in (-1,1):
            for slat in range(3):
                height = y+.111+slat*.068
                part.box("Oak",(x,height,side*(depth*.5-.016)),(width,.050,.029),.006,yaw)
                part.box("OakDark",(x+side*(width*.5-.022),height,0),(.033,.049,depth),.006,yaw)
        for index in range(5):
            xp = x+(index-2)*.135
            coat = "Cardboard" if (level+index)%2 else "Cotton"
            part.box(coat,(xp,y+.19,.034),(.121,.216,.244),.021,(index-2)*.031)
            part.box("Paper",(xp,y+.203,.163),(.095,.081,.013),.004)
    return part


def market_produce_crates():
    part = Module("market_produce_crates")
    for y, z, width, depth in ((.124, -.02, 1.04, .79), (.396, -.11, .92, .65), (.637, -.18, .82, .51)):
        part.box("Walnut", (0, y - .095, z), (width, .077, depth), .014)
        for side in (-1, 1):
            part.box("Oak", (side * (width * .5 - .027), y, z), (.051, .198, depth), .012)
            for slat in (-1, 1):
                part.box("OakDark", (0, y + slat * .053, z + side * (depth * .5 - .022)),
                         (width - .084, .064, .043), .009)
        part.box("Paper", (-.201, y + .054, z + depth * .5 + .003), (.146, .059, .011), .002)
    rng = np.random.default_rng(512)
    for row in range(3):
        for col in range(6):
            x = (col - 2.5) * .106 + rng.uniform(-.011, .011)
            z = -.31 + row * .109 + rng.uniform(-.012, .012)
            y = .727 + rng.uniform(-.014, .011)
            radius = rng.uniform(.045, .054)
            part.cylinder(("Saffron", "Forest", "Umber")[(row + col * 2) % 3], (x, y - .018, z), radius * .90, .039, 9, upper=radius)
            part.cylinder(("Saffron", "Forest", "Umber")[(row + col * 2) % 3], (x, y + .020, z), radius, .036, 9, upper=radius * .61)
    return part


def counter_display():
    part = Module("counter_display")
    part.box("OakDark",(0,.023,-.031),(1.05,.045,.405),.015)
    for side in (-1,1):
        part.box("Oak",(side*.503,.165,-.042),(.050,.323,.378),.014)
    for row in range(2):
        y = .089 + row*.172
        z = -.058 - row*.037
        part.box("Walnut",(0,y,z),(.963,.035,.293),.011)
        part.box("Bronze",(0,y+.015,z+.151),(.964,.048,.022),.008)
        packed_jars(part,(0,y+.022,z+.024),.836,5,151+row)
    return part


def roof_pan(part, material, x0, x1, z0, z1, height, thickness):
    top = [(x, height(z), z) for x,z in ((x0,z0),(x0,z1),(x1,z1),(x1,z0))]
    inset = [(x,y-thickness,z) for x,y,z in top]
    part.shape(material,top+inset,[(0,1,2,3),(7,6,5,4),(1,0,4,5),
                                  (2,1,5,6),(3,2,6,7),(0,3,7,4)],.004)


def roof_shell(style):
    part = Module(f"roof_{style}")
    width, depth = 22.52, 12.52
    half, run = width*.5, depth*.5
    if style == "clay" or style == "zinc":
        height = lambda z: .101 + (1-abs(z)/run)*(.84 if style == "clay" else .61)
        colors = ["ClayRoof","ClayRoofDark"] if style == "clay" else ["ZincRoof","ZincRoofDark"]
        columns = 23 if style == "clay" else 29
        width_each = width/columns
        for column in range(columns):
            x0 = column * width_each - half
            for side in [-1,1]:
                lo, hi = sorted((run*side,0))
                roof_pan(part, colors[int((column*7)%11 in (0,5))], x0, x0+width_each-.008, lo, hi, height, .095)
                ridge = lambda z: height(z)+.022
                roof_pan(part, colors[1],x0,x0+.029,lo,hi,ridge,.035)
        for x in (-half,half):
            part.shape(colors[1],[(x,.025,-run),(x,height(-run),-run),(x,height(0),0),(x,height(run),run),(x,.025,run)],
                       [(0,1,2,3,4) if x<0 else (4,3,2,1,0)])
        part.box(colors[1],(0,height(0)+.013,0),(width,.056,.29),.019)
        for side in [-1,1]:
            part.box("ZincRoofDark",(0,.073,side*(run+.014)),(width,.079,.114),.012)
        for i in range(2 if style == "zinc" else 3):
            x = -6.14 + i*5.2
            z = 2.25 if i%2 else -1.85
            y = height(z)
            part.box(colors[1],(x,y+.213,z),(.68,.465,.71),.027)
            part.box("ZincRoof",(x,y+.46,z),(.84,.121,.86),.021)
    else:
        part.box("SlateRoof",(0,.05,0),(width,.11,depth),.024)
        for side in [-1,1]:
            part.box("SlateRoofSoft",(side*(half-.095),.174,0),(.191,.35,depth),.019)
            part.box("SlateRoofSoft",(0,.174,side*(run-.091)),(width-.41,.35,.183),.018)
            part.box("ZincRoofDark",(side*(half-.096),.353,0),(.262,.058,depth),.012)
            part.box("ZincRoofDark",(0,.353,side*(run-.091)),(width-.41,.058,.255),.012)
        for strip in range(3):
            part.box("SlateRoofSoft", (0,.106,(strip-1)*3.00),(width-.71,.025,.046),.005)
        for x,z in [(-5.4,-1.5),(4.6,2.1)]:
            part.box("ZincRoofDark",(x,.255,z),(2.97,.319,1.48),.041)
            part.box("GlassBlue",(x,.427,z),(2.81,.065,1.33),.024)
            for tooth in range(5):
                part.box("Stainless",(x+(tooth-2)*.545,.461,z),(.046,.028,1.34),.006)
        part.box("SlateRoofSoft",(0,.341,-2.15),(1.69,.472,.91),.028)
        part.box("ZincRoof",(0,.59,-2.15),(1.84,.11,1.07),.019)
        for slit in range(6):
            part.box("Seal",((slit-2.5)*.19,.322,-1.68),(.097,.19,.021),.004)
    return part


def boundary_bay():
    part = Module("perimeter_screen")
    part.box("Sandstone",(0,.41,0),(2.6,.82,.20),.015)
    part.box("Sandstone",(0,.835,0),(2.6,.113,.241),.015)
    part.box("Forest",(0,1.805,0),(2.6,1.93,.193),.002)
    for side in [-1,1]:
        for x in [-.93,-.34,.41,.99]:
            part.box("BlackenedSteel",(x,1.789,side*.108),(.054,1.76,.028),.006)
        for y in [.984,2.54]:
            part.box("BlackenedSteel",(0,y,side*.118),(2.6,.057,.040),.009)
    part.box("Sandstone",(0,2.742,0),(2.6,.116,.24),.018)
    return part


def canopy(name, fabric, striped=False):
    part = Module(name)
    part.box("BlackenedSteel", (0, 0, .01), (3.72, .176, .26), .018)
    segments = 13
    for stripe in range(segments):
        x = (stripe - 6) * .263
        color = "Cotton" if striped and stripe % 2 == 0 else fabric
        vertices = []
        for sample in range(9):
            phase = sample / 8
            height = -.013 - .061 * phase - .141 * phase * phase
            depth = .065 + phase * 1.48
            vertices.extend([(x + side * .1315, height, depth) for side in (-1, 1)])
        # Folded hanging edge with its own scalloped bottom profile.
        for side in (-1, 1):
            vertices.append((x + side * .1315, -.342, 1.548))
        faces = [(sample * 2, (sample + 1) * 2, (sample + 1) * 2 + 1, sample * 2 + 1)
                 for sample in range(9)]
        part.shape(color, vertices, faces)
        part.box(fabric, (x, -.236, 1.543), (.263, .014, .016), .004)
    for side in (-1, 1):
        part.box("BlackenedSteel", (side * 1.61, -.28, .802), (.041, .049, 1.58), .009)
        part.box("Bronze", (side * 1.61, -.211, .094), (.107, .211, .060), .010)
    return part


def skyline(floors):
    part = Module(f"skyline_{floors}")
    width, depth = 13.0, 9.4
    height = floors * 2.65
    face = depth * .5
    shell = {3: "FarBrick", 4: "FarLime", 5: "FarPaint"}[floors]
    part.box(shell, (0, height * .5, 0), (width, height, depth), .06)
    part.box("FarStone", (0, 1.15, 0), (width + .08, 2.30, depth + .08), .025)
    part.box("FarStone", (0, .20, 0), (width + .21, .40, depth + .21), .039)
    if floors == 3:
        run = depth * .5 + .34
        rise = 1.2
        ridge = [(-run, 0), (0, rise), (run, 0)]
        coords = [(x, height + y, z) for x in (-width * .5 - .35, width * .5 + .35) for z, y in ridge]
        part.shape("FarRoof", coords, [(2, 1, 0), (3, 4, 5), (0, 1, 4, 3), (1, 2, 5, 4), (2, 0, 3, 5)], .03)
        part.box("FarBrick", (2.4, height + .994, -.66), (.69, 1.61, .76), .04)
        part.box("FarRoof", (2.4, height + 1.81, -.66), (.82, .16, .89), .035)
    else:
        part.box("FarRoof", (0, height + .08, 0), (width + .30, .23, depth + .30), .032)
        part.box("FarStone", (0, height + .28, face - .04), (width, .39, .19), .022)
        part.box("FarLime", (-3.2, height + .44, -.95), (2.1, .79, 1.31), .041)
        if floors == 5:
            part.box("FarStone", (4.1, height + .62, .63), (2.15, 1.23, 2.0), .049)
            part.box("FarRoof", (4.1, height + 1.26, .63), (2.33, .17, 2.15), .023)
    for floor in range(1, floors):
        y = floor * 2.65 + .13
        part.box("FarStone", (0, y - .91, face + .043), (width + .14, .112, .132), .014)
        for index in range(5):
            x = (index - 2) * 2.28
            opening = 1.36 if (index + floor) % 2 else 1.10
            part.box("FarStone", (x, y, face + .03), (opening + .18, 1.58, .132), .019)
            for pane in (-1, 1):
                part.box("FarGlass", (x + pane * opening * .244, y + .041, face + .105),
                         (opening * .45, 1.34, .027), .009)
            part.box("FarStone", (x, y - .75, face + .108), (opening + .28, .10, .223), .017)
            part.box("FarStone", (x, y + .28, face + .126), (opening, .048, .034), .003)
            if floors >= 4 and (floor + index * 3) % 3 == 0:
                part.box("FarStone", (x, y - .81, face + .50), (1.74, .17, 1.03), .021)
                part.box("FarRoof", (x, y - .15, face + .995), (1.64, .054, .052), .010)
                for rail in range(7):
                    part.box("FarRoof", (x + (rail - 3) * .241, y - .45, face + .995), (.036, .565, .036), .005)
                for direction in (-1, 1):
                    part.box("FarRoof", (x + direction * .817, y - .149, face + .523), (.049, .05, .954), .009)
    for direction in (-1, 1):
        part.box("FarLime", (direction * (width * .5 - .125), height * .53, face + .062),
                 (.220, height * .87, .135), .019)
    for i in range(6):
        x = (i - 2.5) * 1.95
        pane = "FarGlass" if (i + floors) % 3 != 0 else "FarRoof"
        part.box(pane, (x, 1.16, face + .058), (1.35, 1.71, .046), .013)
        part.box("FarRoof", (x, 1.37, face + .096), (1.37, .047, .032), .006)
    return part


def skyline_annex(style):
    part = Module(f"skyline_{style}")
    workshop = style == "atelier"
    shell = "FarPaint" if workshop else "FarBrick"
    depth = 9.4
    height = 8.35 if workshop else 9.85
    face = depth * .5
    part.box(shell, (0, height * .5, -.11), (13, height, depth - .22), .055)
    part.box("FarStone", (0, .26, 0), (13.2, .52, depth + .14), .038)
    part.box("FarRoof", (0, height + .035, -.06), (13.4, .22, depth + .40), .026)
    part.box("FarLime", (0, 2.79, face + .08), (13.22, .25, .59), .024)
    for wing in (-1, 1):
        x = wing * 3.14
        part.box("FarStone", (x, 1.56, face + .055), (5.82, 2.51, .231), .034)
        part.box("FarGlass", (x, 1.62, face + .186), (5.44, 2.21, .071), .019)
        for bay in range(-2, 3):
            part.box("FarRoof", (x + bay * .901, 1.58, face + .243), (.068, 2.33, .079), .010)
        for floor in range(2):
            y = 4.39 + floor * 2.73
            if workshop:
                part.box("FarStone", (x, y, face + .048), (5.28, 1.88, .211), .023)
                part.box("FarGlass", (x, y, face + .171), (5.04, 1.65, .060), .012)
                for rib in range(-2, 3):
                    part.box("FarRoof", (x + rib * .819, y, face + .219), (.056, 1.72, .066), .008)
            else:
                for bay in (-1, 0, 1):
                    bay_x = x + bay * 1.69
                    part.box("FarStone", (bay_x, y, face + .067), (1.28, 1.89, .242), .020)
                    part.box("FarGlass", (bay_x, y - .019, face + .202), (1.05, 1.63, .063), .011)
                    part.box("FarPaint", (bay_x, y - .901, face + .207), (1.35, .086, .273), .013)
        for strut in (-5.4, -3.6, -1.8, 1.8, 3.6, 5.4):
            part.box("FarGlass", (wing * 6.523, height * .62, strut * .67), (.062, 2.05, 1.01), .011)
    upper = .94 if workshop else .43
    part.box("FarLime", (-1.22, height + upper * .5, -.79), (4.32, upper, 3.40), .029)
    part.box("FarRoof", (-1.22, height + upper + .037, -.79), (4.50, .161, 3.54), .021)
    for vent in range(3):
        part.box("FarPaint", (2.11 + vent * .742, height + .214, -.14 + vent * .42), (.56, .425, .784), .036)
    return part


def make_library():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    materials = make_materials()
    modules = [wall("facade_home", "Plaster", "home"), wall("facade_shop", "Brick", "shop"),
               wall("facade_civic", "WarmLime", "civic"), wall("facade_blind", "Plaster", "blind"),
               wall("facade_brick_blind", "Brick", "blind"),
               paving("paving_running_a", 0), paving("paving_running_b", 1), paving("paving_border", 2),
               paving("paving_crossing", 3), court_grates(), rain_pipe(), court_light_span(),
               sofa(), counter("grocer_counter", "GreenPaint"), counter("kitchen_counter", "GreenPaint", True),
               pendant(), rug(), canopy("canopy_common", "Forest"),
               canopy("canopy_kitchen", "Saffron"), canopy("canopy_shop", "ClothRed", True),
               skyline(3), skyline(4), skyline(5), window_basket(), tiled_wall(),
               kitchen_range(), range_hood(), utensil_display(), grocer_shelf(), shop_wall_display(), dinner_service(),
               kitchen_sink(), kitchen_pantry(), dining_chair(), crate_stack(), counter_display(),
               roof_shell("zinc"), roof_shell("clay"), roof_shell("slate"), boundary_bay(),
               skyline_annex("market"), skyline_annex("atelier"), hall_archive(), hall_agenda(), frame_art(), hall_window_trim(),
               kitchen_wall_cupboard(), market_display("bread"), market_display("bottles"), market_display("tins"),
               market_produce_crates(), secondary_display("library"), secondary_display("clinic"), secondary_display("tools")]
    for module in modules:
        module.export(materials)
    arguments = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    output = Path(arguments[0]) if arguments else OUTPUT
    output.parent.mkdir(parents=True, exist_ok=True)
    bake_weave(output.parent)
    bake_paving_material(output.parent)
    bpy.ops.export_scene.gltf(filepath=str(output), export_format="GLB", export_apply=True,
                              export_animations=False, export_lights=False, export_cameras=False,
                              export_extras=False)


if __name__ == "__main__":
    make_library()
