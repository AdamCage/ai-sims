"""Fit animated MakeHuman faces and hair to the existing resident rigs.

Run with Blender 4.5 LTS in background mode. Pass paths after --. Inputs are
the Quaternius wardrobe GLBs from build_characters.py, MPFB 2.0.18, the
extracted MakeHuman system assets and the Faceunits 01 and Visemes 02 CC0 ZIPs.
"""

import argparse
import gzip
import json
from math import hypot
from pathlib import Path
import sys
from zipfile import ZipFile

import addon_utils
import bmesh
import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree
from mathutils.geometry import barycentric_transform
import numpy as np


HAIRSTYLES = ("short02", "braid01", "short01", "long01", "bob01", "ponytail01")
SKINS = {"female": "middleage_asian_female", "male": "middleage_caucasian_male"}
SOURCE_INDEX = "resident_source_index"
IDENTITIES = {
    "Identity_1": ("head/head-fat-incr", "nose/nose-nostrils-width-incr"),
    "Identity_2": ("head/head-fat-decr", "nose/nose-nostrils-width-decr"),
}
FACE_UNITS = {
    "Blink_L": (("eyeBlinkLeft", 1.0),),
    "Blink_R": (("eyeBlinkRight", 1.0),),
    "Brow_Up": (("browInnerUp", 0.75), ("browOuterUpLeft", 0.45), ("browOuterUpRight", 0.45)),
    "Brow_Down": (("browDownLeft", 0.78), ("browDownRight", 0.78)),
    "Lids_Up": (("eyeLookUpLeft", 0.65), ("eyeLookUpRight", 0.65)),
    "Lids_Down": (("eyeLookDownLeft", 0.65), ("eyeLookDownRight", 0.65)),
    "Concern": (("browInnerUp", 0.63), ("mouthFrownLeft", 0.46), ("mouthFrownRight", 0.39)),
    "Smile": (("mouthSmileLeft", 0.83), ("mouthSmileRight", 0.83)),
    "Tension": (("mouthPressLeft", 0.85), ("mouthPressRight", 0.85)),
    "Jaw_Open": (("jawOpen", 0.68),),
}
VISEMES = {
    "Viseme_A": "aa", "Viseme_E": "E", "Viseme_I": "I", "Viseme_O": "O",
    "Viseme_U": "U", "Viseme_MBP": "PP", "Viseme_FV": "FF", "Viseme_SZ": "SS",
}
BLINKS = ("Blink_L", "Blink_R")
LIDS = ("Lids_Up", "Lids_Down")
BROWS = ("Brow_Up", "Brow_Down")
ORAL_MORPHS = ("Jaw_Open", *VISEMES)


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mpfb-src", type=Path, required=True)
    parser.add_argument("--system-assets", type=Path, required=True)
    parser.add_argument("--face-units", type=Path)
    parser.add_argument("--visemes", type=Path)
    parser.add_argument("--wardrobe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--prototype", choices=SKINS)
    options = parser.parse_args(sys.argv[sys.argv.index("--") + 1 :])
    options.face_units = options.face_units or options.system_assets.parent / "faceunits01.zip"
    options.visemes = options.visemes or options.system_assets.parent / "visemes02.zip"
    return options


def enable_mpfb(source):
    repo = bpy.context.preferences.extensions.repos.new(
        name="AI Sims pinned assets", module="ai_sims_assets", custom_directory=str(source.resolve())
    )
    repo.use_custom_directory = True
    module = addon_utils.enable(f"bl_ext.{repo.module}.mpfb", default_set=True)
    if module is None or module.VERSION != (2, 0, 18):
        raise RuntimeError("MPFB 2.0.18 is required for the resident face build.")
    from bl_ext.ai_sims_assets.mpfb.services.humanservice import HumanService
    from bl_ext.ai_sims_assets.mpfb.services.targetservice import TargetService
    from bl_ext.ai_sims_assets.mpfb.services.clothesservice import ClothesService
    from bl_ext.ai_sims_assets.mpfb.entities.clothes.mhclo import Mhclo

    return HumanService, TargetService, ClothesService, Mhclo


def load_image(path, maximum_size, *, colorspace="sRGB"):
    image = bpy.data.images.load(str(path), check_existing=True)
    image.colorspace_settings.name = colorspace
    if max(image.size) > maximum_size:
        ratio = maximum_size / max(image.size)
        image.scale(*(round(size * ratio) for size in image.size))
        image.pack()
    return image


def add_normal(material, image, strength):
    tree = material.node_tree
    image_node = tree.nodes.new("ShaderNodeTexImage")
    image_node.image = image
    tangent = tree.nodes.new("ShaderNodeNormalMap")
    tangent.inputs["Strength"].default_value = strength
    tree.links.new(image_node.outputs["Color"], tangent.inputs["Color"])
    tree.links.new(tangent.outputs["Normal"], tree.nodes["Principled BSDF"].inputs["Normal"])


