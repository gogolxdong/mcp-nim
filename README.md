# Nim Model Context Protocol (MCP) SDK

Nim implementation of the Model Context Protocol (MCP) for building AI agent capabilities.

## Installation

1. Install [Nim compiler](https://nim-lang.org/install.html)
2. Clone repository:
```bash
git clone https://github.com/yourusername/nim-mcp-sdk.git
cd nim-mcp-sdk
```

## Configuration

### Claude Integration
1. Locate MCP config file:
   - Claude Desktop: `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS)
   - Cursor: `%APPDATA%\Cursor\User\globalStorage\rooveterinaryinc.roo-cline\settings\cline_mcp_settings.json` (Windows)

2. Add server configuration:
```json
{
  "mcpServers": {
    "filesystem-server": {
      "command": "nim",
      "args": ["c","-r", "examples/filesystem_server.nim"],
      "cwd": "/path/to/sdk/root",
      "disabled": false
    }
  }
}
```

## Development

### Creating MCP Servers
```nim
import std/[asyncdispatch, json, options]
import ../src/mcp/[client, types]
import ../src/mcp/shared/[protocol, stdio, transport]

proc main() {.async.} =
  let transport = newStdioTransport()
  let protocol = newProtocol(some(ProtocolOptions()))
  
  protocol.setRequestHandler(Request, proc(
    request: Request,
    extra: RequestHandlerExtra
  ): Future[McpResult] {.async.} =
    if request.`method` == "your-method":
      result = McpResult()
    else:
      raise newMcpError(ErrorCode.MethodNotFound)
  )

  await protocol.connect(transport)
  await sleepAsync(1000)
  await protocol.close()

when isMainModule:
  waitFor main()
```

## Examples

### Filesystem Server
```nim
protocol.setRequestHandler("tools/list", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
  result = %*{
    "tools": [
      {
        "name": "read_file",
        "description": "Read file contents",
        "inputSchema": {
          "type": "object",
          "properties": {
            "path": {"type": "string"}
          },
          "required": ["path"],
          "additionalProperties": false
        }
      }
    ]
  }
)
```

## Features
- Type-safe RPC communication
- JSON serialization/deserialization
- Async I/O with progress notifications
- Capability-based security model
- Thread-safe implementations

## Building
```bash
nimble build
nimble test
nimble docs
```

## License
MIT License
