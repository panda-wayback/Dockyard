#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export COMPOSE_PROJECT_NAME="mcpdock-it"
export REGISTRY_PORT="${IT_REGISTRY_PORT:-15050}"
export UI_PORT="${IT_UI_PORT:-18090}"
export REGISTRY_DATA_DIR="$(mktemp -d)"
WORK_DIR="$(mktemp -d)"

REGISTRY="localhost:${REGISTRY_PORT}"
UI="http://localhost:${UI_PORT}"
REPO="mcpdock-it/hello"
TAG="it-tag"
IMAGE="${REGISTRY}/${REPO}:${TAG}"
CONTENT="mcpdock-it-$(date +%s)-$RANDOM"
ACCEPT="application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json"

compose() { docker compose -f "$ROOT/docker-compose.yml" --project-directory "$ROOT" "$@"; }

cleanup() {
  compose down -v >/dev/null 2>&1 || true
  docker rmi -f "$IMAGE" >/dev/null 2>&1 || true
  rm -rf "$REGISTRY_DATA_DIR" "$WORK_DIR"
}
trap cleanup EXIT

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
  compose up -d >/dev/null
  wait_ok "http://${REGISTRY}/v2/"
  wait_ok "${UI}/v2/"
}

tags() { curl -s "${UI}/v2/${REPO}/tags/list"; }

# 启动
start
pass "compose 启动，仓库 API 与 UI 反代均可访问"

# UI 页面
curl -s "${UI}/" | grep -qi "<html" || fail "UI 根路径未返回 Web 页面"
pass "UI 根路径返回 Web 页面"

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

# 持久化
compose down >/dev/null
start
tags | grep -q "\"${TAG}\"" || fail "down 后重新 up，tag 丢失"
pass "数据持久化"

# 通过 UI 删除 tag
DIGEST="$(curl -s -I -H "Accept: ${ACCEPT}" "${UI}/v2/${REPO}/manifests/${TAG}" \
  | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}')"
[ -n "$DIGEST" ] || fail "未取到 manifest digest"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "${UI}/v2/${REPO}/manifests/${DIGEST}")"
[ "$CODE" = "202" ] || fail "删除 tag 返回 ${CODE}，期望 202"
if tags | grep -q "\"${TAG}\""; then fail "删除后 tag 仍存在"; fi
pass "通过 UI 删除 tag"

echo "ALL PASSED"
