# 「旅行L叔」 map-editor catalogue: headless Blender library for building-only low-poly board cities.
#
# Used by tools/map_catalogue/run_archetype_model.py (which execs art-src/custom-map-catalogue/archetypes/<id>/build.py)
# and tools/map_catalogue/render_board_refs.py. Runs in a FRESH headless Blender
# (Blender -b --factory-startup), never in Carlos's open window / the blender-mcp socket.
#
# Conventions (same as the 16 shipped building-only cities, art-src/merchant-board-claude/cities/*/build_building_only.py):
#   * Blender is Z-up; the GLB is exported Y-up, so Blender (x, y, z) == glTF (x, z, -y).
#   * FRONT of the city = Blender -Y = glTF +Z = south, toward the board camera. On the board every city is turned by
#     CITY_YAW -0.44 rad, so the camera sees the FRONT and the RIGHT (+X, east) side, from 25 deg right of the front
#     and 43.5 deg above (VIEW_DIRS["board"]). The DERIVED renders (q34) are from the front-LEFT: the opposite side.
#     Consequence: a form that climbs toward +X also comes toward the board camera and reads flat; make it climb
#     toward -X (it then recedes as it rises and the climb reads steeper).
#   * Unit scale: the shipped cities are 3.5-5.2 units wide and 2.5-3.8 tall; the board scales every city by
#     foot / building_width (foot 3.75 for most), so build at that size (about 4.1 x 3.2 footprint); footprint
#     aspect <= 1.3, trees and lamps included (DESIGN.md 3.13.5; run_archetype_model.py fails the model otherwise).
#   * Flat colours only, no textures, no bevels; faceted (flat-shaded) low-poly primitives.
#   * Colours: start from shared_palette(side) (SHARED_PAL: the shipped cities' own baseColors) and override only
#     what the archetype's look demands; materials through palette_materials(pal).
#   * Detail density like chenla / quanzhou: brick_relief / brick_box on brick, ashlar on stone footings and
#     plinths, row_of for rafter ends / drip tiles / window bars, cornice on wall tops. Bare boxes are unfinished.
#   * One material per object while modelling; the export joins meshes per material (<id>_<Material>).
#   * Night glow on the board (tools/merchant_board_claude_review.gd add_city_night): a material whose name contains
#     "Lamp" becomes a lantern (and gets an omni light); a material matching
#     (^|_)Dark(\.|_|$)|DeepArch|Entry_Reveal|CedarDoor|EntryFrameShade|PagodaReveal|EaveUnderside glows as a lit
#     doorway / window. So: mat("Dark", ...) for openings, lamp_post() for lanterns (WarmMini_* materials, the exact
#     values the shipped cities use).
#   * NO ground slab / plinth / terrain / water plane (catalogue rules.model). Stone footings under a structure are fine.
#
# Blender 5.2 API. No bpy.ops inside the modelling helpers (fast, context-free); ops only in export/render.
import bpy, bmesh, math, os, json, random, re
from mathutils import Vector, Matrix, Euler

GLOW_RE = re.compile(r"(^|_)Dark(\.|_|$)|DeepArch|Entry_Reveal|CedarDoor|EntryFrameShade|PagodaReveal|EaveUnderside")

# ------------------------------------------------------------------------------------------------------------------
# city context
# ------------------------------------------------------------------------------------------------------------------
KINDS = ("buildings", "props", "trees")


class City:
    """Holds the archetype id, the material prefix and one collection per kind (buildings / props / trees)."""

    def __init__(self, aid, prefix):
        self.id = aid
        self.prefix = prefix
        self.cols = {}
        for k in KINDS:
            c = bpy.data.collections.new(f"{aid}_{k}")
            bpy.context.scene.collection.children.link(c)
            self.cols[k] = c

    def col(self, kind):
        return self.cols[kind] if isinstance(kind, str) else kind


CITY = None


def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    s = bpy.context.scene
    s.unit_settings.system = 'METRIC'
    s.unit_settings.scale_length = 1.0


def new_city(aid, prefix):
    global CITY
    CITY = City(aid, prefix)
    return CITY


# ------------------------------------------------------------------------------------------------------------------
# colours and materials
# ------------------------------------------------------------------------------------------------------------------
def srgb_to_lin(c):
    return (c / 12.92) if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hexlin(h):
    h = h.lstrip('#')
    return tuple(srgb_to_lin(int(h[i:i + 2], 16) / 255.0) for i in (0, 2, 4))


def _colour(c):
    return hexlin(c) if isinstance(c, str) else tuple(c)


def mat(name, colour, rough=0.9, metal=0.0, emit=None, emit_strength=1.0, raw_name=False):
    """Flat Principled material. colour: '#RRGGBB' (sRGB, as picked by eye) or a linear (r, g, b) tuple.
    Named '<prefix>_<name>' unless raw_name. Re-calling with the same name returns the same material."""
    full = name if raw_name else f"{CITY.prefix}_{name}"
    m = bpy.data.materials.get(full)
    if m is None:
        m = bpy.data.materials.new(full)
    try:
        m.use_nodes = True  # deprecated no-op in 5.x (always node based), required before 5.0
    except Exception:
        pass
    b = m.node_tree.nodes.get("Principled BSDF")
    rgb = _colour(colour)
    b.inputs["Base Color"].default_value = (*rgb, 1.0)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    if emit is not None:
        b.inputs["Emission Color"].default_value = (*_colour(emit), 1.0)
        b.inputs["Emission Strength"].default_value = emit_strength
    m.diffuse_color = (*rgb, 1.0)  # solid-view colour in the .blend
    return m


def lamp_materials():
    """The shared lantern set of the shipped board cities (values read from assets/merchant_board_claude/cities/*.glb)."""
    return {
        "lamp": mat("WarmMini_Lamp", (1.0, 0.5711, 0.1845), rough=0.9, emit=(1.0, 0.5711, 0.1845), emit_strength=3.0, raw_name=True),
        "stone": mat("WarmMini_stone", (0.328, 0.305, 0.279), rough=0.9, raw_name=True),
        "wood": mat("WarmMini_wooddark", (0.074, 0.038, 0.025), rough=0.9, raw_name=True),
    }


