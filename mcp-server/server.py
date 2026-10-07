#!/usr/bin/env python3
"""MCPDock MCP 服务器：配置页 + streamable-http MCP 端点 + 镜像上传端点。

仅依赖 Python 标准库；上传的镜像经仓库 HTTP API 推入，不使用 Docker。
"""
import hashlib
import html
import json
import os
import re
import shutil
import tarfile
import tempfile
import threading
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REGISTRY_API = os.environ.get("REGISTRY_API", "http://localhost:20070").rstrip("/")
META_DIR = os.environ.get("META_DIR", "/data")
META_FILE = os.path.join(META_DIR, "images.json")
PORT = int(os.environ.get("PORT", "8080"))

_meta_lock = threading.Lock()

# 镜像名：小写字母数字段，段内允许 . _ -，段间用 /
NAME_RE = re.compile(
    r"^[a-z0-9]+(?:[._-][a-z0-9]+)*"
    r"(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*$"
)
TAG_RE = re.compile(r"^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}$")

OCI_MANIFEST = "application/vnd.oci.image.manifest.v1+json"
OCI_CONFIG = "application/vnd.oci.image.config.v1+json"
OCI_LAYER = "application/vnd.oci.image.layer.v1.tar"

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
  h2 { font-size: 18px; margin-top: 40px; }
  .img { border: 1px solid #e5e7eb; border-radius: 8px; padding: 12px 16px;
         margin: 12px 0; }
  .img .name { font-weight: 600; font-size: 16px; }
  .img .tags { margin-left: 8px; color: #6b7280; font-size: 13px; }
  .img .summary { margin: 8px 0 4px; }
  .readme { color: #374151; font-size: 14px; line-height: 1.6; }
  .readme h1, .readme h2, .readme h3, .readme h4, .readme h5, .readme h6 {
    font-size: 15px; margin: 14px 0 6px; }
  .readme p, .readme ul, .readme ol { margin: 6px 0; }
  .readme pre { font-size: 13px; padding: 12px; }
  .readme code { background: #f3f4f6; padding: 1px 4px; border-radius: 4px; }
  .readme pre code { background: none; padding: 0; }
  .readme table { border-collapse: collapse; margin: 6px 0; }
  .readme th, .readme td { border: 1px solid #e5e7eb; padding: 4px 8px;
                           text-align: left; }
  .muted { color: #9ca3af; }
  .error { color: #dc2626; }
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
  <code>~/.cursor/mcp.json</code>）。保存后 AI 即可把项目镜像上传到本仓库并登记简介。
</p>
<h2>仓库镜像</h2>
<input id="filter" placeholder="按镜像名、简介、README 筛选" spellcheck="false" autocomplete="off">
<div id="images"><!--IMAGES--></div>
<script>
  document.getElementById('filter').addEventListener('input', (e) => {
    const kw = e.target.value.trim().toLowerCase();
    document.querySelectorAll('#images .img').forEach((el) => {
      el.style.display = !kw || el.dataset.search.includes(kw) ? '' : 'none';
    });
  });
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


REQUIRED_SECTIONS = ("## 功能", "## 使用", "## 配置")

README_TEMPLATE = """## 功能
- <镜像提供的能力，逐条写>

## 使用
```yaml
services:
  <服务名>:
    image: ${REGISTRY}/<image>:latest
    ports:
      - "<宿主机端口>:<容器端口>"
    environment:
      <变量名>: <值>
    volumes:
      - <卷或宿主机目录>:<容器路径>
```
<启动后如何访问或调用：端口、接口、首次初始化步骤>

## 配置
| 环境变量 | 必填 | 默认值 | 说明 |
|---|---|---|---|
| <变量名> | 是/否 | <默认值> | <含义> |

<端口、数据卷与依赖的其它服务>"""


def tools_for(base_url):
    upload = f"{base_url}/upload?image=<image>&tag=<版本>&tag=latest"
    return [
        {
            "name": "set_image_info",
            "description": (
                "登记 MCPDock 私有仓库中镜像的一句话简介 summary 与镜像 README readme。"
                "把项目镜像上传到仓库的完整流程（在用户本机执行命令）：\n"
                "1. 确定版本 tag：优先取项目版本号（如 package.json、pyproject.toml "
                "中的 version），没有则取 git rev-parse --short HEAD；"
                "每次上传同时打版本 tag 与 latest。\n"
                "2. docker build -t <image>:<版本> <项目目录>\n"
                "3. docker save -o <临时文件>.tar <image>:<版本>\n"
                f"4. curl --fail-with-body -T <临时文件>.tar '{upload}'\n"
                "5. 阅读项目的 README、文档与代码，自行撰写 summary 与 readme，"
                "调用本工具登记，不要向用户询问；完成后删除临时文件。\n"
                "image 为仓库内镜像名（小写，可含 / 路径）。"
                "登记按镜像名保存，与 tag 无关，再次登记覆盖旧值。\n"
                "readme 为 Markdown，必须包含 " + "、".join(REQUIRED_SECTIONS)
                + " 三个二级标题（缺任一节登记失败），可另加其它节。"
                "使用节给出可直接复制的 docker-compose.yml，镜像写作 "
                "${REGISTRY}/<image>:latest（REGISTRY 为仓库地址）。模板：\n"
                + README_TEMPLATE
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "image": {"type": "string", "description": "仓库内镜像名"},
                    "summary": {"type": "string",
                                "description": "一句话说明镜像是什么"},
                    "readme": {"type": "string",
                               "description": "镜像 README（Markdown），"
                                              "含 ## 功能、## 使用、## 配置 三节"},
                },
                "required": ["image", "summary", "readme"],
                "additionalProperties": False,
            },
        },
        {
            "name": "list_images",
            "description": "列出私有仓库中的全部镜像及其 tag、简介与 README。",
            "inputSchema": {
                "type": "object",
                "properties": {},
                "additionalProperties": False,
            },
        },
        {
            "name": "search_images",
            "description": (
                "按关键字查找私有仓库中的镜像，"
                "在镜像名、简介 summary 与 README readme 中做大小写不敏感匹配。"
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "keyword": {"type": "string", "description": "查找关键字"},
                },
                "required": ["keyword"],
                "additionalProperties": False,
            },
        },
    ]


class ToolError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def load_meta():
    try:
        with open(META_FILE, encoding="utf-8") as fh:
            data = json.load(fh)
    except (FileNotFoundError, ValueError, OSError):
        return {}
    return data if isinstance(data, dict) else {}


def save_meta(meta):
    os.makedirs(META_DIR, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=META_DIR)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(meta, fh, ensure_ascii=False)
        os.replace(tmp, META_FILE)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _registry(method, url, data=None, headers=None, timeout=600):
    """返回 (status, headers, body)；HTTP 错误码不抛异常，连接失败抛 REGISTRY_UNAVAILABLE。"""
    req = urllib.request.Request(url, data=data, method=method,
                                 headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.headers, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.headers, exc.read()
    except (urllib.error.URLError, OSError) as exc:
        raise ToolError("REGISTRY_UNAVAILABLE", str(exc))


def _repo_url(image):
    return f"{REGISTRY_API}/v2/{urllib.parse.quote(image, safe='/')}"


# ---------- 上传 ----------

def _digest_of(fileobj):
    h = hashlib.sha256()
    size = 0
    first = b""
    while True:
        chunk = fileobj.read(1024 * 1024)
        if not chunk:
            break
        if not first:
            first = chunk[:4]
        h.update(chunk)
        size += len(chunk)
    return "sha256:" + h.hexdigest(), size, first


def _layer_media_type(head):
    if head[:2] == b"\x1f\x8b":
        return OCI_LAYER + "+gzip"
    if head[:4] == b"\x28\xb5\x2f\xfd":
        return OCI_LAYER + "+zstd"
    return OCI_LAYER


def _push_blob(image, digest, size, open_body):
    status, _, _ = _registry("HEAD", f"{_repo_url(image)}/blobs/{digest}")
    if status == 200:
        return
    status, headers, body = _registry(
        "POST", f"{_repo_url(image)}/blobs/uploads/", data=b"")
    if status != 202 or not headers.get("Location"):
        raise ToolError("PUSH_FAILED",
                        f"开始上传 blob 失败（{status}）：{body[:500]!r}")
    location = urllib.parse.urljoin(REGISTRY_API + "/", headers["Location"])
    sep = "&" if "?" in location else "?"
    with open_body() as fh:
        status, _, body = _registry(
            "PUT", f"{location}{sep}digest={digest}", data=fh,
            headers={"Content-Type": "application/octet-stream",
                     "Content-Length": str(size)})
    if status != 201:
        raise ToolError("PUSH_FAILED",
                        f"上传 blob {digest} 失败（{status}）：{body[:500]!r}")


def push_archive(archive_path, image, tags):
    try:
        tar = tarfile.open(archive_path, "r:*")
    except (tarfile.TarError, OSError) as exc:
        raise ToolError("INVALID_IMAGE_ARCHIVE", f"无法解析 tar：{exc}")
    with tar:
        def member(path):
            try:
                fh = tar.extractfile(path)
            except KeyError:
                fh = None
            if fh is None:
                raise ToolError("INVALID_IMAGE_ARCHIVE", f"缺少文件：{path}")
            return fh

        try:
            entries = json.load(member("manifest.json"))
            entry = entries[0]
            config_path = entry["Config"]
            layer_paths = entry["Layers"]
        except ToolError:
            raise
        except (ValueError, KeyError, IndexError, TypeError) as exc:
            raise ToolError("INVALID_IMAGE_ARCHIVE",
                            f"manifest.json 格式不正确：{exc}")

        descriptors = []
        for path, media_type in ([(config_path, OCI_CONFIG)]
                                 + [(p, None) for p in layer_paths]):
            with member(path) as fh:
                digest, size, head = _digest_of(fh)
            _push_blob(image, digest, size, lambda p=path: member(p))
            descriptors.append({
                "mediaType": media_type or _layer_media_type(head),
                "digest": digest,
                "size": size,
            })

    manifest = json.dumps({
        "schemaVersion": 2,
        "mediaType": OCI_MANIFEST,
        "config": descriptors[0],
        "layers": descriptors[1:],
    }).encode()
    digest = "sha256:" + hashlib.sha256(manifest).hexdigest()
    for tag in tags:
        status, headers, body = _registry(
            "PUT", f"{_repo_url(image)}/manifests/{tag}", data=manifest,
            headers={"Content-Type": OCI_MANIFEST})
        if status != 201:
            raise ToolError("PUSH_FAILED",
                            f"写入 tag {tag} 失败（{status}）：{body[:500]!r}")
        digest = headers.get("Docker-Content-Digest") or digest
    return {"image": image, "tags": tags, "digest": digest}


# ---------- Markdown ----------

_HEADING_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*$")
_UL_RE = re.compile(r"^\s*[-*]\s+(.*)$")
_OL_RE = re.compile(r"^\s*\d+[.)]\s+(.*)$")
_TABLE_SEP_RE = re.compile(r"^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?$")
_INLINE_RE = re.compile(r"`([^`]+)`|\*\*(.+?)\*\*|\[([^\]]+)\]\(([^)\s]+)\)")


def _lines_outside_fences(text):
    in_fence = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("```"):
            in_fence = not in_fence
        elif not in_fence:
            yield stripped


def missing_sections(readme):
    present = set(_lines_outside_fences(readme))
    return [s for s in REQUIRED_SECTIONS if s not in present]


def _inline(text):
    out = []
    pos = 0
    for m in _INLINE_RE.finditer(text):
        out.append(html.escape(text[pos:m.start()]))
        code, bold, label, url = m.groups()
        if code is not None:
            out.append(f"<code>{html.escape(code)}</code>")
        elif bold is not None:
            out.append(f"<strong>{_inline(bold)}</strong>")
        elif url.lower().startswith(("http://", "https://")):
            out.append(f'<a href="{html.escape(url)}" target="_blank" '
                       f'rel="noopener noreferrer">{_inline(label)}</a>')
        else:
            out.append(html.escape(m.group(0)))
        pos = m.end()
    out.append(html.escape(text[pos:]))
    return "".join(out)


def _starts_block(line):
    stripped = line.strip()
    return (stripped.startswith(("```", "|")) or _HEADING_RE.match(stripped)
            or _UL_RE.match(line) or _OL_RE.match(line))


def _table(rows):
    def cells(row):
        return [c.strip() for c in row.strip("|").split("|")]

    if len(rows) < 2 or not _TABLE_SEP_RE.match(rows[1]):
        return f"<p>{_inline(' '.join(rows))}</p>"
    head = "".join(f"<th>{_inline(c)}</th>" for c in cells(rows[0]))
    body = "".join(
        "<tr>" + "".join(f"<td>{_inline(c)}</td>" for c in cells(r)) + "</tr>"
        for r in rows[2:])
    return f"<table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table>"


def render_markdown(text):
    """渲染 Markdown 常用子集；所有文本先转义，原始 HTML 只作为文本显示。"""
    lines = text.splitlines()
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if not stripped:
            i += 1
        elif stripped.startswith("```"):
            i += 1
            code = []
            while i < len(lines) and not lines[i].strip().startswith("```"):
                code.append(lines[i])
                i += 1
            i += 1
            out.append(f"<pre><code>{html.escape(chr(10).join(code))}</code></pre>")
        elif _HEADING_RE.match(stripped):
            m = _HEADING_RE.match(stripped)
            level = len(m.group(1))
            out.append(f"<h{level}>{_inline(m.group(2))}</h{level}>")
            i += 1
        elif stripped.startswith("|"):
            rows = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                rows.append(lines[i].strip())
                i += 1
            out.append(_table(rows))
        elif _UL_RE.match(line) or _OL_RE.match(line):
            tag, regex = ("ul", _UL_RE) if _UL_RE.match(line) else ("ol", _OL_RE)
            items = []
            while i < len(lines) and regex.match(lines[i]):
                items.append(f"<li>{_inline(regex.match(lines[i]).group(1))}</li>")
                i += 1
            out.append(f"<{tag}>{''.join(items)}</{tag}>")
        else:
            para = [stripped]
            i += 1
            while (i < len(lines) and lines[i].strip()
                   and not _starts_block(lines[i])):
                para.append(lines[i].strip())
                i += 1
            out.append(f"<p>{_inline(' '.join(para))}</p>")
    return "".join(out)


# ---------- 工具 ----------

def set_image_info(arguments):
    image = arguments["image"].strip()
    summary = arguments["summary"].strip()
    readme = arguments["readme"].strip()
    if not NAME_RE.match(image):
        raise ValueError("image 不是合法的镜像名")
    if not summary:
        raise ValueError("summary 不能为空")
    if not readme:
        raise ValueError("readme 不能为空")
    missing = missing_sections(readme)
    if missing:
        raise ValueError("readme 缺少必需节：" + "、".join(missing))

    status, _, body = _registry("GET", f"{_repo_url(image)}/tags/list")
    tags = []
    if status == 200:
        try:
            tags = json.loads(body).get("tags") or []
        except ValueError:
            tags = []
    if not tags:
        raise ToolError("IMAGE_NOT_FOUND", f"仓库中没有镜像：{image}")

    try:
        with _meta_lock:
            meta = load_meta()
            meta[image] = {"summary": summary, "readme": readme}
            save_meta(meta)
    except OSError as exc:
        raise ToolError("META_WRITE_FAILED", str(exc))
    return {"image": image, "summary": summary, "readme": readme}


def _catalog_repositories():
    status, _, body = _registry("GET", f"{REGISTRY_API}/v2/_catalog",
                                timeout=10)
    if status != 200:
        raise ToolError("REGISTRY_UNAVAILABLE", f"列出镜像失败（{status}）")
    meta = load_meta()
    repositories = []
    for name in json.loads(body).get("repositories") or []:
        status, _, body = _registry("GET", f"{_repo_url(name)}/tags/list",
                                    timeout=10)
        if status != 200:
            raise ToolError("REGISTRY_UNAVAILABLE",
                            f"列出 {name} 的 tag 失败（{status}）")
        info = meta.get(name, {})
        repositories.append({
            "name": name,
            "tags": json.loads(body).get("tags") or [],
            "summary": info.get("summary", ""),
            "readme": info.get("readme", ""),
        })
    return repositories


def list_images(_arguments):
    return {"repositories": _catalog_repositories()}


def search_images(arguments):
    keyword = arguments["keyword"].strip().lower()
    if not keyword:
        raise ValueError("keyword 不能为空")
    matched = [
        repo for repo in _catalog_repositories()
        if keyword in repo["name"].lower()
        or keyword in repo["summary"].lower()
        or keyword in repo["readme"].lower()
    ]
    return {"repositories": matched}


def render_images():
    try:
        repositories = _catalog_repositories()
    except ToolError as exc:
        return f'<p class="error">仓库不可访问：{html.escape(str(exc))}</p>'
    if not repositories:
        return '<p class="muted">暂无镜像</p>'
    items = []
    for repo in repositories:
        search = " ".join(
            (repo["name"], repo["summary"], repo["readme"])).lower()
        summary = (html.escape(repo["summary"]) if repo["summary"]
                   else '<span class="muted">未登记</span>')
        items.append(
            f'<div class="img" data-search="{html.escape(search)}">'
            f'<span class="name">{html.escape(repo["name"])}</span>'
            f'<span class="tags">{html.escape(", ".join(repo["tags"]))}</span>'
            f'<div class="summary">{summary}</div>'
            f'<div class="readme">{render_markdown(repo["readme"])}</div>'
            '</div>')
    return "".join(items)


TOOL_IMPL = {
    "set_image_info": set_image_info,
    "list_images": list_images,
    "search_images": search_images,
}


def rpc_result(payload):
    return {"content": [
                {"type": "text",
                 "text": json.dumps(payload, ensure_ascii=False)}],
            "structuredContent": payload}


def handle_rpc(message, base_url):
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
                   "serverInfo": {"name": "mcpdock", "version": "0.3.0"}})
    if method == "ping":
        return ok({})
    if method == "tools/list":
        return ok({"tools": tools_for(base_url)})
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
        except (ValueError, AttributeError) as exc:
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

    def _send_json(self, status, payload):
        self._send(status, json.dumps(payload, ensure_ascii=False))

    def _base_url(self):
        proto = self.headers.get("X-Forwarded-Proto", "http")
        host = self.headers.get("Host", f"localhost:{PORT}")
        return f"{proto}://{host}"

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", ""):
            page = CONFIG_PAGE.replace("<!--IMAGES-->", render_images())
            self._send(200, page, "text/html; charset=utf-8")
        elif path == "/mcp":
            # streamable-http 客户端把 404 视为会话失效并反复重连，不提供 SSE 流须回 405
            self.send_response(405)
            self.send_header("Allow", "POST")
            self.send_header("Content-Length", "0")
            self.end_headers()
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
        status, response = handle_rpc(message, self._base_url())
        if response is None:
            self._send(202)
        else:
            self._send(status, json.dumps(response, ensure_ascii=False))

    def do_PUT(self):
        path, _, query = self.path.partition("?")
        if path != "/upload":
            self._send(404, json.dumps({"error": "not found"}))
            return
        params = urllib.parse.parse_qs(query)
        image = (params.get("image") or [""])[0].strip()
        tags = list(dict.fromkeys(t.strip() for t in params.get("tag", [])))
        length = self.headers.get("Content-Length")

        def fail(status, code, message):
            self.close_connection = True
            self._send_json(status, {"error": code, "message": message})

        if not NAME_RE.match(image):
            return fail(400, "INVALID_ARGUMENT", "image 不是合法的镜像名")
        if not tags:
            return fail(400, "INVALID_ARGUMENT", "缺少 tag")
        bad = [t for t in tags if not TAG_RE.match(t)]
        if bad:
            return fail(400, "INVALID_ARGUMENT",
                        "tag 不是合法的标签：" + "、".join(bad))
        if length is None or not length.isdigit():
            return fail(400, "INVALID_ARGUMENT", "缺少 Content-Length")

        work = tempfile.mkdtemp()
        try:
            archive = os.path.join(work, "image.tar")
            remaining = int(length)
            with open(archive, "wb") as fh:
                while remaining > 0:
                    chunk = self.rfile.read(min(remaining, 1024 * 1024))
                    if not chunk:
                        break
                    fh.write(chunk)
                    remaining -= len(chunk)
            if remaining > 0:
                return fail(400, "INVALID_ARGUMENT", "请求体不完整")
            try:
                result = push_archive(archive, image, tags)
            except ToolError as exc:
                status = 400 if exc.code == "INVALID_IMAGE_ARCHIVE" else 502
                return fail(status, exc.code, str(exc))
            self._send_json(200, result)
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def log_message(self, fmt, *args):  # 保持容器日志简洁
        pass


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"MCPDock MCP server listening on :{PORT}")
    server.serve_forever()
