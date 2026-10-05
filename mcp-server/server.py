#!/usr/bin/env python3
"""MCPDock MCP 服务器：配置页 + streamable-http MCP 端点。

仅依赖 Python 标准库；构建/推送通过容器内的 docker CLI
（镜像中 apk 安装）经 /var/run/docker.sock 交给宿主机 daemon 执行。
"""
import json
import os
import re
import subprocess
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REGISTRY_ADDRESS = os.environ.get("REGISTRY_ADDRESS", "localhost:20070")
REGISTRY_API = os.environ.get("REGISTRY_API", "http://localhost:20070").rstrip("/")
PORT = int(os.environ.get("PORT", "8080"))

# 镜像名：小写字母数字段，段内允许 . _ -，段间用 /
NAME_RE = re.compile(
    r"^[a-z0-9]+(?:[._-][a-z0-9]+)*"
    r"(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*$"
)
TAG_RE = re.compile(r"^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}$")

CONFIG_PAGE = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MCPDock MCP 配置</title>
<style>
  body { font-family: system-ui, -apple-system, sans-serif; max-width: 720px;
         margin: 40px auto; padding: 0 16px; color: #1f2937; }
  h1 { font-size: 22px; }
  label { display: block; margin: 16px 0 8px; font-weight: 600; }
  input { width: 100%; box-sizing: border-box; padding: 8px 10px;
          font-size: 15px; border: 1px solid #d1d5db; border-radius: 6px; }
  pre { background: #111827; color: #e5e7eb; padding: 16px; border-radius: 8px;
        overflow-x: auto; font-size: 14px; }
  button { margin-top: 12px; padding: 8px 18px; font-size: 15px; cursor: pointer;
           background: #2563eb; color: #fff; border: none; border-radius: 6px; }
  button:hover { background: #1d4ed8; }
  #status { margin-left: 10px; color: #059669; }
  .hint { margin-top: 20px; color: #6b7280; font-size: 14px; line-height: 1.6; }
</style>
</head>
<body>
<h1>MCPDock MCP 配置</h1>
<label for="url">MCP 服务网址</label>
<input id="url" spellcheck="false" autocomplete="off">
<pre id="json"></pre>
<button id="copy">复制 JSON</button><span id="status"></span>
<p class="hint">
  把 JSON 添加到 Cursor 的 MCP 配置（设置 → MCP，或编辑
  <code>~/.cursor/mcp.json</code>）。保存后 AI 即可调用工具把项目镜像构建并推送到本仓库。
</p>
<script>
  const urlInput = document.getElementById('url');
  const jsonEl = document.getElementById('json');
  const statusEl = document.getElementById('status');
  urlInput.value = location.origin;
  function render() {
    const base = urlInput.value.trim().replace(/\\/+$/, '');
    const cfg = { mcpServers: { mcpdock: { url: base + '/mcp' } } };
    jsonEl.textContent = JSON.stringify(cfg, null, 2);
  }
  urlInput.addEventListener('input', render);
  render();
  document.getElementById('copy').addEventListener('click', async () => {
    await navigator.clipboard.writeText(jsonEl.textContent);
    statusEl.textContent = '已复制';
    setTimeout(() => { statusEl.textContent = ''; }, 2000);
  });
</script>
</body>
</html>
"""

TOOLS = [
    {
        "name": "build_and_push",
        "description": (
            "构建一个 Docker 项目并推送到 MCPDock 私有仓库。"
            "project_dir 是宿主机上含 Dockerfile 的项目目录绝对路径，"
            "image 是仓库内镜像名（可含 / 路径），tag 是标签。"
            "成功后返回推送引用 reference 与 digest。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string",
                                "description": "宿主机上项目目录的绝对路径"},
                "image": {"type": "string", "description": "仓库内镜像名"},
                "tag": {"type": "string", "description": "镜像标签"},
            },
            "required": ["project_dir", "image", "tag"],
            "additionalProperties": False,
        },
    },
    {
        "name": "list_images",
        "description": "列出私有仓库中的全部镜像及其 tag。",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
    },
]


class ToolError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def _run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def build_and_push(arguments):
    project_dir = arguments["project_dir"].strip()
    image = arguments["image"].strip()
    tag = arguments["tag"].strip()

    if not NAME_RE.match(image):
        raise ValueError("image 不是合法的镜像名")
    if not TAG_RE.match(tag):
        raise ValueError("tag 不是合法的标签")
    if not os.path.isdir(project_dir):
        raise ToolError("PROJECT_NOT_FOUND", f"目录不存在：{project_dir}")
    if not os.path.isfile(os.path.join(project_dir, "Dockerfile")):
        raise ToolError("PROJECT_NOT_FOUND",
                        f"目录下没有 Dockerfile：{project_dir}")

    reference = f"{REGISTRY_ADDRESS}/{image}:{tag}"

    build = _run(["docker", "build", "-t", reference, project_dir])
    if build.returncode != 0:
        raise ToolError("BUILD_FAILED",
                        (build.stdout + build.stderr).strip()[-2000:])

    push = _run(["docker", "push", reference])
    if push.returncode != 0:
        raise ToolError("PUSH_FAILED",
                        (push.stdout + push.stderr).strip()[-2000:])

    match = re.search(r"digest:\s*(sha256:[0-9a-f]+)", push.stdout)
    return {"reference": reference,
            "digest": match.group(1) if match else ""}


def list_images(_arguments):
    try:
        with urllib.request.urlopen(f"{REGISTRY_API}/v2/_catalog",
                                    timeout=10) as resp:
            catalog = json.load(resp)
    except (urllib.error.URLError, OSError) as exc:
        raise ToolError("REGISTRY_UNAVAILABLE", str(exc))

    repositories = []
    for name in catalog.get("repositories", []):
        quoted = urllib.request.quote(name, safe="/")
        try:
            with urllib.request.urlopen(
                    f"{REGISTRY_API}/v2/{quoted}/tags/list",
                    timeout=10) as resp:
                tags_data = json.load(resp)
        except (urllib.error.URLError, OSError) as exc:
            raise ToolError("REGISTRY_UNAVAILABLE", str(exc))
        repositories.append({"name": name,
                             "tags": tags_data.get("tags") or []})
    return {"repositories": repositories}


TOOL_IMPL = {
    "build_and_push": build_and_push,
    "list_images": list_images,
}


def rpc_result(payload):
    return {"content": [
                {"type": "text",
                 "text": json.dumps(payload, ensure_ascii=False)}],
            "structuredContent": payload}


def handle_rpc(message):
    """返回 (http_status, response_dict_or_None)；None 表示通知，无响应体。"""
    if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
        return 200, {"jsonrpc": "2.0", "id": None,
                     "error": {"code": -32600, "message": "无效请求"}}
    req_id = message.get("id")
    method = message.get("method")
    params = message.get("params") or {}

    if "id" not in message:
        return 202, None  # 通知

    def ok(result):
        return 200, {"jsonrpc": "2.0", "id": req_id, "result": result}

    def err(code, msg):
        return 200, {"jsonrpc": "2.0", "id": req_id,
                     "error": {"code": code, "message": msg}}

    if method == "initialize":
        return ok({"protocolVersion": "2025-06-18",
                   "capabilities": {"tools": {}},
                   "serverInfo": {"name": "mcpdock", "version": "0.1.0"}})
    if method == "ping":
        return ok({})
    if method == "tools/list":
        return ok({"tools": TOOLS})
    if method == "tools/call":
        if not isinstance(params, dict) or not isinstance(
                params.get("name"), str):
            return err(-32602, "缺少工具名 name")
        name = params["name"]
        arguments = params.get("arguments") or {}
        impl = TOOL_IMPL.get(name)
        if impl is None:
            return err(-32602, f"未知工具：{name}")
        if not isinstance(arguments, dict):
            return err(-32602, "arguments 必须是对象")
        try:
            payload = impl(arguments)
        except KeyError as exc:
            return err(-32602, f"缺少参数：{exc.args[0]}")
        except ValueError as exc:
            return err(-32602, str(exc))
        except ToolError as exc:
            return ok({"isError": True,
                       "content": [{"type": "text",
                                    "text": f"{exc.code}: {exc}"}]})
        return ok(rpc_result(payload))
    return err(-32601, f"未知方法：{method}")


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, body=None, content_type="application/json"):
        data = b"" if body is None else body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if data:
            self.wfile.write(data)

    def do_GET(self):
        if self.path.split("?", 1)[0] in ("/", ""):
            self._send(200, CONFIG_PAGE, "text/html; charset=utf-8")
        else:
            self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        if self.path.split("?", 1)[0] != "/mcp":
            self._send(404, json.dumps({"error": "not found"}))
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            message = json.loads(self.rfile.read(length) or b"null")
        except (ValueError, UnicodeDecodeError):
            self._send(200, json.dumps(
                {"jsonrpc": "2.0", "id": None,
                 "error": {"code": -32700, "message": "解析失败"}}))
            return
        status, response = handle_rpc(message)
        if response is None:
            self._send(202)
        else:
            self._send(status, json.dumps(response, ensure_ascii=False))

    def log_message(self, fmt, *args):  # 保持容器日志简洁
        pass


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"MCPDock MCP server listening on :{PORT}")
    server.serve_forever()
