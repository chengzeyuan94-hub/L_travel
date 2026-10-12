#!/usr/bin/env python3
"""Build SilkRoad's sixteen original low-poly city miniatures in Blender.

Run with Blender --background --factory-startup --python-exit-code 1 --python
tools/lowpoly/build_cities.py. Geometry is authored here, never inferred from
rule data. City identities and transport rules are read, never changed.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from collections import defaultdict
from pathlib import Path

import bpy
import bmesh
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[2]
PALETTE = {
    "sandstone": "D9B985", "cream": "F0E5C9", "terracotta": "C56D4D",
    "roof_red": "A54D3B", "teal": "568D83", "stone": "A5AD9C",
    "dark_wood": "725444", "deep_shadow": "5C5650", "gold": "D7AB51",
    "foliage": "6F9470", "water": "75B5B3", "brick": "AC765A",
}


def linear(v):
    v = int(v, 16) / 255.0
    return v / 12.92 if v < 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def material(name, color):
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = (*[linear(color[i:i + 2]) for i in (0, 2, 4)], 1)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = mat.diffuse_color
    bsdf.inputs["Roughness"].default_value = 0.9
    bsdf.inputs["Metallic"].default_value = 0.0
    mat.use_backface_culling = True
    return mat


class Geometry:
    def __init__(self, city_id):
        self.city_id = city_id
        self.buckets = defaultdict(lambda: [[], []])

    def mesh(self, vertices, faces, mat="sandstone", center=(0, 0, 0), angle=0):
        if self.city_id == "heijokyo":
            # The pagoda finial and tiny niches reuse existing materials,
            # keeping this combined temple complex within eight surfaces.
            mat = {"gold": "cream", "deep_shadow": "dark_wood"}.get(mat, mat)
        target_v, target_f = self.buckets[mat]
        offset = len(target_v)
        c, s = math.cos(angle), math.sin(angle)
        x, y, z = center
        target_v.extend((x + c * vx - s * vy, y + s * vx + c * vy, z + vz)
                        for vx, vy, vz in vertices)
        target_f.extend(tuple(offset + i for i in face) for face in faces)

    def box(self, x, y, z, w, d, h, mat="sandstone", angle=0):
        v = [(sx * w / 2, sy * d / 2, zz) for zz in (0, h)
             for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
        self.mesh(v, [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4),
                      (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)], mat, (x, y, z), angle)

    def ring(self, x, y, z, radius, height, mat="sandstone", sides=12,
             top=None, inner=0, scale_y=1, rotation=0):
        top = radius if top is None else top
        if not inner and top == 0:
            vertices = [(radius*math.cos(rotation+i*math.tau/sides),
                         radius*math.sin(rotation+i*math.tau/sides)*scale_y,0)
                        for i in range(sides)] + [(0,0,height)]
            faces = [tuple(range(sides-1,-1,-1))]
            faces += [(i,(i+1)%sides,sides) for i in range(sides)]
            self.mesh(vertices,faces,mat,(x,y,z))
            return
        rings = [(radius, 0), (top, height)]
        if inner:
            rings.extend([(inner, height), (inner, 0)])
        verts = [(r * math.cos(rotation + i * math.tau / sides),
                  r * math.sin(rotation + i * math.tau / sides) * scale_y, zz)
                 for r, zz in rings for i in range(sides)]
        faces = []
        for j in range(len(rings) if inner else 1):
            nj = (j + 1) % len(rings)
            for i in range(sides):
                ni = (i + 1) % sides
                faces.append((j * sides + i, j * sides + ni, nj * sides + ni, nj * sides + i))
        if not inner:
            faces.extend([tuple(range(sides - 1, -1, -1)), tuple(range(sides, 2 * sides))])
        self.mesh(verts, faces, mat, (x, y, z))

    def dome(self, x, y, z, r, h, mat="cream", sides=12, steps=4):
        verts = []
        for j in range(steps + 1):
            a = j / steps * math.pi / 2
            rr = max(0.0001, r * math.cos(a))
            verts.extend((rr * math.cos(i * math.tau / sides),
                          rr * math.sin(i * math.tau / sides), h * math.sin(a))
                         for i in range(sides))
        faces = [tuple(range(sides - 1, -1, -1))]
        for j in range(steps):
            for i in range(sides):
                ni = (i + 1) % sides
                faces.append((j * sides + i, j * sides + ni,
                              (j + 1) * sides + ni, (j + 1) * sides + i))
        self.mesh(verts, faces, mat, (x, y, z))

    def gable(self, x, y, z, w, d, h, mat="roof_red", angle=0):
        verts = [(-w / 2, -d / 2, 0), (w / 2, -d / 2, 0),
                 (w / 2, d / 2, 0), (-w / 2, d / 2, 0),
                 (0, -d / 2, h), (0, d / 2, h)]
        self.mesh(verts, [(0, 3, 2, 1), (0, 4, 5, 3), (4, 1, 2, 5),
                          (0, 1, 4), (3, 5, 2)], mat, (x, y, z), angle)

    def east_roof(self, x, y, z, w, d, h, mat="teal", angle=0):
        if self.city_id == "quanzhou":
            return self.quanzhou_roof(x, y, z, w, d, h, mat, angle)
        outline = [(-1, -1), (0, -1), (1, -1), (1, 0),
                   (1, 1), (0, 1), (-1, 1), (-1, 0)]
        verts = [(xx * w / 2, yy * d / 2, h * .19 if xx and yy else 0)
                 for xx, yy in outline]
        verts += [(xx * w * .18, yy * d * .15, h) for xx, yy in outline]
        faces = [tuple(range(7, -1, -1)), tuple(range(8, 16))]
        faces.extend((i, (i + 1) % 8, 8 + (i + 1) % 8, 8 + i) for i in range(8))
        self.mesh(verts, faces, mat, (x, y, z), angle)
        self.box(x, y, z + h, w * .4, .045, .035, "cream", angle)

    def quanzhou_roof(self, x, y, z, w, d, h, mat, angle=0):
        """Three rising profiles and a closed, thin eave for the port sample.

        Original width/depth/ridge height are retained; intermediate profiles
        change the silhouette and light planes instead of merely subdividing
        the old flat slope. Other cities keep their original roof topology.
        """
        outline = [(-1, -1), (-1/3, -1), (1/3, -1), (1, -1),
                   (1, -1/3), (1, 1/3), (1, 1), (1/3, 1),
                   (-1/3, 1), (-1, 1), (-1, 1/3), (-1, -1/3)]
        thick = min(.012, h * .15)
        vertices = []
        for ring in range(4):
            for xx, yy in outline:
                corner = abs(xx) == 1 and abs(yy) == 1
                if ring < 2:
                    zz = h * .30 if corner else 0
                    vertices.append((xx*w/2, yy*d/2, zz-(thick if ring == 0 else 0)))
                elif ring == 2:
                    vertices.append((xx*w*.36, yy*d*.36, h*(.30+(.05 if corner else 0))))
                else:
                    vertices.append((xx*w*.18, yy*d*.15, h))
        top_faces = [tuple(range(36, 48))]
        for ring in (1, 2):
            top_faces.extend((ring*12+i, ring*12+(i+1)%12,
                              (ring+1)*12+(i+1)%12, (ring+1)*12+i) for i in range(12))
        edge_faces = [tuple(range(11, -1, -1))]
        edge_faces.extend((i, (i+1)%12, 12+(i+1)%12, 12+i) for i in range(12))
        self.mesh(vertices, top_faces, mat, (x, y, z), angle)
        self.mesh(vertices, edge_faces, "sandstone" if mat == "stone" else "dark_wood", (x, y, z), angle)
        self.box(x, y, z+h, w*.4, .045, .035, "cream", angle)

    def arch(self, x, y, z, w, h, depth, mat="sandstone", angle=0, steps=7):
        """A real open arch: two piers and a segmented half-circle voussoir."""
        radius = w * .5
        thick = w * .18
        spring = h - radius
        c, s = math.cos(angle), math.sin(angle)
        for xx in (-radius - thick / 2, radius + thick / 2):
            self.box(x + xx * c, y + xx * s, z, thick, depth, spring, mat, angle)
        verts = []
        for yy in (-depth / 2, depth / 2):
            for rr in (radius, radius + thick):
                for i in range(steps + 1):
                    a = i / steps * math.pi
                    verts.append((rr * math.cos(a), yy, spring + rr * math.sin(a)))
        n = steps + 1
        faces = []
        for i in range(steps):
            faces += [(i, i + 1, n + i + 1, n + i),
                      (2 * n + i, 3 * n + i, 3 * n + i + 1, 2 * n + i + 1),
                      (n + i, n + i + 1, 3 * n + i + 1, 3 * n + i),
                      (i, 2 * n + i, 2 * n + i + 1, i + 1)]
        faces += [(0, n, 3 * n, 2 * n), (n - 1, 3 * n - 1, 4 * n - 1, 2 * n - 1)]
        self.mesh(verts, faces, mat, (x, y, z), angle)

    def steps(self, x, y, z, w, d, h, count=4, mat="cream"):
        # A single closed staircase solid; overlapping boxes create coplanar
        # side walls, dark seams in Cycles and depth flicker after GLB export.
        profile = [(-d/2, 0), (d/2, 0), (d/2, h)]
        for i in range(count-1, -1, -1):
            yy = -d/2 + i*d/count
            profile.append((yy, h*(i+1)/count))
            if i:
                profile.append((yy, h*i/count))
        n = len(profile)
        vertices = [(xx, yy, zz) for xx in (-w/2, w/2) for yy, zz in profile]
        faces = [tuple(range(n-1, -1, -1)), tuple(range(n, 2*n))]
        faces += [(i, (i+1)%n, (i+1)%n+n, i+n) for i in range(n)]
        self.mesh(vertices, faces, mat, (x, y, z))

    def open_round_wall(self, x, y, z, r, inner, h, gap=.20, mat="brick"):
        sides = 24
        angles = [-math.pi/2+gap+i*(math.tau-2*gap)/sides for i in range(sides+1)]
        vertices = [(rr*math.cos(a), rr*math.sin(a), zz)
                    for rr,zz in ((r,0),(r,h),(inner,h),(inner,0)) for a in angles]
        n = sides+1
        faces = []
        for ring in range(4):
            nextring = (ring+1)%4
            for i in range(sides):
                faces.append((ring*n+i,ring*n+i+1,nextring*n+i+1,nextring*n+i))
        faces += [(0,n,2*n,3*n),(n-1,4*n-1,3*n-1,2*n-1)]
        self.mesh(vertices, faces, mat, (x,y,z))

    def house(self, x, y, w=.26, d=.28, h=.23, roof="roof_red", angle=0):
        self.box(x, y, .04, w, d, h, "cream", angle)
        self.gable(x, y, .04 + h, w * 1.14, d * 1.12, h * .42, roof, angle)
        self.box(x, y - d / 2 - .006, .04, w * .2, .012, h * .55, "dark_wood")

    def flat_house(self, x, y, w=.27, d=.26, h=.26, mat="sandstone", floors=1):
        self.box(x, y, .025, w, d, h, mat)
        self.box(x, y, h + .025, w * 1.06, d * 1.06, .045, "cream")
        for j in range(floors):
            self.box(x - w * .21, y - d / 2 - .007, .10 + j * h / floors,
                     w * .16, .017, .075, "deep_shadow")
            self.box(x + w * .21, y - d / 2 - .007, .10 + j * h / floors,
                     w * .16, .017, .075, "deep_shadow")

    def palm(self, x, y, z=0, h=.45, r=.2):
        self.ring(x, y, z, .025, h, "dark_wood", 7, top=.02)
        for i in range(6):
            a = i * math.tau / 6
            self.mesh([(0, 0, 0), (r * .55, -.052, .075), (r, 0, -.025),
                       (r * .55, .052, .075)], [(0, 1, 2, 3)], "foliage", (x, y, z + h), a)

    def tree(self, x, y, h=.4, r=.16):
        self.ring(x, y, 0, .025, h * .6, "dark_wood", 6)
        self.dome(x, y, h * .35, r, h * .5, "foliage", 7, 3)
        self.ring(x, y, h * .25, r * .6, h * .22, "foliage", 7, top=r)

    def terrace(self, w=1.6, d=1.3, mat="sandstone"):
        verts = [(math.cos(i * math.tau / 8) * w / 2,
                  math.sin(i * math.tau / 8) * d / 2, z)
                 for z in (0, .045) for i in range(8)]
        faces = [tuple(range(7, -1, -1)), tuple(range(8, 16))]
        faces.extend((i, (i + 1) % 8, (i + 1) % 8 + 8, i + 8) for i in range(8))
        self.mesh(verts, faces, mat)

    def east_hall(self, x, y, z, w, d, h, roof="teal"):
        self.box(x, y, z, w * 1.07, d * 1.07, .06, "stone")
        self.box(x, y, z + .06, w * .89, d * .8, h, "cream")
        for xx in (-.39, 0, .39):
            self.box(x + xx * w, y - d * .43, z + .06, .038, .05, h, "terracotta")
        self.east_roof(x, y, z + .06 + h, w * 1.17, d * 1.24, h * .6, roof)

    def pagoda(self, x, y, floors=4, width=.4, height=1.0, mat="teal"):
        self.box(x, y, .025, width * 1.05, width * 1.05, .065, "stone")
        dh = height / (floors + .5)
        for i in range(floors):
            w = width * (1 - i * .12)
            zz = .08 + i * dh
            self.box(x, y, zz, w * .65, w * .65, dh * .8, "cream")
            self.box(x, y-w*.327-.004, zz+dh*.17, w*.18, .010, dh*.37, "deep_shadow")
            for xx in (-.29,.29):
                self.box(x+xx*w, y-w*.335, zz, .015, .018, dh*.77, "sandstone")
            self.east_roof(x, y, zz + dh * .72, w, w, dh * .34, mat)
        self.ring(x, y, .08 + floors * dh, .023, dh * .6, "gold", 6, top=0)


def yumenguan(g):
    g.terrace(1.8, 1.25, "stone")
    g.box(0, .1, .03, .86, .72, .43)
    g.box(0, .1, .46, .89, .74, .08, "cream")
    g.box(0, -.268, .04, .22, .014, .32, "deep_shadow")
    for x in (-.42, .42):
        for y in (-.26, .46):
            g.box(x, y, .44, .19, .19, .2, "sandstone")
    for x in (-.33, -.11, .11, .33):
        g.box(x, -.25, .52, .105, .12, .10)
    g.box(-.68, .27, .03, .4, .1, .22, "brick")
    g.box(.63, .2, .03, .36, .09, .19, "brick")
    g.ring(.67, .34, .02, .14, .70, "sandstone", 4, top=.10, rotation=math.pi / 4)
    g.box(.67, .34, .72, .23, .23, .045, "cream")
    g.flat_house(-.55, -.28, .3, .2, .18)
    # VISUAL-006: an open gateway, timber lookout and lit beacon identify
    # the frontier pass without changing the original fort footprint.
    g.arch(0, -.355, .045, .23, .32, .12, "cream", steps=7)
    for xx in (-.158, .158):
        g.box(xx, -.355, .045, .08, .18, .075, "stone")
    g.gable(0, -.355, .395, .40, .24, .085, "roof_red", math.pi/2)
    g.steps(0, -.48, .045, .34, .19, .08, 3, "stone")
    for xx in (-.17, .17):
        for yy in (-.035, .235):
            g.box(xx, yy, .545, .035, .035, .20, "dark_wood")
    g.east_roof(0, .10, .735, .46, .39, .13, "roof_red")
    for xx in (-.185, .185):
        g.box(xx, .10, .59, .022, .31, .055, "dark_wood")
    for yy in (-.055, .255):
        g.box(0, yy, .61, .37, .022, .04, "dark_wood")
    for xx in (-.23, .23):
        for yy in (-.095, .295):
            g.ring(xx, yy, .76, .022, .07, "roof_red", 6, top=0)
    g.ring(.67, .34, .765, .095, .08, "brick", 8, top=.10, inner=.055)
    g.ring(.67, .34, .80, .055, .12, "gold", 6, top=0)
    for xx in (.59, .75):
        g.box(xx, .224, .31, .018, .02, .44, "dark_wood")
    for i in range(6):
        g.box(.67, .224, .33+i*.065, .17, .022, .018, "dark_wood")


def rome(g):
    g.terrace(1.85, 1.35, "stone")
    # Elliptical amphitheatre with actual arches and an open central arena.
    rx, ry, n = .59, .42, 16
    for level in range(2):
        z = .06 + level * .25
        for i in range(n):
            a = i * math.tau / n
            x, y = -.12 + rx * math.cos(a), .06 + ry * math.sin(a)
            tangent = math.atan2(ry * math.cos(a), -rx * math.sin(a))
            g.arch(x, y, z, .135, .225, .10, "sandstone" if level == 0 else "cream", tangent, 5)
        g.ring(-.12, .06, z + .225, rx + .055, .045, "cream", n,
               inner=rx - .07, scale_y=ry / rx)
    g.ring(-.12, .06, .55, rx + .055, .12, "sandstone", n,
           inner=rx - .07, scale_y=ry / rx)
    # Stepped, genuinely hollow arena tiers remain legible from above.
    for outer, inner, hh in ((.52,.45,.32),(.45,.37,.23),(.37,.29,.14)):
        g.ring(-.12,.06,.045,outer,hh,"stone",16,inner=inner,scale_y=ry/rx)
    g.ring(-.12,.06,.043,.29,.008,"sandstone",16,scale_y=ry/rx)
    for i in range(16):
        a = i * math.tau / 16
        g.box(-.12 + .605 * math.cos(a), .06 + .43 * math.sin(a), .555,
              .04, .04, .08, "cream")
    g.box(.58, -.31, .03, .4, .32, .055, "cream")
    for xx in (.43, .57, .71):
        g.ring(xx, -.41, .085, .025, .27, "cream", 8)
    g.gable(.57, -.29, .36, .45, .37, .12, "roof_red", math.pi / 2)
    g.house(.58, .46, .30, .23, .22)


def constantinople(g):
    g.terrace(1.8, 1.45)
    g.box(0, .06, .045, .79, .7, .43, "cream")
    g.ring(0, .06, .475, .32, .1, "sandstone", 12)
    g.dome(0, .06, .575, .345, .31, "teal", 12, 4)
    for i in range(10):
        a = i*math.tau/10
        g.box(.322*math.cos(a),.06+.322*math.sin(a),.49,.038,.008,.070,
              "deep_shadow",a+math.pi/2)
    for yy in (-.37, .48):
        g.box(0, yy, .045, .58, .33, .29, "cream")
        g.dome(0, yy, .335, .245, .19, "teal", 10, 3)
    for xx in (-.46, .46):
        g.box(xx, .06, .03, .20, .6, .31, "sandstone")
        g.gable(xx, .06, .34, .26, .66, .10, "roof_red")
        for yy in (-.20,.33):
            g.box(xx,yy,.035,.25,.23,.24,"sandstone")
            g.dome(xx,yy,.275,.16,.14,"teal",10,3)
    for xx in (-.72, .72):
        g.box(xx, .33, .045, .18, .21, .36, "brick")
        g.box(xx, .33, .405, .20, .23, .06, "cream")
    g.box(0, .57, .035, 1.42, .08, .18, "brick")
    for xx in (-.24, 0, .24):
        g.arch(xx, -.55, .045, .12, .20, .06, "sandstone")
    # Paired slender skyline towers complement the existing central dome.
    for xx in (-.72, .72):
        g.ring(xx, .33, .465, .065, .34, "cream", 8, top=.048)
        g.ring(xx, .33, .79, .085, .035, "sandstone", 8)
        g.ring(xx, .33, .825, .056, .17, "teal", 8, top=0)


def changan(g):
    g.terrace(1.9, 1.45, "stone")
    g.east_hall(0, .30, .07, 1.03, .57, .33, "teal")
    g.east_roof(0, .30, .70, .72, .44, .15, "roof_red")
    for xx in (-.42,0,.42):
        g.arch(xx,-.34,.045,.23,.28,.19,"sandstone",steps=7)
    for xx in (-.67,-.21,.21,.67):
        g.box(xx,-.34,.045,.13,.19,.32,"sandstone")
    g.box(0,-.34,.36,1.45,.24,.07,"cream")
    for xx in (-.5, .5):
        g.east_hall(xx, -.34, .43, .4, .32, .19, "roof_red")
    g.east_hall(0, -.34, .43, .46, .34, .24, "roof_red")
    g.box(-.74, .04, .045, .055, .94, .17, "cream")
    g.box(.74, .04, .045, .055, .94, .17, "cream")
    g.tree(-.61, .43, .35)
    g.tree(.64, .42, .35)


def panti(g):
    g.terrace(1.85, 1.3, "stone")
    g.box(0, .16, .04, .91, .55, .33, "brick")
    g.box(0, .16, .37, .93, .57, .045, "sandstone")
    g.box(0, -.124, .045, .25, .016, .24, "deep_shadow")
    for xx in (-.45, .45):
        g.ring(xx, -.12, .035, .14, .51, "sandstone", 5, top=.11)
        g.ring(xx, -.12, .545, .135, .07, "cream", 5)
    for i in range(7):
        g.box(-.4 + i * .13, -.12, .4, .07, .10, .085, "sandstone")
    g.flat_house(-.61, .31, .3, .35, .20, "cream")
    g.flat_house(.63, .33, .30, .27, .22)
    # Horse enclosure / caravan court, not a claimed specific modern ruin.
    for xx in (-.24, .02, .28):
        g.box(xx, -.48, .03, .022, .025, .18, "dark_wood")
    g.box(.02, -.48, .12, .57, .023, .028, "dark_wood")
    g.palm(-.69, -.30, h=.57, r=.18)
    # A caravan gatehouse, cloth market stall and masonry well are regional
    # visual motifs, not a reconstruction claim for the uncertain historic site.
    g.arch(0, -.23, .045, .25, .31, .13, "cream", steps=6)
    g.box(0, -.23, .40, .40, .22, .11, "brick")
    g.gable(0, -.23, .51, .45, .26, .12, "roof_red", math.pi/2)
    for xx in (.41, .69):
        for yy in (-.38, -.12):
            g.box(xx, yy, .045, .022, .022, .25, "dark_wood")
    g.gable(.55, -.25, .29, .35, .33, .065, "roof_red")
    for xx in (.46, .62):
        g.box(xx, -.26, .045, .12, .15, .105, "brick")
    g.ring(-.31, -.39, .045, .125, .10, "stone", 8, inner=.082)
    g.ring(-.31, -.39, .085, .079, .006, "deep_shadow", 8)
    for xx in (-.45, -.17):
        g.box(xx, -.39, .145, .025, .025, .25, "dark_wood")
    g.box(-.31, -.39, .395, .33, .04, .03, "dark_wood")
    g.ring(-.31, -.39, .22, .009, .175, "dark_wood", 6)
    g.ring(-.31, -.39, .18, .042, .05, "dark_wood", 8, inner=.029)


def baghdad(g):
    g.terrace(1.85, 1.5)
    g.open_round_wall(0,.03,.045,.70,.60,.25,gap=.20)
    for i in range(16):
        a = i * math.tau / 16
        g.box(.665 * math.cos(a), .03 + .665 * math.sin(a), .295,
              .08, .08, .065, "sandstone", a)
    g.box(0, .12, .04, .49, .45, .36, "cream")
    g.ring(0, .12, .40, .25, .10, "sandstone", 12)
    g.dome(0, .12, .50, .27, .29, "teal", 12, 4)
    g.ring(.38, .19, .03, .07, .67, "cream", 8, top=.045)
    g.ring(.38, .19, .60, .10, .045, "sandstone", 8)
    g.ring(.38, .19, .70, .055, .12, "teal", 8, top=0)
    g.arch(0, -.65, .03, .22, .32, .15, "sandstone", 0)
    g.flat_house(-.36, .12, .23, .3, .21)
    g.flat_house(-.25, -.29, .23, .22, .18)
    g.flat_house(.3, -.27, .24, .24, .19)
    # One compact spiral-ramp tower gives the round city a second clear motif.
    x, y, z, height = -.49, -.16, .045, .64
    g.ring(x, y, z, .125, height, "sandstone", 8, top=.05)
    for i in range(12):
        a, b = i*math.tau/10, (i+1)*math.tau/10
        r0, r1 = .165-i*.006, .165-(i+1)*.006
        z0, z1 = z+i*height/12, z+(i+1)*height/12
        vertices = [(r*math.cos(angle), r*math.sin(angle), zz)
                    for zz_offset in (0, .025)
                    for r,angle,zz in ((r0,a,z0+zz_offset),(r0-.05,a,z0+zz_offset),
                                       (r1-.05,b,z1+zz_offset),(r1,b,z1+zz_offset))]
        g.mesh(vertices, [(0,3,2,1),(4,5,6,7),(0,1,5,4),(1,2,6,5),(2,3,7,6),(3,0,4,7)],
               "brick", (x,y,0))
    g.ring(x, y, z+height, .065, .07, "teal", 8, top=0)


def delhi(g):
    g.terrace(1.75, 1.5)
    g.box(-.17, .17, .04, .39, .39, .08, "cream")
    for i in range(5):
        zz = .12 + i * .18
        r = .17 - i * .023
        g.ring(-.17, .17, zz, r, .18, "terracotta" if i % 2 == 0 else "sandstone", 12, top=r - .022)
        g.ring(-.17, .17, zz + .16, r + .025, .034, "cream", 12)
    g.ring(-.17, .17, 1.02, .055, .085, "roof_red", 8, top=0)
    for x in (-.59, -.22, .15, .52):
        g.arch(x, -.37, .04, .23, .30, .12, "terracotta", steps=7)
    g.box(-.04, -.37, .375, 1.42, .16, .06, "cream")
    g.box(.46, .22, .04, .39, .38, .32, "sandstone")
    g.dome(.46, .22, .36, .23, .19, "cream", 10, 3)
    g.tree(-.6, .4, .36, .16)
    # A monumental open Indian gateway sits behind the existing arcade.
    g.arch(.46, .49, .04, .25, .49, .14, "terracotta", steps=6)
    g.box(.46, .49, .555, .42, .21, .075, "cream")
    for xx in (.30, .62):
        g.ring(xx, .49, .63, .045, .10, "roof_red", 6, top=0)


def geumseong(g):
    g.terrace(1.9, 1.35, "stone")
    # Cheomseongdae's compact, bottle-shaped masonry tower.
    g.box(-.44, -.04, .04, .4, .4, .07, "cream")
    profile = [(.21, .11), (.20, .22), (.17, .36), (.14, .50), (.155, .65)]
    for (r0, z0), (r1, z1) in zip(profile, profile[1:]):
        g.ring(-.44, -.04, z0, r0, z1-z0, "stone", 12, top=r1)
        g.ring(-.44, -.04, z0+.014, r0+.007, .018, "cream", 12, top=r0+.002)
    for xx in (-.57, -.31):
        g.box(xx, -.04, .65, .055, .34, .09, "cream")
    for yy in (-.17, .09):
        g.box(-.44, yy, .65, .31, .055, .09, "cream")
    g.box(-.44, -.20, .38, .075, .012, .09, "deep_shadow")
    g.east_hall(.31, .25, .045, .70, .5, .26, "deep_shadow")
    g.east_roof(.31, .25, .50, .50, .38, .115, "deep_shadow")
    g.dome(.37, -.39, .04, .24, .18, "foliage", 10, 3)
    g.dome(.70, -.22, .04, .18, .16, "foliage", 9, 3)
    # U-shaped subsidiary halls and a raised court rail frame the main temple.
    for xx in (.005, .615):
        g.box(xx, .21, .045, .16, .48, .17, "cream")
        g.gable(xx, .21, .215, .20, .53, .08, "deep_shadow")
    g.box(.31, .435, .045, .62, .13, .17, "cream")
    g.gable(.31, .435, .215, .69, .17, .08, "deep_shadow", math.pi/2)
    g.box(.31, -.09, .045, .76, .26, .055, "stone")
    for xx in (.015, .16, .46, .605):
        g.box(xx, -.18, .10, .025, .025, .105, "cream")
    for xx in (.09, .53):
        g.box(xx, -.18, .16, .18, .022, .025, "cream")
    for xx in (-.05, .67):
        for yy in (-.19, -.12, -.05, .02):
            g.box(xx, yy, .10, .025, .025, .105, "cream")
        g.box(xx, -.085, .16, .022, .235, .025, "cream")
    g.box(.31, .02, .16, .72, .022, .025, "cream")


def chenla(g):
    g.terrace(1.8, 1.45, "stone")
    for x, y, sc in ((0, .17, 1), (-.46, -.21, .65), (.47, -.15, .68)):
        g.ring(x, y, .04, .30*sc, .12*sc, "sandstone", 8)
        g.ring(x, y, .04+.12*sc, .23*sc, .48*sc, "brick", 8, top=.20*sc)
        g.box(x, y-.217*sc, .04+.12*sc, .12*sc, .028, .27*sc, "deep_shadow")
        for j in range(3):
            g.ring(x, y, .04+(.59+j*.11)*sc, (.24-j*.048)*sc, .13*sc,
                   "terracotta", 8, top=(.19-j*.048)*sc)
        g.ring(x, y, .04+.94*sc, .052*sc, .09*sc, "cream", 8, top=0)
    g.tree(-.63, .34, .62, .20)
    g.tree(.60, .37, .55, .19)
    g.steps(0, -.48, .04, .29, .32, .15, 4)
    # Faceted four-sided face crown: eyes, projecting nose and mouth remain
    # geometry, with no face texture or mirrored negative-scale components.
    g.box(0, .17, .425, .43, .43, .185, "stone")
    for angle in (0, math.pi/2, math.pi, math.pi*1.5):
        verts = [(-.065,-.219,.565),(-.015,-.219,.565),(-.015,-.219,.543),(-.065,-.219,.543),
                 (.015,-.219,.565),(.065,-.219,.565),(.065,-.219,.543),(.015,-.219,.543),
                 (-.04,-.219,.484),(.04,-.219,.484),(.04,-.219,.472),(-.04,-.219,.472)]
        g.mesh(verts,[(0,1,2,3),(4,5,6,7),(8,9,10,11)],"deep_shadow",(0,.17,0),angle)
        g.mesh([(-.025,-.219,.54),(.025,-.219,.54),(0,-.26,.505),
                (-.025,-.219,.495),(.025,-.219,.495)],
               [(0,1,2),(0,2,3),(1,4,2),(2,4,3),(0,3,4,1)],"sandstone",(0,.17,0),angle)


def aden(g):
    g.terrace(1.9, 1.4, "stone")
    # Faceted volcanic escarpment carries a compact fortress.
    g.ring(.30, .31, .03, .48, .40, "brick", 7, top=.26)
    g.box(.29, .31, .43, .48, .34, .25, "sandstone")
    for xx in (.06, .52):
        g.box(xx, .27, .43, .14, .19, .37, "cream")
    g.flat_house(-.49, .17, .30, .29, .37, "sandstone", 2)
    g.flat_house(-.27, -.22, .29, .27, .25, "cream")
    g.flat_house(-.67, -.24, .25, .23, .20, "brick")
    for j in range(3):
        g.box(.37, -.28+j*.11, .045, .49-j*.06, .10, .025+j*.035, "stone")
    g.box(.31, -.49, .03, .63, .15, .04, "dark_wood")
    for xx in (.06, .32, .56):
        g.ring(xx, -.54, .025, .025, .11, "dark_wood", 6)
    g.palm(-.08, .38, h=.55, r=.17)
    # Harbour beacon, open cistern and waterfront arcade strengthen the port.
    g.ring(.62, -.27, .05, .10, .50, "cream", 8, top=.07)
    g.ring(.62, -.27, .55, .125, .04, "brick", 8)
    for i in range(4):
        a = math.pi/4+i*math.pi/2
        g.box(.62+.06*math.cos(a), -.27+.06*math.sin(a), .59, .025, .025, .14, "dark_wood")
    g.ring(.62, -.27, .725, .12, .13, "teal", 8, top=0)
    g.ring(.62, -.27, .67, .13, .03, "cream", 8, inner=.115)
    g.ring(.21, -.29, .08, .17, .095, "stone", 12, inner=.125, scale_y=.72)
    g.ring(.21, -.29, .135, .123, .005, "teal", 12, scale_y=.72)
    g.steps(.21, -.455, .03, .23, .16, .08, 3, "stone")
    for xx in (-.48, -.23):
        g.arch(xx, -.48, .045, .16, .28, .115, "cream", steps=6)
    g.box(-.355, -.48, .35, .55, .16, .045, "brick")
    g.box(-.355, -.48, .395, .59, .19, .035, "cream")
    for xx in (-.60, -.11):
        g.box(xx, -.48, .045, .08, .17, .06, "stone")


def heijokyo(g):
    g.terrace(1.85, 1.45, "stone")
    g.east_hall(.15, .28, .04, .91, .56, .30, "roof_red")
    g.east_roof(.15, .28, .58, .65, .46, .16, "teal")
    g.pagoda(-.56, -.13, floors=5, width=.40, height=.88, mat="teal")
    g.box(.2, -.40, .04, .96, .07, .19, "cream")
    g.east_hall(.22, -.38, .04, .39, .24, .16, "roof_red")
    g.box(.71, .04, .04, .06, .93, .18, "cream")
    g.tree(.60, .38, .38, .16)


def simhala(g):
    g.terrace(1.85, 1.5)
    g.ring(-.05, .12, .035, .54, .10, "stone", 16)
    g.ring(-.05, .12, .135, .46, .08, "cream", 16)
    g.dome(-.05, .12, .215, .40, .40, "cream", 16, 5)
    g.box(-.05, .12, .605, .17, .17, .10, "sandstone")
    g.ring(-.05, .12, .705, .07, .26, "gold", 10, top=.009)
    for i in range(4):
        g.ring(-.05, .12, .74+i*.04, .065-i*.012, .017, "cream", 10)
    g.steps(-.05, -.44, .035, .32, .35, .15, 5)
    g.palm(-.65, -.1, h=.65, r=.24)
    g.palm(.63, .24, h=.56, r=.22)
    g.house(.50, -.33, .29, .25, .17, "roof_red")
    # A small seated-image niche at the stair landing identifies the shrine.
    g.arch(-.05, -.405, .19, .16, .25, .10, "sandstone", steps=5)
    g.box(-.05, -.435, .19, .14, .09, .04, "cream")
    g.ring(-.05, -.437, .23, .035, .07, "gold", 7, top=.025)
    g.dome(-.05, -.437, .30, .027, .037, "gold", 7, 2)


def cairo(g):
    g.terrace(1.8, 1.45)
    g.box(.08, .18, .04, .78, .65, .31, "sandstone")
    g.box(.08, .12, .36, .43, .38, .08, "cream")
    g.dome(.08, .12, .44, .255, .25, "cream", 12, 4)
    g.ring(-.52, .22, .04, .10, .40, "sandstone", 8)
    g.ring(-.52, .22, .44, .13, .07, "cream", 8)
    g.ring(-.52, .22, .51, .075, .27, "sandstone", 8, top=.06)
    g.ring(-.52, .22, .78, .10, .045, "cream", 8)
    g.ring(-.52, .22, .825, .055, .15, "teal", 8, top=0)
    for xx in (-.36, -.1, .16, .42):
        g.arch(xx, -.30, .04, .14, .24, .12, "cream", steps=6)
    g.box(.03, -.30, .315, 1.05, .15, .035, "sandstone")
    g.flat_house(.64, .05, .23, .36, .27, "brick")
    g.flat_house(-.55, -.33, .28, .30, .22)
    g.palm(.54, -.43, h=.42, r=.18)
    # A second, compact minaret balances the existing courtyard silhouette.
    g.ring(.53, .42, .04, .075, .46, "sandstone", 8, top=.055)
    g.ring(.53, .42, .50, .09, .035, "cream", 8)
    g.ring(.53, .42, .535, .05, .22, "teal", 8, top=0)


def jeddah(g):
    g.terrace(1.8, 1.4, "stone")
    for x, y, w, d, h in ((-.33, .20, .41, .39, .89), (.22, .26, .37, .42, .72),
                          (.58, -.13, .30, .33, .49), (-.45, -.27, .37, .31, .42)):
        g.flat_house(x, y, w, d, h, "cream", max(2, round(h / .22)))
        for zz in (.23, .47, .70):
            if zz < h - .05:
                g.box(x, y-d*.5-.044, zz, w*.68, .10, .15, "dark_wood")
                for i in (-1, 0, 1):
                    g.box(x+i*w*.19, y-d*.5-.098, zz, .022, .016, .15, "teal")
                g.box(x, y-d*.5-.10, zz+.065, w*.68, .018, .022, "sandstone")
    g.box(.16, -.52, .035, .76, .13, .055, "dark_wood")
    g.palm(-.74, .22, h=.58, r=.17)


def dagon(g):
    g.terrace(1.8, 1.5, "stone")
    # A religious settlement, not an asserted medieval metropolitan port.
    g.ring(0, .16, .035, .50, .13, "sandstone", 10, top=.45)
    for j in range(4):
        g.ring(0, .16, .165+j*.075, .38-j*.047, .085, "gold", 12, top=.34-j*.047)
    g.dome(0, .16, .465, .205, .20, "gold", 12, 3)
    g.ring(0, .16, .655, .14, .37, "gold", 12, top=.012)
    for j in range(4):
        g.ring(0, .16, .77+j*.06, .085-j*.017, .018, "cream", 10)
    g.steps(0, -.39, .025, .37, .43, .22, 5, "cream")
    for xx in (-.52, .52):
        g.house(xx, -.20, .31, .33, .17, "roof_red")
    g.tree(-.61, .30, .48, .21)
    g.tree(.61, .28, .42, .19)


def quanzhou(g):
    g.terrace(1.9, 1.5, "stone")
    for x in (-.44, .45):
        g.pagoda(x, .20, floors=5, width=.38, height=.91, mat="stone")
        dh = .91 / 5.5
        for i in range(5):
            w, zz = .38*(1-i*.12), .08+i*dh
            # Rear corner pilasters complete the existing front pair; two
            # side niches make the towers read in the orbital camera as well.
            for xx in (-.29, .29):
                g.box(x+xx*w, .20+w*.335, zz, .015, .018, dh*.77, "sandstone")
            for side in (-1, 1):
                vx = side*(w*.326+.002)
                g.mesh([(vx,-w*.09,dh*.20),(vx,w*.09,dh*.20),
                        (vx,w*.09,dh*.56),(vx,-w*.09,dh*.56)],
                       [(0,1,2,3) if side > 0 else (3,2,1,0)], "deep_shadow", (x,.20,zz))
    g.east_hall(0, .35, .04, .43, .33, .20, "roof_red")
    # These residential gables stay byte-for-byte geometrically unchanged:
    # the southwest ridge is the existing runtime kitchen-smoke anchor.
    g.house(-.49, -.31, .30, .26, .20, "roof_red")
    g.house(.46, -.33, .31, .25, .20, "roof_red")
    for xx in (-.18, .01, .20):
        g.arch(xx, -.46, .035, .11, .115, .20, "cream", steps=5)
    g.box(.01, -.46, .185, .69, .23, .04, "stone")
    # Minnan red-roofed gatehouse rests above the existing three-arch entrance.
    g.east_hall(.01, -.46, .225, .57, .24, .15, "roof_red")
    # Short covered galleries join the gate-side storehouses to the tower
    # bases. Their open inner sides keep the three-arch/courtyard axis legible.
    for x, inner_side in ((-.49,1),(.46,-1)):
        g.box(x,-.075,.044,.22,.32,.014,"stone")
        for y in (-.20,-.075,.05):
            g.box(x+inner_side*.084,y,.055,.024,.024,.17,"dark_wood")
        g.quanzhou_roof(x,-.075,.225,.25,.32,.045,"roof_red")
    for x in (-.12,.14):
        for y in (-.22,-.05,.12):
            g.box(x,y,.044,.235,.145,.010,"cream")
    # This low threshold terminates at the existing platform edge, without
    # widening the city or extending over the formal land anchor to the south.
    g.box(.01,-.648,.044,.30,.19,.010,"cream")
    for x,y,z,w,d,h in ((-.68,-.30,.05,.095,.105,.09),
                         (-.67,-.18,.05,.085,.09,.075),
                         (-.68,-.30,.14,.075,.085,.06)):
        g.box(x,y,z,w,d,h,"sandstone")
        g.box(x,y,z+h,w+.002,.018,.005,"dark_wood")


BUILDERS = {f.__name__: f for f in (yumenguan, rome, constantinople, changan,
                                  panti, baghdad, delhi, geumseong, chenla, aden,
                                  heijokyo, simhala, cairo, jeddah, dagon, quanzhou)}


def build_city(city_id, mats, parent_collection):
    g = Geometry(city_id)
    BUILDERS[city_id](g)
    all_v = [v for vertices, _faces in g.buckets.values() for v in vertices]
    lo = [min(v[i] for v in all_v) for i in range(3)]
    hi = [max(v[i] for v in all_v) for i in range(3)]
    factor = min(2.1 / max(hi[0]-lo[0], hi[1]-lo[1]), 1.4 / (hi[2]-lo[2]))
    shift = ((lo[0]+hi[0])/2, (lo[1]+hi[1])/2, lo[2])
    if city_id == "quanzhou":
        # DETAIL-012 keeps the existing world-space city frame. An accidental
        # oversized detail must fail, rather than shrinking the whole city.
        factor, shift = 2.1/1.9, (0.0,0.0,0.0)
        assert all(lo[i] >= limit-1e-7 for i,limit in enumerate((-.95,-.75,0))), (lo,hi)
        assert all(hi[i] <= limit+1e-7 for i,limit in enumerate((.95,.75,1.00655))), (lo,hi)
    collection = bpy.data.collections.new(city_id)
    parent_collection.children.link(collection)
    objects = []
    for mat, (vertices, faces) in sorted(g.buckets.items()):
        vertices = [tuple((v[i]-shift[i])*factor for i in range(3)) for v in vertices]
        mesh = bpy.data.meshes.new(f"{city_id}_{mat}")
        mesh.from_pydata(vertices, [], faces)
        bm = bmesh.new()
        bm.from_mesh(mesh)
        bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
        bm.to_mesh(mesh)
        bm.free()
        mesh.materials.append(mats[mat])
        mesh.update()
        obj = bpy.data.objects.new(f"{city_id}_{mat}", mesh)
        collection.objects.link(obj)
        obj["city_id"] = city_id
        obj["asset_kind"] = "silkroad_lowpoly_city"
        for poly in mesh.polygons:
            poly.use_smooth = False
        objects.append(obj)
    bbox = [round((hi[i]-lo[i])*factor, 5) for i in range(3)]
    return objects, {"city_id": city_id, "bbox_blender_xyz": bbox,
                     "mesh_count": len(objects), "material_count": len(objects),
                     "vertices": sum(len(obj.data.vertices) for obj in objects),
                     "triangles": sum(len(p.vertices)-2 for obj in objects for p in obj.data.polygons),
                     "ground_z": 0.0}


def point_at(obj, target):
    obj.rotation_euler = (Vector(target)-obj.location).to_track_quat('-Z', 'Y').to_euler()


def render_setup(scene, mats):
    camera_data = bpy.data.cameras.new("ContactCamera")
    camera = bpy.data.objects.new("ContactCamera", camera_data)
    scene.collection.objects.link(camera)
    camera.location = (3.2, -4.6, 3.3)
    point_at(camera, (0, 0, .45))
    camera_data.type = 'ORTHO'
    camera_data.ortho_scale = 2.85
    scene.camera = camera
    scene.render.engine = 'CYCLES'
    scene.cycles.samples = 24
    scene.cycles.use_denoising = True
    scene.render.resolution_x = 640
    scene.render.resolution_y = 640
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = 'PNG'
    scene.render.film_transparent = False
    scene.view_settings.view_transform = 'Standard'
    scene.view_settings.look = 'None'
    scene.world.color = (.4, .4, .4)
    scene.world.use_nodes = True
    scene.world.node_tree.nodes['Background'].inputs['Color'].default_value = (.74, .79, .82, 1)
    scene.world.node_tree.nodes['Background'].inputs['Strength'].default_value = .7
    ld = bpy.data.lights.new("Softbox", 'AREA')
    lo = bpy.data.objects.new("Softbox", ld)
    scene.collection.objects.link(lo)
    lo.location = (-3, -4, 7)
    ld.energy = 450
    ld.shape = 'DISK'
    ld.size = 4
    point_at(lo, (0, 0, 0))
    mesh = bpy.data.meshes.new("ContactGround")
    mesh.from_pydata([(-200,-200,-.008),(200,-200,-.008),(200,200,-.008),(-200,200,-.008)], [], [(0,1,2,3)])
    mat = material("contact_background", "EAE4D7")
    mesh.materials.append(mat)
    ground = bpy.data.objects.new("ContactGround", mesh)
    scene.collection.objects.link(ground)
    return [camera, lo, ground]


def main():
    argv = sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, default=ROOT/'assets/game/lowpoly/cities')
    parser.add_argument('--source', type=Path, default=ROOT/'docs/design/lowpoly-v1/source/cities.blend')
    parser.add_argument('--render-dir', type=Path, default=ROOT/'docs/design/lowpoly-v1/city-renders')
    parser.add_argument('--skip-renders', action='store_true')
    parser.add_argument('--render-city', choices=sorted(BUILDERS), help='Render one city; source gallery and exports still contain all sixteen.')
    args = parser.parse_args(argv)
    args.out.mkdir(parents=True, exist_ok=True)
    args.source.parent.mkdir(parents=True, exist_ok=True)
    (args.source.parent/'.gdignore').write_text('')
    args.render_dir.mkdir(parents=True, exist_ok=True)
    (args.render_dir/'.gdignore').write_text('')
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    mats = {name: material(name, color) for name, color in PALETTE.items()}
    cities = json.loads((ROOT/'data/rulesets/lshu_configurable_v1/cities.json').read_text())['items']
    assert set(BUILDERS) == {c['id'] for c in cities}, 'City identity mismatch'
    scene = bpy.context.scene
    models, stats = {}, []
    for city in cities:
        cid = city['id']
        objects, info = build_city(cid, mats, scene.collection)
        bpy.ops.object.select_all(action='DESELECT')
        for obj in objects:
            obj.select_set(True)
        bpy.context.view_layer.objects.active = objects[0]
        out = args.out/f'{cid}.glb'
        bpy.ops.export_scene.gltf(filepath=str(out), export_format='GLB', use_selection=True,
                                  export_apply=True, export_yup=True, export_animations=False,
                                  export_materials='EXPORT', export_cameras=False,
                                  export_lights=False, export_extras=True)
        info.update(display_name=city['display_name'], starting_transport=city['starting_transport'],
                    interchange=city['is_transport_interchange'], glb_bytes=out.stat().st_size)
        stats.append(info)
        models[cid] = objects
        print('CITY_EXPORTED', json.dumps(info, ensure_ascii=False), flush=True)
    helpers = render_setup(scene, mats)
    if not args.skip_renders:
        for cid, objects in models.items():
            if args.render_city and cid != args.render_city:
                continue
            for other, other_objs in models.items():
                for obj in other_objs:
                    obj.hide_render = other != cid
            scene.render.filepath = str(args.render_dir/f'{cid}.png')
            bpy.ops.render.render(write_still=True)
    # Editable source opens as an organized 4x4 gallery; exports stay at origin.
    for i, (cid, objects) in enumerate(models.items()):
        for obj in objects:
            obj.hide_render = False
            obj.location.x = (i % 4 - 1.5) * 3.0
            obj.location.y = (i // 4 - 1.5) * 3.0
    for helper in helpers:
        helper.hide_viewport = True
        helper.hide_render = True
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(args.source))
    report = {'generator': 'tools/lowpoly/build_cities.py', 'blender_version': bpy.app.version_string,
              'style': 'original flat-shaded cultural miniatures', 'city_count': len(stats),
              'total_triangles': sum(x['triangles'] for x in stats), 'cities': stats}
    (args.out/'manifest.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
    print('BUILD_COMPLETE', json.dumps({'cities': len(stats), 'triangles': report['total_triangles']}))


if __name__ == '__main__':
    main()
