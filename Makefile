.PHONY: up down restart logs test

up:
	docker compose up -d --build

down:
	docker compose down

restart: down up

logs:
	docker compose logs -f

test:
	./mcp-server/tests/test.sh
	./tests/integration.sh
