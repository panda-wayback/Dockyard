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

export SPORT WORK_DIR REPO REPO2 TAG PULLED REFERENCE2 CONTENT REGNAME

python3 - <<'PY'
import json
import os
import subprocess
import urllib.error
import urllib.parse
import urllib.request

SPORT = os.environ["SPORT"]
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

def upload(path, image, tag):
    with open(path, "rb") as fh:
        data = fh.read()
    query = urllib.parse.urlencode({"image": image, "tag": tag})
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
expect(f"{BASE}/upload" in tools["set_image_info"]["description"],
       "set_image_info 说明缺少上传地址")
print("PASS: tools/list 返回三个工具，说明含上传地址")

# 空仓库
expect(payload_of(call("list_images", {}))["repositories"] == [],
       "空仓库应返回空列表")
print("PASS: list_images 空仓库")
expect("暂无镜像" in page_text(), "空仓库页面应显示暂无镜像")
print("PASS: GET / 空仓库显示暂无镜像")

# 上传 docker save 文件
status, body = upload(f"{WORK_DIR}/image.tar", REPO, TAG)
expect(status == 200, f"上传失败：{status} {body}")
expect(body["image"] == REPO and body["tag"] == TAG, f"上传结果异常：{body}")
expect(body["digest"].startswith("sha256:"), f"digest 异常：{body}")
print("PASS: PUT /upload 返回 image、tag、digest")

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

# 登记简介
SUMMARY = "一个测试用的 hello 镜像"
FEATURES = "内置 content.txt，输出问候，用于验证上传链路。"
r = call("set_image_info",
         {"image": REPO, "summary": SUMMARY, "features": FEATURES})
expect(not r["result"].get("isError"), f"set_image_info 失败：{r}")
expect(payload_of(r) == {"image": REPO, "summary": SUMMARY,
                         "features": FEATURES}, f"登记结果异常：{r}")
print("PASS: set_image_info 登记简介")

# 未登记的镜像（直接推送）
subprocess.run(["docker", "tag", PULLED, REFERENCE2], check=True)
subprocess.run(["docker", "push", "-q", REFERENCE2], check=True,
               stdout=subprocess.DEVNULL)

found = {x["name"]: x for x in
         payload_of(call("list_images", {}))["repositories"]}
entry = found.get(REPO)
expect(entry is not None and entry["tags"] == [TAG],
       f"列表中未找到 {REPO}:{TAG}：{found}")
expect(entry["summary"] == SUMMARY and entry["features"] == FEATURES,
       f"简介或功能说明异常：{entry}")
plain = found.get(REPO2)
expect(plain is not None and plain["summary"] == ""
       and plain["features"] == "", f"未登记镜像简介应为空：{plain}")
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
print("PASS: search_images 按名称与简介查找")

# 网页镜像列表
page = page_text()
for text in (REPO, TAG, SUMMARY, "输出问候", REPO2, "未登记"):
    expect(text in page, f"页面缺少 {text!r}")
print("PASS: GET / 列出镜像、tag、简介，未登记的标明未登记")

r = call("set_image_info", {"image": REPO2, "summary": "<b>粗体</b>",
                            "features": "a & b"})
expect(not r["result"].get("isError"), f"登记失败：{r}")
page = page_text()
expect("&lt;b&gt;粗体&lt;/b&gt;" in page and "<b>粗体" not in page,
       "页面未对简介做 HTML 转义")
print("PASS: GET / 简介内容经 HTML 转义")

# 错误：上传参数不合法
status, body = upload(f"{WORK_DIR}/image.tar", "Bad Name", TAG)
expect(status == 400 and body["error"] == "INVALID_ARGUMENT",
       f"非法镜像名应返回 400 INVALID_ARGUMENT：{status} {body}")
print("PASS: 上传非法镜像名返回 INVALID_ARGUMENT")

# 错误：上传内容不是镜像文件
status, body = upload(f"{WORK_DIR}/garbage.tar", REPO, "bad")
expect(status == 400 and body["error"] == "INVALID_IMAGE_ARCHIVE",
       f"非镜像文件应返回 400 INVALID_IMAGE_ARCHIVE：{status} {body}")
print("PASS: 上传非镜像文件返回 INVALID_IMAGE_ARCHIVE")

# 错误：登记不存在的镜像
r = call("set_image_info", {"image": "mcpdock-test/nope",
                            "summary": SUMMARY, "features": FEATURES})
expect(r["result"].get("isError")
       and "IMAGE_NOT_FOUND" in r["result"]["content"][0]["text"],
       f"应返回 IMAGE_NOT_FOUND：{r}")
print("PASS: 登记不存在的镜像返回 IMAGE_NOT_FOUND")

# 错误：参数缺失或空白 -> -32602
r = call("set_image_info", {})
expect(r["error"]["code"] == -32602, f"缺少参数应返回 -32602：{r}")
r = call("set_image_info", {"image": REPO, "summary": "  ",
                            "features": FEATURES})
expect(r["error"]["code"] == -32602, f"空白 summary 应返回 -32602：{r}")
r = call("search_images", {"keyword": "  "})
expect(r["error"]["code"] == -32602, f"空白 keyword 应返回 -32602：{r}")
print("PASS: 参数缺失或空白返回 -32602")

# 错误：未知方法
r = rpc("no/such", {})
expect(r["error"]["code"] == -32601, f"应返回方法不存在：{r}")
print("PASS: 未知方法返回 -32601")

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