# ------------------------------------------------------------------------------------------------------------------
# the shared board palette
# ------------------------------------------------------------------------------------------------------------------
# Copied from the shipped building-only board cities: baseColorFactor of assets/merchant_board_claude/cities/*.glb,
# linear -> sRGB, rounded to #RRGGBB (the source city is named after each value). The 16 cities share these families
# (changan / chenla / geumseong / heijokyo use the SAME warm sand Stone #C9B697 / StoneShade #9D8970; cairo /
# constantinople / dagon / delhi the same #D8C3A0 / #AF997A ...), which is a large part of why they read as one set.
# An archetype's build.py starts from shared_palette(side) and overrides ONLY the colours its look demands
# (e.g. kiln_town's cobalt, clay and smoke); it must not re-invent stone, wood, leaves or brick.
# "(derived)" marks the few in-between tones that are an even sRGB mix of two shipped values, for course-to-course
# variation; every other value is a shipped value unchanged.
SHARED_PAL = {
    "common": {
        # brick (chenla; constantinople's brick as a fourth tone)
        "Brick": "#A65D39", "BrickLight": "#C47B4B", "BrickDark": "#864B33", "BrickWarm": "#A85B42",
        # plaster / trims (changan, geumseong, aden, jeddah, quanzhou)
        "Plaster": "#E5D5BA", "Trim": "#E9D3B0", "Cream": "#EAD4AB", "Mortar": "#AA9275",
        # openings: the glow-regex material "Dark" (changan / geumseong / heijokyo)
        "Dark": "#30261F",
        # timber, vermilion, gold
        "Timber": "#A84D32", "TimberDark": "#663624", "Vermilion": "#963B27",
        "GoldShade": "#B7832A",
        # roofs: teal-grey (changan), charcoal (heijokyo), terracotta (simhala / rome), red tile (constantinople / dagon)
        "RoofTeal": "#29494E", "RoofTealEdge": "#496066", "RoofCharcoal": "#3E4143", "RoofCharcoalEdge": "#646568",
        "RoofTerracotta": "#A5482E", "RoofTerracottaLight": "#C86A40", "RoofTerracottaFascia": "#82452F",
        "Terracotta": "#B86D45", "TerracottaLight": "#CC8253", "RoofRed": "#874336", "RoofRedEdge": "#B66545",
        # earth / mud brick (yumenguan, panti, aden)
        "Earth": "#BE8651", "EarthLight": "#DCA56D", "EarthDark": "#A77247", "Pot": "#AE6A43",
        # cloth (aden / jeddah / cairo / delhi)
        "ClothRed": "#A94332", "ClothGold": "#C19552", "Cloth": "#A04B40", "ClothLight": "#E0BD82",
        # glazed blue (baghdad)
        "DomeBlue": "#388DB6", "DomeBase": "#286B91", "DomeFacet": "#5BA7CC",
        # whites (simhala)
        "Porcelain": "#FFFAE8", "Ivory": "#FFF1CF",
        # trees (biome: bark / branch; quanzhou fresh greens; palms)
        "Bark": "#75614B", "Branch": "#69503C",
        "LeafFresh": "#5F8D48", "LeafFreshDark": "#477146", "LeafFreshLight": "#81A851",
        "Palm0": "#5F7C49", "Palm1": "#819553", "Palm2": "#A1AC65", "Palm3": "#526F47",
        "LeafRed": "#B14824", "LeafRedShade": "#823823", "LeafGoldAutumn": "#C89132", "LeafGoldShade": "#956226",
        "Cypress": "#405A31", "CypressLight": "#526A3D", "Olive": "#667347", "OliveLight": "#7C8850",
        "StoneLight": "#E7D6B7",
    },
    "east": {
        # changan / chenla / geumseong / heijokyo
        "Stone": "#C9B697", "StoneShade": "#9D8970", "StoneMid": "#B3A084",  # StoneMid (derived)
        "Wood": "#71452E", "WoodLight": "#AB7848",
        "Leaf": "#607039", "LeafLight": "#87904B",          # chenla
        "Gold": "#B79759", "Ochre": "#C79A5E",               # changan gold, quanzhou gold
    },
    "west": {
        # cairo / constantinople / dagon / delhi
        "Stone": "#D8C3A0", "StoneShade": "#AF997A", "StoneMid": "#C4AE8D",  # StoneMid (derived)
        "Wood": "#65402C", "WoodLight": "#94613E",
        "Leaf": "#3E5836", "LeafLight": "#6D793D",          # cairo / constantinople
        "Gold": "#D9A943", "Ochre": "#CF996E",               # cairo gold, aden ochre
    },
}


def shared_palette(side="east", **overrides):
    """SHARED_PAL['common'] + SHARED_PAL[side] + the archetype's own overrides (name -> '#RRGGBB')."""
    if side not in ("east", "west"):
        raise ValueError(f"side must be east or west, not {side!r}")
    pal = dict(SHARED_PAL["common"])
    pal.update(SHARED_PAL[side])
    pal.update(overrides)
    return pal


class _LazyMaterials(dict):
    def __init__(self, pal, rough):
        super().__init__()
        self.pal, self.rough = pal, rough

    def __missing__(self, key):
        if key not in self.pal:
            raise KeyError(f"colour {key!r} is not in the palette (shared_palette + overrides)")
        m = mat(key, self.pal[key], rough=self.rough)
        self[key] = m
        return m


def palette_materials(pal, rough=0.9):
    """M[key] -> flat material <prefix>_<key> in pal[key], created on first use (so the .blend / GLB only carry the
    colours the model uses). Name the openings 'Dark' and roof undersides 'EaveUnderside' so the board's night-glow
    regex lights them (KT_Dark, KT_EaveUnderside)."""
    return _LazyMaterials(pal, rough)


# ------------------------------------------------------------------------------------------------------------------
# object helpers
# ------------------------------------------------------------------------------------------------------------------
def _rot(rot):
    if rot is None:
        return Euler((0, 0, 0))
    if isinstance(rot, (int, float)):
        return Euler((0, 0, math.radians(rot)))
    return Euler(tuple(math.radians(r) for r in rot))


def _mk(name, bm, m, col, loc=(0, 0, 0), rot=None, scale=(1, 1, 1)):
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-6)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        p.use_smooth = False
    o = bpy.data.objects.new(name, me)
    CITY.col(col).objects.link(o)
    if m is not None:
        me.materials.append(m)
    o.location = Vector(loc)
    o.rotation_euler = _rot(rot)
    o.scale = Vector(scale)
    return o


def group(objs, loc=(0, 0, 0), rot=None, pivot=(0, 0, 0)):
    """Move / turn a set of objects built in local coordinates as one piece (rot in degrees, about pivot)."""
    R = _rot(rot).to_matrix().to_4x4()
    M = Matrix.Translation(Vector(loc)) @ Matrix.Translation(Vector(pivot)) @ R @ Matrix.Translation(-Vector(pivot))
    for o in objs:
        o.matrix_world = M @ o.matrix_world
    return objs


def box(name, size, loc=(0, 0, 0), rot=None, m=None, col="buildings", top=(1.0, 1.0), top_shift=(0.0, 0.0)):
    """Box whose ORIGIN IS THE CENTRE OF ITS BOTTOM FACE. top scales the top face (a frustum / tapered block),
    top_shift slides it (a leaning block)."""
    sx, sy, sz = size
    hx, hy = sx / 2, sy / 2
    tx, ty = hx * top[0], hy * top[1]
    dx, dy = top_shift
    bm = bmesh.new()
    v = [bm.verts.new(p) for p in ((-hx, -hy, 0), (hx, -hy, 0), (hx, hy, 0), (-hx, hy, 0),
                                   (-tx + dx, -ty + dy, sz), (tx + dx, -ty + dy, sz), (tx + dx, ty + dy, sz), (-tx + dx, ty + dy, sz))]
    for f in ((0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)):
        bm.faces.new([v[i] for i in f])
    return _mk(name, bm, m, col, loc, rot)


