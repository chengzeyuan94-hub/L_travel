"""Offline regression tests for the Tripo CLI's validation and paid-task safety.

Run with: python3 -m unittest discover -s tools/tests -p 'test_tripo_pipeline.py'
No API credentials, network access, or third-party Python packages are required.
"""

import base64
import hashlib
import io
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest import mock
import urllib.request
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tripo_pipeline as pipeline


def png_bytes(rgb=(255, 0, 0)):
    """A complete two-by-two PNG, generated without an imaging dependency."""
    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress((b"\0" + bytes(rgb) * 2) * 2))
            + chunk(b"IEND", b""))


# A real two-by-two JPEG fixture, kept inline so tests do not need Pillow.
JPEG_BYTES = base64.b64decode(
    "/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGg"
    "AAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAAqADAAQAAAABAAAAAgAAAAD/7QA4UGhv"
    "dG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+"
    "/8AAEQgAAgACAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkK"
    "C//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCsc"
    "EVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVm"
    "Z2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8"
    "TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEB"
    "AQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYS"
    "QVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDRE"
    "VGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKj"
    "pKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/"
    "j5+v/bAEMAAgICAgICAwICAwUDAwMFBgUFBQUGCAYGBgYGCAoICAgICAgKCgoKCgoKCg"
    "wMDAwMDA4ODg4ODw8PDw8PDw8PD//bAEMBAgICBAQEBwQEBxALCQsQEBAQEBAQEBAQ"
    "EBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQAAf/a"
    "AAwDAQACEQMRAD8A+L6KKK/lM/38P//Z"
)


def triangle_glb():
    """A valid GLB 2.0 containing one indexed triangle."""
    document = {
        "asset": {"version": "2.0"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0}],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}],
        "buffers": [{"byteLength": 42}],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0, "byteLength": 36, "target": 34962},
            {"buffer": 0, "byteOffset": 36, "byteLength": 6, "target": 34963},
        ],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3",
             "min": [0, 0, 0], "max": [1, 1, 0]},
            {"bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"},
        ],
    }
    json_chunk = json.dumps(document, separators=(",", ":")).encode()
    json_chunk += b" " * (-len(json_chunk) % 4)
    bin_chunk = struct.pack("<9f3H", 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 2)
    bin_chunk += b"\0" * (-len(bin_chunk) % 4)
    body = (struct.pack("<I4s", len(json_chunk), b"JSON") + json_chunk
            + struct.pack("<I4s", len(bin_chunk), b"BIN\0") + bin_chunk)
    return struct.pack("<4sII", b"glTF", 2, 12 + len(body)) + body


class FakeClient:
    def __init__(self, task_result=None, task_error=None, task_status=None):
        self.calls = []
        self.task_result = {"task_id": "task-123"} if task_result is None else task_result
        self.task_error = task_error
        self.task_status = task_status or {
            "status": "success", "output": {"model": "https://cdn.example.test/model.glb"}}

    def request(self, method, path, data=None, content_type="application/json"):
        self.calls.append((method, path, data, content_type))
        if (method, path) == ("POST", "/upload/sts"):
            return {"image_token": "uploaded-token"}
        if (method, path) == ("POST", "/task"):
            if self.task_error:
                raise self.task_error
            return self.task_result
        if (method, path) == ("GET", "/task/task-123"):
            return self.task_status
        raise AssertionError(f"Unexpected API request: {method} {path}")

    def count(self, method, path):
        return sum(call[:2] == (method, path) for call in self.calls)


class FakeResponse(io.BytesIO):
    def __init__(self, data, url):
        super().__init__(data)
        self.headers = {"Content-Length": str(len(data))}
        self.status = 200
        self.url = url

    def geturl(self):
        return self.url


class FakeOpener:
    def __init__(self, data):
        self.data = data
        self.calls = []

    def open(self, request, timeout=None):
        self.calls.append((request, timeout))
        return FakeResponse(self.data, request.full_url)


class PipelineTestCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.manifest_path = self.root / "manifest.json"
        self.run_dir = self.root / "run"
        (self.root / "input.png").write_bytes(png_bytes())
        # A regression that accidentally bypasses the fakes must fail offline.
        for target in ("urllib.request.urlopen", "urllib.request.OpenerDirector.open"):
            guard = mock.patch(target, side_effect=AssertionError("Network forbidden"))
            guard.start()
            self.addCleanup(guard.stop)

    def manifest(self, **changes):
        value = {"schema_version": 1, "type": "text_to_model", "prompt": "A low poly tower"}
        value.update(changes)
        self.manifest_path.write_text(json.dumps(value), encoding="utf-8")
        return self.manifest_path

    def image_manifest(self, **changes):
        value = {"schema_version": 1, "type": "image_to_model", "image": "input.png"}
        value.update(changes)
        self.manifest_path.write_text(json.dumps(value), encoding="utf-8")
        return self.manifest_path

    def multiview_manifest(self, **changes):
        value = {"schema_version": 1, "type": "multiview_to_model",
                 "views": {"front": "input.png", "left": "input.png",
                           "back": None, "right": None}}
        value.update(changes)
        self.manifest_path.write_text(json.dumps(value), encoding="utf-8")
        return self.manifest_path

    def succeeded_run(self, url="https://cdn.example.test/model.glb"):
        client = FakeClient(task_status={"status": "success", "output": {"model": url}})
        pipeline.submit(self.manifest(), self.run_dir, client=client)
        pipeline.status(self.run_dir, client=client)
        return client


