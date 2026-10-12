#!/usr/bin/env python3
"""One explicit Tripo task at a time; offline planning and resumable receipts.

Python stdlib only. No task POST is retried. Workflow examples live in
experiments/city-design/tripo-pipeline-v01/. Run with --help for commands.
"""

import argparse
import contextlib
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import struct
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


API_BASE = "https://api.tripo3d.ai/v2/openapi"
DEFAULT_MODEL = "v3.1-20260211"
LOWPOLY_MODEL = "P1-20260311"
VIEW_ORDER = ("front", "left", "back", "right")
IMAGE_LIMIT = 20_000_000
DOWNLOAD_LIMIT = 256 * 1024 * 1024
JSON_LIMIT = 2 * 1024 * 1024
GENERATION_TYPES = {"image_to_model", "multiview_to_model", "text_to_model"}
BOOL_PARAMETERS = {"texture", "pbr", "generate_parts", "quad", "export_uv", "smart_low_poly"}
INT_PARAMETERS = {"face_limit", "model_seed", "texture_seed"}
PARAMETERS = BOOL_PARAMETERS | INT_PARAMETERS | {"geometry_quality"}
TASK_ID_PATTERN = re.compile(r"[A-Za-z0-9_-]{1,200}\Z")


class PipelineError(RuntimeError):
    """An actionable, credential-free diagnostic."""


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def read_json(path):
    try:
        with Path(path).open("rb") as stream:
            data = stream.read(JSON_LIMIT + 1)
        if len(data) > JSON_LIMIT:
            raise PipelineError("JSON file exceeds the 2 MiB limit")
        return json.loads(data)
    except (OSError, ValueError):
        raise PipelineError("Cannot read a valid JSON file: " + str(path)) from None


def atomic_bytes(path, data):
    path = Path(path)
    fd, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def atomic_json(path, value):
    atomic_bytes(path, json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False).encode("utf-8") + b"\n")


def redact(value, key):
    if isinstance(value, str):
        return value.replace(key, "[REDACTED]") if key else value
    if isinstance(value, dict):
        return {redact(k, key): redact(v, key) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v, key) for v in value]
    return value


def valid_task_id(value):
    if not isinstance(value, str) or not TASK_ID_PATTERN.fullmatch(value):
        raise PipelineError("Invalid or missing task_id")
    return value


