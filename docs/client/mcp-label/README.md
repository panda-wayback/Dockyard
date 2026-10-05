# MCP Label 规范

面向镜像作者：在镜像中声明 MCP server 的启动方式，MCPDock 据此生成 MCP 客户端配置。

## 声明方式

在 Dockerfile 中添加 Label `ai.mcpdock.mcp`，值为一段 YAML：

```dockerfile
LABEL ai.mcpdock.mcp="\
name: pan-easy
transport: stdio
command: python
args:
  - -m
  - pan_easy.mcp
env:
  PAN_EASY_HOME: /data"
```

## 字段

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `name` | 字符串 | 是 | MCP server 名称，非空 |
| `transport` | 字符串 | 是 | 目前只支持 `stdio` |
| `command` | 字符串 | 是 | 启动命令 |
| `args` | 字符串列表 | 否 | 命令参数 |
| `env` | 字符串到字符串的映射 | 否 | 环境变量 |

不允许出现上表以外的字段；拼错字段名会被判为不合规。

## 生成结果

上面的声明会生成：

```json
{
  "mcpServers": {
    "pan-easy": {
      "command": "python",
      "args": ["-m", "pan_easy.mcp"],
      "env": {
        "PAN_EASY_HOME": "/data"
      }
    }
  }
}
```

省略 `args` / `env` 时，生成结果中也不包含对应字段。