def normal_from_skin(image):
    # A restrained normal detail made from the retained skin texture and fine
    # microrelief. Export a regular tangent map that both renderers can sample.
    width, height = image.size
    pixels = np.empty(width * height * 4, dtype=np.float32)
    image.pixels.foreach_get(pixels)
    step = max(1, (max(width, height) + 1023) // 1024)
    diffuse = pixels.reshape(height, width, 4)[::step, ::step]
    height, width = diffuse.shape[:2]
    luma = diffuse[:, :, :3] @ np.array((0.22, 0.66, 0.12), dtype=np.float32)
    # Keep painted lip and eye colour out of the surface relief. A coloured
    # edge in the source texture must not become a ridge across the eyelid.
    near = (np.roll(luma, 2, 0) + np.roll(luma, -2, 0)
            + np.roll(luma, 2, 1) + np.roll(luma, -2, 1)) * 0.25
    freckles = np.clip(luma - near, -0.052, 0.052)
    rng = np.random.default_rng(619)
    pores = rng.normal(0.0, 1.0, (height, width)).astype(np.float32)
    relief = 0.30 * freckles + 0.009 * pores
    dy, dx = np.gradient(relief)
    normal = np.stack((-1.65 * dx, -1.65 * dy, np.ones_like(dx)), axis=-1)
    normal /= np.linalg.norm(normal, axis=-1, keepdims=True)
    packed = np.ones_like(diffuse)
    packed[:, :, :3] = normal * 0.5 + 0.5
    output = bpy.data.images.new("resident_skin_micro_normal", width, height, alpha=False)
    output.colorspace_settings.name = "Non-Color"
    output.pixels.foreach_set(packed.ravel())
    output.pack()
    return output


def smooth_head(head):
    # Subdivide the same neutral mesh and each source shape with identical
    # topology so Blinks and visemes retain their correspondence after export.
    shapes = list(head.data.shape_keys.key_blocks)[1:]
    subdivision = head.modifiers.new("Close-up surface", "SUBSURF")
    subdivision.levels = 1
    subdivision.uv_smooth = "PRESERVE_BOUNDARIES"
    subdivision.boundary_smooth = "PRESERVE_CORNERS"
    graph = bpy.context.evaluated_depsgraph_get()
    smooth = bpy.data.meshes.new_from_object(head.evaluated_get(graph), depsgraph=graph)
    poses = {}
    for shape in shapes:
        shape.value = 1.0
        graph.update()
        coords = coordinate_buffer(head.evaluated_get(graph).data.vertices)
        poses[shape.name] = coords
        shape.value = 0.0
    head.modifiers.remove(subdivision)
    source = head.data
    head.data = smooth
    head.shape_key_add(name="Basis", from_mix=False)
    for name, coords in poses.items():
        shape = head.shape_key_add(name=name, from_mix=False)
        shape.data.foreach_set("co", coords)
    bpy.data.meshes.remove(source)


def image_material(name, image, roughness, *, cards=False, alpha_cutoff=None):
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    material.use_backface_culling = not cards
    tree = material.node_tree
    shader = tree.nodes.get("Principled BSDF")
    shader.inputs["Roughness"].default_value = roughness
    texture = tree.nodes.new("ShaderNodeTexImage")
    texture.image = image
    tree.links.new(texture.outputs["Color"], shader.inputs["Base Color"])
    if alpha_cutoff is not None:
        material.surface_render_method = "DITHERED"
        # Hair uses a stable silhouette mask; the eye asset needs the mask to
        # leave the corneal window clear in front of the textured iris.
        cutoff = tree.nodes.new("ShaderNodeMath")
        cutoff.operation = "GREATER_THAN"
        cutoff.inputs[1].default_value = alpha_cutoff
        tree.links.new(texture.outputs["Alpha"], cutoff.inputs[0])
        tree.links.new(cutoff.outputs[0], shader.inputs["Alpha"])
    elif cards:
        material.surface_render_method = "BLENDED"
        tree.links.new(texture.outputs["Alpha"], shader.inputs["Alpha"])
    return material


def texture_material(name, source, roughness, *, cards=False, alpha_cutoff=None, maximum_size=1024):
    return image_material(name, load_image(source, maximum_size), roughness, cards=cards, alpha_cutoff=alpha_cutoff)


def diffuse_texture(material_file):
    for line in material_file.read_text(encoding="utf-8").splitlines():
        if line.startswith("diffuseTexture "):
            return material_file.parent / line.split(maxsplit=1)[1].strip()
    raise ValueError(f"No diffuse texture in {material_file}")


def split_eye_surfaces(mesh, material, image):
    # The source atlas masks the corneal shell completely. Its dedicated UV
    # island lets us keep an opaque globe and reuse the original shell.
    width, height = image.size
    pixels = np.empty(width * height * 4, dtype=np.float32)
    image.pixels.foreach_get(pixels)
    alpha = pixels.reshape(height, width, 4)[:, :, 3]
    uv = mesh.uv_layers.active.data
    cornea = bpy.data.materials.new("ResidentCorneas")
    cornea.use_nodes = True
    cornea.use_backface_culling = True
    cornea.surface_render_method = "BLENDED"
    interface = cornea.node_tree.nodes["Principled BSDF"]
    interface.inputs["Base Color"].default_value = (0.67, 0.72, 0.75, 1.0)
    interface.inputs["Alpha"].default_value = 0.085
    interface.inputs["Roughness"].default_value = 0.12
    interface.inputs["IOR"].default_value = 1.376
    mesh.materials.append(cornea)
    shell_count = 0
    for polygon in mesh.polygons:
        center = sum((uv[loop].uv for loop in polygon.loop_indices), Vector((0, 0))) / polygon.loop_total
        if alpha[int(center.y * height) % height, int(center.x * width) % width] < 0.2:
            polygon.material_index = 1
            shell_count += 1
    if not 0 < shell_count < len(mesh.polygons):
        raise RuntimeError("Expected opaque globes and a separate corneal UV island.")
    material.surface_render_method = "DITHERED"


def rig_mesh(mesh, rig, *, neck=False, eyes=False):
    mesh.parent = rig
    mesh.vertex_groups.clear()
    if eyes:
        for side, sign in (("L", 1), ("R", -1)):
            pivot = mesh.vertex_groups.new(name=f"Eye_{side}")
            pivot.add([vertex.index for vertex in mesh.data.vertices if vertex.co.x * sign > 0], 1.0, "REPLACE")
    elif neck:
        head = mesh.vertex_groups.new(name="Head")
        collar = mesh.vertex_groups.new(name="neck_01")
        shoulders = mesh.vertex_groups.new(name="spine_03")
        pivot = rig.data.bones["Head"].head_local.z
        neck_base = rig.data.bones["neck_01"].head_local.z
        for vertex in mesh.data.vertices:
            blend = min(1.0, max(0.0, (vertex.co.z - pivot + 0.033) / 0.055))
            collar_blend = min(1.0, max(0.0, (vertex.co.z - neck_base + 0.025) / 0.053))
            if blend > 0.0:
                head.add([vertex.index], blend, "REPLACE")
            if blend < 1.0 and collar_blend > 0.0:
                collar.add([vertex.index], (1.0 - blend) * collar_blend, "REPLACE")
            if blend < 1.0 and collar_blend < 1.0:
                shoulders.add([vertex.index], (1.0 - blend) * (1.0 - collar_blend), "REPLACE")
    else:
        head = mesh.vertex_groups.new(name="Head")
        head.add(list(range(len(mesh.data.vertices))), 1.0, "REPLACE")
    mesh.modifiers.clear()
    modifier = mesh.modifiers.new("Animated resident", "ARMATURE")
    modifier.object = rig
    for face in mesh.data.polygons:
        face.use_smooth = True


def crop_head(mesh, collar_z):
    cropped = bmesh.new()
    cropped.from_mesh(mesh)
    bmesh.ops.bisect_plane(
        cropped,
        geom=list(cropped.verts) + list(cropped.edges) + list(cropped.faces),
        dist=0.00001,
        plane_co=(0, 0, collar_z),
        plane_no=(0, 0, 1),
        clear_inner=True,
    )
    bmesh.ops.delete(cropped, geom=[v for v in cropped.verts if not v.link_faces], context="VERTS")
    # The basemesh includes the shoulders. Fit the lower neck inside the
    # existing collars so those shoulders cannot poke through when animated.
    for vertex in cropped.verts:
        z = vertex.co.z
        if z >= 1.58:
            continue
        blend = min(1.0, (1.58 - z) / 0.035)
        x, y = vertex.co.x, vertex.co.y - 0.02
        span = hypot(x / 0.059, y / 0.053)
        if span > 1.0:
            shrink = 1.0 - blend * (1.0 - 1.0 / span)
            vertex.co.x = x * shrink
            vertex.co.y = 0.02 + y * shrink
    rim = [edge for edge in cropped.edges if edge.is_boundary and all(abs(v.co.z - collar_z) < 0.0001 for v in edge.verts)]
    bmesh.ops.holes_fill(cropped, edges=rim)
    cropped.to_mesh(mesh)
    cropped.free()


def coordinate_buffer(vertices):
    coordinates = np.empty(len(vertices) * 3, dtype=np.float32)
    vertices.foreach_get("co", coordinates)
    return coordinates


def blend_pose(human, target_service, name, components):
    basis_key = human.data.shape_keys.reference_key
    basis = coordinate_buffer(basis_key.data)
    shape = human.shape_key_add(name=name, from_mix=False)
    output = basis.copy()
    for text, weight in components:
        target = target_service.target_string_to_shape_key(text, "ResidentSource", human)
        output += weight * (coordinate_buffer(target.data) - basis)
        human.shape_key_remove(target)
    shape.data.foreach_set("co", output)
    return (output - basis).reshape(-1, 3)


def face_deltas(human, target_service, options):
    if human.data.shape_keys is None:
        human.shape_key_add(name="Basis", from_mix=False)
    morphs = {}
    core_targets = options.mpfb_src / "mpfb" / "data" / "targets"
    for name, paths in IDENTITIES.items():
        sources = []
        for index, path in enumerate(paths):
            with gzip.open(core_targets / (path + ".target.gz"), "rt", encoding="utf-8") as source:
                sources.append((source.read(), 0.38 if index == 0 else 0.55))
        morphs[name] = blend_pose(human, target_service, name, sources)
    with ZipFile(options.face_units) as units:
        for name, targets in FACE_UNITS.items():
            sources = [(units.read(f"targets/faceunits/{target}.target").decode("utf-8"), weight)
                       for target, weight in targets]
            morphs[name] = blend_pose(human, target_service, name, sources)
    with ZipFile(options.visemes) as visemes:
        for name, target in VISEMES.items():
            source = visemes.read(f"targets/visemes/viseme_{target}.target").decode("utf-8")
            morphs[name] = blend_pose(human, target_service, name, ((source, 0.82),))
    return morphs


def skin_morphs(head, deltas, linear_transform):
    ids = head.data.attributes.get(SOURCE_INDEX)
    if ids is None:
        raise RuntimeError("Head crop lost the source vertex correspondence for the resident morphs.")
    source_indices = [entry.value for entry in ids.data]
    head.data.attributes.remove(ids)
    basis = head.shape_key_add(name="Basis", from_mix=False)
    for name, delta in deltas.items():
        shape = head.shape_key_add(name=name, from_mix=False)
        changed = False
        for index, source in enumerate(source_indices):
            if basis.data[index].co.z < 1.51:
                continue
            displacement = linear_transform @ Vector(delta[source])
            if displacement.length_squared > 1e-12:
                shape.data[index].co = basis.data[index].co + displacement
                changed = True
        if not changed:
            raise RuntimeError(f"Resident morph {name} has no retained head vertices.")


def remove_original_head(body):
    retained = bmesh.new()
    retained.from_mesh(body.data)
    faces = [face for face in retained.faces if abs(face.calc_center_median().x) < 0.25]
    bmesh.ops.delete(retained, geom=faces, context="FACES")
    retained.to_mesh(body.data)
    retained.free()
    body.name = "Hands"


def fit_dental_arch(points):
    middle = (min(point.z for point in points) + max(point.z for point in points)) * 0.5
    return [Vector((point.x * 0.96, point.y + 0.005, middle + (point.z - middle) * 0.87))
            for point in points]


def frontal_surface(mesh):
    mesh.calc_loop_triangles()
    vertices = [vertex.co.copy() for vertex in mesh.vertices]
    return vertices, BVHTree.FromPolygons(vertices, [triangle.vertices for triangle in mesh.loop_triangles],
                                         all_triangles=True)


def visible_hair_depth(mesh, vertices, surface, image, x, z, skin_depth):
    # Trace through transparent layers of the existing styled groom. The
    # actual opacity edge guides the attachment points on both head shapes.
    direction = Vector((0.0, 1.0, 0.0))
    start = Vector((x, -0.5, z))
    uv = mesh.uv_layers.active.data
    height, width = image.shape[:2]
    for _ in range(12):
        hit, _, index, _ = surface.ray_cast(start, direction)
        if hit is None or hit.y > skin_depth + 0.001:
            return None
        triangle = mesh.loop_triangles[index]
        a, b, c = (vertices[vertex] for vertex in triangle.vertices)
        u, v, w = (Vector((*uv[loop].uv, 0.0)) for loop in triangle.loops)
        point = barycentric_transform(hit, a, b, c, u, v, w)
        if image[int(point.y * height) % height, int(point.x * width) % width, 3] >= 0.27:
            return hit.y
        start = hit + direction * 0.00010
    return None


def crown_strands(surface, crown, rng):
    # Follow the sculpted cap from the part to the sides of the crown. Grazing
    # and back light reveal the fine strands above the volume of the cut.
    down = Vector((0, 0, -1))
    strands = []
    for index in range(225):
        side = -1 if index % 3 == 0 else 1
        root_x = rng.uniform(-0.04, 0.029)
        root_y = rng.uniform(-0.062, 0.075)
        reach = rng.uniform(0.014, 0.043)
        radius = rng.uniform(0.00020, 0.00037)
        points = []
        for step in range(5):
            t = step / 4.0
            x = root_x + side * reach * t
            y = root_y + reach * (0.46 * t + 0.40 * t * t)
            hit, normal, _, _ = surface.ray_cast(Vector((x, y, crown + 0.06)), down)
            if hit is None or hit.z < crown - 0.060:
                break
            lifted = hit + normal * (0.0006 + 0.0016 * t * t)
            points.append((lifted.x, lifted.y, lifted.z, radius * (1.0 - 0.35 * t), t))
        if len(points) == 5:
            strands.append(points)
    return strands


def fringe_material():
    size = 64
    x, y = np.meshgrid(np.linspace(-1.0, 1.0, size), np.linspace(0.0, 1.0, size))
    width = 0.85 * (1.0 - y) ** 0.57 + 0.015
    coverage = np.clip((width - np.abs(x)) * 3.8, 0.0, 1.0)
    coverage *= 0.91 * (1.0 - y) ** 0.68
    color = np.empty((size, size, 4), dtype=np.float32)
    highlight = 0.045 * np.exp(-((x + 0.11) * 2.2) ** 2)
    color[:, :, 0] = 0.26 + highlight
    color[:, :, 1] = 0.19 + highlight * 0.80
    color[:, :, 2] = 0.14 + highlight * 0.67
    color[:, :, 3] = coverage
    texture = bpy.data.images.new("resident_hairline_atlas", size, size, alpha=True)
    texture.pixels.foreach_set(color.ravel())
    texture.pack()
    material = image_material("ResidentFringe", texture, 0.64, cards=True)
    material.node_tree.nodes["Principled BSDF"].inputs["Specular IOR Level"].default_value = 0.28
    return material


def add_short_fringe(hair, head, rig):
    mesh = hair.data
    hair_vertices, hair_surface = frontal_surface(mesh)
    _, skin_surface = frontal_surface(head.data)
    diffuse = mesh.materials[0].node_tree.nodes.get("Image Texture").image
    width, height = diffuse.size
    pixels = np.empty(width * height * 4, dtype=np.float32)
    diffuse.pixels.foreach_get(pixels)
    image = pixels.reshape(height, width, 4)
    crown = max(vertex.co.z for vertex in head.data.vertices)
    direction = Vector((0.0, 1.0, 0.0))
    rng = np.random.default_rng(702)
    fringe = []
    for index in range(180):
        x = (index / 179.0 - 0.5) * 0.151 + rng.uniform(-0.00040, 0.00040)
        first = None
        depth = 0.0
        consecutive = 0
        for z in np.linspace(crown - 0.105, crown - 0.024, 84):
            hit, _, _, _ = skin_surface.ray_cast(Vector((x, -0.5, z)), direction)
            hair_depth = None if hit is None else visible_hair_depth(mesh, hair_vertices, hair_surface, image, x, z, hit.y)
            if hair_depth is None:
                consecutive = 0
                continue
            if consecutive == 0:
                first = z
                depth = max(0.0015, min(0.009, hit.y - hair_depth))
            consecutive += 1
            if consecutive == 3:
                break
        if consecutive < 3:
            continue
        length = rng.uniform(0.0032, 0.0086)
        drift = rng.uniform(0.0011, 0.0041)
        radius = rng.uniform(0.00019, 0.00036)
        root_height = first + rng.uniform(0.0006, 0.0014)
        points = []
        for step in range(4):
            progress = step / 3.0
            px = x + drift * progress ** 1.30
            pz = root_height - length * progress
            skin, _, _, _ = skin_surface.ray_cast(Vector((px, -0.5, pz)), direction)
            if skin is None:
                break
            py = skin.y - (0.0008 + (depth - 0.0008) * (1.0 - progress) ** 1.4)
            points.append((px, py, pz, radius * (1.0 - 0.26 * progress), progress))
        if len(points) == 4:
            fringe.append(points)
    if len(fringe) < 55:
        raise RuntimeError(f"Only {len(fringe)} short fringe strips fitted to {head.name}")
    crown = max(point.z for point in hair_vertices)
    strands = crown_strands(hair_surface, crown, rng)

    new_material = len(mesh.materials)
    mesh.materials.append(fringe_material())
    edited = bmesh.new()
    edited.from_mesh(mesh)
    uv = edited.loops.layers.uv.active
    for strip in fringe + strands:
        pairs = []
        for index, (x, y, z, radius, fraction) in enumerate(strip):
            point = Vector((x, y, z))
            if len(strip) == 4:
                width = Vector((radius, 0, 0))
            else:
                previous = Vector(strip[max(0, index - 1)][:3])
                following = Vector(strip[min(index + 1, len(strip) - 1)][:3])
                width = (following - previous).cross(Vector((0, 0, 1))).normalized() * radius
            left = edited.verts.new(point - width)
            right = edited.verts.new(point + width)
            pairs.append((left, right, fraction))
        for upper, lower in zip(pairs, pairs[1:]):
            upper_left, upper_right, start = upper
            lower_left, lower_right, end = lower
            surface = edited.faces.new((upper_left, lower_left, lower_right, upper_right))
            surface.material_index = new_material
            for loop, coordinate in zip(surface.loops, ((0, start), (0, end), (1, end), (1, start))):
                loop[uv].uv = coordinate
    edited.to_mesh(mesh)
    edited.free()
    rig_mesh(hair, rig)
    print(f"Fitted {len(fringe)} fringe and {len(strands)} crown strands to {head.name}.")


def attach_part(human, services, system, category, key, name, material_path, roughness, rig, fit, *, poses=()):
    human_service, _, clothes_service, mhclo_type = services
    path = str(system / category / key / f"{key}.mhclo")
    proxy = human_service.add_mhclo_asset(
        path,
        human,
        asset_type=category.capitalize(),
        subdiv_levels=0,
        material_type="NONE",
        set_up_rigging=False,
    )
    proxy.name = name
    coordinates = [fit(proxy.matrix_world @ vertex.co) for vertex in proxy.data.vertices]
    deformed = {}
    if poses:
        definition = mhclo_type()
        definition.load(path)
        definition.clothes = proxy
        for pose in poses:
            key_block = human.data.shape_keys.key_blocks[pose]
            key_block.value = 1.0
            clothes_service.fit_clothes_to_human(proxy, human, mhclo=definition, set_parent=False)
            deformed[pose] = [fit(proxy.matrix_world @ vertex.co) for vertex in proxy.data.vertices]
            key_block.value = 0.0
    if category == "teeth":
        # Keep the sculpted gingiva and enamel below the inner lip line even
        # at the full viseme aperture used in the editor and in close shots.
        coordinates = fit_dental_arch(coordinates)
        deformed = {pose: fit_dental_arch(points) for pose, points in deformed.items()}
    elif category == "tongue":
        # The fitted tongue tip must stay behind the upper incisors when an
        # open vowel exposes both meshes at the same time.
        inset = Vector((0, 0.009, -0.002))
        coordinates = [point + inset for point in coordinates]
        deformed = {pose: [point + inset for point in points] for pose, points in deformed.items()}
    proxy.parent = None
    proxy.matrix_world.identity()
    for vertex, coordinate in zip(proxy.data.vertices, coordinates):
        vertex.co = coordinate
    proxy.data.materials.clear()
    cards = category in ("eyebrows", "eyelashes", "hair")
    maximum_size = {"eyebrows": 512, "eyelashes": 512, "teeth": 512, "tongue": 256}.get(category, 1024)
    if category == "hair" and key != "short02":
        maximum_size = 512
    material = texture_material(name, diffuse_texture(material_path), roughness, cards=cards,
                                alpha_cutoff=0.27 if category == "hair" else None,
                                maximum_size=maximum_size)
    proxy.data.materials.append(material)
    normal = material_path.parent / f"{key}_normal.png"
    if category == "hair" and normal.is_file():
        add_normal(material, load_image(normal, 512, colorspace="Non-Color"), 0.42)
    if category == "hair":
        material.node_tree.nodes["Principled BSDF"].inputs["Specular IOR Level"].default_value = 0.22
    if category == "eyes":
        shader = material.node_tree.nodes["Principled BSDF"]
        shader.inputs["IOR"].default_value = 1.376
        shader.inputs["Coat Weight"].default_value = 0.22
        shader.inputs["Coat Roughness"].default_value = 0.14
        split_eye_surfaces(proxy.data, material, material.node_tree.nodes.get("Image Texture").image)
        add_eye_bones(rig, proxy)
    if deformed:
        basis = proxy.shape_key_add(name="Basis", from_mix=False)
        for pose, fitted in deformed.items():
            if not any((co - neutral.co).length_squared > 1e-12 for co, neutral in zip(fitted, basis.data)):
                continue
            shape = proxy.shape_key_add(name=pose, from_mix=False)
            for vertex, coordinate in zip(shape.data, fitted):
                vertex.co = coordinate
    rig_mesh(proxy, rig, eyes=category == "eyes")
    return proxy


def add_eye_bones(rig, eyes):
    bpy.context.view_layer.objects.active = rig
    rig.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    for side, sign in (("L", 1), ("R", -1)):
        points = [vertex.co for vertex in eyes.data.vertices if vertex.co.x * sign > 0]
        if not points:
            raise RuntimeError(f"Missing the {side} eyeball in {eyes.name}")
        pivot = Vector([(min(point[axis] for point in points) + max(point[axis] for point in points)) / 2.0
                        for axis in range(3)])
        bone = rig.data.edit_bones.new(f"Eye_{side}")
        bone.parent = rig.data.edit_bones["Head"]
        bone.head = pivot
        bone.tail = pivot + Vector((0, 0, 0.018))
    bpy.ops.object.mode_set(mode="OBJECT")


def glb_document(path):
    with path.open("rb") as stream:
        stream.seek(12)
        length = int.from_bytes(stream.read(4), "little")
        if stream.read(4) != b"JSON":
            raise ValueError(f"No JSON chunk in {path}")
        return json.loads(stream.read(length))


def mesh_targets(document, node):
    mesh = document["meshes"][node["mesh"]]
    return set(mesh.get("extras", {}).get("targetNames", []))


def verify_export(output, wardrobe, required_clips, required_poses):
    result = glb_document(output)
    clips = {clip["name"] for clip in result.get("animations", [])}
    if clips != required_clips:
        raise RuntimeError(f"Unexpected animation set in {output.name}: {clips ^ required_clips}.")
    nodes = {node["name"]: node for node in result.get("nodes", []) if "name" in node}
    required = {"ResidentSkin", "ResidentEyes", "ResidentLashes", "ResidentTeeth", "ResidentTongue", "Eye_L", "Eye_R"}
    required.update(f"Hair_{index}" for index in range(len(HAIRSTYLES)))
    if not required <= nodes.keys():
        raise RuntimeError(f"Missing resident face nodes in {output.name}: {required - nodes.keys()}")
    exported_poses = mesh_targets(result, nodes["ResidentSkin"])
    if exported_poses != required_poses:
        raise RuntimeError(f"Incorrect face morphs in {output.name}: {exported_poses ^ required_poses}")
    if not set(BLINKS) <= mesh_targets(result, nodes["ResidentLashes"]):
        raise RuntimeError(f"Eyelashes do not follow both lids in {output.name}.")
    short_hair = result["meshes"][nodes["Hair_0"]["mesh"]]
    if not any(result["materials"][surface["material"]]["name"] == "ResidentFringe"
               for surface in short_hair["primitives"]):
        raise RuntimeError(f"No scalp fringe in {output.name}.")
    source = glb_document(wardrobe)
    for node in source["nodes"]:
        name = node.get("name", "")
        if name.startswith("Clothing_") and "mesh" in node:
            if name not in nodes or mesh_targets(source, node) != mesh_targets(result, nodes[name]):
                raise RuntimeError(f"Altered garment contract for {name} in {output.name}.")
    print(f"Resident rig verified: {output.name}, {len(clips)} clips, {len(exported_poses)} face morphs, "
          f"{output.stat().st_size} bytes")


def build(options, sex, services):
    human_service, target_service, _, _ = services
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    bpy.data.orphans_purge(do_recursive=True)
    filename = f"human_{sex}.glb"
    wardrobe = options.wardrobe / filename
    bpy.ops.import_scene.gltf(filepath=str(wardrobe.resolve()))
    rig = next(obj for obj in bpy.context.scene.objects if obj.type == "ARMATURE")
    original = next(obj for obj in rig.children_recursive if obj.name == "Body")
    original_top = max(v.co.z for v in original.data.vertices)
    male = sex == "male"
    profile = target_service.get_default_macro_info_dict()
    profile.update(gender=1.0 if male else 0.0, age=0.49 if male else 0.44, muscle=0.4)
    profile["race"] = {"asian": 0.24, "caucasian": 0.54, "african": 0.22} if male else {
        "asian": 0.65, "caucasian": 0.20, "african": 0.15
    }
    human = human_service.create_human(macro_detail_dict=profile)
    source_indices = human.data.attributes.new(SOURCE_INDEX, "INT", "POINT")
    source_indices.data.foreach_set("value", list(range(len(human.data.vertices))))
    deltas = face_deltas(human, target_service, options)
    graph = bpy.context.evaluated_depsgraph_get()
    source = human.evaluated_get(graph)
    head_mesh = bpy.data.meshes.new_from_object(source, depsgraph=graph, preserve_all_data_layers=True)
    head = bpy.data.objects.new("ResidentSkin", head_mesh)
    bpy.context.collection.objects.link(head)
    crown = max(v.co.z for v in head_mesh.vertices)
    target = rig.data.bones["Head"].head_local.copy()
    # The scalp and underside of the chin define a human head's vertical scale.
    # Keep depth and width proportional when replacing the old stylized mesh.
    origin = Vector((0.0, 0.017, crown - 0.207))
    scale = (original_top - target.z) / (crown - origin.z)
    target.y += 0.037

    def fit(coordinate):
        return target + (coordinate - origin) * scale

    for vertex in head_mesh.vertices:
        vertex.co = fit(source.matrix_world @ vertex.co)
    crop_head(head_mesh, 1.47)
    skin_morphs(head, deltas, source.matrix_world.to_3x3() * scale)
    skin = SKINS[sex]
    texture = diffuse_texture(options.system_assets / "skins" / skin / f"{skin}.mhmat")
    head_mesh.materials.clear()
    skin_material = texture_material("ResidentSkin", texture, 0.56)
    add_normal(skin_material, normal_from_skin(load_image(texture, 1024)), 0.60)
    head_mesh.materials.append(skin_material)
    smooth_head(head)
    rig_mesh(head, rig, neck=True)

    remove_original_head(original)
    for obj in list(rig.children_recursive):
        if obj.name.startswith(("Hair_", "Eyebrows", "Eyes")):
            bpy.data.objects.remove(obj, do_unlink=True)

    system = options.system_assets
    eye = "brown" if male else "brownlight"
    attach_part(human, services, system, "eyes", "high-poly", "ResidentEyes",
                system / "eyes" / "materials" / f"{eye}.mhmat", 0.19, rig, fit)
    brow = "eyebrow012" if male else "eyebrow009"
    attach_part(human, services, system, "eyebrows", brow, "ResidentBrows",
                system / "eyebrows" / brow / f"{brow}.mhmat", 0.78, rig, fit,
                poses=(*IDENTITIES, *BROWS, "Concern"))
    lash = "eyelashes01" if male else "eyelashes02"
    attach_part(human, services, system, "eyelashes", lash, "ResidentLashes",
                system / "eyelashes" / lash / f"{lash}.mhmat", 0.72, rig, fit,
                poses=(*IDENTITIES, *BLINKS, *LIDS))
    attach_part(human, services, system, "teeth", "teeth_base", "ResidentTeeth",
                system / "teeth" / "teeth_base" / "teeth.mhmat", 0.36, rig, fit, poses=ORAL_MORPHS)
    attach_part(human, services, system, "tongue", "tongue01", "ResidentTongue",
                system / "tongue" / "tongue01" / "tongue01.mhmat", 0.47, rig, fit, poses=ORAL_MORPHS)
    for index, hair in enumerate(HAIRSTYLES):
        hairstyle = attach_part(human, services, system, "hair", hair, f"Hair_{index}",
                                system / "hair" / hair / f"{hair}.mhmat", 0.61, rig, fit)
        if index == 0:
            add_short_fringe(hairstyle, head, rig)
    bpy.data.objects.remove(human, do_unlink=True)

    bpy.ops.object.select_all(action="DESELECT")
    rig.select_set(True)
    for obj in rig.children_recursive:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = rig
    bpy.context.scene.render.fps = 30
    output = options.output / filename
    bpy.ops.export_scene.gltf(
        filepath=str(output), export_format="GLB", use_selection=True,
        export_animations=True, export_animation_mode="NLA_TRACKS", export_nla_strips=True,
        export_force_sampling=True, export_frame_range=False, export_yup=True, export_extras=False,
    )
    expected = set(json.loads((options.wardrobe / "manifest.json").read_text(encoding="utf-8"))["animations"])
    verify_export(output, wardrobe, expected, set(deltas))


def write_manifest(options):
    manifest = json.loads((options.wardrobe / "manifest.json").read_text(encoding="utf-8"))
    manifest.update({
        "head_source": "https://github.com/makehumancommunity/mpfb2/releases/tag/v2.0.18",
        "head_materials_source": "https://static.makehumancommunity.org/assets/assetpacks/makehuman_system_assets.html",
        "face_unit_source": "https://static.makehumancommunity.org/assets/assetpacks/faceunits01.html",
        "viseme_source": "https://static.makehumancommunity.org/assets/assetpacks/visemes02.html",
        "face_mesh": "ResidentSkin",
        "eye_bones": ["Eye_L", "Eye_R"],
        "face_morphs": [*IDENTITIES, *FACE_UNITS, *VISEMES],
        "face_modifications": "Subdivided head and facial poses with fitted mouth anatomy, transparent corneal "
                              "shells, independent eye pivots and directional lid and eyelash morphs. "
                              "Mesh strands feather the hairline and follow the crown."
    })
    (options.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def main():
    options = arguments()
    if options.wardrobe.resolve() == options.output.resolve():
        raise ValueError("Choose a separate output directory from the wardrobe inputs.")
    options.output.mkdir(parents=True, exist_ok=True)
    options.system_assets = options.system_assets.resolve()
    services = enable_mpfb(options.mpfb_src)
    for sex in (options.prototype,) if options.prototype else SKINS:
        build(options, sex, services)
    if not options.prototype:
        write_manifest(options)


if __name__ == "__main__":
    main()