def prism(name, pts, depth, axis='y', loc=(0, 0, 0), rot=None, m=None, col="buildings", centred=True):
    """Extrude a 2D outline. axis 'y': pts are (x, z), extruded along Y (a facade piece: arch, gable end);
    axis 'x': pts are (y, z), extruded along X (a tunnel / roof running along X). Origin on the outline's plane
    origin, centred on the extrusion unless centred=False (then it runs 0..depth)."""
    a0 = -depth / 2 if centred else 0.0
    a1 = a0 + depth

    def P(p, a):
        return (p[0], a, p[1]) if axis == 'y' else (a, p[0], p[1])

    bm = bmesh.new()
    r0 = [bm.verts.new(P(p, a0)) for p in pts]
    r1 = [bm.verts.new(P(p, a1)) for p in pts]
    bm.faces.new(r0)
    bm.faces.new(list(reversed(r1)))
    n = len(pts)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((r0[i], r0[j], r1[j], r1[i]))
    return _mk(name, bm, m, col, loc, rot)


def arch_pts(w, h, segs=6, pointed=0.0):
    """Outline of a round-headed opening, w wide and h tall, standing on z=0 (pointed > 0 lifts the crown)."""
    r = w / 2
    spring = max(0.0, h - r - pointed)
    pts = [(-r, 0.0), (r, 0.0), (r, spring)]
    for i in range(1, segs):
        t = math.pi * i / segs
        pts.append((r * math.cos(t), spring + (r + pointed) * math.sin(t)))
    pts.append((-r, spring))
    return pts


def vault_pts(half_w, wall_h, rise, segs=8):
    """Cross-section of a barrel vault on low side walls (tunnel kiln, arcade), base on z=0."""
    pts = [(-half_w, 0.0), (half_w, 0.0)]
    for i in range(segs + 1):
        t = math.pi * i / segs
        pts.append((half_w * math.cos(t), wall_h + rise * math.sin(t)))
    return pts


def cyl(name, r, h, segs=8, loc=(0, 0, 0), rot=None, m=None, col="buildings", r_top=None):
    return lathe(name, [(r, 0.0), (r if r_top is None else r_top, h)], segs, loc, rot, m, col)


def lathe(name, profile, segs=8, loc=(0, 0, 0), rot=None, m=None, col="buildings", cap_bottom=True, cap_top=True, phase=0.0):
    """Revolve [(r, z), ...] (bottom to top) about Z. Few segments = faceted low-poly."""
    bm = bmesh.new()
    rings = []
    for (r, z) in profile:
        if r < 1e-5:
            rings.append([bm.verts.new((0.0, 0.0, z))])
            continue
        rings.append([bm.verts.new((r * math.cos(2 * math.pi * i / segs + phase), r * math.sin(2 * math.pi * i / segs + phase), z))
                      for i in range(segs)])
    for j in range(len(rings) - 1):
        a, b = rings[j], rings[j + 1]
        if len(a) == 1 and len(b) == 1:
            continue
        if len(a) == 1:
            for i in range(segs):
                bm.faces.new((a[0], b[i], b[(i + 1) % segs]))
        elif len(b) == 1:
            for i in range(segs):
                bm.faces.new((a[i], a[(i + 1) % segs], b[0]))
        else:
            for i in range(segs):
                bm.faces.new((a[i], a[(i + 1) % segs], b[(i + 1) % segs], b[i]))
    if cap_bottom and len(rings[0]) > 1:
        bm.faces.new(list(reversed(rings[0])))
    if cap_top and len(rings[-1]) > 1:
        bm.faces.new(rings[-1])
    return _mk(name, bm, m, col, loc, rot)


def ico(name, radius=0.5, subdiv=1, loc=(0, 0, 0), scale=(1, 1, 1), rot=None, m=None, col="buildings", jitter=0.0, seed=1):
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=radius)
    if jitter > 0:
        rnd = random.Random(seed)
        for v in bm.verts:
            v.co *= 1.0 + rnd.uniform(-jitter, jitter)
    return _mk(name, bm, m, col, loc, rot, scale)


# ------------------------------------------------------------------------------------------------------------------
# architecture
# ------------------------------------------------------------------------------------------------------------------
def roof_profile(depth, rise, overhang=0.12, thick=0.05, sag=0.35, samples=3):
    """Cross-section (y, z) of a gable roof with a gently concave (Chinese) slope, eave at z=0, ridge at z=rise."""
    D = depth / 2 + overhang
    left = [(-D * (1 - i / samples), rise * ((i / samples) ** (1 + sag))) for i in range(samples + 1)]  # eave -> ridge
    right = [(-y, z) for (y, z) in reversed(left[:-1])]                                                # ridge -> eave
    outer = left + right
    inner = [(y, z - thick) for (y, z) in reversed(outer)]
    return outer + inner


def gable_roof(name, length, depth, rise, loc=(0, 0, 0), rot=None, m=None, col="buildings", overhang=0.12, thick=0.05,
               sag=0.35, gable_overhang=0.08, corner_lift=0.0, ribs=None, rib_m=None, rib_step=0.11, rib_w=0.035):
    """Gable roof running along X, eave line at loc.z. corner_lift raises the four eave corners (upturned eaves).
    ribs=True adds raised tile rows (roll tiles) following the slope, in rib_m (default: m)."""
    L = length + 2 * gable_overhang
    prof = roof_profile(depth, rise, overhang, thick, sag)
    o = prism(name, prof, L, 'x', loc, rot, m, col)
    if corner_lift:
        D = depth / 2 + overhang
        for v in o.data.vertices:
            ey = abs(v.co.y) / D
            ex = abs(v.co.x) / (L / 2)
            if ey > 0.55:
                v.co.z += corner_lift * ((ey - 0.55) / 0.45) ** 2 * (0.35 + 0.65 * ex ** 3)
    out = [o]
    if ribs:
        n = max(2, int(L / rib_step))
        prof_r = [(y * 0.985, z + 0.018) for (y, z) in roof_profile(depth, rise, overhang, 0.03, sag)]
        for i in range(n):
            x = -L / 2 + (i + 0.5) * L / n
            r = prism(f"{name}_rib{i}", prof_r, rib_w, 'x', (0, 0, 0), None, rib_m or m, col)
            r.location = Vector(loc) + _rot(rot).to_matrix() @ Vector((x, 0, 0))
            r.rotation_euler = _rot(rot)
            if corner_lift:
                D = depth / 2 + overhang
                ex = abs(x) / (L / 2)
                for v in r.data.vertices:
                    ey = abs(v.co.y) / D
                    if ey > 0.55:
                        v.co.z += corner_lift * ((ey - 0.55) / 0.45) ** 2 * (0.35 + 0.65 * ex ** 3)
            out.append(r)
    return out


