# MCP 服务器

## 目标
随私有仓库一起提供一个 MCP 服务器和配置页，IDE 复制页面生成的 JSON 后，AI 即可把项目镜像构建并推送到本仓库。

## 需求
- `docker compose up -d` 后 MCP 服务器随仓库启动，暴露一个宿主机端口（`MCP_PORT`，默认 20080）。
- 浏览器打开 MCP 服务器根路径看到配置页：
  - 可填写/修改 MCP 服务器自己的访问网址，默认取当前页面的访问地址。
  - 按该网址实时生成 `mcpServers` JSON（streamable-http，含 `url` 字段），可一键复制。
- 把生成的 JSON 加入 Cursor 等 IDE 的 MCP 配置后，可通过 MCP 工具：
  - 给定宿主机上的项目目录、镜像名、tag，执行构建并推送到本仓库（tag 为 `<registry 地址>/<镜像名>:<tag>`）。
  - 列出仓库中的镜像与 tag。
- 推送到的 registry 地址沿用部署时的 `REGISTRY_PORT`（默认 `localhost:20070`）。

## 方案
- 新增：Module `mcp-server/`，职责为提供配置页与 streamable-http MCP 端点，并通过宿主机 Docker 完成构建/推送、通过仓库 API 列出镜像。
- 修改：根 Module（项目根目录）的 compose 增加 mcp 服务、`MCP_PORT` 环境变量与集成测试。
- MCP 服务挂载 `/var/run/docker.sock`（在宿主机 Docker 上执行 build/push）与宿主机 HOME（让容器内能访问项目目录，macOS 下容器内外路径一致）。
- 配置页的网址只在浏览器端拼接，服务端不保存任何配置。
- 取舍：常驻 HTTP 服务而非 stdio 按需容器，理由是配置页与 MCP 端点可同源共存、JSON 只需一个 URL、不依赖客户端本机装有 docker 以外的运行时。

## 不做
- MCP 端点与配置页的认证鉴权（本地/内网使用，对外暴露交给前置反向代理）。
- 自动把 JSON 写入 IDE（只生成和复制）。
- 拉取镜像、删除镜像等推送以外的操作。
- stdio 传输方式。
