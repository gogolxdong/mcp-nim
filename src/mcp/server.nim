import std/[asyncdispatch, json, options, tables, uri, strutils, times, strformat]
import ./types as mcp_types
import ./shared/[protocol, transport, base_types]

type
  ResourceHandler* = proc(uri: Uri, params: JsonNode): Future[JsonNode] {.async.}
  ToolHandler* = proc(params: JsonNode): Future[JsonNode] {.async.}

  McpServer* = ref object
    protocol*: protocol.Protocol
    serverInfo: mcp_types.ClientInfo
    capabilities: mcp_types.ServerCapabilities
    resources*: Table[string, ResourceHandler]
    tools*: Table[string, ToolHandler]
    initialized*: bool
    running*: bool

proc handleInitialize(server: McpServer, request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
  stderr.writeLine "[MCP] Handling initialize request"
  result = %*{
    "protocolVersion": mcp_types.LATEST_PROTOCOL_VERSION,
    "capabilities": server.capabilities,
    "serverInfo": {
      "name": server.serverInfo.name,
      "version": server.serverInfo.version
    }
  }
  server.initialized = true
  stderr.writeLine "[MCP] Initialize response: ", $result

proc handleInitialized(server: McpServer, notification: base_types.JsonRpcNotification) {.async.} =
  stderr.writeLine "[MCP] Received initialized notification"

proc newMcpServer*(serverInfo: mcp_types.ClientInfo, capabilities: mcp_types.ServerCapabilities): McpServer =
  new(result)
  result.serverInfo = serverInfo
  result.capabilities = capabilities
  result.protocol = protocol.newProtocol(
    transport = nil,
    clientInfo = serverInfo,
    serverCapabilities = capabilities
  )
  result.resources = initTable[string, ResourceHandler]()
  result.tools = initTable[string, ToolHandler]()
  result.initialized = false
  result.running = false

proc connect*(server: McpServer, transport: transport.Transport) {.async.} =
  # Set up message handler
  transport.setMessageHandler(proc(message: JsonNode) =
    var formatNow = times.utc(times.now()).format("yyyy-MM-dd HH:mm:ss'Z'")
    stderr.writeLine &"[{formatNow}][MCP] Received message: ", $message
    if message.hasKey("method"):
      if message["method"].getStr == "initialize":
        let request = JsonRpcRequest(
          jsonrpc: message["jsonrpc"].getStr,
          id: RequestId(kind: ridInt, intVal: message["id"].getInt),
          `method`: message["method"].getStr,
          params: message["params"]
        )
        let extra = RequestHandlerExtra(signal: newAbortSignal())
        
        proc handleMessage() {.async.} =
          var formatNow = times.utc(times.now()).format("yyyy-MM-dd HH:mm:ss'Z'")
          try:
            let response = await server.handleInitialize(request, extra)
            let jsonResponse = %*{
              "jsonrpc": "2.0",
              "id": request.id.intVal,
              "result": response
            }
            stderr.writeLine &"[{formatNow}][MCP] Sending initialize response: ", $jsonResponse
            await transport.send(jsonResponse)
            stderr.writeLine &"[{formatNow}][MCP] Initialize response sent successfully"
          except Exception as e:
            stderr.writeLine &"[{formatNow}][MCP] Error handling initialize request: ", e.msg
            stderr.writeLine getStackTrace(e)
        
        asyncCheck handleMessage()
  )

  # Connect transport and protocol
  stderr.writeLine "[MCP] Protocol connecting to transport"
  await server.protocol.connect(transport)  # This will start the transport internally
  server.running = true

proc close*(server: McpServer) {.async.} =
  if server.running:
    server.running = false
    if not isNil(server.protocol):
      await server.protocol.close()
    # Clear handlers
    server.resources.clear()
    server.tools.clear()
    server.initialized = false
    stderr.writeLine "[MCP] Server closed"

proc addResource*(server: McpServer, name: string, handler: ResourceHandler) =
  server.resources[name] = handler

proc addTool*(server: McpServer, name: string, handler: ToolHandler) =
  server.tools[name] = handler

proc handleListResources(server: McpServer, params: JsonNode): Future[JsonNode] {.async.} =
  var resources = newJArray()
  for name in server.resources.keys:
    resources.add(%*{"name": name})
  result = %*{"resources": resources}

proc handleListTools(server: McpServer, params: JsonNode): Future[JsonNode] {.async.} =
  var tools = newJArray()
  for name, handler in server.tools:
    tools.add(%*{
      "name": name,
      "description": case name
      of "read_file": "Read the complete contents of a file from the file system. Handles various text encodings and provides detailed error messages if the file cannot be read. Use this tool when you need to examine the contents of a single file. Only works within allowed directories."
      of "read_multiple_files": "Read the contents of multiple files simultaneously. This is more efficient than reading files one by one when you need to analyze or compare multiple files. Each file's content is returned with its path as a reference. Failed reads for individual files won't stop the entire operation. Only works within allowed directories."
      of "write_file": "Create a new file or completely overwrite an existing file with new content. Use with caution as it will overwrite existing files without warning. Handles text content with proper encoding. Only works within allowed directories."
      of "edit_file": "Make line-based edits to a text file. Each edit replaces exact line sequences with new content. Returns a git-style diff showing the changes made. Only works within allowed directories."
      of "create_directory": "Create a new directory or ensure a directory exists. Can create multiple nested directories in one operation. If the directory already exists, this operation will succeed silently. Perfect for setting up directory structures for projects or ensuring required paths exist. Only works within allowed directories."
      of "list_directory": "Get a detailed listing of all files and directories in a specified path. Results clearly distinguish between files and directories with [FILE] and [DIR] prefixes. This tool is essential for understanding directory structure and finding specific files within a directory. Only works within allowed directories."
      of "directory_tree": "Get a recursive tree view of files and directories as a JSON structure. Each entry includes 'name', 'type' (file/directory), and 'children' for directories. Files have no children array, while directories always have a children array (which may be empty). The output is formatted with 2-space indentation for readability. Only works within allowed directories."
      of "move_file": "Move or rename files and directories. Can move files between directories and rename them in a single operation. If the destination exists, the operation will fail. Works across different directories and can be used for simple renaming within the same directory. Both source and destination must be within allowed directories."
      of "search_files": "Recursively search for files and directories matching a pattern. Searches through all subdirectories from the starting path. The search is case-insensitive and matches partial names. Returns full paths to all matching items. Great for finding files when you don't know their exact location. Only searches within allowed directories."
      of "get_file_info": "Retrieve detailed metadata about a file or directory. Returns comprehensive information including size, creation time, last modified time, permissions, and type. This tool is perfect for understanding file characteristics without reading the actual content. Only works within allowed directories."
      of "list_allowed_directories": "Returns the list of directories that this server is allowed to access. Use this to understand which directories are available before trying to access files."
      else: "No description available",
      "inputSchema": case name
      of "read_file": %*{
        "type": "object",
        "properties": {"path": {"type": "string"}},
        "required": ["path"],
        "additionalProperties": false,
        "$schema": "http://json-schema.org/draft-07/schema#"
      }
      of "read_multiple_files": %*{
        "type": "object",
        "properties": {"paths": {"type": "array", "items": {"type": "string"}}},
        "required": ["paths"],
        "additionalProperties": false,
        "$schema": "http://json-schema.org/draft-07/schema#"
      }
      of "write_file": %*{
        "type": "object",
        "properties": {
          "path": {"type": "string"},
          "content": {"type": "string"}
        },
        "required": ["path", "content"],
        "additionalProperties": false,
        "$schema": "http://json-schema.org/draft-07/schema#"
      }
      of "edit_file": %*{
        "type": "object",
        "properties": {
          "path": {"type": "string"},
          "edits": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "oldText": {"type": "string", "description": "Text to search for - must match exactly"},
                "newText": {"type": "string", "description": "Text to replace with"}
              },
              "required": ["oldText", "newText"],
              "additionalProperties": false
            }
          },
          "dryRun": {"type": "boolean", "default": false, "description": "Preview changes using git-style diff format"}
        },
        "required": ["path", "edits"],
        "additionalProperties": false,
        "$schema": "http://json-schema.org/draft-07/schema#"
      }
      of "create_directory": %*{
        "type": "object",
        "properties": {"path": {"type": "string"}},
        "required": ["path"],
        "additionalProperties": false,
        "$schema": "http://json-schema.org/draft-07/schema#"
      }
      of "list_directory": %*{
        "type": "object",
        "properties": {"path": {"type": "string"}},
        "required": ["path"],
        "additionalProperties": false,
        "$schema": "http://json-schema.org/draft-07/schema#"
      }
      of "directory_tree": %*{
        "type": "object",
        "properties": {"path": {"type": "string"}},
        "required": ["path"],
        "additionalProperties": false,
        "$schema": "http://json-schema.org/draft-07/schema#"
      }
      of "move_file": %*{
        "type": "object",
        "properties": {
          "source": {"type": "string"},
          "destination": {"type": "string"}
        },
        "required": ["source", "destination"],
        "additionalProperties": false,
        "$schema": "http://json-schema.org/draft-07/schema#"
      }
      of "search_files": %*{
        "type": "object",
        "properties": {
          "path": {"type": "string"},
          "pattern": {"type": "string"},
          "excludePatterns": {"type": "array", "items": {"type": "string"}, "default": []}
        },
        "required": ["path", "pattern"],
        "additionalProperties": false,
        "$schema": "http://json-schema.org/draft-07/schema#"
      }
      of "get_file_info": %*{
        "type": "object",
        "properties": {"path": {"type": "string"}},
        "required": ["path"],
        "additionalProperties": false,
        "$schema": "http://json-schema.org/draft-07/schema#"
      }
      of "list_allowed_directories": %*{
        "type": "object",
        "properties": {},
        "required": [],
        "additionalProperties": false,
        "$schema": "http://json-schema.org/draft-07/schema#"
      }
      else: %*{}
    })
  result = %*{"tools": tools}