def ridge(name, length, loc, rot=None, m=None, col="buildings", w=0.06, h=0.06, horn=0.07):
    """Ridge beam with two small upturned end horns (for gable_roof), loc = centre of its bottom."""
    parts = [box(name, (length, w, h), loc, rot, m, col)]
    R = _rot(rot).to_matrix()
    for s in (-1, 1):
        p = Vector(loc) + R @ Vector((s * length / 2, 0, 0))
        parts.append(box(f"{name}_horn{'LR'[s > 0]}", (0.07, w * 0.9, h + horn), p, rot, m, col, top=(0.6, 0.8),
                         top_shift=(s * 0.05, 0)))
    return parts


def lean_to_roof(name, length, depth, drop, loc, rot=None, m=None, col="buildings", thick=0.04, overhang=0.06):
    """Single-pitch roof along X: high edge at +Y (loc.z), low edge at -Y (loc.z - drop)."""
    D = depth + overhang
    pts = [(-D / 2, -drop), (D / 2, 0.0), (D / 2, -thick), (-D / 2, -drop - thick)]
    return prism(name, pts, length + 2 * overhang, 'x', loc, rot, m, col)


def arched_opening(name, w, h, loc, rot=None, m=None, col="buildings", depth=0.03, frame=None, frame_m=None, segs=6):
    """A dark arched opening on a wall facing -Y (rotate for other walls): a proud dark panel in the arch outline,
    optionally inside a slightly larger lighter frame. loc = bottom centre on the wall surface."""
    out = []
    R = _rot(rot).to_matrix()
    if frame:
        f = prism(f"{name}_frame", arch_pts(w + 2 * frame, h + frame, segs), depth * 0.6, 'y', (0, 0, 0), None, frame_m, col)
        f.location = Vector(loc) + R @ Vector((0, -depth * 0.3, -frame * 0.5))
        f.rotation_euler = _rot(rot)
        out.append(f)
    o = prism(name, arch_pts(w, h, segs), depth, 'y', (0, 0, 0), None, m, col)
    o.location = Vector(loc) + R @ Vector((0, -depth * 0.5, 0))
    o.rotation_euler = _rot(rot)
    out.append(o)
    return out


def chimney(name, base_w, height, loc, m, band_m=None, cap_m=None, dark_m=None, col="buildings", taper=0.72, bands=(0.35, 0.62), cap_h=0.1):
    """Square tapered brick chimney standing on loc (bottom centre), with darker brick courses and a flared cap."""
    out = [box(name, (base_w, base_w, height), loc, None, m, col, top=(taper, taper))]
    x, y, z = loc
    for i, f in enumerate(bands):
        w = base_w * (1 - (1 - taper) * f) + 0.03
        out.append(box(f"{name}_band{i}", (w, w, 0.05), (x, y, z + height * f), None, band_m or m, col))
    wt = base_w * taper
    out.append(box(f"{name}_cap", (wt + 0.06, wt + 0.06, cap_h), (x, y, z + height - cap_h * 0.3), None, cap_m or band_m or m, col, top=(1.06, 1.06)))
    if dark_m is not None:
        out.append(box(f"{name}_flue", (wt * 0.62, wt * 0.62, 0.02), (x, y, z + height + cap_h * 0.7), None, dark_m, col))
    return out


def smoke(name, base, m, n=3, r0=0.12, grow=1.35, drift=(0.1, 0.0), rise=0.2, col="buildings", seed=3):
    """A few low-poly smoke puffs rising from base and drifting sideways."""
    out = []
    p = Vector(base)
    r = r0
    for i in range(n):
        out.append(ico(f"{name}{i}", r, 1, (p.x, p.y, p.z + r * 0.7), (1.15, 1.0, 0.85), (0, 0, 17 * i), m, col, jitter=0.12, seed=seed + i))
        p = p + Vector((drift[0], drift[1], rise + r * 0.6))
        r *= grow
    return out


def lamp_post(name, loc, height=0.55, col="props", mats=None):
    """The shipped cities' small lantern post (stone foot, dark post, glowing box, dark cap). loc = bottom centre."""
    mm = mats or lamp_materials()
    x, y, z = loc
    k = height / 0.55
    out = [box(f"{name}_foot", (0.2, 0.2, 0.09), (x, y, z), None, mm["stone"], col, top=(0.85, 0.85)),
           box(f"{name}_post", (0.045, 0.045, 0.3 * k), (x, y, z + 0.09), None, mm["wood"], col),
           box(f"{name}_lamp", (0.14, 0.14, 0.18 * k), (x, y, z + 0.09 + 0.29 * k), None, mm["lamp"], col),
           box(f"{name}_cap", (0.23, 0.23, 0.07), (x, y, z + 0.09 + 0.47 * k), None, mm["wood"], col, top=(0.25, 0.25))]
    return out


def leaf(name, base, direction, length=0.2, width=0.045, m=None, col="trees", thick=0.008):
    """A lanceolate (pointed) leaf blade, a thin double-sided solid (glTF materials are single-sided):
    it starts at base and points along direction, lying as flat as possible (its face looks up)."""
    d = Vector(direction).normalized()
    side = d.cross(Vector((0, 0, 1)))
    if side.length < 1e-3:
        side = d.cross(Vector((1, 0, 0)))
    side.normalize()
    n = side.cross(d).normalized()
    b = Vector(base)
    outline = [(0.0, 0.0), (width / 2, length * 0.38), (0.0, length), (-width / 2, length * 0.38)]
    bm = bmesh.new()
    top = [bm.verts.new(b + side * x + d * y + n * thick / 2) for x, y in outline]
    bot = [bm.verts.new(b + side * x + d * y - n * thick / 2) for x, y in outline]
    bm.faces.new(top)
    bm.faces.new(list(reversed(bot)))
    for i in range(4):
        j = (i + 1) % 4
        bm.faces.new((top[i], bot[i], bot[j], top[j]))
    return _mk(name, bm, m, col)


