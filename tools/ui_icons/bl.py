#!/usr/bin/env python3
"""把一段 Python 发给正在运行的 Blender（blender-mcp 插件，localhost:9876）执行。
用法：python3 tools/ui_icons/bl.py <script.py> [--timeout 300]"""
import socket, json, sys
path = sys.argv[1]
timeout = float(sys.argv[sys.argv.index("--timeout") + 1]) if "--timeout" in sys.argv else 300
code = open(path, encoding="utf-8").read()
s = socket.create_connection(("127.0.0.1", 9876), timeout=timeout)
s.sendall(json.dumps({"type": "execute_code", "params": {"code": code}}).encode())
buf = b""
s.settimeout(timeout)
while True:
    c = s.recv(1 << 20)
    if not c:
        break
    buf += c
    try:
        r = json.loads(buf.decode())
        break
    except Exception:
        continue
r = json.loads(buf.decode())
res = r.get("result")
if isinstance(res, dict):
    print(res.get("result", res))
else:
    print(r)
if r.get("status") != "success":
    sys.exit(1)