class ManifestTests(PipelineTestCase):
    def test_image_plan_uses_content_hash_and_resolved_path(self):
        plan = pipeline.prepare_manifest(self.image_manifest())
        expected_hash = hashlib.sha256(png_bytes()).hexdigest()
        self.assertEqual(plan["request_template"]["model_version"], "v3.1-20260211")
        self.assertEqual(plan["request_template"]["file"],
                         {"type": "png", "input_sha256": expected_hash})
        self.assertEqual(plan["inputs"][0]["path"], str(self.root / "input.png"))
        self.assertEqual(plan["inputs"][0]["sha256"], expected_hash)
        self.assertEqual(plan["inputs"][0]["role"], "image")
        self.assertEqual(plan["inputs"][0]["bytes"], len(png_bytes()))
        self.assertEqual(len(plan["identity_sha256"]), 64)

    def test_jpeg_input_is_supported(self):
        (self.root / "input.jpg").write_bytes(JPEG_BYTES)
        plan = pipeline.prepare_manifest(self.image_manifest(image="input.jpg"))
        self.assertEqual(plan["inputs"][0]["type"], "jpeg")
        self.assertEqual(plan["request_template"]["file"]["type"], "jpeg")

    def test_invalid_png_and_jpeg_are_rejected_before_submission(self):
        for filename in ("fake.png", "fake.jpg", "fake.jpeg"):
            with self.subTest(filename=filename):
                (self.root / filename).write_bytes(b"not an image")
                client = FakeClient()
                with self.assertRaises(pipeline.PipelineError):
                    pipeline.submit(self.image_manifest(image=filename), self.run_dir, client=client)
                self.assertEqual(client.calls, [])

    def test_image_type_is_detected_from_content_instead_of_extension(self):
        (self.root / "renamed.jpg").write_bytes(png_bytes())
        plan = pipeline.prepare_manifest(self.image_manifest(image="renamed.jpg"))
        self.assertEqual(plan["inputs"][0]["type"], "png")
        self.assertEqual(plan["request_template"]["file"]["type"], "png")

    def test_multiview_preserves_named_view_order_and_null_slots(self):
        left_bytes = png_bytes((0, 255, 0))
        (self.root / "left.png").write_bytes(left_bytes)
        views = {"right": None, "back": None, "left": "left.png", "front": "input.png"}
        plan = pipeline.prepare_manifest(self.multiview_manifest(views=views))
        files = plan["request_template"]["files"]
        front = {"type": "png", "input_sha256": hashlib.sha256(png_bytes()).hexdigest()}
        left = {"type": "png", "input_sha256": hashlib.sha256(left_bytes).hexdigest()}
        self.assertEqual(files, [front, left, {}, {}])
        self.assertEqual([item["role"] for item in plan["inputs"]], ["front", "left"])

    def test_all_four_views_are_submitted_in_front_left_back_right_order(self):
        contents = {"front": png_bytes((255, 0, 0)), "left": png_bytes((0, 255, 0)),
                    "back": png_bytes((0, 0, 255)), "right": png_bytes((255, 255, 0))}
        for role, content in contents.items():
            (self.root / f"{role}.png").write_bytes(content)
        views = {role: f"{role}.png" for role in ("right", "back", "left", "front")}
        plan = pipeline.prepare_manifest(self.multiview_manifest(views=views))
        self.assertEqual(plan["request_template"]["files"], [
            {"type": "png", "input_sha256": hashlib.sha256(contents[role]).hexdigest()}
            for role in ("front", "left", "back", "right")
        ])

    def test_multiview_requires_all_four_exact_view_names(self):
        valid = {"front": "input.png", "left": "input.png", "back": None, "right": None}
        for missing in valid:
            with self.subTest(missing=missing):
                views = dict(valid)
                del views[missing]
                with self.assertRaises(pipeline.PipelineError):
                    pipeline.prepare_manifest(self.multiview_manifest(views=views))
        for extra in ("rear", "Front", "top"):
            with self.subTest(extra=extra):
                with self.assertRaises(pipeline.PipelineError):
                    pipeline.prepare_manifest(self.multiview_manifest(views={**valid, extra: None}))

    def test_multiview_requires_front_and_two_nonempty_views(self):
        invalid = [
            {"front": None, "left": "input.png", "back": "input.png", "right": None},
            {"front": "input.png", "left": None, "back": None, "right": None},
        ]
        for views in invalid:
            with self.subTest(views=views):
                with self.assertRaises(pipeline.PipelineError):
                    pipeline.prepare_manifest(self.multiview_manifest(views=views))

    def test_parts_generation_rejects_texture_pbr_or_quad(self):
        for conflicting in ("texture", "pbr", "quad"):
            with self.subTest(parameter=conflicting):
                parameters = {"generate_parts": True, "texture": False, "pbr": False, "quad": False}
                parameters[conflicting] = True
                with self.assertRaises(pipeline.PipelineError):
                    pipeline.prepare_manifest(self.manifest(parameters=parameters))

    def test_p1_rejects_unsupported_parameter_presence_even_when_false(self):
        for forbidden in ("generate_parts", "quad", "smart_low_poly", "geometry_quality"):
            with self.subTest(parameter=forbidden):
                with self.assertRaises(pipeline.PipelineError):
                    pipeline.prepare_manifest(self.manifest(
                        model_version="P1-20260311", parameters={forbidden: False}))

    def test_p1_requires_exact_model_version(self):
        with self.assertRaises(pipeline.PipelineError):
            pipeline.prepare_manifest(self.manifest(model_version="P1"))