def bamboo_clump(name, loc, culm_m, leaf_m, leaf2_m=None, n=7, h=1.8, spread=0.16, seed=5, col="trees", node_m=None,
                 sprays=4, per_spray=4, leaf_len=0.2, reach=1.0):
    """A clump of thin, slightly leaning bamboo culms; the upper half carries sprays of pointed drooping leaves
    and each tip a small upright tuft. reach < 1 keeps the sprays tighter (narrower footprint)."""
    rnd = random.Random(seed)
    out = []
    x0, y0, z0 = loc
    for i in range(n):
        a = 2 * math.pi * i / n + rnd.uniform(-0.3, 0.3)
        rr = spread * math.sqrt(rnd.uniform(0.15, 1.0))
        hx, hy = x0 + rr * math.cos(a), y0 + rr * math.sin(a)
        hh = h * rnd.uniform(0.72, 1.0)
        lean = rnd.uniform(3, 9)
        tilt = Euler((math.radians(-lean * math.sin(a)), math.radians(lean * math.cos(a)), 0))
        c = cyl(f"{name}_culm{i}", 0.028, hh, 5, (hx, hy, z0), None, culm_m, col, r_top=0.017)
        c.rotation_euler = tilt
        out.append(c)
        M = tilt.to_matrix()
        root = Vector((hx, hy, z0))
        if node_m is not None:
            for k in range(1, 5):
                nd = cyl(f"{name}_node{i}_{k}", 0.032, 0.025, 5, (0, 0, 0), None, node_m, col)
                nd.location = root + M @ Vector((0, 0, hh * k / 5.2))
                nd.rotation_euler = tilt
                out.append(nd)
        for k in range(sprays):
            t = 0.5 + 0.47 * (k + rnd.uniform(0.1, 0.8)) / sprays
            p = root + M @ Vector((0, 0, hh * t))
            side = a + rnd.uniform(-0.9, 0.9) + (math.pi * 0.85 if k % 2 else 0.0)
            droop = math.radians(rnd.uniform(18, 42) + (1 - t) * 25)
            for j in range(per_spray):
                az = side + (j - (per_spray - 1) / 2) * 0.5 + rnd.uniform(-0.15, 0.15)
                dj = droop + rnd.uniform(-0.15, 0.15)
                dvec = Vector((math.cos(az) * math.cos(dj), math.sin(az) * math.cos(dj), -math.sin(dj)))
                ln = leaf_len * rnd.uniform(0.8, 1.15) * (1.1 - 0.3 * t) * reach
                lm = leaf2_m if (leaf2_m is not None and (j + k + i) % 3 == 0) else leaf_m
                out.append(leaf(f"{name}_leaf{i}_{k}_{j}", p, dvec, ln, ln * 0.24, lm, col))
        tip = root + M @ Vector((0, 0, hh))
        for j in range(3):
            az = a + 2 * math.pi * j / 3 + rnd.uniform(-0.3, 0.3)
            el = math.radians(rnd.uniform(35, 60))
            dvec = Vector((math.cos(az) * math.cos(el), math.sin(az) * math.cos(el), math.sin(el)))
            out.append(leaf(f"{name}_tip{i}_{j}", tip, dvec, leaf_len * 0.8 * reach, leaf_len * 0.19, leaf2_m or leaf_m, col))
    return out


def wall_bricks(name, face, axis, w, h, mats, n=12, seed=1, col="buildings", brick=(0.1, 0.05), proud=0.012, avoid=()):
    """Scatter proud single bricks on a flat wall (the shipped cities' brick texture, e.g. chenla).
    face: (x, y, z) = centre of the wall's bottom edge ON the face; axis: '-y' '+y' '-x' '+x' = which way the face
    looks; w, h = wall size; avoid = [(u0, u1, z0, z1), ...] rectangles in wall coordinates (u across, z up from
    face z) to keep clear (doors, vents)."""
    rnd = random.Random(seed)
    out = []
    fx, fy, fz = face
    bw, bh = brick
    tries = 0
    while len(out) < n and tries < n * 20:
        tries += 1
        row = rnd.randrange(max(1, int(h / bh) - 1))
        z = (row + 0.5) * bh
        u = rnd.uniform(-w / 2 + bw * 0.7, w / 2 - bw * 0.7)
        u = round((u + (bw / 2 if row % 2 else 0)) / bw) * bw - (bw / 2 if row % 2 else 0)
        if abs(u) > w / 2 - bw * 0.6 or any(u0 - bw / 2 <= u <= u1 + bw / 2 and z0 - bh <= z <= z1 + bh for u0, u1, z0, z1 in avoid):
            continue
        m = mats[rnd.randrange(len(mats))]
        if axis in ('-y', '+y'):
            sgn = -1 if axis == '-y' else 1
            o = box(f"{name}{len(out)}", (bw * 0.92, proud * 2, bh * 0.84), (fx + u * -sgn, fy, fz + z - bh * 0.42), None, m, col)
        else:
            sgn = -1 if axis == '-x' else 1
            o = box(f"{name}{len(out)}", (proud * 2, bw * 0.92, bh * 0.84), (fx, fy + u * sgn, fz + z - bh * 0.42), None, m, col)
        out.append(o)
    return out


# ------------------------------------------------------------------------------------------------------------------
# relief detail (the shipped cities' surface density: chenla's proud brick courses, changan's coursed stone, trims)
# ------------------------------------------------------------------------------------------------------------------
# All relief helpers build ONE mesh object per material (hundreds of bricks stay a handful of objects in the .blend);
# the export joins per material anyway. They work on any flat rectangle given as a frame:
#   origin = bottom centre of the rectangle ON the surface, u = unit vector across it (left -> right as seen from
#   outside), v = unit vector up the surface (slanted for a tapered face), n = outward normal (u x v).
AXIS_FRAMES = {  # wall looking along axis: (u, n); v is always +Z for a vertical wall
    "-y": ((1, 0, 0), (0, -1, 0)), "+y": ((-1, 0, 0), (0, 1, 0)),
    "+x": ((0, 1, 0), (1, 0, 0)), "-x": ((0, -1, 0), (-1, 0, 0)),
}


def wall_frame(face, axis):
    """Frame of a vertical wall: face = bottom centre of the wall ON its surface, axis = the way it looks."""
    u, n = AXIS_FRAMES[axis]
    return Vector(face), Vector(u), Vector((0, 0, 1)), Vector(n)


def _cuboid(bm, corner, U, V, N, back=False):
    """Add the cuboid corner + a*U + b*V + c*N (a, b, c in 0..1) to bm; back=False leaves out the c=0 face (it sits
    on a wall). Faces are wound outward when U x V points along N."""
    c = Vector(corner)
    P = [bm.verts.new(c + U * a + V * b + N * t) for t in (0, 1) for b in (0, 1) for a in (0, 1)]
    # index = t*4 + b*2 + a
    quads = [(4, 5, 7, 6), (0, 1, 5, 4), (2, 6, 7, 3), (0, 4, 6, 2), (1, 3, 7, 5)]
    if back:
        quads.append((0, 2, 3, 1))
    for q in quads:
        bm.faces.new([P[i] for i in q])


def _mesh_from(name, bm, m, col):
    if len(bm.faces) == 0:
        bm.free()
        return None
    return _mk(name, bm, m, col)


