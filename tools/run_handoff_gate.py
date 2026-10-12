#!/usr/bin/env python3
"""《丝路商旅》正式交接门禁 runner。

设计约束（来自 TASK-HANDOFF-INTEGRITY-001）：

1. 不改变任何现有测试语义 —— 本 runner 只负责调度、判定与归档，不向被测场景注入参数。
2. 每个套件使用独立 Godot 进程，摘要单独保存。
3. 严格串行；窗口类测试永不并发（本 runner 全程单进程顺序执行，由构造保证）。
4. ERROR / leak / 非零退出码一律视为失败，即使套件自报 failed=0。
5. 压力测试的 quiet 只作用于控制台与摘要：完整日志始终落盘，
   生产诊断（如 EventSystem 逐抽日志）不被删除也不被改写。

用法：
    python3 tools/run_handoff_gate.py                 # 跑全部
    python3 tools/run_handoff_gate.py --group rules   # 只跑某组
    python3 tools/run_handoff_gate.py --skip stress   # 跳过某组
    python3 tools/run_handoff_gate.py --list          # 只列清单
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "tools" / "handoff_test_manifest.json"
DEFAULT_GODOT = "/Applications/Godot.app/Contents/MacOS/Godot"

RESULT_RE = re.compile(r"passed=(\d+)\s+failed=(\d+)")
# 部分套件（如 formal_ui_full_game_e2e）只报 failed=N，没有 passed=N。
# 必须单独识别，否则这些套件会退化成"只看退出码"，门禁形同虚设。
FAILED_ONLY_RE = re.compile(r"\bfailed=(\d+)")

# Bind actual execution inputs, including untracked files, not just a Git ref.
# Import caches, editable Blender sources and validation outputs are not runtime
# inputs. Import settings beside assets ARE inputs and remain in this inventory.
INPUT_DIRECTORIES = ("scripts", "scenes", "data", "assets", "tests")
TOOL_SUFFIXES = {".py", ".gd", ".tscn", ".tres", ".json", ".sh", ".uid"}
DOCUMENT_INPUTS = (
    "docs/research/YF064-original-physical-assets-ledger.md",
)


def execution_inputs(root: Path = ROOT) -> list[Path]:
    paths = {root / "project.godot", root / "tools/handoff_test_manifest.json",
             root / "tools/run_handoff_gate.py"}
    paths.update(root / relative for relative in DOCUMENT_INPUTS)
    for optional in ("export_presets.cfg", "override.cfg"):
        if (root / optional).is_file():
            paths.add(root / optional)
    for directory in (*INPUT_DIRECTORIES, "tools"):
        for path in (root / directory).rglob("*"):
            if not path.is_file() or any((part.startswith(".") and part != ".gdignore") or part == "__pycache__"
                                         for part in path.relative_to(root).parts):
                continue
            if path.suffix in {".blend", ".blend1", ".pyc"}:
                continue
            if directory == "tools" and path.suffix not in TOOL_SUFFIXES and path.name != ".gdignore":
                continue
            paths.add(path)
    return sorted(paths)


def capture_inputs(root: Path = ROOT) -> dict:
    files, errors = {}, []
    for path in execution_inputs(root):
        relative = path.relative_to(root).as_posix()
        try:
            digest = hashlib.sha256()
            with path.open("rb") as handle:
                for block in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(block)
            files[relative] = digest.hexdigest()
        except OSError as error:
            errors.append({"path": relative, "error": str(error)})
    git = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True)
    if git.returncode:
        errors.append({"path": ".git/HEAD", "error": git.stderr.strip()})
    return {"captured_at_utc": datetime.now(timezone.utc).isoformat(),
            "git_head": git.stdout.strip() if git.returncode == 0 else None,
            "source_sha256": files, "file_count": len(files), "errors": errors,
            "scope": "All scripts/scenes/data/assets/tests, executable tool sources and JSON, project and export configuration, physical-assets ledger and physical-board corridor manifest (under data); includes UI, all GLBs and asset import settings; excludes caches, Blender source and dynamic evidence outputs."}


def compare_inputs(start: dict, end: dict) -> dict:
    before, after = start["source_sha256"], end["source_sha256"]
    added = sorted(set(after) - set(before))
    removed = sorted(set(before) - set(after))
    changed = sorted(path for path in before.keys() & after.keys() if before[path] != after[path])
    head_changed = start["git_head"] != end["git_head"]
    return {"ok": not (added or removed or changed or head_changed or start["errors"] or end["errors"]),
            "added": added, "removed": removed, "changed": changed,
            "git_head_changed": head_changed, "start_errors": start["errors"], "end_errors": end["errors"]}


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")


def load_manifest() -> dict:
    with MANIFEST.open(encoding="utf-8") as handle:
        return json.load(handle)


def resolve_godot(explicit: str | None) -> str:
    for candidate in (explicit, os.environ.get("GODOT"), DEFAULT_GODOT):
        if candidate and Path(candidate).exists():
            return candidate
    sys.exit(
        "找不到 Godot 可执行文件。请安装 Godot 4.7.x 到 /Applications，"
        "或用 --godot / GODOT 环境变量指定路径。"
    )


def build_command(stage: dict, godot: str) -> list[str]:
    kind = stage["kind"]
    if kind == "python":
        return [sys.executable, str(ROOT / stage["script"]), *stage.get("args", [])]
    if kind == "godot_headless":
        return [godot, "--headless", "--path", str(ROOT), *stage.get("args", [])]
    if kind == "godot_scene":
        cmd = [godot]
        # 窗口类测试必须使用真实窗口，不能加 --headless。
        if not stage.get("windowed", False):
            cmd.append("--headless")
        cmd += ["--path", str(ROOT), stage["scene"]]
        return cmd
    raise ValueError("未知 stage kind: %s" % kind)


def scan_failures(text: str, patterns: dict) -> list[str]:
    """返回命中的失败证据；ERROR / leak / 断言失败都算。"""
    hits: list[str] = []
    for label, needles in patterns.items():
        for needle in needles:
            if needle.startswith("^"):
                found = re.findall(needle + r".*", text, flags=re.MULTILINE)
            else:
                found = [line for line in text.splitlines() if needle in line]
            if found:
                hits.append("%s: %s" % (label, found[0].strip()[:200]))
                break
    return hits


def condense(text: str, keep_patterns: list[str]) -> str:
    """quiet 模式：只保留摘要与失败上下文，完整日志另行落盘。"""
    kept = []
    compiled = [re.compile(p) for p in keep_patterns]
    for line in text.splitlines():
        if any(rx.search(line) for rx in compiled):
            kept.append(line)
    return "\n".join(kept)


def run_stage(stage: dict, godot: str, log_dir: Path, patterns: dict) -> dict:
    cmd = build_command(stage, godot)
    started = time.time()
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, errors="replace")
    elapsed = time.time() - started
    output = proc.stdout + proc.stderr

    # 完整日志始终落盘 —— 生产诊断一律保留。
    full_log = log_dir / ("%s.log" % stage["id"])
    full_log.write_text(output, encoding="utf-8")

    reasons: list[str] = []
    if proc.returncode != 0:
        reasons.append("非零退出码: %d" % proc.returncode)
    reasons += scan_failures(output, patterns)

    passed = failed = None
    match = None
    for match in RESULT_RE.finditer(output):
        pass
    if match:
        passed, failed = int(match.group(1)), int(match.group(2))
    else:
        # 回退：只报 failed=N 的套件也必须被判定，不能只靠退出码。
        tail = None
        for tail in FAILED_ONLY_RE.finditer(output):
            pass
        if tail:
            failed = int(tail.group(1))

    if failed is not None and failed != 0:
        reasons.append("套件自报 failed=%d" % failed)
    expect = stage.get("expect_passed")
    if expect is not None:
        if passed is None:
            reasons.append("清单声明 expect_passed=%d，但输出里找不到 passed=N" % expect)
        elif passed != expect:
            reasons.append("passed 偏离基线: 期望 %d，实际 %d" % (expect, passed))
    if stage.get("kind") == "godot_scene" and failed is None:
        reasons.append("未在输出中找到 failed=N 摘要，无法判定该套件")

    expect_out = stage.get("expect_stdout")
    if expect_out and expect_out not in output:
        reasons.append("缺少期望输出: %s" % expect_out)

    if stage.get("quiet"):
        condensed = condense(output, stage.get("quiet_keep_patterns", []))
        (log_dir / ("%s.summary.log" % stage["id"])).write_text(condensed, encoding="utf-8")

    return {
        "id": stage["id"],
        "title": stage["title"],
        "group": stage.get("group", ""),
        "windowed": stage.get("windowed", False),
        "command": " ".join(cmd),
        "exit_code": proc.returncode,
        "passed": passed,
        "failed": failed,
        "expect_passed": stage.get("expect_passed"),
        "elapsed_sec": round(elapsed, 1),
        "log": str(full_log.relative_to(ROOT)) if full_log.is_relative_to(ROOT) else str(full_log),
        "ok": not reasons,
        "reasons": reasons,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="《丝路商旅》交接门禁 runner（串行）")
    parser.add_argument("--godot", help="Godot 可执行文件路径")
    parser.add_argument("--group", action="append", help="只运行指定分组，可重复")
    parser.add_argument("--skip", action="append", default=[], help="跳过指定分组，可重复")
    parser.add_argument("--log-dir", help="日志目录，默认 /tmp/silkroad_handoff_gate_<ts>")
    parser.add_argument("--list", action="store_true", help="只列出清单，不执行")
    args = parser.parse_args()

    manifest = load_manifest()
    stages = manifest["stages"]
    if args.group:
        stages = [s for s in stages if s.get("group") in args.group]
    if args.skip:
        stages = [s for s in stages if s.get("group") not in args.skip]

    if args.list:
        for stage in stages:
            flag = " [窗口]" if stage.get("windowed") else ""
            print("%-42s %-8s %s%s" % (stage["id"], stage.get("group", ""), stage["title"], flag))
        return 0

    if not stages:
        sys.exit("没有匹配的 stage。")

    godot = resolve_godot(args.godot)
    log_dir = Path(args.log_dir) if args.log_dir else Path("/tmp/silkroad_handoff_gate_%d" % int(time.time()))
    if any(log_dir.resolve().is_relative_to(ROOT / directory) for directory in (*INPUT_DIRECTORIES, "tools")):
        parser.error("--log-dir 必须位于输入目录之外（建议 /tmp 或 docs/design/.../validation），避免门禁输出改变被测输入。")
    log_dir.mkdir(parents=True, exist_ok=True)

    # Persist this BEFORE launching any stage. Never attach today's hash to an
    # earlier run: both snapshots below belong to this invocation only.
    input_start = capture_inputs()
    write_json(log_dir / "input-start.json", input_start)
    # An interrupted invocation must not leave an earlier green summary looking
    # like the result of this run. The completed summary replaces this sentinel.
    write_json(log_dir / "summary.json", {
        "status": "input_snapshot_failed" if input_start["errors"] else "in_progress",
        "ok": False, "failed": 1, "total": len(stages), "completed_stages": 0,
        "source_sha256": input_start["source_sha256"], "git_head": input_start["git_head"],
        "input_started_at_utc": input_start["captured_at_utc"], "input_errors": input_start["errors"],
        "results": [],
    })
    if input_start["errors"]:
        print("FAIL: 无法完整记录门禁执行输入，未启动任何阶段。")
        print(json.dumps(input_start["errors"], ensure_ascii=False))
        return 1

    version = subprocess.run([godot, "--version"], capture_output=True, text=True).stdout.strip()
    print("Godot   : %s" % version)
    print("日志目录: %s" % log_dir)
    print("执行方式: 严格串行；窗口类测试互斥\n")

    patterns = manifest["failure_patterns"]
    results = []
    for index, stage in enumerate(stages, 1):
        flag = " [窗口]" if stage.get("windowed") else ""
        print("[%2d/%2d] %-44s%s ... " % (index, len(stages), stage["id"], flag), end="", flush=True)
        result = run_stage(stage, godot, log_dir, patterns)
        results.append(result)
        detail = ""
        if result["passed"] is not None:
            detail = " %d/%d" % (result["passed"], result["failed"])
        print("%s%s (%.1fs)" % ("PASS" if result["ok"] else "FAIL", detail, result["elapsed_sec"]))
        for reason in result["reasons"]:
            print("         ↳ %s" % reason)

    input_end = capture_inputs()
    write_json(log_dir / "input-end.json", input_end)
    input_integrity = compare_inputs(input_start, input_end)
    failed = [r for r in results if not r["ok"]]
    overall_ok = not failed and input_integrity["ok"]
    summary = {
        "godot": version,
        "log_dir": str(log_dir),
        "total": len(results),
        # Keep a nonzero failed field on input drift, even if all stage logs
        # passed. stage_failed preserves the separate suite-result count.
        "failed": len(failed) if input_integrity["ok"] else max(1, len(failed)),
        "stage_failed": len(failed),
        "ok": overall_ok,
        "status": "passed" if overall_ok else "failed",
        "completed_stages": len(results),
        "git_head": input_start["git_head"],
        "source_sha256": input_start["source_sha256"],
        "input_started_at_utc": input_start["captured_at_utc"],
        "input_finished_at_utc": input_end["captured_at_utc"],
        "input_integrity": input_integrity,
        "input_binding_scope_note": "Actual invocation start/end snapshots. Detects added, removed or changed input bytes and HEAD between those snapshots; does not monitor temporary changes restored before the end. Keep inputs frozen throughout execution.",
        "results": results,
    }
    write_json(log_dir / "summary.json", summary)

    print("\n%s  阶段 %d/%d 通过；输入一致性 %s" % ("全部通过" if overall_ok else "存在失败", len(results) - len(failed), len(results), "PASS" if input_integrity["ok"] else "FAIL"))
    if not input_integrity["ok"]:
        print("FAIL: 门禁期间源码、资产、配置或 Git HEAD 改变，整组结果不得作为稳定版本通过证据。")
        print(json.dumps(input_integrity, ensure_ascii=False))
    print("摘要: %s" % (log_dir / "summary.json"))
    return 0 if overall_ok else 1


if __name__ == "__main__":
    sys.exit(main())
