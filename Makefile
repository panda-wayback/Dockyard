.PHONY: up down restart logs clean-meta test

up:
	docker compose up -d --build

down:
	docker compose down

restart: down up

logs:
	docker compose logs -f

clean-meta:
	docker compose exec mcp sh -c 'find "$$META_DIR" -mindepth 1 -delete'

test:
	./mcp-server/tests/test.sh
	./tests/integration.sh