def image_info(base, role, value):
    if not isinstance(value, str) or not value.strip():
        raise PipelineError(role + " must name a local PNG or JPEG file")
    path = (base / value).resolve()
    try:
        with path.open("rb") as stream:
            data = stream.read(IMAGE_LIMIT + 1)
    except OSError:
        raise PipelineError("Cannot read image: " + str(path)) from None
    if len(data) > IMAGE_LIMIT:
        raise PipelineError("Image exceeds the 20 MB limit: " + str(path))
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        kind = "png"
    elif data.startswith(b"\xff\xd8\xff"):
        kind = "jpeg"
    else:
        raise PipelineError("Image must contain PNG or JPEG magic bytes: " + str(path))
    return {"role": role, "path": str(path), "type": kind, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def validate_parameters(parameters, model):
    if not isinstance(parameters, dict):
        raise PipelineError("parameters must be an object")
    if set(parameters) - PARAMETERS:
        raise PipelineError("Unsupported generation parameter(s): " + ", ".join(sorted(set(parameters) - PARAMETERS)))
    if model == LOWPOLY_MODEL and set(parameters) & {"quad", "smart_low_poly", "generate_parts", "geometry_quality"}:
        raise PipelineError("P1 does not accept quad, smart_low_poly, generate_parts, or geometry_quality, even when false")
    for name in BOOL_PARAMETERS & set(parameters):
        if type(parameters[name]) is not bool:
            raise PipelineError(name + " must be a boolean")
    for name in INT_PARAMETERS & set(parameters):
        if type(parameters[name]) is not int:
            raise PipelineError(name + " must be an integer")
    if parameters.get("quad"):
        raise PipelineError("quad=true is unsupported by this GLB handoff; use quad=false or omit it")
    quality = parameters.get("geometry_quality", "standard")
    if quality not in ("standard", "detailed"):
        raise PipelineError("geometry_quality must be standard or detailed")
    if parameters.get("generate_parts") and any(parameters.get(k) is not False for k in ("texture", "pbr", "quad")):
        raise PipelineError("generate_parts=true requires explicit texture=false, pbr=false, quad=false")
    if parameters.get("texture") is False and parameters.get("pbr", True):
        raise PipelineError("texture=false requires explicit pbr=false because PBR enables texturing")
    if "face_limit" in parameters:
        minimum, maximum = (48, 20000) if model == LOWPOLY_MODEL else (1, 2000000 if quality == "detailed" else 1500000)
        if not minimum <= parameters["face_limit"] <= maximum:
            raise PipelineError("face_limit must be between %d and %d for this model/quality" % (minimum, maximum))


def prepare_manifest(path):
    """Validate without credentials or network; hash every input and requested field."""
    path = Path(path).resolve()
    manifest = read_json(path)
    if not isinstance(manifest, dict) or type(manifest.get("schema_version")) is not int or manifest["schema_version"] != 1:
        raise PipelineError("Manifest must be an object with schema_version=1")
    kind = manifest.get("type")
    if not isinstance(kind, str) or kind not in GENERATION_TYPES | {"mesh_segmentation"}:
        raise PipelineError("Unsupported task type")
    common = {"schema_version", "name", "type", "model_version", "parameters"}
    per_type = {"image_to_model": {"image"}, "multiview_to_model": {"views"}, "text_to_model": {"prompt"}, "mesh_segmentation": {"original_model_task_id"}}
    if set(manifest) - common - per_type[kind]:
        raise PipelineError("Manifest contains fields that are not supported for " + kind)
    if "name" in manifest and (not isinstance(manifest["name"], str) or not manifest["name"].strip()):
        raise PipelineError("name must be a nonempty string")
    normalized = copy.deepcopy(manifest)
    parameters = normalized.setdefault("parameters", {})
    payload = {"type": kind}
    inputs = []
    if kind in GENERATION_TYPES:
        model = normalized.setdefault("model_version", DEFAULT_MODEL)
        if model not in (DEFAULT_MODEL, LOWPOLY_MODEL):
            raise PipelineError("Generation model_version must be " + DEFAULT_MODEL + " or " + LOWPOLY_MODEL)
        validate_parameters(parameters, model)
        payload.update(model_version=model, **parameters)
    else:
        if parameters != {}:
            raise PipelineError("mesh_segmentation does not accept generation parameters")
        if "model_version" in normalized:
            if normalized["model_version"] != "v1.0-20250506":
                raise PipelineError("mesh_segmentation model_version can only be v1.0-20250506")
            payload["model_version"] = normalized["model_version"]
        payload["original_model_task_id"] = valid_task_id(manifest.get("original_model_task_id"))
    if kind == "text_to_model":
        prompt = manifest.get("prompt")
        if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 1024:
            raise PipelineError("prompt must contain 1 to 1024 characters")
        payload["prompt"] = prompt
    elif kind == "image_to_model":
        info = image_info(path.parent, "image", manifest.get("image"))
        inputs.append(info)
        payload["file"] = {"type": info["type"], "input_sha256": info["sha256"]}
    elif kind == "multiview_to_model":
        views = manifest.get("views")
        if not isinstance(views, dict) or set(views) != set(VIEW_ORDER):
            raise PipelineError("views must explicitly name front, left, back, right; use null for omitted views")
        if views["front"] is None or sum(v is not None for v in views.values()) < 2:
            raise PipelineError("multiview requires front and at least one additional image")
        payload["files"] = []
        for role in VIEW_ORDER:
            if views[role] is None:
                payload["files"].append({})
            else:
                info = image_info(path.parent, role, views[role])
                inputs.append(info)
                payload["files"].append({"type": info["type"], "input_sha256": info["sha256"]})
    identity = {"manifest": normalized, "request_template": payload, "inputs": [{k: v for k, v in i.items() if k != "path"} for i in inputs]}
    return {"manifest": normalized, "inputs": inputs, "request_template": payload, "identity_sha256": digest(identity)}


def load_key():
    key = os.environ.get("TRIPO_API_KEY", "").strip()
    if not key:
        path = Path.home() / ".config/silkroad/tripo-api-key"
        try:
            fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            with os.fdopen(fd, "r", encoding="utf-8") as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or info.st_uid != os.getuid():
                    raise PipelineError("Credential file must be owned by this user with mode 0600")
                key = stream.read(16385).strip()
        except (OSError, UnicodeError):
            raise PipelineError("Set TRIPO_API_KEY or create ~/.config/silkroad/tripo-api-key with mode 0600") from None
    if not key or len(key) > 16384 or any(c.isspace() for c in key):
        raise PipelineError("Credential must be a nonempty single token")
    return key


def https_url(value):
    if not isinstance(value, str) or any(ord(c) < 32 for c in value):
        raise PipelineError("Output download URL must be HTTPS")
    try:
        parsed = urllib.parse.urlsplit(value)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.port not in (None, 443):
            raise ValueError
    except ValueError:
        raise PipelineError("Output download URL must be HTTPS without user information or a nonstandard port") from None
    return value


class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def __init__(self, api=False):
        super().__init__()
        self.api = api

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # No task POST is ever replayed, even for a same-host redirect.
        if self.api:
            raise PipelineError("API redirects are disabled; request was not replayed")
        https_url(newurl)
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is not None:
            redirected.remove_header("Authorization")
        return redirected


class ApiClient:
    def __init__(self, key):
        self.key = key
        self.opener = urllib.request.build_opener(SafeRedirect(api=True))

    def request(self, method, path, data=None, content_type="application/json"):
        if not path.startswith("/") or "?" in path or "#" in path:
            raise PipelineError("Invalid API route")
        body = canonical(data) if isinstance(data, dict) else data
        request = urllib.request.Request(API_BASE + path, data=body, method=method,
                                         headers={"Authorization": "Bearer " + self.key, "Content-Type": content_type})
        try:
            with self.opener.open(request, timeout=90) as response:
                raw = response.read(JSON_LIMIT + 1)
            if len(raw) > JSON_LIMIT:
                raise PipelineError("API response exceeds the JSON size limit")
            result = json.loads(raw)
        except urllib.error.HTTPError as error:
            # Server bodies can echo request headers; never log or persist them.
            raise PipelineError("Tripo API HTTP %d" % error.code) from None
        except (OSError, ValueError, urllib.error.URLError):
            raise PipelineError("Tripo API transport or JSON response failed") from None
        if not isinstance(result, dict) or result.get("code", 0) != 0:
            raise PipelineError("Tripo API returned an unsuccessful response")
        data = result.get("data", result)
        if not isinstance(data, dict):
            raise PipelineError("Tripo API data is not an object")
        return redact(data, self.key)


@contextlib.contextmanager
def run_lock(run_dir, create=False):
    run_dir = Path(run_dir).resolve()
    if create:
        run_dir.mkdir(parents=True, mode=0o700, exist_ok=True)
    if not run_dir.is_dir():
        raise PipelineError("Run directory does not exist")
    lock = run_dir / ".lock"
    try:
        lock.mkdir(mode=0o700)
    except FileExistsError:
        raise PipelineError("Run directory is locked. If its process died, inspect receipt before manually removing .lock") from None
    try:
        yield run_dir
    finally:
        lock.rmdir()


def load_receipt(run_dir):
    row = read_json(Path(run_dir) / "receipt.json")
    if not isinstance(row, dict) or row.get("receipt_version") != 1:
        raise PipelineError("Unsupported or malformed receipt")
    try:
        identity = {"manifest": row["manifest"], "request_template": row["request_template"],
                    "inputs": [{k: v for k, v in item.items() if k != "path"} for item in row["inputs"]]}
        if digest(identity) != row["identity_sha256"]:
            raise PipelineError("Receipt manifest/input identity does not match its hash")
        if "request_payload" in row and digest(row["request_payload"]) != row.get("request_payload_sha256"):
            raise PipelineError("Receipt request payload does not match its hash")
    except (KeyError, TypeError, ValueError, AttributeError):
        raise PipelineError("Malformed receipt identity") from None
    return row


def save_receipt(run_dir, row, client=None):
    atomic_json(Path(run_dir) / "receipt.json", redact(row, getattr(client, "key", "")))


def upload_input(client, info):
    try:
        data = Path(info["path"]).read_bytes()
    except OSError:
        raise PipelineError("Input disappeared before upload") from None
    if len(data) > IMAGE_LIMIT or hashlib.sha256(data).hexdigest() != info["sha256"]:
        raise PipelineError("Input changed after planning; no task was submitted")
    boundary = "----SilkRoadTripo" + uuid.uuid4().hex
    # Fixed filename avoids multipart injection through local filenames.
    prefix = ('--%s\r\nContent-Disposition: form-data; name="file"; filename="input.%s"\r\nContent-Type: image/%s\r\n\r\n' % (boundary, info["type"], info["type"])).encode()
    body = prefix + data + ("\r\n--" + boundary + "--\r\n").encode()
    result = client.request("POST", "/upload/sts", body, content_type="multipart/form-data; boundary=" + boundary)
    token = result.get("image_token") or result.get("file_token")
    if not isinstance(token, str) or not token:
        raise PipelineError("Upload returned no image_token or file_token")
    return token


def submit(manifest_path, run_dir, client=None):
    plan = prepare_manifest(manifest_path)
    with run_lock(run_dir, create=True) as directory:
        if (directory / "receipt.json").exists():
            row = load_receipt(directory)
            if row.get("identity_sha256") != plan["identity_sha256"]:
                raise PipelineError("Run directory belongs to an incompatible manifest or changed input; use a new directory")
            if row.get("task_id"):
                valid_task_id(row["task_id"])
                return row
            if row.get("status") not in ("prepared", "uploading"):
                raise PipelineError("Submission requires manual reconciliation; submitting/uncertain tasks are never resubmitted")
        else:
            row = {"receipt_version": 1, **plan, "status": "prepared", "uploads": {}, "created_at": time.time()}
            save_receipt(directory, row)
        client = client or ApiClient(load_key())
        for info in plan["inputs"]:
            if info["sha256"] not in row["uploads"]:
                row["status"] = "uploading"
                save_receipt(directory, row, client)
                row["uploads"][info["sha256"]] = upload_input(client, info)
                save_receipt(directory, row, client)
        payload = copy.deepcopy(plan["request_template"])
        files = [payload["file"]] if "file" in payload else payload.get("files", [])
        for item in files:
            if item:
                item["file_token"] = row["uploads"][item.pop("input_sha256")]
        row.update(status="submitting", request_payload=payload, request_payload_sha256=digest(payload), submitted_at=time.time())
        # This durable boundary must precede the sole potentially billable request.
        save_receipt(directory, row, client)
        try:
            result = client.request("POST", "/task", payload)
            row["task_id"] = valid_task_id(result.get("task_id"))
        except Exception:
            row["status"] = "uncertain_submission"
            row["error"] = "Task submission outcome is unknown. Reconcile in Tripo before any new submission."
            save_receipt(directory, row, client)
            raise PipelineError(row["error"]) from None
        row["status"] = "queued"
        save_receipt(directory, row, client)
        return row


def safe_output(output):
    result = {}
    if isinstance(output, dict):
        for field in ("pbr_model", "model", "model_url"):
            value = output.get(field)
            if isinstance(value, dict):
                value = value.get("url")
            if isinstance(value, str):
                try:
                    result[field] = https_url(value)
                except PipelineError:
                    pass
    return result


def balance(client=None):
    """Read wallet figures once; never infer fixed prices or submit a task."""
    client = client or ApiClient(load_key())
    result = client.request("GET", "/user/balance")
    return {field: value for field, value in result.items()
            if field in {"balance", "frozen", "frozen_balance", "available", "credits"}
            and type(value) in (int, float) and math.isfinite(value)}


def status(run_dir, client=None):
    with run_lock(run_dir) as directory:
        row = load_receipt(directory)
        task_id = valid_task_id(row.get("task_id"))
        client = client or ApiClient(load_key())
        result = client.request("GET", "/task/" + task_id)
        if "task_id" in result and result["task_id"] != task_id:
            raise PipelineError("API task_id does not match receipt")
        remote_status = result.get("status")
        if not isinstance(remote_status, str) or not re.fullmatch(r"[a-z_]{1,40}", remote_status):
            raise PipelineError("API returned an invalid task status")
        row["status"] = remote_status
        for field in ("progress", "consumed_credit", "credits_consumed", "credits"):
            value = result.get(field)
            if type(value) in (int, float) and math.isfinite(value):
                row["progress" if field == "progress" else "credits"] = value
        if "output" in result:
            row["output"] = safe_output(result["output"])
        row["checked_at"] = time.time()
        if remote_status == "success" and not row.get("output"):
            row["download_note"] = "Unsupported output layout: no HTTPS pbr_model/model/model_url. Inspect Tripo output; no editable GLB was downloaded."
        else:
            row.pop("download_note", None)
        save_receipt(directory, row, client)
        return row


def inspect_glb(data):
    """Check GLB2 container boundaries and count triangle primitives (not instances)."""
    if len(data) < 20 or data[:4] != b"glTF":
        raise PipelineError("Downloaded output is not a GLB")
    version, declared_length = struct.unpack_from("<II", data, 4)
    if version != 2 or declared_length != len(data):
        raise PipelineError("Invalid GLB version or container length")
    offset, document, chunk_count = 12, None, 0
    while offset < len(data):
        if offset + 8 > len(data):
            raise PipelineError("Truncated GLB chunk header")
        length, kind = struct.unpack_from("<II", data, offset)
        offset += 8
        if length % 4 or offset + length > len(data):
            raise PipelineError("Invalid GLB chunk length")
        if chunk_count == 0:
            if kind != 0x4E4F534A:
                raise PipelineError("GLB must start with a JSON chunk")
            try:
                document = json.loads(data[offset:offset + length])
            except (ValueError, UnicodeError):
                raise PipelineError("Invalid GLB JSON chunk") from None
        elif kind == 0x4E4F534A:
            raise PipelineError("Duplicate GLB JSON chunk")
        offset += length
        chunk_count += 1
    if not isinstance(document, dict) or not isinstance(document.get("asset"), dict) or document["asset"].get("version") != "2.0":
        raise PipelineError("Invalid glTF 2.0 document")
    # A stand-alone raw handoff must not silently rely on missing external files.
    buffers, images = document.get("buffers", []), document.get("images", [])
    if not isinstance(buffers, list) or not isinstance(images, list):
        raise PipelineError("GLB resource layout is malformed")
    for entry in buffers + images:
        uri = entry.get("uri") if isinstance(entry, dict) else None
        if uri is not None and (not isinstance(uri, str) or not uri.startswith("data:")):
            raise PipelineError("GLB references external resources; a standalone model cannot be saved")
    meshes, accessors = document.get("meshes", []), document.get("accessors", [])
    if not isinstance(meshes, list) or not meshes or not isinstance(accessors, list):
        raise PipelineError("GLB contains no inspectable mesh")
    triangles, primitives = 0, 0
    try:
        for mesh in meshes:
            for primitive in mesh["primitives"]:
                if primitive.get("mode", 4) != 4:
                    raise PipelineError("GLB has non-triangle primitives; unsupported handoff layout")
                accessor_id = primitive.get("indices", primitive.get("attributes", {}).get("POSITION"))
                if type(accessor_id) is not int or not 0 <= accessor_id < len(accessors):
                    raise PipelineError("GLB primitive has an invalid accessor")
                count = accessors[accessor_id]["count"]
                if type(count) is not int or count < 3 or count % 3:
                    raise PipelineError("GLB primitive has an invalid triangle count")
                triangles += count // 3
                primitives += 1
    except (KeyError, TypeError, AttributeError):
        raise PipelineError("GLB mesh layout is malformed") from None
    if not primitives:
        raise PipelineError("GLB contains no triangle primitives")
    return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(), "meshes": len(meshes), "primitives": primitives,
            "triangles": triangles, "extensions": document.get("extensionsUsed", [])}


