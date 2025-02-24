import std/[asyncdispatch, json, options, tables, uri]
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

proc connect*(server: McpServer, transport: transport.Transport) {.async.} =
  await server.protocol.connect(transport)

proc close*(server: McpServer) {.async.} =
  await server.protocol.close()

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
  for name in server.tools.keys:
    tools.add(%*{"name": name})
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
  server.protocol.setRequestHandler("listResources", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    result = await server.handleListResources(request.params)
  )

  server.protocol.setRequestHandler("listTools", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    result = await server.handleListTools(request.params)
  )

  server.protocol.setRequestHandler("readResource", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    result = await server.handleReadResource(request.params)
  )

  server.protocol.setRequestHandler("executeTool", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    result = await server.handleExecuteTool(request.params)
  )

export McpServer, newMcpServer
export connect, close
export ResourceHandler, ToolHandler 