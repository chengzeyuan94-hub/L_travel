#!/usr/bin/env python3
"""Independent, read-only geometry audit for TASK-PLANET-DENSITY-017.

Reads the new, pre-work 017 baseline, exported GLB and shared runtime mesh data.
Never executes a generator, starts Godot, or changes historical 012 evidence.
Raw density/relief metrics do not constitute visual or performance acceptance.
Requires NumPy/Pillow from the bundled Python runtime. Exit 0 pass, 1 failed
contract, 2 missing/invalid inputs. --phase terrain omits new runtime props.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import itertools
import json
import math
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

sys.dont_write_bytecode = True
from visual_006_audit import GLB, logical, normalize, np, sha, percentiles
from variation_007_audit import Audit, function_snapshot, json_safe
from detail_012_audit import Routes, direction, pose, triangles, footprint_clearance, arc_distances, point_arc_distance

ROOT = Path(__file__).resolve().parents[2]
BASELINE = Path('/Users/chengzeyuan/SilkRoadEvidence/planet-density-017/baseline')
LAND = 'spherical_continents_and_biomes'
TERRAIN = 'assets/game/lowpoly/planet/terrain.glb'
STATS = 'assets/game/lowpoly/planet/planet-stats.json'
DATA = 'data/rulesets/lshu_configurable_v1'
TOLERANCE = 2e-5


def read(path):
    return json.loads(Path(path).read_text())


def array_sha(value):
    value = np.asarray(value)
    return hashlib.sha256(str(value.shape).encode() + value.tobytes()).hexdigest()


def unique_points(points):
    points = np.asarray(points)
    return points[np.unique(np.round(points, 7), axis=0, return_index=True)[1]] if len(points) else points


class RaySurface:
    """Exact radial ray/triangle intersections accelerated by conservative caps.

    The grid indexes triangle centers, not terrain heights. Every query tests
    all centers within the maximum triangle cap, including boundary neighbors.
    Candidate faces are then intersected against the actual exported vertices.
    """
    def __init__(self, primitives):
        self.triangles = triangles([p for p in primitives if p['name'] == LAND])
        self.unit_triangles = normalize(self.triangles)
        self.centers = normalize(self.unit_triangles.mean(axis=1))
        self.extents = np.linalg.norm(self.unit_triangles - self.centers[:, None], axis=2).max(axis=1)
        self.cell = max(float(self.extents.max()) * 1.05, .025)
        self.grid = defaultdict(list)
        for i, p in enumerate(self.centers):
            self.grid[tuple(np.floor(p / self.cell).astype(int))].append(i)
        self.a = self.triangles[:, 0]
        self.e1, self.e2 = self.triangles[:, 1] - self.a, self.triangles[:, 2] - self.a
        self.q = np.cross(-self.a, self.e1)
        self.numerator = np.einsum('ij,ij->i', self.e2, self.q)

    def sample(self, point):
        normal = normalize(point)
        key = np.floor(normal / self.cell).astype(int)
        candidates = [i for offset in itertools.product((-1, 0, 1), repeat=3)
                      for i in self.grid.get(tuple(key + offset), ())]
        ids = np.asarray(candidates, dtype=int)
        if not len(ids):
            return None
        p = np.cross(normal, self.e2[ids])
        det = np.einsum('ij,ij->i', self.e1[ids], p)
        with np.errstate(divide='ignore', invalid='ignore'):
            u = np.einsum('ij,ij->i', -self.a[ids], p) / det
            v = (self.q[ids] @ normal) / det
            radius = self.numerator[ids] / det
        valid = np.flatnonzero((abs(det) > 1e-10) & (u >= -1e-6) & (v >= -1e-6)
                               & (u + v <= 1.000001) & (radius > 0))
        if not len(valid):
            return None
        j = valid[np.argmax(radius[valid])]
        return {'radius': float(radius[j]), 'face': int(ids[j]), 'barycentric': [1-u[j]-v[j], u[j], v[j]]}


def frozen(root, baseline, audit):
    manifest = read(baseline / 'manifest.json')
    audit.check('new_017_baseline_identified', manifest.get('task') == 'TASK-PLANET-DENSITY-017'
                and bool(manifest.get('created_at_utc')) and 'planet-density-017' in str(baseline))
    files = manifest['files']
    copies = [p for p in files if (baseline / p).is_file()]
    bad_copies = [p for p in copies if sha(baseline / p) != files[p]['sha256']]
    audit.check('available_prework_copies_match_manifest', bool(copies) and not bad_copies,
                copies=len(copies), mismatches=bad_copies)
    required = [TERRAIN, STATS, f'{DATA}/board_nodes.json', f'{DATA}/board_edges.json',
                'scripts/ui/planet_geometry.gd', 'tools/lowpoly/build_planet.py']
    audit.check('required_prework_geometry_and_source_copies_exist', all(p in copies for p in required))
    fixed = [p for p in files if p.startswith('data/') or p.startswith('scripts/') and p not in (
        'scripts/ui/lowpoly_board_view.gd', 'scripts/ui/planet_ambient_layer.gd') or p in (
        'project.godot', 'tools/lowpoly/detail_012_audit.py', 'tools/lowpoly/variation_007_audit.py',
        'tools/lowpoly/visual_006_audit.py')
        or p.endswith('.glb') and p != TERRAIN]
    bad = [p for p in fixed if not (root / p).is_file() or sha(root / p) != files[p]['sha256']]
    audit.check('rules_projection_water_16_cities_vehicles_existing_ambient_geometry_exact', not bad,
                files=len(fixed), mismatches=bad)
    old_glbs = {p for p in files if p.startswith('assets/game/lowpoly/') and p.endswith('.glb')}
    new_glbs = {p.relative_to(root).as_posix() for p in (root / 'assets/game/lowpoly').rglob('*.glb')}
    audit.check('lowpoly_glb_inventory_unchanged', old_glbs == new_glbs,
                added=sorted(new_glbs-old_glbs), removed=sorted(old_glbs-new_glbs))
    before = function_snapshot(baseline / 'tools/lowpoly/build_planet.py', 'biome_at')
    after = function_snapshot(root / 'tools/lowpoly/build_planet.py', 'biome_at')
    audit.check('biome_classification_source_bytes_and_AST_frozen',
                all(before[k] == after[k] for k in ('bytes_sha256', 'ast_sha256')))
    old_stats, stats = read(baseline / STATS), read(root / STATS)
    for k in ('scenery_direction_sha256', 'dune_positions_sha256', 'main_rng_state_sha256', 'coast_reference_sha256'):
        audit.check(k + '_frozen', bool(old_stats.get(k)) and old_stats[k] == stats.get(k), sha256=stats.get(k))
    nodes = read(root / DATA / 'board_nodes.json')['items']
    edges = read(root / DATA / 'board_edges.json')['items']
    audit.check('formal_graph_16_cities_47_nodes_50_edges', len(nodes) == 47 and len(edges) == 50
                and sum(n.get('node_type') == 'CITY' for n in nodes) == 16)
    return {'manifest_sha256': sha(baseline / 'manifest.json'), 'created_at_utc': manifest['created_at_utc'],
            'git_head': manifest.get('git_head'), 'frozen_paths': fixed}, nodes, edges, old_stats, stats


def terrain_layout(old, new, audit):
    mutable = set()
    for node in old.doc['nodes']:
        if node.get('name') == LAND:
            for p in old.doc['meshes'][node['mesh']]['primitives']:
                mutable.update(p['attributes'][k] for k in ('POSITION', 'NORMAL', 'COLOR_0'))
    # JSON structure is exact except POSITION bounds, which must follow relief.
    old_doc, new_doc = copy.deepcopy(old.doc), copy.deepcopy(new.doc)
    position_accessors = {p['attributes']['POSITION'] for n in old.doc['nodes'] if n.get('name') == LAND
                          for p in old.doc['meshes'][n['mesh']]['primitives']}
    for doc in (old_doc, new_doc):
        for i in position_accessors:
            for key in ('min', 'max'):
                doc['accessors'][i].pop(key, None)
    audit.check('terrain_scene_surfaces_materials_topology_accessor_layout_exact', old_doc == new_doc,
                mutable_accessors=sorted(mutable), allowed_metadata='land POSITION min/max only')
    unchanged = [i for i in range(len(old.doc['accessors'])) if i not in mutable]
    bad = [i for i in unchanged if i >= len(new.doc['accessors']) or
           not np.array_equal(old.accessor(i), new.accessor(i))]
    audit.check('every_nonland_attribute_and_all_indices_exact', not bad, accessors=len(unchanged), mismatches=bad)
    # This also freezes padding and unused original data, not merely referenced arrays.
    allowed_bytes = np.zeros(len(old.binary), dtype=bool)
    widths = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4}
    sizes = {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4}
    for i in mutable:
        a = old.doc['accessors'][i]; view = old.doc['bufferViews'][a['bufferView']]
        width = widths[a['type']] * sizes[a['componentType']]
        start = view.get('byteOffset', 0) + a.get('byteOffset', 0)
        stride = view.get('byteStride', width)
        for j in range(a['count']):
            allowed_bytes[start+j*stride:start+j*stride+width] = True
    binary_equal = len(old.binary) == len(new.binary) and np.array_equal(
        np.frombuffer(old.binary, dtype=np.uint8)[~allowed_bytes], np.frombuffer(new.binary, dtype=np.uint8)[~allowed_bytes])
    audit.check('all_binary_bytes_outside_land_position_normal_color_frozen', binary_equal)
    ps_old, ps_new = old.primitives(), new.primitives()
    land_old, land_new = [p for p in ps_old if p['name'] == LAND], [p for p in ps_new if p['name'] == LAND]
    positions_old, positions_new = (np.concatenate([p['positions'] for p in ps]) for ps in (land_old, land_new))
    if positions_old.shape != positions_new.shape:
        raise ValueError('Changed land cardinality; dependent geometry tests cannot match baseline vertices')
    audit.check('land_finite_vertices_and_valid_colors', np.isfinite(positions_new).all() and
                all(p['color'] is not None and np.isfinite(p['color']).all() and
                    (p['color'] >= 0).all() and (p['color'] <= 1).all() for p in land_new))
    direction_error = np.linalg.norm(normalize(positions_new)-normalize(positions_old), axis=1)
    audit.check('land_relief_is_radial_without_changing_geographic_directions', direction_error.max() < 2e-6,
                maximum_unit_direction_error=float(direction_error.max()))
    delta = np.linalg.norm(positions_new, axis=1)-np.linalg.norm(positions_old, axis=1)
    audit.check('land_radial_displacement_within_0_335_world', abs(delta).max() <= .335 + TOLERANCE,
                maximum_absolute_delta=float(abs(delta).max()))
    keys, ids = np.unique(np.round(normalize(positions_old), 6), axis=0, return_inverse=True)
    spread = 0.
    for i in range(len(keys)):
        spread = max(spread, float(np.ptp(delta[ids == i])))
    audit.check('shared_geographic_vertices_have_identical_relief_no_seam_cracks', spread < TOLERANCE,
                maximum_shared_delta_spread=spread)
    ts_old, ts_new = triangles(land_old), triangles(land_new)
    normal_old, normal_new = (np.cross(ts[:, 1]-ts[:, 0], ts[:, 2]-ts[:, 0]) for ts in (ts_old, ts_new))
    area_new = np.linalg.norm(normal_new, axis=1)/2
    audit.check('land_faces_non_degenerate_without_winding_flips', area_new.min() > 1e-10 and
                (np.sum(normal_old*normal_new, axis=1) > 0).all(), minimum_area=float(area_new.min()))
    normals_finite = all(np.isfinite(new.accessor(i)).all() for i in mutable)
    audit.check('all_mutable_vertex_attributes_finite', normals_finite)
    bounds_ok = all(all(np.max(abs(np.asarray(new.doc['accessors'][i][key])-
                    getattr(new.accessor(i), reducer)(axis=0))) < TOLERANCE
                    for key,reducer in [('min','min'),('max','max')]) for i in position_accessors)
    audit.check('updated_POSITION_bounds_match_actual_accessor_values',bounds_ok)
    changed = np.max(np.linalg.norm(ts_new-ts_old, axis=2), axis=1) > TOLERANCE
    boundary = coastline_faces(ts_old)
    audit.check('actual_coast_vertices_and_all_incident_land_faces_unchanged',
                not (boundary & changed).any(), protected_faces=int(boundary.sum()), changed_intersections=int((boundary & changed).sum()))
    return ps_old, ps_new, {'triangles': len(ts_new), 'surfaces': len(land_new), 'vertices': len(positions_new),
        'changed_faces': int(changed.sum()), 'changed_vertices': int((abs(delta) > TOLERANCE).sum()),
        'unchanged_faces_percent': float(np.mean(~changed)*100), 'radial_delta_world': percentiles(delta),
        'baseline_radius_world': percentiles(np.linalg.norm(positions_old, axis=1)),
        'current_radius_world': percentiles(np.linalg.norm(positions_new, axis=1)),
        'baseline_color_channels': [percentiles(np.concatenate([p['color'] for p in land_old])[:, k]) for k in range(3)],
        'current_color_channels': [percentiles(np.concatenate([p['color'] for p in land_new])[:, k]) for k in range(3)]}, changed


def coastline_faces(ts):
    _, ids = np.unique(np.round(normalize(ts.reshape((-1, 3))), 6), axis=0, return_inverse=True)
    faces = ids.reshape((-1, 3))
    counts = Counter(tuple(sorted((a, b))) for f in faces for a, b in zip(f, np.roll(f, -1)))
    boundary_vertices = set(v for edge, n in counts.items() if n == 1 for v in edge)
    return np.asarray([any(v in boundary_vertices for v in f) for f in faces])


def inside_spherical(points, triangles_unit):
    centers = normalize(triangles_unit.mean(axis=1))
    normals = np.cross(triangles_unit, np.roll(triangles_unit, -1, axis=1))
    signs = np.sign(np.sum(normals * centers[:, None], axis=2))
    signed = np.einsum('tvi,pi->tpv', normals * signs[:, :, None], np.asarray(points))
    nondegenerate = abs(np.linalg.det(triangles_unit)) > 1e-12
    return (signed >= -1e-12).all(axis=2) & nondegenerate[:, None]


def triangle_distances(one, others):
    """Exact continuous minor-sphere triangle separation; includes interiors."""
    one, others = normalize(one), normalize(others)
    distances = np.full(len(others), math.pi)
    overlap = inside_spherical(one, others).any(axis=1)
    overlap |= inside_spherical(others.reshape((-1, 3)), one[None])[0].reshape((-1, 3)).any(axis=1)
    for a, b in zip(one, np.roll(one, -1, axis=0)):
        for j in range(3):
            distances = np.minimum(distances, arc_distances(a, b, others[:, j], others[:, (j+1)%3]))
    return np.where(overlap, 0., distances) * 11


def mesh_clearance(test_triangles, obstacle_triangles, threshold):
    """Conservative caps select candidates; exact faces determine violations."""
    obstacles = normalize(obstacle_triangles)
    centers = normalize(obstacles.mean(axis=1))
    extents = np.arccos(np.clip(np.sum(obstacles*centers[:, None], axis=2), -1, 1)).max(axis=1)
    minimum, violations, pairs = math.inf, [], 0
    for i, triangle in enumerate(normalize(test_triangles)):
        center = normalize(triangle.mean(axis=0))
        extent = np.arccos(np.clip(triangle @ center, -1, 1)).max()
        lower = (np.arccos(np.clip(centers @ center, -1, 1))-extent-extents)*11
        candidates = np.flatnonzero(lower <= max(threshold, minimum if math.isfinite(minimum) else threshold))
        if not len(candidates):
            continue
        values = triangle_distances(triangle, obstacles[candidates]); pairs += len(candidates)
        actual = float(values.min()); minimum = min(minimum, actual)
        if actual < threshold - 2e-5:
            violations.append({'test_face': i, 'obstacle_face': int(candidates[np.argmin(values)]), 'clearance_world': actual})
    return {'threshold_world': threshold, 'minimum_tested_world': minimum if math.isfinite(minimum) else None,
            'violations': violations, 'exact_candidate_pairs': pairs,
            'note': 'Null minimum means all conservative angular caps lie beyond the threshold; not an unknown clearance.'}


def compare_contacts(points, before, after):
    rows, changed, missing = [], [], []
    for index, point in enumerate(unique_points(points)):
        old, new = before.sample(point), after.sample(point)
        if old is None:
            continue
        if new is None:
            missing.append(index); continue
        delta = new['radius']-old['radius']
        rows.append({'point': point, 'baseline_gap_world': float(np.linalg.norm(point)-old['radius']),
                     'current_gap_world': float(np.linalg.norm(point)-new['radius']), 'surface_delta_world': delta})
        if abs(delta) > TOLERANCE:
            changed.append(index)
    return {'samples_on_baseline_land': len(rows), 'surface_delta_world': percentiles([r['surface_delta_world'] for r in rows]),
            'changed_samples': changed, 'missing_current_support': missing, 'rows': rows}


def protection(root, old_ps, new_ps, changed, nodes, routes, audit):
    before, after = RaySurface(old_ps), RaySurface(new_ps)
    changed_faces = before.triangles[changed]
    route_clearance = footprint_clearance(changed_faces, routes) if len(changed_faces) else {'minimum_world': None}
    audit.check('changed_land_faces_clear_entire_continuous_route_by_0_34_world',
                not len(changed_faces) or route_clearance['minimum_world'] >= .34-TOLERANCE, **route_clearance)
    anchors=[xy for n in nodes for xy in (n.get('route_anchors') or {'default':n['map_position']}).values()]
    marker_distances=[point_mesh_distance(direction(xy),changed_faces) for xy in anchors] if len(changed_faces) else []
    audit.check('changed_land_faces_clear_all_actual_route_marker_anchors_by_0_34_world',
                not marker_distances or min(marker_distances)>=.34-TOLERANCE,
                anchors=len(anchors),minimum_world=min(marker_distances) if marker_distances else None)
    city_obstacles, city_contacts = [], {}
    for n in nodes:
        if n.get('node_type') != 'CITY':
            continue
        ps = GLB(root / f"assets/game/lowpoly/cities/{n['city_id']}.glb").primitives()
        points = np.concatenate([p['positions'] for p in ps]); low, high = points.min(axis=0), points.max(axis=0)
        xy = np.asarray(n['map_position']) + [0, -85]
        corners = np.asarray([[low[0], 0, low[2]], [high[0], 0, low[2]], [high[0], 0, high[2]], [low[0], 0, high[2]]])
        city_obstacles.extend(pose(corners, xy)[[[0, 1, 2], [0, 2, 3]]])
        ts = triangles(ps); floor = ts[np.all(abs(ts[:, :, 1]-low[1]) < TOLERANCE, axis=1)]
        samples = np.concatenate((points[abs(points[:, 1]-low[1]) < TOLERANCE], floor.mean(axis=1)))
        city_contacts[n['id']] = compare_contacts(pose(samples, xy), before, after)
    city_clearance = mesh_clearance(changed_faces, np.asarray(city_obstacles), .12)
    audit.check('changed_land_faces_clear_actual_16_city_AABB_footprints_plus_0_12_world', not city_clearance['violations'], **city_clearance)
    audit.check('all_actual_city_foundation_contacts_preserve_baseline_support', all(
        c['samples_on_baseline_land'] and not c['changed_samples'] and not c['missing_current_support'] for c in city_contacts.values()))
    obstacles = [p for p in old_ps if p['name'] not in (LAND, 'radial_coastal_cliffs')]
    obstacle_ts = triangles(obstacles)
    prop_clearance = mesh_clearance(changed_faces, obstacle_ts, .025)
    audit.check('changed_land_faces_do_not_touch_old_props_mountains_dunes_harbor_oases', not prop_clearance['violations'], **prop_clearance)
    # Actual vertices, edge midpoints and barycenters cover original geometry
    # contacts. Report baseline gaps separately, preserving pre-existing shape.
    samples = np.concatenate([obstacle_ts.reshape((-1, 3)), obstacle_ts.mean(axis=1),
                              ((obstacle_ts + np.roll(obstacle_ts, -1, axis=1))/2).reshape((-1, 3))])
    contacts = compare_contacts(samples, before, after)
    audit.check('old_geometry_contact_surface_heights_preserved_by_actual_rays',
                contacts['samples_on_baseline_land'] > 0 and not contacts['changed_samples'] and not contacts['missing_current_support'],
                samples=contacts['samples_on_baseline_land'], delta_world=contacts['surface_delta_world'],
                changed_samples=contacts['changed_samples'][:30])
    ambient = read(root / 'scripts/ui/ambient/placements.json')
    ambient_contacts = {}
    for i, xy in enumerate(ambient['sheep']):
        feet = np.asarray([[x,0,z] for x in (-.08,.08) for z in (-.125,.125)])
        yaw = ambient['sheep_yaws'][i]
        rotation = np.asarray([[math.cos(yaw),0,math.sin(yaw)],[0,1,0],[-math.sin(yaw),0,math.cos(yaw)]])
        ambient_contacts[f'sheep_{i}'] = compare_contacts(pose(feet @ rotation.T, xy, ambient['sheep_ground_heights'][i]), before, after)
    for i, xy in enumerate(ambient['flags']):
        feet = np.asarray([[.035*math.cos(a),0,.035*math.sin(a)] for a in np.linspace(0,math.tau,6,endpoint=False)])
        ambient_contacts[f'flag_{i}'] = compare_contacts(pose(feet, xy, ambient['flag_ground_heights'][i]), before, after)
    feet = np.asarray([[.3*math.cos(a),0,.3*math.sin(a)] for a in np.linspace(0,math.tau,7,endpoint=False)])
    ambient_contacts['windmill'] = compare_contacts(pose(feet, ambient['windmill'], ambient['windmill_ground_height']), before, after)
    audit.check('original_sheep_flag_windmill_actual_foot_offsets_keep_surface_height', all(
        c['samples_on_baseline_land'] and not c['changed_samples'] and not c['missing_current_support'] for c in ambient_contacts.values()))
    return {'routes': route_clearance, 'route_marker_distances_world':marker_distances,'cities': city_clearance,
            'city_foundation_contacts': city_contacts, 'existing_geometry': prop_clearance,
            'existing_ambient_foot_contacts': ambient_contacts,
            'existing_geometry_contact_summary': {k:v for k,v in contacts.items() if k != 'rows'}}, before, after


def logical_triangle_distances(point, world_triangles):
    """Planar logical footprints with each triangle on one longitude branch."""
    ts = logical(world_triangles.reshape((-1,3))).reshape((-1,3,2))
    # Unwrap each edge with respect to its first vertex, then move the complete
    # triangle to the nearest periodic copy. Never wrap vertices independently.
    ts[:,:,0] = ts[:,0:1,0] + (ts[:,:,0]-ts[:,0:1,0]+3072)%6144-3072
    ts[:,:,0] += (np.rint((point[0]-ts[:,:,0].mean(axis=1))/6144)*6144)[:,None]
    edges = np.roll(ts,-1,axis=1)-ts
    rel = np.asarray(point)[None,None,:]-ts
    sq = np.sum(edges*edges,axis=2)
    t = np.clip(np.sum(rel*edges,axis=2)/np.maximum(sq,1e-20),0,1)
    dist = np.linalg.norm(rel-t[:,:,None]*edges,axis=2).min(axis=1)
    cross = edges[:,:,0]*rel[:,:,1]-edges[:,:,1]*rel[:,:,0]
    area = edges[:,0,0]*edges[:,1,1]-edges[:,0,1]*edges[:,1,0]
    inside = ((cross>=-1e-9).all(axis=1)|(cross<=1e-9).all(axis=1)) & (abs(area)>1e-9)
    return np.where(inside,0.,dist)


def point_mesh_distance(point, world_triangles):
    q, ts = normalize(point), normalize(world_triangles)
    if inside_spherical(q[None],ts).any():
        return 0.
    return float(min(point_arc_distance(q,ts[:,i],ts[:,(i+1)%3]).min() for i in range(3))*11)


def route_stations(edges, interval=50.):
    rows = []
    for edge in edges:
        if edge['route_type'] != 'LAND':
            continue
        points = np.asarray(edge['movement_polyline'],float)
        lengths = np.linalg.norm(np.diff(points,axis=0),axis=1)
        cumulative = np.r_[0,np.cumsum(lengths)]
        for s in np.arange(0,cumulative[-1]+1e-7,interval):
            j = min(np.searchsorted(cumulative,s,side='right')-1,len(lengths)-1)
            point = points[j] + (points[j+1]-points[j])*(s-cumulative[j])/max(lengths[j],1e-20)
            rows.append({'edge_id':edge['id'],'distance_along_edge_logical':float(s),'logical':point})
    return rows


def density_metrics(old_ps, new_triangles, nodes, edges, instances):
    old = triangles([p for p in old_ps if p['name'] not in (LAND,'radial_coastal_cliffs')])
    all_new = np.concatenate((old,new_triangles)) if len(new_triangles) else old
    stations = route_stations(edges)
    cities = [{'city_id':n['id'],'logical':np.asarray(n['map_position'])+[0,-85]}
              for n in nodes if n.get('node_type')=='CITY']
    def summarize(rows):
        for row in rows:
            xy = np.asarray(row['logical']); q = direction(xy)
            for name, ts in [('baseline',old),('current',all_new)]:
                row[name+'_nearest_geometry_logical'] = float(logical_triangle_distances(xy,ts).min())
                row[name+'_nearest_geometry_geodesic_world'] = point_mesh_distance(q,ts)
            delta = np.asarray([np.asarray(i['logical'])-xy for i in instances])
            if len(delta):
                delta[:,0]=(delta[:,0]+3072)%6144-3072
            row['new_instance_centers_within_150_logical'] = int((np.linalg.norm(delta,axis=1)<=150).sum()) if len(delta) else 0
        summary = {}
        for name in ('baseline','current'):
            log = [r[name+'_nearest_geometry_logical'] for r in rows]
            geo = [r[name+'_nearest_geometry_geodesic_world'] for r in rows]
            summary[name] = {'nearest_footprint_logical':percentiles(log),'nearest_footprint_geodesic_world':percentiles(geo),
                'empty_neighborhood_150_logical_percent':float(np.mean(np.asarray(log)>150)*100),
                'empty_neighborhood_1_5_world_percent':float(np.mean(np.asarray(geo)>1.5)*100)}
        return {'samples':len(rows),'summary':summary,'rows':rows}
    return {'method':'Nearest actual decorative triangle footprint, not semantic object counts or objects per terrain triangle. Existing geometry includes trees, rocks, dunes, mountains, oases and harbor; excludes continent and coast cliffs. City centers are visual map_position+(0,-85). LAND stations every 50 logical units along each full polyline, without resetting at segment boundaries. Geodesic distance is continuous triangle separation on radius 11 sphere.',
            'route_stations':summarize(stations),'city_neighborhoods':summarize(cities),
            'screen_density':'Not measured. Native paired screenshots are reviewed separately; object/triangle ratios are not used as a pixel visibility proxy.'}


def runtime_props(path, root, nodes, routes, surface, audit):
    config = read(path)
    audit.check('shared_runtime_geometry_json_bound_to_actual_terrain', config.get('terrain_sha256') == sha(root/TERRAIN))
    groups = config['groups']; instances_all = [i for g in groups for i in g['instances']]
    ids = [i['id'] for i in instances_all]
    audit.check('runtime_instances_unique_and_declared_count_matches_actual', len(ids)>0 and len(ids)==len(set(ids))
                and config['instance_count']==len(ids), actual_instances=len(ids), initial_target=114,
                note='114 is an initial quota, not an obligation to fill unsafe sites. Actual distribution is reported.')
    audit.check('four_shared_prototype_batches', len(groups)==4 and len({g['id'] for g in groups})==4)
    city_ts, city_centers = [], []
    for n in nodes:
        if n.get('node_type')!='CITY':continue
        ps=GLB(root/f"assets/game/lowpoly/cities/{n['city_id']}.glb").primitives()
        points=np.concatenate([p['positions'] for p in ps]); low,high=points.min(axis=0),points.max(axis=0)
        xy=np.asarray(n['map_position'])+[0,-85]; city_centers.append(xy)
        corners=np.asarray([[low[0],0,low[2]],[high[0],0,low[2]],[high[0],0,high[2]],[low[0],0,high[2]]])
        city_ts.extend(pose(corners,xy)[[[0,1,2],[0,2,3]]])
    city_ts=np.asarray(city_ts)
    rows, world_faces, inventories, feet_gaps = [], [], [], []
    instance_triangles=[]
    old_triangles=triangles([p for p in GLB(root/TERRAIN).primitives() if p['name'] not in (LAND,'radial_coastal_cliffs')])
    face_materials = [p['material'].get('name','') for p in GLB(root/TERRAIN).primitives()
                      if p['name']==LAND for _ in p['faces']]
    face_colors = np.concatenate([p['color'][p['faces']] for p in GLB(root/TERRAIN).primitives() if p['name']==LAND])
    biome_counts = Counter()
    structural_errors, unsupported, incorrect_ground_evidence = [], [], []
    for group in groups:
        vertices=np.asarray(group['vertices'],float); faces=np.asarray(group['indices'],int).reshape((-1,3))
        normals=np.asarray(group['normals'],float); colors=np.asarray(group['colors'],float)
        feet=np.asarray(group['foot_points'],float)
        area=np.linalg.norm(np.cross(vertices[faces[:,1]]-vertices[faces[:,0]],vertices[faces[:,2]]-vertices[faces[:,0]]),axis=1)/2
        valid=np.isfinite(vertices).all() and np.isfinite(normals).all() and np.isfinite(colors).all()
        valid=valid and len(normals)==len(vertices)==len(colors) and (colors>=0).all() and (colors<=1).all() and area.min()>1e-10
        bottom=unique_points(vertices[abs(vertices[:,1])<1e-7])
        bottom_keys={tuple(p) for p in np.round(bottom,7)};foot_keys={tuple(p) for p in np.round(feet,7)}
        valid=valid and len(feet)>0 and bottom_keys==foot_keys
        if not valid:structural_errors.append(group['id'])
        inventories.append({'group':group['id'],'instances':len(group['instances']),'triangles_per_instance':len(faces),
                            'prototype_bounds_min':vertices.min(axis=0),'prototype_bounds_max':vertices.max(axis=0),
                            'minimum_triangle_area':float(area.min()),'actual_bottom_contact_vertices':len(bottom)})
        for instance in group['instances']:
            basis=np.asarray(instance['basis'],float).reshape((3,3),order='F'); position=np.asarray(instance['position'],float)
            scales=np.linalg.norm(basis,axis=0)
            world=vertices@basis.T+position;foot_world=feet@basis.T+position;ts=world[faces]
            if (not np.isfinite(world).all() or np.linalg.det(basis)<=0 or np.ptp(scales)>1e-6 or
                    np.max(abs((basis/scales).T@(basis/scales)-np.eye(3)))>1e-5):
                structural_errors.append(instance['id'])
            authored_q=direction(instance['logical']);authored_hit=surface.sample(authored_q)
            if authored_hit is None:
                structural_errors.append(instance['id']+'_authored_land_miss')
            else:
                plane=surface.triangles[authored_hit['face']]
                face_up=normalize(np.cross(plane[1]-plane[0],plane[2]-plane[0]))
                face_up*=np.sign(face_up@authored_q)
                up=basis[:,1]/scales[1]
                inset=authored_q*authored_hit['radius']-position
                if np.linalg.norm(face_up-up)>2e-5 or np.linalg.norm(inset-up*(inset@up))>2e-5 or not -.001<=inset@up<=.065:
                    structural_errors.append(instance['id']+'_ground_normal_or_inset')
            center=surface.sample(position)
            samples=[]
            for j,point in enumerate(foot_world):
                hit=surface.sample(point)
                if hit is None:unsupported.append([instance['id'],j]);continue
                gap=float(np.linalg.norm(point)-hit['radius']);feet_gaps.append(gap)
                samples.append({'local':feet[j],'world':point,'surface':normalize(point)*hit['radius'],'gap_world':gap})
            evidence=instance.get('ground_samples',[])
            if len(evidence)!=len(samples):incorrect_ground_evidence.append(instance['id'])
            else:
                for sample in samples:
                    match=[e for e in evidence if np.linalg.norm(np.asarray(e['local'])-sample['local'])<1e-7]
                    if len(match)!=1 or any(np.linalg.norm(np.asarray(match[0][k])-sample[k])>2e-5 for k in ('world','surface')):
                        incorrect_ground_evidence.append(instance['id']);break
            if center is None:unsupported.append([instance['id'],'center'])
            else:biome_counts[face_materials[center['face']]]+=1
            tint=np.asarray(instance['color'],float)
            effective_rgb=colors[:,:3]*tint[:3]
            terrain_rgb=np.asarray(center['barycentric'])@face_colors[center['face'],:,:3] if center else None
            route=footprint_clearance(ts,routes)
            city=mesh_clearance(ts,city_ts,.12)
            old_clearance=mesh_clearance(ts,old_triangles,.035)
            rows.append({'id':instance['id'],'group':group['id'],'logical':instance['logical'],
                'quota':instance.get('quota'),'scale':float(scales[0]),'basis_up':basis[:,1]/scales[1],
                'local_scaled_bounds_size':np.ptp(vertices,axis=0)*scales[0],
                'raw_vertex_albedo_rgb_mean':effective_rgb.mean(axis=0),'raw_terrain_color_at_center':terrain_rgb,
                'route_center_distance_logical':routes.distances([instance['logical']])[0],
                'city_visual_center_distance_logical':float(np.linalg.norm(np.asarray(city_centers)-instance['logical'],axis=1).min()),
                'continuous_route_footprint_clearance_world':route['minimum_world'],'city_footprint_clearance':city,
                'old_geometry_footprint_clearance':old_clearance,
                'actual_foot_contacts':samples,'land_face':center['face'] if center else None})
            world_faces.extend(ts)
            instance_triangles.append(ts)
    audit.check('runtime_prototypes_and_positive_uniform_instance_transforms_valid',not structural_errors,errors=structural_errors)
    audit.check('all_actual_runtime_feet_and_centers_have_land_support',not unsupported,missing=unsupported)
    audit.check('runtime_ground_samples_match_independent_mesh_and_ray_reconstruction',not incorrect_ground_evidence,
                mismatches=incorrect_ground_evidence)
    audit.check('runtime_actual_feet_embed_no_deeper_than_0_055_and_float_no_more_than_0_0015_world',
                bool(feet_gaps) and min(feet_gaps)>=-.055-TOLERANCE and max(feet_gaps)<=.0015+TOLERANCE,
                gap_world=percentiles(feet_gaps))
    audit.check('every_runtime_prop_continuous_route_footprint_clearance_at_least_0_34_world',
                all(r['continuous_route_footprint_clearance_world']>=.34-TOLERANCE for r in rows),
                minimum_world=min(r['continuous_route_footprint_clearance_world'] for r in rows))
    audit.check('every_runtime_prop_city_AABB_footprint_clearance_at_least_0_12_world',
                all(not r['city_footprint_clearance']['violations'] for r in rows))
    audit.check('every_runtime_prop_keeps_0_035_world_from_actual_old_geometry_footprints',
                all(not r['old_geometry_footprint_clearance']['violations'] for r in rows))
    world_faces=np.asarray(world_faces)
    anchors=[xy for n in nodes for xy in (n.get('route_anchors') or {'default':n['map_position']}).values()]
    anchor_clearance=[point_mesh_distance(direction(xy),world_faces) for xy in anchors]
    audit.check('new_prop_footprints_clear_all_route_marker_anchors_by_0_34_world',
                min(anchor_clearance)>=.34-TOLERANCE,anchors=len(anchors),minimum_world=min(anchor_clearance))
    pairs=[]
    # Only intersecting angular caps require an exact triangle/triangle test.
    centers=[normalize(normalize(ts).reshape((-1,3)).mean(axis=0)) for ts in instance_triangles]
    extents=[np.arccos(np.clip(normalize(ts).reshape((-1,3))@center,-1,1)).max()
             for ts,center in zip(instance_triangles,centers)]
    for i in range(len(rows)):
        for j in range(i):
            if (math.acos(np.clip(centers[i]@centers[j],-1,1))-extents[i]-extents[j])*11>.09:
                continue
            result=mesh_clearance(instance_triangles[i],instance_triangles[j],.09)
            pairs.append({'a':rows[i]['id'],'b':rows[j]['id'],**result})
    audit.check('new_instances_do_not_overlap_and_keep_0_09_world_footprint_spacing',not any(p['violations'] for p in pairs),
                exact_candidate_instance_pairs=len(pairs))
    quotas=Counter(str((i.get('quota') or {}).get('kind','missing')) for i in instances_all)
    quota_ids=Counter(str((i.get('quota') or {}).get('id','missing')) for i in instances_all)
    return {'json_sha256':sha(path),'instances':len(ids),'prototype_groups':inventories,'quota_counts':dict(quotas),
            'total_instanced_triangles':sum(g['triangles_per_instance']*g['instances'] for g in inventories),
            'albedo_note':'Raw vertex/instance RGB product only. Lighting, contact shadows, tone mapping and final pixel contrast require native screenshots.',
            'quota_destination_counts':dict(quota_ids),'actual_foot_gap_world':percentiles(feet_gaps),
            'actual_land_material_counts':dict(biome_counts),
            'actual_land_material_percent':{k:100*v/len(ids) for k,v in biome_counts.items()},
            'route_marker_clearances_world':anchor_clearance,'close_instance_pair_checks':pairs,
            'instances_detail':rows},world_faces,instances_all


def self_test():
    """Analytical geometric fixtures, independent of production assets."""
    audit=Audit()
    def q(x,y):return direction([2048+x,681.5+y])
    one=np.asarray([q(-100,-100),q(100,-100),q(0,100)])
    inner=np.asarray([q(-10,-10),q(10,-10),q(0,10)])
    audit.check('contained_triangle_has_zero_clearance',triangle_distances(one,inner[None])[0]<1e-9)
    audit.check('containment_symmetric',triangle_distances(inner,one[None])[0]<1e-9)
    crossing=np.asarray([q(-120,0),q(120,0),q(0,-150)])
    audit.check('crossing_triangle_edges_zero_clearance',triangle_distances(one,crossing[None])[0]<1e-9)
    far=np.asarray([q(300,300),q(310,300),q(300,310)])
    audit.check('disjoint_triangle_has_positive_clearance',triangle_distances(one,far[None])[0]>.1)
    audit.check('winding_does_not_change_footprint',abs(triangle_distances(one,far[None])[0]-triangle_distances(one[::-1],far[::-1][None])[0])<1e-10)
    line=np.asarray([q(-10,0),q(0,0),q(10,0)])
    audit.check('degenerate_projection_does_not_contain_half_sphere',not inside_spherical(q(500,500)[None],line[None]).any())
    ps=[{'name':LAND,'positions':one*11.08,'faces':np.asarray([[0,1,2]])}]
    ray=RaySurface(ps);hit=ray.sample(q(0,0));n=np.cross(one[1]-one[0],one[2]-one[0])
    expected=float((one[0]*11.08)@n/(q(0,0)@n))
    audit.check('radial_hit_matches_analytical_plane',hit is not None and abs(hit['radius']-expected)<1e-10)
    audit.check('ray_off_triangle_is_land_miss',ray.sample(q(500,500)) is None)
    seam=np.asarray([direction([-1020,500]),direction([5110,500]),direction([-1020,520])])
    audit.check('logical_seam_not_stretched_across_map',logical_triangle_distances([2048,510],seam[None])[0]>3000)
    audit.check('single_triangle_all_vertices_are_coast',coastline_faces((one*11.08)[None]).all())
    return {'task':'TASK-PLANET-DENSITY-017','kind':'analytical auditor fixtures','checks':audit.checks,
            'ok':all(c['passed'] for c in audit.checks),'passed':sum(c['passed'] for c in audit.checks),'total':len(audit.checks)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--baseline', type=Path, default=BASELINE)
    parser.add_argument('--phase', choices=('terrain', 'complete'), default='complete')
    parser.add_argument('--props', type=Path)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--output', type=Path, default=BASELINE.parent / 'geometry-audit.json')
    args = parser.parse_args(); audit = Audit()
    if args.self_test:
        report=self_test();args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps(json_safe(report),indent=2)+'\n')
        print(json.dumps(report));return 0 if report['ok'] else 1
    args.props=args.props or args.root/'scripts/ui/ambient/corridor_017_placements.json'
    source_paths = [TERRAIN, STATS, 'scripts/ui/planet_geometry.gd',
                    'tools/lowpoly/density_017_audit.py', 'tools/lowpoly/detail_012_audit.py',
                    'tools/lowpoly/variation_007_audit.py', 'tools/lowpoly/visual_006_audit.py']
    manifest=read(args.baseline/'manifest.json')
    source_paths+= [p for p in manifest['files'] if p.startswith(('scripts/','data/')) or p.endswith('.glb') or p=='project.godot']
    source_paths+= [p for p in ('scripts/ui/planet_corridor_props.gd','scripts/ui/ambient/corridor_017_placements.json',
                               'scripts/ui/planet_route_geometry.gd') if (args.root/p).exists()]
    source_paths=sorted(set(source_paths))
    start_hashes = {p: sha(args.root / p) for p in source_paths}
    frozen_result, nodes, edges, old_stats, stats = frozen(args.root, args.baseline, audit)
    old, new = GLB(args.baseline / TERRAIN), GLB(args.root / TERRAIN)
    old_ps, new_ps, land, changed = terrain_layout(old, new, audit)
    protected, before, after = protection(args.root, old_ps, new_ps, changed, nodes, Routes(edges), audit)
    props = None
    new_triangles=np.empty((0,3,3));instances=[]
    if args.phase == 'complete':
        audit.check('macro_relief_changes_actual_exported_land_faces',land['changed_faces']>0)
        props,new_triangles,instances=runtime_props(args.props,args.root,nodes,Routes(edges),after,audit)
    density=density_metrics(old_ps,new_triangles,nodes,edges,instances)
    end_hashes = {p: sha(args.root / p) for p in source_paths}
    audit.check('audit_inputs_unchanged_between_actual_start_and_end', start_hashes == end_hashes)
    report = {'task': 'TASK-PLANET-DENSITY-017', 'phase': args.phase, 'created_at_utc': datetime.now(timezone.utc).isoformat(),
              'ok': all(c['passed'] for c in audit.checks), 'passed': sum(c['passed'] for c in audit.checks),
              'total': len(audit.checks), 'baseline': frozen_result, 'source_sha256': start_hashes,
              'terrain': land, 'protection': protected, 'props': props, 'density':density,'checks': audit.checks,
              'scope': 'Actual exported geometry and shared runtime data. No GUI, performance or visual acceptance is claimed.',
              'measurement_notes': ['Distances use game world units, not physical units.',
                  'Density is measured in logical/geodesic neighborhoods; objects per triangle is not a visibility metric.',
                  'Color and relief distributions are raw metrics. No high-pass aesthetic threshold is treated as a gate.']}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(json_safe(report), indent=2, ensure_ascii=False)+'\n')
    print(json.dumps({'ok': report['ok'], 'passed': report['passed'], 'total': report['total'], 'output': str(args.output),
                      'failed': [c['name'] for c in audit.checks if not c['passed']]}, ensure_ascii=False))
    return 0 if report['ok'] else 1


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, KeyError, FileNotFoundError) as exc:
        print(f'Invalid audit input: {exc}', file=sys.stderr)
        raise SystemExit(2)