def download(run_dir, opener=None):
    with run_lock(run_dir) as directory:
        row = load_receipt(directory)
        if row.get("status") != "success":
            raise PipelineError("Download requires a success receipt; run status first")
        destination = directory / "model.glb"
        if destination.exists():
            with destination.open("rb") as stream:
                data = stream.read(DOWNLOAD_LIMIT + 1)
            if len(data) > DOWNLOAD_LIMIT:
                raise PipelineError("Existing model exceeds the download limit")
            info = inspect_glb(data)
            expected = row.get("model") or row.get("pending_model", {})
            if expected.get("sha256") != info["sha256"]:
                raise PipelineError("Existing model differs from its receipt; raw output will not be overwritten")
            atomic_bytes(directory / "model.glb.sha256", (info["sha256"] + "  model.glb\n").encode())
            if "pending_model" in row:
                row["model"] = row.pop("pending_model")
                row["downloaded_at"] = time.time()
                row["review_status"] = "raw_candidate_requires_visual_and_topology_review"
                save_receipt(directory, row)
            return row
        output = safe_output(row.get("output"))
        url = next((output[k] for k in ("pbr_model", "model", "model_url") if k in output), None)
        if not url:
            raise PipelineError("Unsupported output layout: no HTTPS GLB model link; segmented archives or part lists require explicit handling")
        opener = opener or urllib.request.build_opener(SafeRedirect())
        request = urllib.request.Request(https_url(url), method="GET", headers={"Accept": "model/gltf-binary, application/octet-stream"})
        try:
            with opener.open(request, timeout=120) as response:
                length = response.headers.get("Content-Length")
                if length is not None and int(length) > DOWNLOAD_LIMIT:
                    raise PipelineError("Output exceeds the 256 MiB download limit")
                data = response.read(DOWNLOAD_LIMIT + 1)
        except (OSError, ValueError, urllib.error.URLError):
            raise PipelineError("Model download failed; no candidate was saved") from None
        if len(data) > DOWNLOAD_LIMIT:
            raise PipelineError("Output exceeds the 256 MiB download limit")
        info = inspect_glb(data)
        info["path"] = "model.glb"
        # The GLB is validated before promotion; the receipt never claims topology/visual approval.
        row["pending_model"] = info
        save_receipt(directory, row)
        atomic_bytes(destination, data)
        atomic_bytes(directory / "model.glb.sha256", (info["sha256"] + "  model.glb\n").encode())
        row["model"] = row.pop("pending_model")
        row["downloaded_at"] = time.time()
        limit = row["request_template"].get("face_limit")
        if limit is not None:
            row["requested_face_limit"] = limit
            row["triangle_count_exceeds_requested_face_limit"] = info["triangles"] > limit
        row["review_status"] = "raw_candidate_requires_visual_and_topology_review"
        save_receipt(directory, row)
        return row


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("balance", help="Read account balance once; does not submit a task")
    plan_parser = commands.add_parser("plan", help="Offline validation and input/request hashes; never loads credentials")
    plan_parser.add_argument("manifest", type=Path)
    submit_parser = commands.add_parser("submit", help="Explicitly submit one task, or reuse its existing task ID")
    submit_parser.add_argument("manifest", type=Path)
    submit_parser.add_argument("--out", type=Path, required=True)
    for command in ("status", "download"):
        sub = commands.add_parser(command, help="Check one task once" if command == "status" else "Download one successful GLB without API credentials")
        sub.add_argument("run_dir", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "balance":
            result = balance()
        elif args.command == "plan":
            result = prepare_manifest(args.manifest)
        elif args.command == "submit":
            result = submit(args.manifest, args.out)
        elif args.command == "status":
            result = status(args.run_dir)
        else:
            result = download(args.run_dir)
        print(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False))
        return 0
    except PipelineError as error:
        print("ERROR: " + str(error), file=sys.stderr)
        return 2
    except (OSError, ValueError, TypeError, KeyError):
        print("ERROR: Local I/O or receipt validation failed; no automatic resubmission was attempted", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
