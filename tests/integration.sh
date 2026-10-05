#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export COMPOSE_PROJECT_NAME="mcpdock-it"
export REGISTRY_PORT="${IT_REGISTRY_PORT:-21070}"
export UI_PORT="${IT_UI_PORT:-21090}"
export MCP_PORT="${IT_MCP_PORT:-21080}"
export REGISTRY_DATA_DIR="$(mktemp -d)"
WORK_DIR="$(mktemp -d)"

REGISTRY="localhost:${REGISTRY_PORT}"
UI="http://localhost:${UI_PORT}"
MCP="http://localhost:${MCP_PORT}"
REPO="mcpdock-it/hello"
MCP_REPO="mcpdock-it/mcp-hello"
TAG="it-tag"
IMAGE="${REGISTRY}/${REPO}:${TAG}"
MCP_IMAGE="${REGISTRY}/${MCP_REPO}:${TAG}"
CONTENT="mcpdock-it-$(date +%s)-$RANDOM"
ACCEPT="application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json"

compose() { docker compose -f "$ROOT/docker-compose.yml" --project-directory "$ROOT" "$@"; }

cleanup() {
  compose down -v >/dev/null 2>&1 || true
  docker rmi -f "$IMAGE" "$MCP_IMAGE" >/dev/null 2>&1 || true
  rm -rf "$REGISTRY_DATA_DIR" "$WORK_DIR"
}
trap cleanup EXIT

mcp_call() {  # $@ 透传给内嵌 python：tool 与参数，stdout 输出 result 文本
  python3 - "$MCP/mcp" "$@" <<'PY'
import json
import sys
import urllib.request

url = sys.argv[1]
tool = sys.argv[2]
args = json.loads(sys.argv[3])
msg = {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
       "params": {"name": tool, "arguments": args}}
req = urllib.request.Request(
    url, data=json.dumps(msg).encode(),
    headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req) as resp:
    print(json.dumps(json.load(resp), ensure_ascii=False))
PY
}

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

wait_ok() {
  local url="$1"
  for _ in $(seq 1 60); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$url")" = "200" ] && return 0
    sleep 1
  done
  fail "等待 $url 返回 200 超时"
}

start() {
  compose up -d --build >/dev/null
  wait_ok "http://${REGISTRY}/v2/"
  wait_ok "${UI}/v2/"
  wait_ok "${MCP}/"
}

tags() { curl -s "${UI}/v2/${REPO}/tags/list"; }

# 启动
start
pass "compose 启动，仓库 API 与 UI 反代均可访问"

# UI 页面
curl -s "${UI}/" | grep -qi "<html" || fail "UI 根路径未返回 Web 页面"
pass "UI 根路径返回 Web 页面"

# MCP 配置页与 /mcp 端点
curl -s "${MCP}/" | grep -q "mcpServers" || fail "MCP 配置页缺少 mcpServers"
INIT="$(curl -s -X POST "${MCP}/mcp" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize"}')"
echo "$INIT" | grep -q '"protocolVersion"' || fail "MCP initialize 失败：$INIT"
TLIST="$(curl -s -X POST "${MCP}/mcp" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"
echo "$TLIST" | grep -q "set_image_info" || fail "MCP tools/list 缺少 set_image_info"
echo "$TLIST" | grep -q "${MCP}/upload" || fail "MCP 工具说明缺少上传地址 ${MCP}/upload"
echo "$TLIST" | grep -q "list_images" || fail "MCP tools/list 缺少 list_images"
echo "$TLIST" | grep -q "search_images" || fail "MCP tools/list 缺少 search_images"
pass "MCP 配置页与 /mcp 端点（initialize、tools/list）"

# push
printf '%s' "$CONTENT" > "$WORK_DIR/content.txt"
printf 'FROM scratch\nCOPY content.txt /content.txt\nCMD ["/content.txt"]\n' > "$WORK_DIR/Dockerfile"
docker build -q -t "$IMAGE" "$WORK_DIR" >/dev/null
docker push -q "$IMAGE" >/dev/null || fail "docker push 失败"
pass "docker push"

# UI 列出镜像与 tag
curl -s "${UI}/v2/_catalog" | grep -q "\"${REPO}\"" || fail "UI 镜像列表中没有 ${REPO}"
tags | grep -q "\"${TAG}\"" || fail "UI tag 列表中没有 ${TAG}"
pass "UI 列出镜像与 tag"