def brick_relief(name, origin, u, v, w, h, mats, n=None, course=0.055, brick=0.12, fill=0.55, proud=0.012,
                 gap=0.012, seed=1, avoid=(), col="buildings", weights=None, taper=0.0, v0=0.0, rows_every=0,
                 row_m=None):
    """Running-bond proud bricks over a flat rectangle (chenla's brick relief). Every course is laid out, odd courses
    offset by half a brick; each brick is kept with probability `fill` and takes a random material from `mats`
    (optionally `weights`) -> one mesh per material. avoid = [(u0, u1, z0, z1)] rectangles left clear (openings),
    in the same (u across from the centre, v up from the origin) coordinates. taper: the rectangle narrows by this
    fraction of w from bottom to top. v0: start height. rows_every=k lays every k-th course as a continuous proud
    string course in row_m (a raised brick band). Returns the created objects."""
    rnd = random.Random(seed)
    O, U, V = Vector(origin), Vector(u).normalized(), Vector(v).normalized()
    N = (Vector(n) if n is not None else U.cross(V)).normalized()
    per = {id(m): (m, bmesh.new()) for m in mats}
    band_bm = bmesh.new() if (rows_every and row_m is not None) else None
    ncourse = max(1, int((h - v0) / course))
    for r in range(ncourse):
        z0 = v0 + r * course
        z1 = z0 + course - gap
        half = w / 2 * (1 - taper * ((z0 + z1) / 2) / max(h, 1e-6))
        if band_bm is not None and r % rows_every == rows_every - 1:
            if not any(z0 < a3 and z1 > a2 for a0, a1, a2, a3 in avoid):
                _cuboid(band_bm, O + U * (-half) + V * z0, U * (2 * half), V * (z1 - z0), N * (proud * 1.4))
            continue
        off = (brick / 2) if r % 2 else 0.0
        a = -half - off
        while a < half:
            b = a + brick - gap
            a0, b0 = max(a, -half + gap / 2), min(b, half - gap / 2)
            if b0 - a0 > brick * 0.35 and rnd.random() < fill and not any(
                    a0 < x1 and b0 > x0 and z0 < y1 and z1 > y0 for x0, x1, y0, y1 in avoid):
                m = rnd.choices(mats, weights=weights)[0] if weights else mats[rnd.randrange(len(mats))]
                _cuboid(per[id(m)][1], O + U * a0 + V * z0, U * (b0 - a0), V * (z1 - z0), N * proud)
            a += brick
    out = []
    for i, (m, bm) in enumerate(per.values()):
        o = _mesh_from(f"{name}_{i}", bm, m, col)
        if o is not None:
            out.append(o)
    if band_bm is not None:
        o = _mesh_from(f"{name}_band", band_bm, row_m, col)
        if o is not None:
            out.append(o)
    return out


def ashlar(name, origin, u, v, w, h, mats, n=None, course=0.1, block=(0.14, 0.3), gap=0.014, proud=0.008, seed=1,
           avoid=(), col="buildings", weights=None):
    """Coursed dressed stone: every course filled with blocks of random length in `block`, separated by `gap`
    joints that show the wall body behind (so the body colour is the mortar / shade). Close tones in `mats`
    (e.g. Stone, StoneMid, StoneShade) mixed block by block -> one mesh per material."""
    rnd = random.Random(seed)
    O, U, V = Vector(origin), Vector(u).normalized(), Vector(v).normalized()
    N = (Vector(n) if n is not None else U.cross(V)).normalized()
    per = {id(m): (m, bmesh.new()) for m in mats}
    ncourse = max(1, round(h / course))
    ch = h / ncourse
    for r in range(ncourse):
        z0, z1 = r * ch + gap / 2, (r + 1) * ch - gap / 2
        a = -w / 2 + gap / 2 - (rnd.uniform(0, block[0]) if r % 2 else 0.0)
        while a < w / 2 - gap:
            ln = rnd.uniform(*block)
            a0, b0 = max(a, -w / 2 + gap / 2), min(a + ln - gap, w / 2 - gap / 2)
            if b0 - a0 > 0.03 and not any(a0 < x1 and b0 > x0 and z0 < y1 and z1 > y0 for x0, x1, y0, y1 in avoid):
                m = rnd.choices(mats, weights=weights)[0] if weights else mats[rnd.randrange(len(mats))]
                _cuboid(per[id(m)][1], O + U * a0 + V * z0, U * (b0 - a0), V * (z1 - z0), N * proud)
            a += ln
    out = []
    for i, (m, bm) in enumerate(per.values()):
        o = _mesh_from(f"{name}_{i}", bm, m, col)
        if o is not None:
            out.append(o)
    return out


def box_faces(size, loc, top=(1.0, 1.0), faces=("-y", "+y", "-x", "+x")):
    """Frames of the side faces of box(size, loc, top=...) (the same bottom-centred, optionally tapered block):
    {axis: (origin, u, v, n, width_bottom, slant_height, taper_fraction)}."""
    sx, sy, sz = size
    x, y, z = loc
    out = {}
    for ax in faces:
        u, n = AXIS_FRAMES[ax]
        U, N = Vector(u), Vector(n)
        if ax in ("-y", "+y"):
            half_n, w, tw = sy / 2, sx, sx * top[0]
            inset = half_n * (1 - top[1])
        else:
            half_n, w, tw = sx / 2, sy, sy * top[1]
            inset = half_n * (1 - top[0])
        O = Vector((x, y, z)) + N * half_n
        V = Vector((0, 0, sz)) - N * inset
        slant = V.length
        V.normalize()
        out[ax] = (O, U, V, U.cross(V).normalized(), w, slant, 1 - tw / w)
    return out


def brick_box(name, size, loc, body_m, mats, faces=("-y", "+y", "-x", "+x"), top=(1.0, 1.0), col="buildings",
              avoid=None, rot=None, **kw):
    """A solid block in body_m (the joint colour) with brick_relief on the named side faces; avoid = {axis: [...]}.
    kw go to brick_relief (course, brick, fill, proud, seed, rows_every, row_m ...). rot (deg about Z) turns the
    whole block about its bottom centre."""
    out = [box(name, size, loc, None, body_m, col, top=top)]
    seed = kw.pop("seed", 1)
    for i, (ax, (O, U, V, N, w, h, taper)) in enumerate(box_faces(size, loc, top, faces).items()):
        out += brick_relief(f"{name}_{ax[1]}{'pm'[ax[0] == '+']}", O, U, V, w, h, mats, N, taper=taper, seed=seed + 7 * i,
                            avoid=(avoid or {}).get(ax, ()), col=col, **kw)
    if rot:
        group(out, rot=rot, pivot=loc)
    return out