class SubmissionTests(PipelineTestCase):
    def test_image_is_uploaded_and_request_uses_token(self):
        client = FakeClient()
        receipt = pipeline.submit(self.image_manifest(), self.run_dir, client=client)
        self.assertEqual(client.count("POST", "/upload/sts"), 1)
        self.assertEqual(client.count("POST", "/task"), 1)
        payload = next(call[2] for call in client.calls if call[:2] == ("POST", "/task"))
        self.assertEqual(payload["file"], {"type": "png", "file_token": "uploaded-token"})
        self.assertEqual(receipt["task_id"], "task-123")
        self.assertEqual(pipeline.read_json(self.run_dir / "receipt.json")["task_id"], "task-123")

    def test_known_task_is_reused_without_any_network_calls(self):
        path = self.manifest()
        initial = pipeline.submit(path, self.run_dir, client=FakeClient())
        client = FakeClient()
        repeated = pipeline.submit(path, self.run_dir, client=client)
        self.assertEqual(repeated["task_id"], initial["task_id"])
        self.assertEqual(client.calls, [])

    def test_interrupted_submission_requires_reconciliation_without_retry(self):
        path = self.manifest()
        receipt = pipeline.submit(path, self.run_dir, client=FakeClient())
        receipt.pop("task_id")
        receipt["status"] = "submitting"
        (self.run_dir / "receipt.json").write_text(json.dumps(receipt), encoding="utf-8")
        client = FakeClient()
        with self.assertRaises(pipeline.PipelineError):
            pipeline.submit(path, self.run_dir, client=client)
        self.assertEqual(client.calls, [])
        self.assertEqual(pipeline.read_json(self.run_dir / "receipt.json")["status"], "submitting")

    def test_existing_lock_blocks_submission_without_network(self):
        self.run_dir.mkdir()
        (self.run_dir / ".lock").mkdir()
        client = FakeClient()
        with self.assertRaises(pipeline.PipelineError):
            pipeline.submit(self.manifest(), self.run_dir, client=client)
        self.assertEqual(client.calls, [])
        self.assertTrue((self.run_dir / ".lock").is_dir())

    def test_submitting_receipt_is_durable_before_paid_post(self):
        client = FakeClient()
        real_request = client.request

        def inspect_boundary(method, path, data=None, content_type="application/json"):
            if (method, path) == ("POST", "/task"):
                row = pipeline.read_json(self.run_dir / "receipt.json")
                self.assertEqual(row["status"], "submitting")
                self.assertEqual(row["request_payload"], data)
                self.assertEqual(row["request_payload_sha256"], pipeline.digest(data))
                self.assertFalse(row.get("task_id"))
            return real_request(method, path, data, content_type)

        client.request = inspect_boundary
        pipeline.submit(self.manifest(), self.run_dir, client=client)
        self.assertEqual(client.count("POST", "/task"), 1)

    def test_tampered_request_payload_is_not_trusted_or_resubmitted(self):
        path = self.manifest()
        receipt = pipeline.submit(path, self.run_dir, client=FakeClient())
        receipt["request_payload"]["prompt"] = "An altered paid request"
        (self.run_dir / "receipt.json").write_text(json.dumps(receipt), encoding="utf-8")
        client = FakeClient()
        with self.assertRaises(pipeline.PipelineError):
            pipeline.submit(path, self.run_dir, client=client)
        self.assertEqual(client.calls, [])

    def test_changed_manifest_cannot_reuse_existing_run(self):
        pipeline.submit(self.manifest(), self.run_dir, client=FakeClient())
        client = FakeClient()
        with self.assertRaises(pipeline.PipelineError):
            pipeline.submit(self.manifest(prompt="A different object"), self.run_dir, client=client)
        self.assertEqual(client.calls, [])
        self.assertEqual(pipeline.read_json(self.run_dir / "receipt.json")["task_id"], "task-123")

    def test_changed_input_content_cannot_reuse_existing_run(self):
        path = self.image_manifest()
        pipeline.submit(path, self.run_dir, client=FakeClient())
        (self.root / "input.png").write_bytes(png_bytes((0, 255, 0)))
        client = FakeClient()
        with self.assertRaises(pipeline.PipelineError):
            pipeline.submit(path, self.run_dir, client=client)
        self.assertEqual(client.calls, [])

    def test_ambiguous_post_is_recorded_and_never_automatically_resubmitted(self):
        path = self.image_manifest()
        secret = "fake-api-key-that-must-not-be-persisted"
        client = FakeClient(task_error=TimeoutError("response was lost: " + secret))
        client.key = secret
        with self.assertRaises(pipeline.PipelineError) as raised:
            pipeline.submit(path, self.run_dir, client=client)
        self.assertNotIn(secret, str(raised.exception))
        self.assertNotIn(secret, (self.run_dir / "receipt.json").read_text())
        receipt = pipeline.read_json(self.run_dir / "receipt.json")
        self.assertEqual(receipt["status"], "uncertain_submission")
        self.assertFalse(receipt.get("task_id"))
        with self.assertRaises(pipeline.PipelineError):
            pipeline.submit(path, self.run_dir, client=client)
        self.assertEqual(client.count("POST", "/task"), 1)
        self.assertEqual(client.count("POST", "/upload/sts"), 1)

    def test_response_without_task_id_is_also_ambiguous_and_not_resubmitted(self):
        path = self.manifest()
        client = FakeClient(task_result={"message": "accepted"})
        with self.assertRaises(pipeline.PipelineError):
            pipeline.submit(path, self.run_dir, client=client)
        self.assertEqual(pipeline.read_json(self.run_dir / "receipt.json")["status"],
                         "uncertain_submission")
        with self.assertRaises(pipeline.PipelineError):
            pipeline.submit(path, self.run_dir, client=client)
        self.assertEqual(client.count("POST", "/task"), 1)

    def test_status_reads_existing_task_without_creating_another(self):
        pipeline.submit(self.manifest(), self.run_dir, client=FakeClient())
        client = FakeClient()
        receipt = pipeline.status(self.run_dir, client=client)
        self.assertEqual(receipt["task_id"], "task-123")
        self.assertEqual([call[:2] for call in client.calls], [("GET", "/task/task-123")])


