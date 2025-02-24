import std/[asyncdispatch, json, options, tables, uri, strutils, times, strformat]
import ./types as mcp_types
import ./shared/[protocol, transport, base_types]

type
  ResourceHandler* = proc(uri: Uri, params: JsonNode): Future[JsonNode] {.async.}
  ToolHandler* = proc(params: JsonNode): Future[JsonNode] {.async.}

  ToolInfo* = object
    description*: string
    inputSchema*: JsonNode

  McpServer* = ref object
    protocol*: protocol.Protocol
    serverInfo: mcp_types.ClientInfo
    capabilities: mcp_types.ServerCapabilities
    resources*: Table[string, ResourceHandler]
    tools*: Table[string, ToolHandler]
    toolDescriptions*: Table[string, string]
    toolSchemas*: Table[string, JsonNode]
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
  result.toolDescriptions = initTable[string, string]()
  result.toolSchemas = initTable[string, JsonNode]()
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

proc addTool*(server: McpServer, name: string, handler: ToolHandler, description: string, schema: JsonNode) =
  server.tools[name] = handler
  server.toolDescriptions[name] = description
  server.toolSchemas[name] = schema

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
      "description": server.toolDescriptions.getOrDefault(name, "No description available"),
      "inputSchema": server.toolSchemas.getOrDefault(name, %*{})
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