# pull 并校验内容一致
docker rmi -f "$IMAGE" >/dev/null
docker pull -q "$IMAGE" >/dev/null || fail "docker pull 失败"
CID="$(docker create "$IMAGE")"
docker cp "$CID:/content.txt" "$WORK_DIR/pulled.txt" >/dev/null
docker rm "$CID" >/dev/null
[ "$(cat "$WORK_DIR/pulled.txt")" = "$CONTENT" ] || fail "pull 回来的内容与 push 的不一致"
pass "docker pull 内容一致"

# 客户端流程：本机构建（多层基础镜像）→ docker save → 上传到 MCP → 登记简介
MCP_PROJ="$WORK_DIR/mcp-proj"
MCP_LOCAL="mcpdock-it-local-$$:${TAG}"
mkdir -p "$MCP_PROJ"
printf '# Hello MCP\n\n一个演示问候服务。\n' > "$MCP_PROJ/README.md"
printf 'FROM registry:2\nCOPY README.md /README.md\n' > "$MCP_PROJ/Dockerfile"
docker build -q -t "$MCP_LOCAL" "$MCP_PROJ" >/dev/null
docker save -o "$WORK_DIR/mcp.tar" "$MCP_LOCAL"
docker rmi -f "$MCP_LOCAL" >/dev/null
RESP="$(curl -s --fail-with-body -T "$WORK_DIR/mcp.tar" \
  "${MCP}/upload?image=${MCP_REPO}&tag=${TAG}")" || fail "上传失败：$RESP"
echo "$RESP" | grep -q "sha256:" || fail "上传未返回 digest：$RESP"
docker pull -q "$MCP_IMAGE" >/dev/null || fail "上传的镜像无法 pull"
CID="$(docker create "$MCP_IMAGE")"
docker cp "$CID:/README.md" "$WORK_DIR/mcp-readme.md" >/dev/null
docker rm "$CID" >/dev/null
cmp -s "$WORK_DIR/mcp-readme.md" "$MCP_PROJ/README.md" || fail "上传镜像内容不一致"
pass "镜像经 MCP 上传端点推入仓库，可 pull 且内容一致"

MCP_SUMMARY="演示用问候镜像"
MCP_FEATURES="内置 README，提供问候与演示功能。"
ARGS="$(python3 - "$MCP_REPO" "$MCP_SUMMARY" "$MCP_FEATURES" <<'PY'
import json, sys
print(json.dumps({"image": sys.argv[1], "summary": sys.argv[2],
                  "features": sys.argv[3]}))
PY
)"
RESP="$(mcp_call set_image_info "$ARGS")"
echo "$RESP" | grep -q "$MCP_SUMMARY" || fail "MCP set_image_info 失败：$RESP"
pass "MCP set_image_info 登记简介"

# MCP 列表带简介
RESP="$(mcp_call list_images '{}')"
echo "$RESP" | grep -q "\"name\": \"${MCP_REPO}\"" || fail "MCP 列表缺少 ${MCP_REPO}：$RESP"
echo "$RESP" | grep -q "$MCP_SUMMARY" || fail "MCP 列表缺少简介：$RESP"
pass "MCP list_images 返回镜像与简介"

# MCP 按功能说明搜索
RESP="$(mcp_call search_images '{"keyword": "问候"}')"
echo "$RESP" | grep -q "\"name\": \"${MCP_REPO}\"" || fail "搜索 '问候' 未命中：$RESP"
pass "MCP search_images 按简介关键字查找"

# 持久化
compose down >/dev/null
start
tags | grep -q "\"${TAG}\"" || fail "down 后重新 up，tag 丢失"
RESP="$(mcp_call search_images '{"keyword": "问候"}')"
echo "$RESP" | grep -q "$MCP_SUMMARY" || fail "重启后简介丢失：$RESP"
pass "数据与镜像简介持久化"

# 通过 UI 删除 tag
DIGEST="$(curl -s -I -H "Accept: ${ACCEPT}" "${UI}/v2/${REPO}/manifests/${TAG}" \
  | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}')"
[ -n "$DIGEST" ] || fail "未取到 manifest digest"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "${UI}/v2/${REPO}/manifests/${DIGEST}")"
[ "$CODE" = "202" ] || fail "删除 tag 返回 ${CODE}，期望 202"
if tags | grep -q "\"${TAG}\""; then fail "删除后 tag 仍存在"; fi
pass "通过 UI 删除 tag"

echo "ALL PASSED"