proc handleReadResource(server: McpServer, params: JsonNode): Future[JsonNode] {.async.} =
  let resourceId = params["resourceId"].getStr
  if not server.resources.hasKey(resourceId):
    raise newMcpError(base_types.ErrorCode.InvalidRequest, "Resource not found")
  
  let handler = server.resources[resourceId]
  result = await handler(parseUri(""), params)

proc handleExecuteTool(server: McpServer, params: JsonNode): Future[JsonNode] {.async.} =
  let toolId = params["toolId"].getStr
  if not server.tools.hasKey(toolId):
    raise newMcpError(base_types.ErrorCode.InvalidRequest, "Tool not found")
  
  let handler = server.tools[toolId]
  result = await handler(params)

proc start*(server: McpServer) =
  # Register standard request handlers
  server.protocol.setRequestHandler("initialize", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    result = await server.handleInitialize(request, extra)
  )

  server.protocol.setNotificationHandler("notifications/initialized", proc(notification: base_types.JsonRpcNotification): Future[void] {.async.} =
    await server.handleInitialized(notification)
  )

  server.protocol.setRequestHandler("tools/list", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    result = await server.handleListTools(request.params)
  )

  server.protocol.setRequestHandler("resources/list", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    result = await server.handleListResources(request.params)
  )

  server.protocol.setRequestHandler("readResource", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    result = await server.handleReadResource(request.params)
  )

  server.protocol.setRequestHandler("executeTool", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    result = await server.handleExecuteTool(request.params)
  )

# Export public types and procedures
export McpServer, newMcpServer
export connect, close
export ResourceHandler, ToolHandler 