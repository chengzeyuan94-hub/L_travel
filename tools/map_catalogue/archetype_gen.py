"""Generate the concept image or the four-view sheet of one catalogue archetype (steps 1 and 2 of the model chain).

Builds the prompt with archetype_prompts.py, resolves the reference images and calls
art-src/cards-v2/tools/gen_card.py (CherryIN, openai/gpt-image-2.5-flare, /images/edits, quality high, png).
The API key is read by gen_card.py ONLY from $CHERRYIN_KEY_FILE; this script only checks that the variable is set.
Every call is ONE try (gen_card --retries 1) so a budget is a real budget; a quota / balance error stops the run
and prints the relay's message verbatim (exit code 3).

Outputs in art-src/custom-map-catalogue/archetypes/<id>/:
  01-concept.prompt.txt | 02-fourview.prompt.txt      the assembled prompt (written before the call, reviewable)
  attempts/01-concept-aN.png (+ .prompt.txt, .json)   every generation (gen_card's own sidecars)
  01-concept.png (+ .prompt.txt, .json)               the chosen attempt (latest by default, or --select N)
  ../generation_log.jsonl                             one line per API call (time, id, stage, attempt, status)

usage (repo root):
  python3 tools/map_catalogue/archetype_gen.py kiln_town concept --dry-run
  CHERRYIN_KEY_FILE=$HOME/.config/silkroad/cherryin-api-key python3 tools/map_catalogue/archetype_gen.py kiln_town concept
  ... kiln_town concept --note "one-line correction for this attempt"
  ... kiln_town concept --extra-ref <dir>/attempts/01-concept-a1.png --note "Reference image 3 is the previous
      attempt: keep ..., fix ..."           # iterate on an attempt instead of starting over
  ... kiln_town concept --select 1          # promote an earlier attempt, no API call
  ... kiln_town fourview                    # needs the chosen 01-concept.png

--dry-run prints the prompt, the size and the reference images and writes NOTHING (no folders, no prompt file).
An archetype without its own entry (layout + views) in archetype_models.json is refused unless --allow-generic:
the layout is what makes the concept compose for the board camera.
"""
import argparse
import datetime
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import archetype_prompts as P  # noqa: E402

GEN_CARD = os.path.join(P.ROOT, "art-src/cards-v2/tools/gen_card.py")
LOG = os.path.join(P.ART_DIR, "generation_log.jsonl")
QUOTA_PAT = re.compile(r"insufficient_user_quota|insufficient[_ ]quota|quota|balance", re.I)


def log_call(rec):
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def attempts(d, stem):
    out = {}
    for p in glob.glob(os.path.join(d, "attempts", f"{stem}-a*.png")):
        m = re.search(r"-a(\d+)\.png$", p)
        if m:
            out[int(m.group(1))] = p
    return out


def promote(d, stem, src):
    dst = os.path.join(d, f"{stem}.png")
    shutil.copyfile(src, dst)
    for ext in (".prompt.txt", ".json"):
        if os.path.exists(src + ext):
            shutil.copyfile(src + ext, dst + ext)
    print("chosen:", os.path.relpath(src, P.ROOT), "->", os.path.relpath(dst, P.ROOT))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("id")
    ap.add_argument("stage", choices=sorted(P.STAGES))
    ap.add_argument("--note", help="one-line correction appended to the prompt for this attempt")
    ap.add_argument("--extra-ref", action="append", default=[],
                    help="extra reference image appended after the stage's refs (e.g. the previous attempt); "
                         "describe its role in --note")
    ap.add_argument("--select", type=int, help="promote attempt N to the chosen image (no API call)")
    ap.add_argument("--no-promote", action="store_true", help="keep the previous chosen image")
    ap.add_argument("--dry-run", action="store_true", help="print prompt + refs, write nothing, call nothing")
    ap.add_argument("--allow-generic", action="store_true",
                    help="allow an archetype without its own layout/views entry in archetype_models.json")
    ap.add_argument("--timeout", type=int, default=600)
    a = ap.parse_args()

    stem = P.STAGES[a.stage]["file"]
    d = P.paths(a.id)["dir"]
    if a.select:
        src = attempts(d, stem).get(a.select)
        if not src:
            raise SystemExit(f"no attempt {a.select} for {a.id} {a.stage}")
        promote(d, stem, src)
        return

    h = P.hints_for(a.id)
    if not h["has_entry"] and not a.allow_generic:
        raise SystemExit(f"{a.id} has no layout / views entry in tools/map_catalogue/archetype_models.json: write one "
                         "(described for the board camera) or pass --allow-generic")
    size = h[P.STAGES[a.stage]["size_key"]]
    prompt = P.build_prompt(a.id, a.stage, a.note)
    refs = P.refs_for(a.id, a.stage) + [os.path.abspath(r) for r in a.extra_ref]
    for r in refs:
        if not os.path.exists(r):
            raise SystemExit(f"missing reference image: {r}")
    n = max(attempts(d, stem), default=0) + 1
    out = os.path.join(d, "attempts", f"{stem}-a{n}.png")
    if a.dry_run:  # nothing is written: no folders, no prompt file, no log line
        print(f"size: {size}\nrefs:\n  " + "\n  ".join(os.path.relpath(r, P.ROOT) for r in refs) + "\n")
        print(prompt)
        print("\n(dry run: nothing sent, nothing written; a real run writes", os.path.relpath(out, P.ROOT) + ")")
        return
    os.makedirs(os.path.join(d, "attempts"), exist_ok=True)
    ppath = os.path.join(d, f"{stem}.prompt.txt")
    with open(ppath, "w", encoding="utf-8") as f:
        f.write(prompt + "\n")
    cmd = [sys.executable, GEN_CARD, "--out", out, "--prompt-file", ppath, "--size", size, "--retries", "1",
           "--timeout", str(a.timeout), "--background", "opaque"]
    for r in refs:
        cmd += ["--ref", r]
    if not os.environ.get("CHERRYIN_KEY_FILE"):
        raise SystemExit("set CHERRYIN_KEY_FILE (the key is never passed on the command line)")
    t0 = time.time()
    res = subprocess.run(cmd, capture_output=True, text=True)
    rec = {"time": datetime.datetime.now().isoformat(timespec="seconds"), "id": a.id, "stage": a.stage, "attempt": n,
           "out": os.path.relpath(out, P.ROOT), "size": size, "refs": [os.path.relpath(r, P.ROOT) if r.startswith(P.ROOT) else r for r in refs],
           "note": a.note, "seconds": round(time.time() - t0, 1), "ok": res.returncode == 0 and os.path.exists(out)}
    if not rec["ok"]:
        rec["error"] = (res.stderr or res.stdout)[-1500:]
    log_call(rec)
    sys.stdout.write(res.stdout)
    if not rec["ok"]:
        sys.stderr.write(res.stderr)
        if QUOTA_PAT.search(res.stderr or ""):
            print("\nSTOPPED: the image relay reported a quota / balance problem (message above, verbatim).", file=sys.stderr)
            sys.exit(3)
        sys.exit(1)
    if not a.no_promote:
        promote(d, stem, out)


if __name__ == "__main__":
    main()
