import std/[asyncdispatch, json, options]
import ./types as mcp_types
import ./shared/[protocol, transport, base_types]

const
  DEFAULT_INIT_TIMEOUT_MSEC = 120000  # 2 minutes

type
  McpClient* = ref object
    protocol*: protocol.Protocol
    clientInfo: mcp_types.ClientInfo
    serverCapabilities: Option[mcp_types.ServerCapabilities]

proc newMcpClient*(clientInfo: mcp_types.ClientInfo): McpClient =
  new(result)
  result.clientInfo = clientInfo
  result.protocol = protocol.newProtocol(
    transport = nil,
    clientInfo = clientInfo,
    serverCapabilities = mcp_types.ServerCapabilities(
      tools: newJObject()
    )
  )

proc connect*(client: McpClient, transport: Transport): Future[void] {.async.} =
  client.protocol.transport = transport
  await client.protocol.connect(transport)

  # Send initialize request
  let initRequest = %*{
    "jsonrpc": protocol.JSONRPC_VERSION,
    "method": "initialize",
    "params": {
      "protocolVersion": mcp_types.LATEST_PROTOCOL_VERSION,
      "clientInfo": {
        "name": client.clientInfo.name,
        "version": client.clientInfo.version
      }
    }
  }

  let response = await client.protocol.request(
    initRequest,
    JsonNode,
    some(protocol.RequestOptions(timeout: some(DEFAULT_INIT_TIMEOUT_MSEC)))
  )

  # Parse server capabilities
  if response.hasKey("capabilities"):
    client.serverCapabilities = some(response["capabilities"].toMcp(mcp_types.ServerCapabilities))

  # Send initialized notification
  let initNotification = %*{
    "jsonrpc": protocol.JSONRPC_VERSION,
    "method": "initialized"
  }
  await client.protocol.processNotification(initNotification)

proc close*(client: McpClient): Future[void] {.async.} =
  await client.protocol.close()

proc ping*(client: McpClient): Future[JsonNode] {.async.} =
  let request = %*{
    "jsonrpc": protocol.JSONRPC_VERSION,
    "method": "ping"
  }
  result = await client.protocol.request(request, JsonNode)

proc listResources*(client: McpClient, cursor: Option[mcp_types.Cursor] = none(mcp_types.Cursor)): Future[JsonNode] {.async.} =
  var request = %*{
    "jsonrpc": protocol.JSONRPC_VERSION,
    "method": "listResources"
  }
  if cursor.isSome:
    request["params"] = %*{"cursor": cursor.get}
  result = await client.protocol.request(request, JsonNode)

proc readResource*(client: McpClient, resourceId: string): Future[JsonNode] {.async.} =
  let request = %*{
    "jsonrpc": protocol.JSONRPC_VERSION,
    "method": "readResource",
    "params": {
      "resourceId": resourceId
    }
  }
  result = await client.protocol.request(request, JsonNode)

proc subscribe*(client: McpClient, resourceId: string): Future[JsonNode] {.async.} =
  let request = %*{
    "jsonrpc": protocol.JSONRPC_VERSION,
    "method": "subscribe",
    "params": {
      "resourceId": resourceId
    }
  }
  result = await client.protocol.request(request, JsonNode)

proc unsubscribe*(client: McpClient, resourceId: string): Future[JsonNode] {.async.} =
  let request = %*{
    "jsonrpc": protocol.JSONRPC_VERSION,
    "method": "unsubscribe",
    "params": {
      "resourceId": resourceId
    }
  }
  result = await client.protocol.request(request, JsonNode)

proc executeTool*(client: McpClient, toolId: string, params: JsonNode = nil, options: Option[protocol.RequestOptions] = none(protocol.RequestOptions)): Future[JsonNode] {.async.} =
  var request = %*{
    "jsonrpc": protocol.JSONRPC_VERSION,
    "method": "executeTool",
    "params": {
      "toolId": toolId
    }
  }
  if not params.isNil:
    for key, value in params:
      request["params"][key] = value
  result = await client.protocol.request(request, JsonNode, options)

export McpClient, newMcpClient, connect, close
export ping, listResources, readResource, subscribe, unsubscribe, executeTool