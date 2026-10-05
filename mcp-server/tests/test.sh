#!/usr/bin/env bash
# mcp-server 黑盒测试：自启临时 registry 与本服务进程，
# 通过 HTTP / JSON-RPC 验证配置页、tools、build_and_push（含简介）、
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
REFERENCE="localhost:${RPORT}/${REPO}:${TAG}"
REFERENCE2="localhost:${RPORT}/${REPO2}:${TAG}"
CONTENT="mcpdock-mcp-$(date +%s)-$RANDOM"

cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  docker rm -f "$REGNAME" >/dev/null 2>&1 || true
  docker rmi -f "$REFERENCE" "$REFERENCE2" >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR" "$META_DIR"
}
trap cleanup EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

# 临时 registry
docker run -d --name "$REGNAME" -p "${RPORT}:5000" registry:2 >/dev/null

# 在宿主机直接起服务进程（测试环境需有 python3 与 docker CLI）
REGISTRY_ADDRESS="localhost:${RPORT}" \
REGISTRY_API="http://localhost:${RPORT}" \
META_DIR="$META_DIR" \
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

export SPORT WORK_DIR REPO REPO2 TAG REFERENCE REFERENCE2

python3 - <<'PY'
import json
import os
import subprocess
import urllib.request

SPORT = os.environ["SPORT"]
WORK_DIR = os.environ["WORK_DIR"]
REPO = os.environ["REPO"]
REPO2 = os.environ["REPO2"]
TAG = os.environ["TAG"]
REFERENCE = os.environ["REFERENCE"]
REFERENCE2 = os.environ["REFERENCE2"]
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
expect(names == {"build_and_push", "list_images", "search_images"},
       f"工具列表异常：{names}")
print("PASS: tools/list 返回三个工具")

# 空仓库
r = rpc("tools/call", {"name": "list_images", "arguments": {}})
payload = json.loads(r["result"]["content"][0]["text"])
expect(payload["repositories"] == [], "空仓库应返回空列表")
print("PASS: list_images 空仓库")

SUMMARY = "一个测试用的 hello 镜像"
FEATURES = "内置 content.txt，输出问候，用于验证 MCP 推送链路。"

# build_and_push（AI 风格：带自己提炼的简介与功能说明）
r = rpc("tools/call", {"name": "build_and_push", "arguments": {
    "project_dir": f"{WORK_DIR}/proj", "image": REPO, "tag": TAG,
    "summary": SUMMARY, "features": FEATURES}})
expect(not r["result"].get("isError"), f"build_and_push 失败：{r}")
payload = json.loads(r["result"]["content"][0]["text"])
expect(payload["reference"] == REFERENCE, f"reference 异常：{payload}")
expect(payload["digest"].startswith("sha256:"), f"digest 异常：{payload}")
print("PASS: build_and_push 返回 reference 与 digest")

# list_images 能看到镜像、tag 与简介
r = rpc("tools/call", {"name": "list_images", "arguments": {}})
payload = json.loads(r["result"]["content"][0]["text"])
found = {x["name"]: x for x in payload["repositories"]}
entry = found.get(REPO)
expect(entry is not None and entry["tags"] == [TAG],
       f"列表中未找到 {REPO}:{TAG}：{found}")
expect(entry["summary"] == SUMMARY and entry["features"] == FEATURES,
       f"简介或功能说明异常：{entry}")
print("PASS: list_images 列出镜像、tag 与简介")

# 直接 docker push 的镜像：简介为空
subprocess.run(["docker", "build", "-q", "-t", REFERENCE2,
                f"{WORK_DIR}/proj"], check=True,
               stdout=subprocess.DEVNULL)
subprocess.run(["docker", "push", "-q", REFERENCE2], check=True,
               stdout=subprocess.DEVNULL)
r = rpc("tools/call", {"name": "list_images", "arguments": {}})
payload = json.loads(r["result"]["content"][0]["text"])
plain = {x["name"]: x for x in payload["repositories"]}.get(REPO2)
expect(plain is not None and plain["summary"] == ""
       and plain["features"] == "", f"原生推送镜像简介应为空：{plain}")
print("PASS: 未经 MCP 推送的镜像简介为空")

# search_images：命中功能说明
r = rpc("tools/call", {"name": "search_images",
                       "arguments": {"keyword": "问候"}})
payload = json.loads(r["result"]["content"][0]["text"])
names = {x["name"] for x in payload["repositories"]}
expect(names == {REPO}, f"搜索 '问候' 应只命中 {REPO}：{names}")
# 大小写不敏感命中镜像名
r = rpc("tools/call", {"name": "search_images",
                       "arguments": {"keyword": "PLAIN"}})
payload = json.loads(r["result"]["content"][0]["text"])
names = {x["name"] for x in payload["repositories"]}
expect(names == {REPO2}, f"搜索 'PLAIN' 应命中 {REPO2}：{names}")
# 无匹配
r = rpc("tools/call", {"name": "search_images",
                       "arguments": {"keyword": "不存在的关键字xyz"}})
payload = json.loads(r["result"]["content"][0]["text"])
expect(payload["repositories"] == [], f"无匹配应返回空列表：{payload}")
print("PASS: search_images 按名称与简介查找")

# 错误：目录不存在
r = rpc("tools/call", {"name": "build_and_push", "arguments": {
    "project_dir": f"{WORK_DIR}/nope", "image": REPO, "tag": TAG,
    "summary": SUMMARY, "features": FEATURES}})
expect(r["result"].get("isError"), "应返回 isError")
expect("PROJECT_NOT_FOUND" in r["result"]["content"][0]["text"],
       "应返回 PROJECT_NOT_FOUND")
print("PASS: 项目目录不存在返回 PROJECT_NOT_FOUND")

# 错误：缺少参数 -> -32602
r = rpc("tools/call", {"name": "build_and_push", "arguments": {}})
expect(r["error"]["code"] == -32602, f"应返回参数错误：{r}")
print("PASS: 缺少参数返回 -32602")

# 错误：summary 为空白 -> -32602
r = rpc("tools/call", {"name": "build_and_push", "arguments": {
    "project_dir": f"{WORK_DIR}/proj", "image": REPO, "tag": TAG,
    "summary": "   ", "features": FEATURES}})
expect(r["error"]["code"] == -32602, f"空白 summary 应返回参数错误：{r}")
print("PASS: summary 为空白返回 -32602")

# 错误：search_images keyword 空白 -> -32602
r = rpc("tools/call", {"name": "search_images",
                       "arguments": {"keyword": "  "}})
expect(r["error"]["code"] == -32602, f"空白 keyword 应返回参数错误：{r}")
print("PASS: keyword 为空白返回 -32602")

# 错误：未知方法
r = rpc("no/such", {})
expect(r["error"]["code"] == -32601, f"应返回方法不存在：{r}")
print("PASS: 未知方法返回 -32601")
PY

pass "mcp-server 全部用例"
echo "ALL PASSED"