class DownloadTests(PipelineTestCase):
    def test_valid_glb_is_downloaded_with_hash_and_geometry_metadata(self):
        self.succeeded_run()
        content = triangle_glb()
        opener = FakeOpener(content)
        receipt = pipeline.download(self.run_dir, opener=opener)
        model = receipt["model"]
        self.assertEqual((self.run_dir / model["path"]).read_bytes(), content)
        self.assertEqual(model["sha256"], hashlib.sha256(content).hexdigest())
        self.assertEqual(model["bytes"], len(content))
        self.assertEqual(model["meshes"], 1)
        self.assertEqual(model["triangles"], 1)

    def test_download_uses_https_without_api_authorization_header(self):
        url = "https://cdn.example.test/model.glb?signature=temporary"
        self.succeeded_run(url)
        opener = FakeOpener(triangle_glb())
        with mock.patch.dict("os.environ", {"TRIPO_API_KEY": "must-not-reach-cdn"}):
            pipeline.download(self.run_dir, opener=opener)
        self.assertEqual(len(opener.calls), 1)
        request, timeout = opener.calls[0]
        self.assertEqual(request.full_url, url)
        self.assertEqual(request.get_method(), "GET")
        self.assertEqual(timeout, 120)
        self.assertNotIn("authorization", {key.lower() for key, _ in request.header_items()})

    def test_non_https_url_is_rejected_before_download(self):
        self.succeeded_run("http://cdn.example.test/model.glb")
        opener = FakeOpener(triangle_glb())
        with self.assertRaises(pipeline.PipelineError):
            pipeline.download(self.run_dir, opener=opener)
        self.assertEqual(opener.calls, [])
        self.assertFalse((self.run_dir / "model.glb").exists())

    def test_html_or_json_error_body_is_never_saved_as_model(self):
        for body in (b"<html>Expired download URL</html>", b'{"error":"denied"}'):
            with self.subTest(body=body):
                self.succeeded_run()
                with self.assertRaises(pipeline.PipelineError):
                    pipeline.download(self.run_dir, opener=FakeOpener(body))
                self.assertFalse((self.run_dir / "model.glb").exists())
                receipt = pipeline.read_json(self.run_dir / "receipt.json")
                self.assertFalse(receipt.get("model"))

    def test_truncated_glb_is_rejected(self):
        self.succeeded_run()
        with self.assertRaises(pipeline.PipelineError):
            pipeline.download(self.run_dir, opener=FakeOpener(triangle_glb()[:-4]))
        self.assertFalse((self.run_dir / "model.glb").exists())

    def test_download_recovers_saved_glb_after_final_receipt_write_failure(self):
        self.succeeded_run()
        content = triangle_glb()
        save_receipt = pipeline.save_receipt

        def fail_after_model_saved(directory, row, client=None):
            if "model" in row and (directory / "model.glb").exists():
                raise OSError("Simulated interruption before final receipt write")
            return save_receipt(directory, row, client)

        with mock.patch.object(pipeline, "save_receipt", side_effect=fail_after_model_saved):
            with self.assertRaises(OSError):
                pipeline.download(self.run_dir, opener=FakeOpener(content))
        pending = pipeline.read_json(self.run_dir / "receipt.json")
        self.assertEqual(pending["pending_model"]["sha256"], hashlib.sha256(content).hexdigest())
        self.assertNotIn("model", pending)
        self.assertEqual((self.run_dir / "model.glb").read_bytes(), content)

        opener = FakeOpener(b"Must not download again")
        recovered = pipeline.download(self.run_dir, opener=opener)
        self.assertEqual(opener.calls, [])
        self.assertNotIn("pending_model", recovered)
        self.assertEqual(recovered["model"]["sha256"], pending["pending_model"]["sha256"])
        self.assertEqual(recovered["review_status"], "raw_candidate_requires_visual_and_topology_review")
        self.assertEqual((self.run_dir / "model.glb.sha256").read_text().strip(),
                         hashlib.sha256(content).hexdigest() + "  model.glb")
        self.assertNotIn("pending_model", pipeline.read_json(self.run_dir / "receipt.json"))

    def test_existing_model_with_changed_bytes_is_not_overwritten(self):
        self.succeeded_run()
        content = triangle_glb()
        pipeline.download(self.run_dir, opener=FakeOpener(content))
        changed = content[:-1] + bytes([content[-1] ^ 1])
        (self.run_dir / "model.glb").write_bytes(changed)
        opener = FakeOpener(content)
        with self.assertRaises(pipeline.PipelineError):
            pipeline.download(self.run_dir, opener=opener)
        self.assertEqual(opener.calls, [])
        self.assertEqual((self.run_dir / "model.glb").read_bytes(), changed)


