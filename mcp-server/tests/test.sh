#!/usr/bin/env bash
# mcp-server 黑盒测试：自启临时 registry 与本服务进程，
# 通过 HTTP / JSON-RPC 验证配置页、tools、PUT /upload、set_image_info、
# list_images、search_images 与错误。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

freeport() {
  python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'
}

RPORT="$(freeport)"
SPORT="$(freeport)"
REGNAME="mcpdock-mcp-test-$$"
WORK_DIR="$(mktemp -d)"
META_DIR="$(mktemp -d)"
REPO="mcpdock-test/hello"
REPO2="mcpdock-test/plain"
TAG="test-tag"
LOCAL_IMAGE="mcpdock-test-local-$$:${TAG}"
PULLED="localhost:${RPORT}/${REPO}:${TAG}"
REFERENCE2="localhost:${RPORT}/${REPO2}:${TAG}"
CONTENT="mcpdock-mcp-$(date +%s)-$RANDOM"

cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  docker rm -f "$REGNAME" >/dev/null 2>&1 || true
  docker rmi -f "$LOCAL_IMAGE" "$PULLED" "$REFERENCE2" >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR" "$META_DIR"
}
trap cleanup EXIT

pass() { echo "PASS: $1"; }

# 临时 registry
docker run -d --name "$REGNAME" -p "${RPORT}:5000" registry:2 >/dev/null

# 在宿主机直接起服务进程（测试环境需有 python3 与 docker CLI）
REGISTRY_API="http://localhost:${RPORT}" \
META_DIR="$META_DIR" \
PORT="$SPORT" python3 "$ROOT/server.py" >/dev/null 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 60); do
  curl -s -o /dev/null "http://localhost:${SPORT}/" && break
  sleep 1
done
for _ in $(seq 1 60); do
  curl -s -o /dev/null "http://localhost:${RPORT}/v2/" && break
  sleep 1
done

# 本机构建并导出镜像（模拟客户端）
mkdir -p "$WORK_DIR/proj"
printf '%s' "$CONTENT" > "$WORK_DIR/proj/content.txt"
printf 'FROM scratch\nCOPY content.txt /content.txt\nCMD ["/content.txt"]\n' > "$WORK_DIR/proj/Dockerfile"
docker build -q -t "$LOCAL_IMAGE" "$WORK_DIR/proj" >/dev/null
docker save -o "$WORK_DIR/image.tar" "$LOCAL_IMAGE"
printf 'not a tar' > "$WORK_DIR/garbage.tar"

export SPORT RPORT WORK_DIR META_DIR REPO REPO2 TAG PULLED REFERENCE2 CONTENT REGNAME

python3 - <<'PY'
import json
import os
import subprocess
import urllib.error
import urllib.parse
import urllib.request

SPORT = os.environ["SPORT"]
RPORT = os.environ["RPORT"]
WORK_DIR = os.environ["WORK_DIR"]
REPO = os.environ["REPO"]
REPO2 = os.environ["REPO2"]
TAG = os.environ["TAG"]
PULLED = os.environ["PULLED"]
REFERENCE2 = os.environ["REFERENCE2"]
CONTENT = os.environ["CONTENT"]
BASE = f"http://localhost:{SPORT}"
URL = f"{BASE}/mcp"
_id = 0

def rpc(method, params=None):
    global _id
    _id += 1
    msg = {"jsonrpc": "2.0", "id": _id, "method": method}
    if params is not None:
        msg["params"] = params
    req = urllib.request.Request(
        URL, data=json.dumps(msg).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)

def call(name, arguments):
    return rpc("tools/call", {"name": name, "arguments": arguments})

def payload_of(r):
    return json.loads(r["result"]["content"][0]["text"])

def upload(path, image, tags):
    with open(path, "rb") as fh:
        data = fh.read()
    query = urllib.parse.urlencode(
        [("image", image)] + [("tag", t) for t in tags])
    req = urllib.request.Request(
        f"{BASE}/upload?{query}", data=data, method="PUT")
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, json.load(resp)
    except urllib.error.HTTPError as exc:
        return exc.code, json.load(exc)

def expect(cond, msg):
    if not cond:
        raise AssertionError(msg)

