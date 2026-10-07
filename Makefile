.PHONY: up down restart logs clean-meta clean-empty-repos test

SHELL := /bin/bash
REGISTRY_DATA_DIR ?= ./data/registry


up:
	docker compose up -d --build

down:
	docker compose down

restart: down up

logs:
	docker compose logs -f

clean-meta:
	docker compose exec mcp sh -c 'find "$$META_DIR" -mindepth 1 -delete'

clean-empty-repos:
	@set -e; \
	base="$(REGISTRY_DATA_DIR)/docker/registry/v2/repositories"; \
	if [ ! -d "$$base" ]; then echo "没有仓库数据目录：$$base"; exit 0; fi; \
	names=(); paths=(); \
	while IFS= read -r -d '' m; do \
	  repo="$$(dirname "$$m")"; \
	  if [ -z "$$(ls -A "$$m/tags" 2>/dev/null)" ] && [ -z "$$(ls -A "$$repo/_uploads" 2>/dev/null)" ]; then \
	    names+=("$${repo#$$base/}"); paths+=("$$repo"); \
	  fi; \
	done < <(find "$$base" -type d -name _manifests -print0); \
	if [ "$${#names[@]}" -eq 0 ]; then echo "没有需要清理的空仓库"; exit 0; fi; \
	echo "将删除以下空仓库（含其简介登记）："; printf '  %s\n' "$${names[@]}"; \
	read -r -p "确认删除？[y/N] " ans; \
	if [ "$$ans" != y ] && [ "$$ans" != Y ]; then echo "已取消"; exit 0; fi; \
	docker compose stop registry; \
	for p in "$${paths[@]}"; do \
	  rm -rf "$$p"; \
	  d="$$(dirname "$$p")"; \
	  while [ "$$d" != "$$base" ]; do rmdir "$$d" 2>/dev/null || break; d="$$(dirname "$$d")"; done; \
	done; \
	joined=$$(IFS='|'; echo "$${names[*]}"); \
	docker compose exec -T -e REPOS="$$joined" mcp python3 -c 'import json,os; ns=os.environ["REPOS"].split("|"); p=os.path.join(os.environ["META_DIR"],"images.json"); m=json.load(open(p)) if os.path.exists(p) else {}; [m.pop(n,None) for n in ns]; json.dump(m,open(p,"w"),ensure_ascii=False)' || echo "警告：简介登记清理失败（mcp 服务可能未运行）"; \
	docker compose start registry

test:
	./mcp-server/tests/test.sh
	./tests/integration.sh
