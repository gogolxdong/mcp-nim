import std/[asyncdispatch, json, options, tables, uri, strutils, times, strformat]
import ./types as mcp_types
import ./shared/[protocol, transport, base_types]

type
  ResourceHandler* = proc(uri: Uri, params: JsonNode): Future[JsonNode] {.async.}
  ToolHandler* = proc(params: JsonNode): Future[JsonNode] {.async.}

  ToolInfo* = object
    description*: string
    inputSchema*: JsonNode

  McpServer* = ref object of RootObj
    protocol*: protocol.Protocol
    serverInfo: mcp_types.ClientInfo
    capabilities: mcp_types.ServerCapabilities
    resources*: Table[string, ResourceHandler]
    tools*: Table[string, ToolHandler]
    toolDescriptions*: Table[string, string]
    toolSchemas*: Table[string, JsonNode]
    initialized*: bool
    running*: bool

proc handleInitialize*(server: McpServer, request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
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

proc handleListTools*(server: McpServer, params: JsonNode): Future[JsonNode] {.async.} =
  var tools = newJArray()
  for name, handler in server.tools:
    tools.add(%*{
      "name": name,
      "description": server.toolDescriptions.getOrDefault(name, "No description available"),
      "inputSchema": server.toolSchemas.getOrDefault(name, %*{})
    })
  result = %*{"tools": tools}

proc handleListResources*(server: McpServer, params: JsonNode): Future[JsonNode] {.async.} =
  var resources = newJArray()
  for name in server.resources.keys:
    resources.add(%*{"name": name})
  result = %*{"resources": resources}

proc handleReadResource*(server: McpServer, params: JsonNode): Future[JsonNode] {.async.} =
  let resourceId = params["resourceId"].getStr
  if not server.resources.hasKey(resourceId):
    raise newMcpError(base_types.ErrorCode.InvalidRequest, "Resource not found")
  
  let handler = server.resources[resourceId]
  result = await handler(parseUri(""), params)

proc handleExecuteTool*(server: McpServer, params: JsonNode): Future[JsonNode] {.async.} =
  let toolId = params["toolId"].getStr
  if not server.tools.hasKey(toolId):
    raise newMcpError(base_types.ErrorCode.InvalidRequest, "Tool not found")
  
  let handler = server.tools[toolId]
  result = await handler(params)

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
      let methodName = message["method"].getStr
      let request = JsonRpcRequest(
        jsonrpc: message["jsonrpc"].getStr,
        id: if message.hasKey("id"): RequestId(kind: ridInt, intVal: message["id"].getInt) else: RequestId(kind: ridNone),
        `method`: methodName,
        params: if message.hasKey("params"): message["params"] else: newJObject()
      )
      let extra = RequestHandlerExtra(signal: newAbortSignal())
      
      proc handleMessage() {.async.} =
        try:
          var response: JsonNode
          case methodName:
          of "initialize":
            response = await handleInitialize(server, request, extra)
          of "tools/list":
            response = await handleListTools(server, request.params)
          of "resources/list":
            response = await handleListResources(server, request.params)
          of "prompts/list":
            response = %*{
              "prompts": [],
              "pagination": {
                "total": 0,
                "hasMore": false
              }
            }
          of "readResource":
            response = await handleReadResource(server, request.params)
          of "executeTool":
            response = await handleExecuteTool(server, request.params)
          of "notifications/initialized":
            discard
            return
          else:
            raise newMcpError(ErrorCode.MethodNotFound, "Method not found: " & methodName)
          
          if request.id.kind != ridNone:
            let jsonResponse = %*{
              "jsonrpc": "2.0",
              "id": request.id.intVal,
              "result": response
            }
            stderr.writeLine &"[{formatNow}][MCP] Sending response: ", $jsonResponse
            await transport.send(jsonResponse)
            
        except McpError as e:
          stderr.writeLine &"[{formatNow}][MCP] MCP error handling request: ", e.msg
          if request.id.kind != ridNone:
            let errorResponse = %*{
              "jsonrpc": "2.0",
              "id": request.id.intVal,
              "error": {
                "code": e.code.int,
                "message": e.msg
              }
            }
            await transport.send(errorResponse)
        except Exception as e:
          stderr.writeLine &"[{formatNow}][MCP] Error handling request: ", e.msg
          stderr.writeLine getStackTrace(e)
          if request.id.kind != ridNone:
            let errorResponse = %*{
              "jsonrpc": "2.0",
              "id": request.id.intVal,
              "error": {
                "code": ErrorCode.InternalError.int,
                "message": "Internal error: " & e.msg
              }
            }
            await transport.send(errorResponse)
      
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

proc start*(server: McpServer) =
  # Register standard request handlers
  server.protocol.setRequestHandler("initialize", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    result = await handleInitialize(server, request, extra)
  )

  server.protocol.setNotificationHandler("notifications/initialized", proc(notification: base_types.JsonRpcNotification): Future[void] {.async.} =
    discard
  )

  server.protocol.setRequestHandler("tools/list", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    result = await handleListTools(server, request.params)
  )

  server.protocol.setRequestHandler("resources/list", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    result = await handleListResources(server, request.params)
  )

  server.protocol.setRequestHandler("prompts/list", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    result = %*{
      "prompts": [],
      "pagination": {
        "total": 0,
        "hasMore": false
      }
    }
  )

  server.protocol.setRequestHandler("readResource", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    result = await handleReadResource(server, request.params)
  )

  server.protocol.setRequestHandler("executeTool", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    result = await handleExecuteTool(server, request.params)
  )

# Export public types and procedures
export McpServer, newMcpServer
export connect, close
export ResourceHandler, ToolHandler 