def registry_tags(image):
    with urllib.request.urlopen(
            f"http://localhost:{RPORT}/v2/{image}/tags/list") as resp:
        return set(json.load(resp).get("tags") or [])

def manifest_digest(image, tag):
    req = urllib.request.Request(
        f"http://localhost:{RPORT}/v2/{image}/manifests/{tag}", method="HEAD",
        headers={"Accept": "application/vnd.oci.image.manifest.v1+json"})
    with urllib.request.urlopen(req) as resp:
        return resp.headers["Docker-Content-Digest"]

def page_text():
    with urllib.request.urlopen(f"{BASE}/") as resp:
        expect(resp.status == 200, f"GET / 状态异常：{resp.status}")
        return resp.read().decode()

# 配置页
page = page_text()
expect("<html" in page and "mcpServers" in page, "配置页内容不正确")
expect('id="filter"' in page, "页面缺少筛选框")
print("PASS: GET / 返回配置页与筛选框")

# GET /mcp 不提供 SSE 流
try:
    urllib.request.urlopen(urllib.request.Request(
        URL, headers={"Accept": "text/event-stream"}))
    raise AssertionError("GET /mcp 应返回 405")
except urllib.error.HTTPError as exc:
    expect(exc.code == 405 and exc.headers.get("Allow") == "POST",
           f"GET /mcp 应返回 405 Allow: POST：{exc.code} {exc.headers.get('Allow')}")
print("PASS: GET /mcp 返回 405 Allow: POST")

# initialize
r = rpc("initialize", {})
expect(r["result"]["protocolVersion"] == "2025-06-18", "initialize 失败")
print("PASS: initialize")

# tools/list
r = rpc("tools/list", {})
tools = {t["name"]: t for t in r["result"]["tools"]}
expect(set(tools) == {"set_image_info", "list_images", "search_images"},
       f"工具列表异常：{set(tools)}")
desc = tools["set_image_info"]["description"]
expect(f"{BASE}/upload" in desc, "set_image_info 说明缺少上传地址")
for text in ("## 功能", "## 使用", "## 配置", "${REGISTRY}", "pull_policy: always"):
    expect(text in desc, f"set_image_info 说明缺少 {text!r}")
expect(tools["set_image_info"]["inputSchema"]["required"]
       == ["image", "summary", "readme"], "set_image_info 参数应为 image、summary、readme")
print("PASS: tools/list 返回三个工具，说明含上传地址、必需节、${REGISTRY} 写法与 pull_policy")

# 空仓库
expect(payload_of(call("list_images", {}))["repositories"] == [],
       "空仓库应返回空列表")
print("PASS: list_images 空仓库")
expect("暂无镜像" in page_text(), "空仓库页面应显示暂无镜像")
print("PASS: GET / 空仓库显示暂无镜像")

# 上传 docker save 文件，一次打多个 tag（重复值只算一次）
status, body = upload(f"{WORK_DIR}/image.tar", REPO, [TAG, "latest", TAG])
expect(status == 200, f"上传失败：{status} {body}")
expect(body["image"] == REPO and body["tags"] == [TAG, "latest"],
       f"上传结果异常：{body}")
expect(body["digest"].startswith("sha256:"), f"digest 异常：{body}")
print("PASS: PUT /upload 返回 image、去重后的 tags、digest")
expect(registry_tags(REPO) == {TAG, "latest"},
       f"仓库 tag 异常：{registry_tags(REPO)}")
expect(manifest_digest(REPO, TAG) == manifest_digest(REPO, "latest")
       == body["digest"], "各 tag 应指向同一 manifest")
print("PASS: 多个 tag 写入仓库且指向同一 manifest")

# 从仓库 pull 回来内容一致
subprocess.run(["docker", "pull", "-q", PULLED], check=True,
               stdout=subprocess.DEVNULL)
cid = subprocess.run(["docker", "create", PULLED], check=True,
                     capture_output=True, text=True).stdout.strip()
subprocess.run(["docker", "cp", f"{cid}:/content.txt",
                f"{WORK_DIR}/pulled.txt"], check=True,
               stdout=subprocess.DEVNULL)
