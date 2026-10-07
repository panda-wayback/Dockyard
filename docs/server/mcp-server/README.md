# MCP 服务器

## 目标
随私有仓库一起提供一个 MCP 服务器和配置页，IDE 复制页面生成的 JSON 后，AI 即可在本机构建镜像并上传到本仓库、登记镜像简介，并查看与查找仓库中的镜像；客户端除 Docker 外无需任何配置。

## 需求
- `docker compose up -d` 后 MCP 服务器随仓库启动，暴露一个宿主机端口（`MCP_PORT`，默认 20080）；登记数据保存在项目目录下（`MCP_DATA_DIR`，默认 `./data/mcp`）。
- 浏览器打开 MCP 服务器根路径看到配置页：
  - 可填写/修改 MCP 服务器自己的访问网址，默认取当前页面的访问地址。
  - 按该网址实时生成 `mcpServers` JSON（streamable-http，含 `url` 字段），可一键复制。
  - 下方显示仓库镜像列表，含简介与镜像 README，可按关键字筛选。
- 把生成的 JSON 加入 Cursor 等 IDE 的 MCP 配置后：
  - AI 在本机 `docker build` 并把镜像导出为文件，经 HTTP 上传给 MCP 服务器，由服务器推入本仓库；上传方式（含上传地址）写在 MCP 工具说明中，按客户端访问 MCP 服务器的地址自动生成。
  - 镜像一律按 `linux/amd64` 构建：工具说明中的构建命令带 `--platform linux/amd64`；上传时服务器检查镜像平台，不是 `linux/amd64` 则拒绝，不写入任何 tag，错误信息给出正确的构建命令。
  - 一次上传可同时打多个 tag。工具说明要求每次上传同时打版本 tag 与 `latest`：版本 tag 优先取项目版本号，没有则取 git commit 短哈希，便于回滚；`latest` 始终指向最新上传。
  - 上传后通过 MCP 工具登记该镜像的简介与镜像 README（功能、使用、配置）。
  - 通过 MCP 工具列出仓库中的镜像、tag 与简介，并按关键字查找镜像。
- 仓库为 HTTP、部署在远程服务器时，客户端无需配置 HTTPS 或 insecure-registries 即可完成上传。

## 方案
- 子功能：[镜像简介与搜索](image-meta/README.md)，上传后登记简介与镜像 README，并按关键字查找镜像。
- 子功能：[镜像简介网页](image-page/README.md)，在配置页下方浏览镜像简介并按关键字筛选。
- 新增：Module `mcp-server/`，职责为提供配置页、streamable-http MCP 端点与镜像上传端点；上传的镜像经仓库 HTTP API 推入本仓库，通过仓库 API 列出镜像，并保存镜像简介。
- 修改：根 Module（项目根目录）的 compose 增加 mcp 服务、`MCP_PORT` 与 `MCP_DATA_DIR`（登记数据目录，默认 `./data/mcp`，与仓库数据同在项目 `data/` 下）环境变量与集成测试；mcp 服务经 compose 内网访问仓库，不挂载 Docker socket。
- 配置页的网址只在浏览器端拼接，服务端不保存任何配置。
- 取舍：镜像经 MCP 服务器中转推送，不让客户端直接 `docker push`；理由是 Docker 只允许对 localhost 用 HTTP 推送，中转后由服务器对本机仓库推送，客户端零配置。
- 取舍：不在 MCP 服务器上构建；理由是项目代码在客户端，远程部署时服务器上没有项目目录。
- 取舍：平台在上传端强制校验，不只写在工具说明里；理由是 macOS（Apple Silicon）默认构建 arm64，到 amd64 服务器运行才报错，且客户端缓存的工具说明可能过期，服务端校验可保证仓库中只有可运行的镜像。
- 取舍：平台固定为 `linux/amd64`，不做配置项；理由是部署服务器均为 amd64。
- 取舍：多 tag 在一次上传中完成，不让客户端按 tag 重复上传；理由是镜像文件只传一次，各 tag 指向同一 manifest。
- 取舍：常驻 HTTP 服务而非 stdio 按需容器，理由是配置页、MCP 端点与上传端点可同源共存、JSON 只需一个 URL。

## 不做
- MCP 端点、上传端点与配置页的认证鉴权（对外暴露交给前置反向代理）。
- 仓库 HTTPS（交给前置反向代理）。
- 在 MCP 服务器上构建镜像。
- 多平台镜像（同一 tag 同时含 amd64 与 arm64）。
- 自动把 JSON 写入 IDE（只生成和复制）。
- 拉取镜像、删除镜像等操作。
- stdio 传输方式。