def row_of(name, p0, p1, count, size, m, col="buildings", top=(1.0, 1.0), rotz=0.0, ends=True):
    """`count` small blocks (size = (sx, sy, sz), bottom-centred, turned rotz deg) evenly from p0 to p1, one mesh:
    rafter ends under an eave, brackets, crenels, drip tiles, fence pickets, stake rows."""
    bm = bmesh.new()
    P0, P1 = Vector(p0), Vector(p1)
    R = Matrix.Rotation(math.radians(rotz), 3, 'Z')
    sx, sy, sz = size
    hx, hy = sx / 2, sy / 2
    tx, ty = hx * top[0], hy * top[1]
    corners = [Vector(c) for c in ((-hx, -hy, 0), (hx, -hy, 0), (hx, hy, 0), (-hx, hy, 0),
                                   (-tx, -ty, sz), (tx, -ty, sz), (tx, ty, sz), (-tx, ty, sz))]
    for i in range(count):
        t = (i / (count - 1) if count > 1 else 0.5) if ends else (i + 0.5) / count
        c = P0.lerp(P1, t)
        v = [bm.verts.new(c + R @ k) for k in corners]
        for f in ((0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)):
            bm.faces.new([v[j] for j in f])
    return _mesh_from(name, bm, m, col)


def cornice(name, loc, w, d, m, steps=((0.025, 0.035), (0.05, 0.03)), col="buildings", m2=None):
    """Stepped cornice / plinth course round a block of plan w x d: each step (outset, height) is a slab slightly
    larger than the block, stacked from loc.z up (alternate steps in m2 if given)."""
    out = []
    x, y, z = loc
    for i, (o, hh) in enumerate(steps):
        out.append(box(f"{name}{i}", (w + 2 * o, d + 2 * o, hh), (x, y, z), None, (m2 if (m2 is not None and i % 2) else m), col))
        z += hh
    return out


# ------------------------------------------------------------------------------------------------------------------
# inspection / finishing
# ------------------------------------------------------------------------------------------------------------------
def meshes(scene_only=True):
    return [o for o in bpy.context.scene.objects if o.type == 'MESH']


def bbox(objs=None):
    objs = objs if objs is not None else meshes()
    bpy.context.view_layer.update()
    mn = Vector((1e9, 1e9, 1e9))
    mx = Vector((-1e9, -1e9, -1e9))
    for o in objs:
        mw = o.matrix_world
        for v in o.data.vertices:
            p = mw @ v.co
            mn = Vector(map(min, mn, p))
            mx = Vector(map(max, mx, p))
    return mn, mx


def tris(objs=None):
    objs = objs if objs is not None else meshes()
    return sum(sum(len(p.vertices) - 2 for p in o.data.polygons) for o in objs)


def finish():
    """Apply all transforms, then move the city so its XY footprint centre is at the origin and its lowest
    point is on the ground (z = 0). Returns the measured dims."""
    objs = meshes()
    bpy.context.view_layer.update()
    for o in objs:
        o.data.transform(o.matrix_world)
        o.matrix_world = Matrix.Identity(4)
    mn, mx = bbox(objs)
    off = Vector(((mn.x + mx.x) / 2, (mn.y + mx.y) / 2, mn.z))
    T = Matrix.Translation(-off)
    for o in objs:
        o.data.transform(T)
        o.data.update()
    mn, mx = bbox(objs)
    return dims(objs)


def dims(objs=None):
    objs = objs if objs is not None else meshes()
    mn, mx = bbox(objs)
    w, d, h = mx.x - mn.x, mx.y - mn.y, mx.z - mn.z
    return {"width_x": round(w, 4), "depth_y": round(d, 4), "height": round(h, 4),
            "aspect": round(max(w, d) / max(1e-6, min(w, d)), 3), "bbox_min": [round(c, 4) for c in mn],
            "bbox_max": [round(c, 4) for c in mx], "triangles": tris(objs), "objects": len(objs)}


def join_by_material(prefix_id):
    """Join every mesh per (single) material into '<id>_<Material>'; returns the joined objects."""
    by_mat = {}
    for o in meshes():
        if len(o.data.materials) != 1:
            raise RuntimeError(f"{o.name}: expected exactly one material, has {len(o.data.materials)}")
        by_mat.setdefault(o.data.materials[0].name, []).append(o)
    joined = []
    for mname, grp in sorted(by_mat.items()):
        bpy.ops.object.select_all(action='DESELECT')
        for o in grp:
            o.select_set(True)
        bpy.context.view_layer.objects.active = grp[0]
        if len(grp) > 1:
            bpy.ops.object.join()
        ob = bpy.context.view_layer.objects.active
        ob.name = f"{prefix_id}_{re.sub(r'[^A-Za-z0-9]+', '_', mname).strip('_')}"
        ob.data.name = ob.name
        ob["city_id"] = prefix_id
        ob["piece"] = "custom_map_catalogue_building_only"
        joined.append(ob)
    return joined


