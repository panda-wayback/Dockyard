#!/usr/bin/env bash
# mcp-server 黑盒测试：自启临时 registry 与本服务进程，
# 通过 HTTP / JSON-RPC 验证配置页、tools、build_and_push、list_images 与错误。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

freeport() {
  python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'
}

RPORT="$(freeport)"
SPORT="$(freeport)"
REGNAME="mcpdock-mcp-test-$$"
WORK_DIR="$(mktemp -d)"
REPO="mcpdock-test/hello"
TAG="test-tag"
REFERENCE="localhost:${RPORT}/${REPO}:${TAG}"
CONTENT="mcpdock-mcp-$(date +%s)-$RANDOM"

cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  docker rm -f "$REGNAME" >/dev/null 2>&1 || true
  docker rmi -f "$REFERENCE" >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

# 临时 registry
docker run -d --name "$REGNAME" -p "${RPORT}:5000" registry:2 >/dev/null

# 在宿主机直接起服务进程（测试环境需有 python3 与 docker CLI）
REGISTRY_ADDRESS="localhost:${RPORT}" \
REGISTRY_API="http://localhost:${RPORT}" \
PORT="$SPORT" python3 "$ROOT/server.py" >/dev/null 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 60); do
  curl -s -o /dev/null "http://localhost:${SPORT}/" && break
  sleep 1
done

# 准备待构建项目
mkdir -p "$WORK_DIR/proj"
printf '%s' "$CONTENT" > "$WORK_DIR/proj/content.txt"
printf 'FROM scratch\nCOPY content.txt /content.txt\n' > "$WORK_DIR/proj/Dockerfile"

export SPORT WORK_DIR REPO TAG REFERENCE

python3 - <<'PY'
import json
import os
import urllib.request

SPORT = os.environ["SPORT"]
WORK_DIR = os.environ["WORK_DIR"]
REPO = os.environ["REPO"]
TAG = os.environ["TAG"]
REFERENCE = os.environ["REFERENCE"]
URL = f"http://localhost:{SPORT}/mcp"
_id = 0

def rpc(method, params=None, raw=None):
    global _id
    _id += 1
    msg = {"jsonrpc": "2.0", "id": _id, "method": method}
    if params is not None:
        msg["params"] = params
    if raw is not None:
        msg = raw
    req = urllib.request.Request(
        URL, data=json.dumps(msg).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)

def expect(cond, msg):
    if not cond:
        raise AssertionError(msg)

# 配置页
with urllib.request.urlopen(f"http://localhost:{SPORT}/") as resp:
    page = resp.read().decode()
expect("<html" in page and "mcpServers" in page, "配置页内容不正确")
print("PASS: GET / 返回配置页")

# initialize
r = rpc("initialize", {})
expect(r["result"]["protocolVersion"] == "2025-06-18", "initialize 失败")
print("PASS: initialize")

# tools/list
r = rpc("tools/list", {})
names = {t["name"] for t in r["result"]["tools"]}
expect(names == {"build_and_push", "list_images"}, f"工具列表异常：{names}")
print("PASS: tools/list 返回两个工具")

# 空仓库
r = rpc("tools/call", {"name": "list_images", "arguments": {}})
payload = json.loads(r["result"]["content"][0]["text"])
expect(payload["repositories"] == [], "空仓库应返回空列表")
print("PASS: list_images 空仓库")

# build_and_push
r = rpc("tools/call", {"name": "build_and_push", "arguments": {
    "project_dir": f"{WORK_DIR}/proj", "image": REPO, "tag": TAG}})
expect(not r["result"].get("isError"), f"build_and_push 失败：{r}")
payload = json.loads(r["result"]["content"][0]["text"])
expect(payload["reference"] == REFERENCE, f"reference 异常：{payload}")
expect(payload["digest"].startswith("sha256:"), f"digest 异常：{payload}")
print("PASS: build_and_push 返回 reference 与 digest")

# list_images 能看到
r = rpc("tools/call", {"name": "list_images", "arguments": {}})
payload = json.loads(r["result"]["content"][0]["text"])
found = {x["name"]: x["tags"] for x in payload["repositories"]}
expect(found.get(REPO) == [TAG], f"列表中未找到 {REPO}:{TAG}：{found}")
print("PASS: list_images 列出已推送镜像与 tag")

# 错误：目录不存在
r = rpc("tools/call", {"name": "build_and_push", "arguments": {
    "project_dir": f"{WORK_DIR}/nope", "image": REPO, "tag": TAG}})
expect(r["result"].get("isError"), "应返回 isError")
expect("PROJECT_NOT_FOUND" in r["result"]["content"][0]["text"],
       "应返回 PROJECT_NOT_FOUND")
print("PASS: 项目目录不存在返回 PROJECT_NOT_FOUND")

# 错误：缺少参数 -> -32602
r = rpc("tools/call", {"name": "build_and_push", "arguments": {}})
expect(r["error"]["code"] == -32602, f"应返回参数错误：{r}")
print("PASS: 缺少参数返回 -32602")

# 错误：未知方法
r = rpc("no/such", {})
expect(r["error"]["code"] == -32601, f"应返回方法不存在：{r}")
print("PASS: 未知方法返回 -32601")
PY

pass "mcp-server 全部用例"
echo "ALL PASSED"
