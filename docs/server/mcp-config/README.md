# MCP 配置生成

## 目标
选中仓库中的一个镜像 tag，一键得到可粘贴进 Cursor / Claude Desktop 的 MCP 配置。

## 需求
- 独立页面，可选择仓库中的镜像与 tag。
- 镜像按 [MCP Label 规范](../../client/mcp-label/README.md) 声明了 MCP：页面展示生成的 `mcpServers` JSON，可一键复制，并提示 Cursor 与 Claude Desktop 的配置文件位置。
- 镜像未声明 MCP：提示「该镜像未声明 MCP」。
- 声明内容不合规（YAML 写错、缺字段、拼错字段名等）：显示具体错误原因，不生成 JSON。
- 多架构镜像同样可用。

## 方案
- 新增：Module `mcp-config/`，把 Label 文本转换为 `mcpServers` JSON，不合规时返回错误原因（纯函数）。
- 新增：Module `registry-client/`，通过仓库 HTTP API 列出镜像、tag，读取指定 tag 的 Labels。
- 新增：Module `mcp-page/`，独立页面，串联上面两个 Module 完成选择、展示、复制。
- 取舍：与私有仓库的 UI 完全隔离（不挂进 joxit 容器、不改 joxit），理由是方便独立开发部署、互不影响更安全。
- 取舍：Label 中出现未定义字段时报错、不忽略，理由是拼错字段名（如 `commnad`）能立刻发现，而不是生成跑不起来的配置。
- 取舍：多架构镜像优先读取 linux/amd64 的 Labels，没有则取第一个平台，理由是 Labels 通常跨平台一致。

## 不做
- stdio 以外的 MCP 传输方式（SSE、streamable-http）。
- 按客户端输出不同格式（Cursor 与 Claude Desktop 共用同一份 JSON）。
- 把配置自动写入客户端（只生成和复制）。
