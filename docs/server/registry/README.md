# 私有仓库

## 目标
一条命令部署带 Web UI 的 Docker 私有仓库。

## 需求
- 执行 `docker compose up -d` 后，可以 `docker push` / `docker pull` 镜像到本仓库。
- 浏览器可浏览仓库中的镜像与 tag、删除 tag。
- 仓库数据持久化，容器重建后镜像不丢失。

## 方案
- 复用：官方镜像 `registry:2` 作为仓库服务；官方镜像 `joxit/docker-registry-ui` 作为浏览 UI，开启 `NGINX_PROXY_PASS_URL` 反代仓库，UI 与仓库 API 同源。
- 新增：根 Module（项目根目录），职责为 compose 部署编排与集成测试。
- 取舍：使用官方镜像不改源码，不选 fork joxit，理由是零维护成本、可直接升级。

## 不做
- 用户与权限管理（需要时沿用仓库的 Basic Auth）。
- HTTPS（交给前置反向代理）。
- MCP 相关功能（见独立功能 [MCP 配置生成](../mcp-config/README.md)）。