subprocess.run(["docker", "rm", cid], check=True, stdout=subprocess.DEVNULL)
with open(f"{WORK_DIR}/pulled.txt") as fh:
    expect(fh.read() == CONTENT, "pull 回来的内容与上传的不一致")
print("PASS: 上传的镜像可 pull 且内容一致")

# 登记简介与 README
SUMMARY = "一个测试用的 hello 镜像"
README = """## 功能
- 输出问候，用于验证上传链路

## 使用
```yaml
services:
  hello:
    image: ${REGISTRY}/mcpdock-test/hello:latest
```
<script>alert(1)</script>

## 配置
| 环境变量 | 必填 | 默认值 | 说明 |
|---|---|---|---|
| GREETING | 否 | hi | 问候语 |

[文档](https://example.com/doc) [坏链接](javascript:alert(1))"""
r = call("set_image_info",
         {"image": REPO, "summary": SUMMARY, "readme": README})
expect(not r["result"].get("isError"), f"set_image_info 失败：{r}")
expect(payload_of(r) == {"image": REPO, "summary": SUMMARY,
                         "readme": README}, f"登记结果异常：{r}")
print("PASS: set_image_info 登记简介与 README")

# README 缺少必需节（围栏代码块内的标题不算）
r = call("set_image_info", {"image": REPO, "summary": SUMMARY,
                            "readme": "## 功能\nx\n```\n## 使用\n```"})
expect(r.get("error", {}).get("code") == -32602
       and "## 使用" in r["error"]["message"]
       and "## 配置" in r["error"]["message"]
       and "## 功能" not in r["error"]["message"],
       f"缺少必需节应返回 -32602 并列出 ## 使用、## 配置：{r}")
print("PASS: README 缺少必需节返回参数错误并列出缺少的节")

# 未登记的镜像（直接推送）
subprocess.run(["docker", "tag", PULLED, REFERENCE2], check=True)
subprocess.run(["docker", "push", "-q", REFERENCE2], check=True,
               stdout=subprocess.DEVNULL)

found = {x["name"]: x for x in
         payload_of(call("list_images", {}))["repositories"]}
entry = found.get(REPO)
expect(entry is not None and set(entry["tags"]) == {TAG, "latest"},
       f"列表中未找到 {REPO} 的 tag：{found}")
expect(entry["summary"] == SUMMARY and entry["readme"] == README,
       f"简介或 README 异常：{entry}")
plain = found.get(REPO2)
expect(plain is not None and plain["summary"] == ""
       and plain["readme"] == "", f"未登记镜像简介应为空：{plain}")
print("PASS: list_images 返回镜像、tag 与简介，未登记的为空")

# search_images
names = {x["name"] for x in
         payload_of(call("search_images", {"keyword": "问候"}))["repositories"]}
expect(names == {REPO}, f"搜索 '问候' 应只命中 {REPO}：{names}")
names = {x["name"] for x in
         payload_of(call("search_images", {"keyword": "PLAIN"}))["repositories"]}
expect(names == {REPO2}, f"搜索 'PLAIN' 应命中 {REPO2}：{names}")
expect(payload_of(call("search_images", {"keyword": "不存在xyz"}))
       ["repositories"] == [], "无匹配应返回空列表")
print("PASS: search_images 按名称与 README 查找")

# 网页镜像列表
page = page_text()
for text in (REPO, TAG, SUMMARY, REPO2, "未登记"):
    expect(text in page, f"页面缺少 {text!r}")
print("PASS: GET / 列出镜像、tag、简介，未登记的标明未登记")

for text in ("<h2>功能</h2>", "<li>输出问候，用于验证上传链路</li>",
             "<pre><code>services:", "<th>环境变量</th>", "<td>GREETING</td>",
             '<a href="https://example.com/doc"',
             "&lt;script&gt;alert(1)&lt;/script&gt;"):
    expect(text in page, f"README 渲染缺少 {text!r}")
expect("<script>alert" not in page and 'href="javascript:' not in page,
       "README 中的 HTML 与非 http(s) 链接不应生效")
print("PASS: GET / 按 Markdown 渲染 README，HTML 与非 http(s) 链接按文本显示")

r = call("set_image_info", {"image": REPO2, "summary": "<b>粗体</b>",
                            "readme": "## 功能\na\n## 使用\nb\n## 配置\nc"})