def export_glb(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    for sc in bpy.data.scenes:  # nothing selected anywhere (a stray selection must never leak into an export)
        for o in sc.objects:
            o.select_set(False)
    bpy.ops.export_scene.gltf(filepath=path, export_format='GLB', export_yup=True, export_apply=True,
                              use_selection=False, export_extras=True, export_cameras=False, export_lights=False,
                              export_animations=False, export_materials='EXPORT')


# ------------------------------------------------------------------------------------------------------------------
# rendering (the exact camera and light of the DERIVED board-city renders, render_preview.py "q34")
# ------------------------------------------------------------------------------------------------------------------
VIEW_DIRS = {
    "q34": lambda: Vector((-math.sin(math.radians(45)) * math.cos(math.radians(35)), -math.cos(math.radians(45)) * math.cos(math.radians(35)), math.sin(math.radians(35)))),
    # what the merchant board shows: camera PITCH 0.76 rad above the horizon, looking north, every city turned by
    # CITY_YAW -0.44 rad -> in model space the camera sits 25.2 deg to the RIGHT of the front (+X side visible)
    "board": lambda: Vector((math.sin(0.44) * math.cos(0.76), -math.cos(0.44) * math.cos(0.76), math.sin(0.76))),
    "front": lambda: Vector((0, -1, 0)), "back": lambda: Vector((0, 1, 0)),
    "left": lambda: Vector((-1, 0, 0)), "right": lambda: Vector((1, 0, 0)), "top": lambda: Vector((0, -1e-4, 1)),
}


def import_glb(path):
    reset_scene()
    bpy.ops.import_scene.gltf(filepath=path)
    return meshes()


def _studio(bg=0.62, key_rot=(50, 0, -35), key_energy=3.2, key_dir=None):
    scene = bpy.context.scene
    for o in [o for o in scene.objects if o.type in ('LIGHT', 'CAMERA')]:
        bpy.data.objects.remove(o, do_unlink=True)
    sun_data = bpy.data.lights.new("Key", 'SUN')
    sun_data.energy = key_energy
    sun_data.angle = math.radians(3)
    sun = bpy.data.objects.new("Key", sun_data)
    scene.collection.objects.link(sun)
    if key_dir is not None:  # key_dir points from the model toward the light
        sun.rotation_mode = 'QUATERNION'
        sun.rotation_quaternion = (-Vector(key_dir)).normalized().to_track_quat('-Z', 'Y')
    else:
        sun.rotation_euler = tuple(math.radians(r) for r in key_rot)
    world = bpy.data.worlds.get("Grey") or bpy.data.worlds.new("Grey")
    scene.world = world
    try:
        world.use_nodes = True
    except Exception:
        pass
    bgn = world.node_tree.nodes.get("Background")
    bgn.inputs[0].default_value = (bg, bg, bg, 1.0)
    bgn.inputs[1].default_value = 1.0
    scene.render.engine = 'BLENDER_EEVEE'
    scene.view_settings.view_transform = 'Standard'
    try:
        scene.eevee.taa_render_samples = 32
    except Exception:
        pass
    return sun


def render_view(out, view="q34", W=800, H=600, ortho_scale=None, margin=1.08, transparent=False, key_rot=(50, 0, -35),
                bg=0.62, label=None, centre=None, key_dir=None):
    """Orthographic render of every mesh in the scene. q34 == the DERIVED renders' camera (front-left, 35 deg).
    ortho_scale fixes the scale (for same-scale sheets); else the frame is fitted to the projected vertices."""
    scene = bpy.context.scene
    _studio(bg, key_rot, key_dir=key_dir)
    objs = meshes()
    mn, mx = bbox(objs)
    c = centre if centre is not None else (mn + mx) / 2
    d = VIEW_DIRS[view]().normalized()
    cam_data = bpy.data.cameras.new("Cam")
    cam_data.type = 'ORTHO'
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.rotation_mode = 'QUATERNION'
    cam.rotation_quaternion = (-d).to_track_quat('-Z', 'Y')
    rot = cam.rotation_quaternion.to_matrix()
    right, up = rot @ Vector((1, 0, 0)), rot @ Vector((0, 1, 0))
    xs, ys = [], []
    for o in objs:
        mw = o.matrix_world
        for v in o.data.vertices:
            p = mw @ v.co - c
            xs.append(p.dot(right))
            ys.append(p.dot(up))
    w, h = max(xs) - min(xs), max(ys) - min(ys)
    off = right * ((max(xs) + min(xs)) / 2) + up * ((max(ys) + min(ys)) / 2)
    if ortho_scale is not None:  # same-scale sheets: keep the ground line fixed, centre horizontally
        off = right * ((max(xs) + min(xs)) / 2) + up * (min(ys) + ortho_scale * (H / max(W, H)) * 0.42)
    cam_data.ortho_scale = ortho_scale or max(w, h * W / H) * margin
    dist = (mx - mn).length * 2 + 10
    cam.location = c + off + d * dist
    cam_data.clip_start = 0.01
    cam_data.clip_end = dist * 3
    txt = None
    if label:
        fc = bpy.data.curves.new("Label", 'FONT')
        fc.body = label
        fc.size = cam_data.ortho_scale * 0.045
        txt = bpy.data.objects.new("Label", fc)
        lm = bpy.data.materials.new("LabelInk")
        try:
            lm.use_nodes = True
        except Exception:
            pass
        bsdf = lm.node_tree.nodes.get("Principled BSDF")
        bsdf.inputs["Base Color"].default_value = (0.1, 0.07, 0.05, 1)
        bsdf.inputs["Emission Color"].default_value = (0.1, 0.07, 0.05, 1)
        bsdf.inputs["Emission Strength"].default_value = 1.0
        fc.materials.append(lm)
        scene.collection.objects.link(txt)
        half_w = cam_data.ortho_scale / 2
        half_h = half_w * H / W if W >= H else cam_data.ortho_scale / 2
        if W < H:
            half_w = half_h * W / H
        txt.rotation_mode = 'QUATERNION'
        txt.rotation_quaternion = cam.rotation_quaternion
        txt.location = cam.location - d * 1.0 + right * (-half_w * 0.95) + up * (half_h * 0.86)
    scene.render.resolution_x = W
    scene.render.resolution_y = H
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = transparent
    scene.render.image_settings.file_format = 'PNG'
    scene.render.image_settings.color_mode = 'RGBA' if transparent else 'RGB'
    scene.render.filepath = out
    os.makedirs(os.path.dirname(out), exist_ok=True)
    bpy.ops.render.render(write_still=True)
    info = {"out": out, "view": view, "ortho_scale": round(cam_data.ortho_scale, 4), "fit_w": round(w, 4), "fit_h": round(h, 4)}
    bpy.data.objects.remove(cam, do_unlink=True)
    if txt is not None:
        bpy.data.objects.remove(txt, do_unlink=True)
    return info


def fit_scale(view, W, H, margin=1.08):
    """Ortho scale that fits every mesh in this view (for picking one common scale across views)."""
    objs = meshes()
    mn, mx = bbox(objs)
    c = (mn + mx) / 2
    d = VIEW_DIRS[view]().normalized()
    rot = (-d).to_track_quat('-Z', 'Y').to_matrix()
    right, up = rot @ Vector((1, 0, 0)), rot @ Vector((0, 1, 0))
    xs, ys = [], []
    for o in objs:
        for v in o.data.vertices:
            p = o.matrix_world @ v.co - c
            xs.append(p.dot(right))
            ys.append(p.dot(up))
    return max(max(xs) - min(xs), (max(ys) - min(ys)) * W / H) * margin


def compose(paths, out, cols, cell_w, cell_h, gap=8, bg=(0.93, 0.93, 0.93)):
    """Tile rendered PNGs (row-major) into one sheet with numpy (no PIL in Blender's Python)."""
    import numpy as np
    rows = (len(paths) + cols - 1) // cols
    Wt, Ht = cols * cell_w + (cols + 1) * gap, rows * cell_h + (rows + 1) * gap
    sheet = np.ones((Ht, Wt, 4), dtype=np.float32)
    sheet[..., 0], sheet[..., 1], sheet[..., 2] = bg
    for i, p in enumerate(paths):
        img = bpy.data.images.load(p, check_existing=False)
        w, h = img.size
        px = np.array(img.pixels[:], dtype=np.float32).reshape(h, w, 4)
        r, c = divmod(i, cols)
        # numpy rows go bottom-up in Blender images: row 0 of the sheet array is the bottom of the picture
        y0 = Ht - gap - (r + 1) * cell_h - r * gap
        x0 = gap + c * (cell_w + gap)
        sheet[y0:y0 + h, x0:x0 + w, :] = px[:cell_h, :cell_w, :]
        bpy.data.images.remove(img)
    im = bpy.data.images.new("sheet", Wt, Ht, alpha=True)
    im.pixels = sheet.ravel()
    im.filepath_raw = out
    im.file_format = 'PNG'
    im.save()
    bpy.data.images.remove(im)
    return out