class RedirectTests(unittest.TestCase):
    def test_api_redirect_is_rejected_before_request_headers_can_be_copied(self):
        handler = pipeline.SafeRedirect(api=True)
        request = urllib.request.Request("https://api.tripo3d.ai/v2/openapi/task", method="POST",
                                         data=b"{}", headers={"Authorization": "Bearer private-key"})
        with mock.patch.object(urllib.request.HTTPRedirectHandler, "redirect_request") as redirect:
            with self.assertRaises(pipeline.PipelineError):
                handler.redirect_request(request, None, 303, "See Other", {},
                                         "https://other.example.test/task")
            redirect.assert_not_called()

    def test_download_redirect_cannot_downgrade_to_http(self):
        handler = pipeline.SafeRedirect()
        request = urllib.request.Request("https://cdn.example.test/model.glb")
        with mock.patch.object(urllib.request.HTTPRedirectHandler, "redirect_request") as redirect:
            with self.assertRaises(pipeline.PipelineError):
                handler.redirect_request(request, None, 302, "Found", {},
                                         "http://other.example.test/model.glb")
            redirect.assert_not_called()

    def test_https_download_redirect_does_not_forward_authorization(self):
        handler = pipeline.SafeRedirect()
        request = urllib.request.Request("https://cdn.example.test/model.glb",
                                         headers={"Authorization": "Bearer private-key"})
        redirected = handler.redirect_request(request, None, 302, "Found", {},
                                               "https://other.example.test/model.glb")
        self.assertEqual(redirected.full_url, "https://other.example.test/model.glb")
        self.assertNotIn("authorization", {key.lower() for key, _ in redirected.header_items()})


class BalanceTests(unittest.TestCase):
    def test_balance_uses_read_only_route_and_exposes_only_numeric_balances(self):
        client = mock.Mock()
        client.request.return_value = {
            "balance": 20, "frozen": 2.5, "available": 17.5, "private": "hidden", "user_id": 123}
        self.assertEqual(pipeline.balance(client=client), {"balance": 20, "frozen": 2.5, "available": 17.5})
        client.request.assert_called_once_with("GET", "/user/balance")

    def test_balance_drops_nonfinite_boolean_and_string_values(self):
        client = mock.Mock()
        client.request.return_value = {"balance": float("nan"), "frozen": True, "available": "42"}
        self.assertEqual(pipeline.balance(client=client), {})


if __name__ == "__main__":
    unittest.main()