expect(not r["result"].get("isError"), f"登记失败：{r}")
page = page_text()
expect("&lt;b&gt;粗体&lt;/b&gt;" in page and "<b>粗体" not in page,
       "页面未对简介做 HTML 转义")
print("PASS: GET / 简介内容经 HTML 转义")

# 错误：上传参数不合法
status, body = upload(f"{WORK_DIR}/image.tar", "Bad Name", [TAG])
expect(status == 400 and body["error"] == "INVALID_ARGUMENT",
       f"非法镜像名应返回 400 INVALID_ARGUMENT：{status} {body}")
status, body = upload(f"{WORK_DIR}/image.tar", REPO, [])
expect(status == 400 and body["error"] == "INVALID_ARGUMENT",
       f"没有 tag 应返回 400 INVALID_ARGUMENT：{status} {body}")
status, body = upload(f"{WORK_DIR}/image.tar", REPO, ["good-tag", "bad tag"])
expect(status == 400 and body["error"] == "INVALID_ARGUMENT",
       f"含非法 tag 应返回 400 INVALID_ARGUMENT：{status} {body}")
expect("good-tag" not in registry_tags(REPO), "含非法 tag 时不应写入任何 tag")
print("PASS: 上传非法镜像名、没有 tag、含非法 tag 返回 INVALID_ARGUMENT 且不写入")

# 错误：上传内容不是镜像文件
status, body = upload(f"{WORK_DIR}/garbage.tar", REPO, ["bad"])
expect(status == 400 and body["error"] == "INVALID_IMAGE_ARCHIVE",
       f"非镜像文件应返回 400 INVALID_IMAGE_ARCHIVE：{status} {body}")
print("PASS: 上传非镜像文件返回 INVALID_IMAGE_ARCHIVE")

# 错误：登记不存在的镜像
r = call("set_image_info", {"image": "mcpdock-test/nope",
                            "summary": SUMMARY, "readme": README})
expect(r["result"].get("isError")
       and "IMAGE_NOT_FOUND" in r["result"]["content"][0]["text"],
       f"应返回 IMAGE_NOT_FOUND：{r}")
print("PASS: 登记不存在的镜像返回 IMAGE_NOT_FOUND")

# 错误：参数缺失或空白 -> -32602
r = call("set_image_info", {})
expect(r["error"]["code"] == -32602, f"缺少参数应返回 -32602：{r}")
r = call("set_image_info", {"image": REPO, "summary": "  ",
                            "readme": README})
expect(r["error"]["code"] == -32602, f"空白 summary 应返回 -32602：{r}")
r = call("set_image_info", {"image": REPO, "summary": SUMMARY,
                            "readme": "  "})
expect(r["error"]["code"] == -32602, f"空白 readme 应返回 -32602：{r}")
r = call("search_images", {"keyword": "  "})
expect(r["error"]["code"] == -32602, f"空白 keyword 应返回 -32602：{r}")
print("PASS: 参数缺失或空白返回 -32602")

# 错误：未知方法
r = rpc("no/such", {})
expect(r["error"]["code"] == -32601, f"应返回方法不存在：{r}")
print("PASS: 未知方法返回 -32601")

# 清空 META_DIR 即清空全部登记，无需重启
META_DIR = os.environ["META_DIR"]
for entry in os.listdir(META_DIR):
    os.remove(os.path.join(META_DIR, entry))
found = payload_of(call("list_images", {}))["repositories"]
expect(found and all(x["summary"] == "" and x["readme"] == "" for x in found),
       f"清空 META_DIR 后所有登记应为空：{found}")
print("PASS: 清空 META_DIR 后全部登记清空，镜像仍在")

# 仓库不可访问：页面仍可用
subprocess.run(["docker", "stop", os.environ["REGNAME"]], check=True,
               stdout=subprocess.DEVNULL)
page = page_text()
expect("mcpServers" in page and "仓库不可访问" in page,
       "仓库不可访问时页面应显示配置区与错误信息")
print("PASS: 仓库不可访问时 GET / 仍返回配置区并提示错误")
PY

pass "mcp-server 全部用例"
echo "ALL PASSED"
