#!/usr/bin/env python3
"""Deform every vertex/triangle of actual Godot seated-idle pose samples.

No fixed bone count, index fallback, or missing-bone tolerance is used. Input is
produced by audit_seated_idle.gd through the shipping actor.set_time method.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    data = json.loads(args.input.read_text())
    checks: dict[str, bool] = {}
    errors: list[str] = []

    def check(name: str, value: bool) -> None:
        checks[name] = bool(value)
        if not value:
            errors.append(name)

    check("three_complete_cycles_sampled", data["full_cycles"] >= 3)
    check("same_skeleton_for_body_and_outline", data["same_skeleton"] and len(set(data["mesh_skeleton_paths"])) == 1)
    records = data["meshes"]
    mapping = [{bind["name"]: bind for bind in mesh["bind_mapping"]} for mesh in records]
    same_names = mapping[0].keys() == mapping[1].keys()
    check("body_outline_same_named_binds", same_names)
    check("body_outline_same_inverse_binds", same_names and all(
        np.allclose(mapping[0][name]["inverse_bind"], mapping[1][name]["inverse_bind"], rtol=0, atol=1e-6)
        and mapping[0][name]["bone"] == mapping[1][name]["bone"] for name in mapping[0]
    ))
    counts = [len(mesh["bind_mapping"]) for mesh in records]
    offsets = np.cumsum([0] + counts)
    poses_file = Path(data["matrix_file"])
    matrices = np.fromfile(poses_file, dtype="<f4")
    expected_values = len(data["samples"]) * int(offsets[-1]) * 12
    check("complete_pose_matrix_file", matrices.size == expected_values)
    if matrices.size != expected_values:
        raise ValueError(f"Expected {expected_values} matrix values, found {matrices.size}")
    matrices = matrices.reshape(len(data["samples"]), int(offsets[-1]), 3, 4)
    check("finite_pose_matrices", np.isfinite(matrices).all())
    mesh_data = []
    for mesh in records:
        vertices, weights, bones, triangles = [], [], [], []
        base = 0
        prefix = mesh["name"]
        named = [bind["name"] for bind in mesh["bind_mapping"]]
        check(prefix + ":all_binds_named_and_unique", all(named) and len(named) == len(set(named)))
        check(prefix + ":all_bind_bones_exist", all(0 <= bind["bone"] < data["skeleton_bones"] for bind in mesh["bind_mapping"]))
        for surface in mesh["surfaces"]:
            p = np.asarray(surface["positions"], dtype=np.float64)
            w = np.asarray(surface["weights"], dtype=np.float64).reshape(len(p), -1)
            b = np.asarray(surface["bones"], dtype=np.int64).reshape(len(p), -1)
            tri = np.asarray(surface["indices"], dtype=np.int64).reshape(-1, 3)
            vertices.append(p)
            weights.append(w)
            bones.append(b)
            triangles.append(tri + base)
            base += len(p)
        p, w, b, tri = map(np.concatenate, (vertices, weights, bones, triangles))
        check(prefix + ":finite_source_vertices", np.isfinite(p).all())
        check(prefix + ":finite_nonnegative_weights", np.isfinite(w).all() and (w >= 0).all())
        check(prefix + ":normalized_weights", np.max(np.abs(w.sum(axis=1) - 1)) <= 1e-4)
        check(prefix + ":all_bind_indices_valid", (b >= 0).all() and (b < len(named)).all())
        check(prefix + ":all_triangle_indices_valid", (tri >= 0).all() and (tri < len(p)).all())
        if not checks[prefix + ":all_bind_indices_valid"] or not checks[prefix + ":all_triangle_indices_valid"]:
            raise ValueError(prefix + " has invalid indices; refusing to clamp or ignore them")
        edges = np.unique(np.sort(np.concatenate((tri[:, [0, 1]], tri[:, [1, 2]], tri[:, [2, 0]])), axis=1), axis=0)
        mesh_data.append({"name": prefix, "p": p, "homogeneous": np.c_[p, np.ones(len(p))], "weights": w,
                          "bones": b, "edges": edges, "triangles": len(tri), "bind_names": named})

    body_index = next(i for i, mesh in enumerate(mesh_data) if mesh["name"] == "PantiSeatedBody")
    outline_index = next(i for i, mesh in enumerate(mesh_data) if mesh["name"] == "PantiSeatedOutline")

    def vertex_keys(mesh):
        for p, b, w in zip(mesh["p"], mesh["bones"], mesh["weights"]):
            influences = tuple(sorted((mesh["bind_names"][int(bone)], round(float(weight), 6))
                                      for bone, weight in zip(b, w) if weight > 0))
            yield tuple(np.round(p, 6)) + (influences,)

    body_lookup = {key: index for index, key in enumerate(vertex_keys(mesh_data[body_index]))}
    outline_matches = np.asarray([body_lookup.get(key, -1) for key in vertex_keys(mesh_data[outline_index])])
    check("every_outline_vertex_matches_body_position_and_weights", (outline_matches >= 0).all())
    # Limits are stated in this seated body's own measured height. They catch
    # isolated stretched triangles and gross excursions; matching repeated
    # phases and seams separately catches cumulative/loop-specific corruption.
    thresholds = {"weight_sum_error_max": 1e-4, "same_phase_vertex_error_u": 2e-5,
                  "body_outline_vertex_error_u": 2e-5, "root_same_phase_error_u": 2e-5,
                  "seat_anchor_error_u": 1e-4,
                  "model_transform_change_max": 1e-7, "edge_growth_factor": 3.0,
                  "edge_growth_height_allowance": 0.015, "vertex_excursion_height_ratio": 0.55,
                  "minimum_pose_motion_height_ratio": 0.005,
                  "boundary_vertex_jump_height_ratio": 0.001}
    reference = [None] * len(records)
    reference_edges = [None] * len(records)
    heights = [None] * len(records)
    phase_reference: dict[tuple[int, int], np.ndarray] = {}
    long_reference: dict[tuple[int, int], np.ndarray] = {}
    boundary_pairs: dict[tuple[int, int], np.ndarray] = {}
    max_repeat, max_long, max_outline, max_seam = 0.0, 0.0, 0.0, 0.0
    rows = []
    all_finite, edges_ok, envelope_ok = True, True, True
    peak_edges = [0.0] * len(records)
    peak_excursion = [0.0] * len(records)
    for sample_index, sample in enumerate(data["samples"]):
        deformed = []
        sample_rows = []
        for mesh_index, mesh in enumerate(mesh_data):
            transforms = matrices[sample_index, offsets[mesh_index]:offsets[mesh_index + 1]]
            skinned = np.einsum("vwij,vj,vw->vi", transforms[mesh["bones"]], mesh["homogeneous"], mesh["weights"], optimize=True)
            finite = bool(np.isfinite(skinned).all())
            all_finite &= finite
            edges = mesh["edges"]
            lengths = np.linalg.norm(skinned[edges[:, 0]] - skinned[edges[:, 1]], axis=1)
            if reference[mesh_index] is None:
                reference[mesh_index] = skinned.copy()
                reference_edges[mesh_index] = lengths.copy()
                heights[mesh_index] = float(np.ptp(skinned, axis=0)[1])
            height = heights[mesh_index]
            edge_allowance = reference_edges[mesh_index] * thresholds["edge_growth_factor"] + height * thresholds["edge_growth_height_allowance"]
            edge_violations = int(np.count_nonzero(lengths > edge_allowance))
            edges_ok &= edge_violations == 0
            excursion = float(np.linalg.norm(skinned - reference[mesh_index], axis=1).max())
            envelope_ok &= excursion <= height * thresholds["vertex_excursion_height_ratio"]
            peak_edges[mesh_index] = max(peak_edges[mesh_index], float(lengths.max()))
            peak_excursion[mesh_index] = max(peak_excursion[mesh_index], excursion)
            key = (mesh_index, sample["phase_index"])
            if sample["kind"] == "cycle":
                if sample["cycle"] == 0:
                    phase_reference[key] = skinned.astype(np.float32)
                else:
                    max_repeat = max(max_repeat, float(np.linalg.norm(skinned - phase_reference[key], axis=1).max()))
            elif sample["kind"] == "long_run":
                if sample["cycle"] == 0:
                    long_reference[key] = skinned.copy()
                else:
                    max_long = max(max_long, float(np.linalg.norm(skinned - long_reference[key], axis=1).max()))
            elif sample["kind"] == "boundary":
                key = (mesh_index, sample["cycle"])
                if sample["phase_index"] == -1:
                    boundary_pairs[key] = skinned.copy()
                elif sample["phase_index"] == 1:
                    jump = float(np.linalg.norm(skinned - boundary_pairs.pop(key), axis=1).max())
                    max_seam = max(max_seam, jump / height)
            sample_rows.append({"mesh": mesh["name"], "finite": finite, "aabb_min": skinned.min(axis=0).tolist(),
                                "aabb_max": skinned.max(axis=0).tolist(), "max_triangle_edge_u": float(lengths.max()),
                                "edge_limit_violations": edge_violations, "max_vertex_excursion_u": excursion})
            deformed.append(skinned)
        if (outline_matches >= 0).all():
            max_outline = max(max_outline, float(np.linalg.norm(deformed[outline_index] - deformed[body_index][outline_matches], axis=1).max()))
        rows.append({"kind": sample["kind"], "cycle": sample["cycle"], "phase_index": sample["phase_index"],
                     "time_s": sample["time_s"], "meshes": sample_rows})
    # Positions/rotations may breathe naturally. At identical phases, every
    # root-bone matrix and the model root must nevertheless repeat exactly.
    root_references = {}
    root_error = 0.0
    model_transforms = np.asarray([sample["model_global_transform"] for sample in data["samples"]])
    model_change = float(np.max(np.abs(model_transforms - model_transforms[0])))
    seat_error = float(max(np.linalg.norm(np.asarray(sample["seat_anchor"]) - np.asarray(sample["seat_anchor_target"]))
                           for sample in data["samples"]))
    for sample in data["samples"]:
        if sample["kind"] not in ("cycle", "long_run"):
            continue
        for name, pose in sample["root_bone_poses"].items():
            key = (sample["kind"], sample["phase_index"], name)
            if sample["cycle"] == 0:
                root_references[key] = np.asarray(pose)
            else:
                root_error = max(root_error, float(np.max(np.abs(np.asarray(pose) - root_references[key]))))
    check("every_deformed_vertex_and_edge_finite", all_finite)
    check("seated_idle_has_pose_motion", peak_excursion[body_index] > heights[body_index] * thresholds["minimum_pose_motion_height_ratio"])
    check("no_excessively_stretched_triangle_edges", edges_ok)
    check("vertices_inside_seated_motion_envelope", envelope_ok)
    check("three_cycles_same_phase_vertices_repeat", max_repeat <= thresholds["same_phase_vertex_error_u"])
    check("loop_2000_same_phase_vertices_repeat", max_long <= thresholds["same_phase_vertex_error_u"])
    check("loop_boundaries_continuous", max_seam <= thresholds["boundary_vertex_jump_height_ratio"])
    check("body_outline_deform_together", max_outline <= thresholds["body_outline_vertex_error_u"])
    check("model_root_has_no_accumulated_drift", model_change <= thresholds["model_transform_change_max"])
    check("root_bones_same_phase_no_accumulated_drift", root_error <= thresholds["root_same_phase_error_u"])
    check("seat_material_point_remains_fixed", seat_error <= thresholds["seat_anchor_error_u"])
    summaries = [{"name": mesh["name"], "vertices": len(mesh["p"]), "triangles": mesh["triangles"],
                  "unique_edges": len(mesh["edges"]), "named_skin_binds": len(mesh["bind_names"]),
                  "seated_reference_height_u": heights[i], "max_triangle_edge_u": peak_edges[i],
                  "max_vertex_excursion_u": peak_excursion[i], "weight_sum_max_error": float(np.max(np.abs(mesh["weights"].sum(axis=1) - 1)))}
                 for i, mesh in enumerate(mesh_data)]
    result = {"schema": "silkroad.panti-seated-idle-audit.v1", "pass": all(checks.values()),
              "source": str(args.input.resolve()), "source_sha256": hashlib.sha256(args.input.read_bytes()).hexdigest(),
              "asset": data["asset"], "asset_sha256": data["asset_sha256"], "controller": data["controller"],
              "controller_sha256": data["controller_sha256"], "method": "CPU linear blend skinning of every body/outline vertex using actual Godot named Skin binds and the shipping seated actor.set_time path; all unique triangle edges checked at every pose.",
              "duration_s": data["duration_s"], "pose_samples": len(rows), "full_cycles": data["full_cycles"],
              "long_run_cycle": 2000, "meshes": summaries, "thresholds": thresholds, "checks": checks,
              "measurements": {"three_cycle_same_phase_max_vertex_error_u": max_repeat,
                               "loop_2000_same_phase_max_vertex_error_u": max_long,
                               "body_outline_max_vertex_error_u": max_outline,
                               "boundary_max_vertex_jump_height_ratio": max_seam,
                               "model_transform_max_change": model_change,
                               "seat_anchor_max_error_u": seat_error,
                               "same_phase_root_matrix_max_error": root_error},
              "limitations": "Deformation integrity is independent of lighting and appearance; rendered scene/seat contact still requires visual review. The 2000-loop check evaluates the same absolute-time path used by the viewer, not an alternate FBX or artificial animation mixer.",
              "errors": errors, "samples": rows}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "samples"}, ensure_ascii=False, indent=2))
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
