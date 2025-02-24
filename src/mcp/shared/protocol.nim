import std/[asyncdispatch, json, options, tables, times]
import ../types as mcp_types
import ./base_types
import ./transport
import ./stdio
import ./json_utils

const
  DEFAULT_REQUEST_TIMEOUT_MSEC* = 60000
  DEFAULT_INIT_TIMEOUT_MSEC* = 120000  # 初始化请求使用更长的超时时间
  JSONRPC_VERSION* = "2.0"

type
  ProgressCallback* = proc(progress: JsonNode): Future[void] {.async.}
  RequestHandler* = proc(request: base_types.JsonRpcRequest, extra: RequestHandlerExtra): Future[JsonNode] {.async.}
  NotificationHandler* = proc(notification: base_types.JsonRpcNotification): Future[void] {.async.}

  ResponseKind = enum
    rkSuccess, rkError

  Response = object
    case kind: ResponseKind
    of rkSuccess:
      success: base_types.JsonRpcResponse
    of rkError:
      error: base_types.McpError

  ResponseHandlerRef* = ref object
    callback: proc(response: Response) {.gcsafe.}

  ProtocolOptions* = object
    enforceStrictCapabilities*: bool

  RequestOptions* = object
    onprogress*: Option[ProgressCallback]
    signal*: Option[base_types.AbortSignal]
    timeout*: Option[int]

  RequestHandlerExtra* = object
    signal*: base_types.AbortSignal

  PendingRequest = object
    promise: Future[JsonNode]
    startTime: Time
    options: Option[RequestOptions]

  Protocol* = ref object
    progressToken*: Option[base_types.ProgressToken]
    transport*: Transport
    requestMessageId*: int
    requestHandlers*: Table[string, RequestHandler]
    notificationHandlers*: Table[string, NotificationHandler]
    responseHandlers*: Table[int, ResponseHandlerRef]
    progressHandlers*: Table[int, ProgressCallback]
    options*: Option[ProtocolOptions]
    onclose*: Option[proc()]
    onerror*: Option[proc(error: base_types.McpError)]
    fallbackRequestHandler*: Option[RequestHandler]
    fallbackNotificationHandler*: Option[NotificationHandler]
    clientInfo*: mcp_types.ClientInfo
    serverCapabilities*: mcp_types.ServerCapabilities
    onmessage*: Option[mcp_types.MessageCallback]
    pendingRequests: Table[int, PendingRequest]
    nextId: int

method assertCapabilityForMethod*(protocol: Protocol, `method`: string) {.base.} =
  discard

method assertNotificationCapability*(protocol: Protocol, `method`: string) {.base.} =
  discard

method assertRequestHandlerCapability*(protocol: Protocol, `method`: string) {.base.} =
  discard

proc newResponseHandler(callback: proc(response: Response) {.gcsafe.}): ResponseHandlerRef =
  ResponseHandlerRef(callback: callback)

proc call(handler: ResponseHandlerRef, response: Response) =
  handler.callback(response)

proc newProtocol*(
  transport: Transport,
  clientInfo: mcp_types.ClientInfo,
  serverCapabilities: mcp_types.ServerCapabilities,
  options: Option[ProtocolOptions] = none(ProtocolOptions)
): Protocol =
  new(result)
  result.transport = transport
  result.clientInfo = clientInfo
  result.serverCapabilities = serverCapabilities
  result.requestMessageId = 0
  result.requestHandlers = initTable[string, RequestHandler]()
  result.notificationHandlers = initTable[string, NotificationHandler]()
  result.responseHandlers = initTable[int, ResponseHandlerRef]()
  result.progressHandlers = initTable[int, ProgressCallback]()
  result.options = options
  result.nextId = 1

proc onClose(protocol: Protocol) =
  let responseHandlers = protocol.responseHandlers
  protocol.responseHandlers = initTable[int, ResponseHandlerRef]()
  protocol.progressHandlers.clear()
  
  if protocol.onclose.isSome:
    protocol.onclose.get()()

  let error = newMcpError(ErrorCode.ConnectionClosed, "Connection closed")
  for handler in responseHandlers.values:
    handler.call(Response(kind: rkError, error: error))

proc onError(protocol: Protocol, error: McpError) =
  stderr.writeLine "[MCP] Error: ", error.msg
  if error.data.isSome:
    stderr.writeLine "[MCP] Error Data: ", error.data.get
  
  if protocol.onerror.isSome:
    protocol.onerror.get()(error)

proc onProgress(protocol: Protocol, notification: JsonNode) =
  let progressToken = notification["progressToken"]
  if progressToken.isNil:
    protocol.onError(newMcpError(
      ErrorCode.InvalidRequest,
      "Progress notification missing token"
    ))
    return

  let tokenId = progressToken.getInt(-1)
  if tokenId >= 0 and protocol.progressHandlers.hasKey(tokenId):
    let handler = protocol.progressHandlers[tokenId]
    asyncCheck handler(notification)

proc onResponse(protocol: Protocol, message: JsonNode) =
  stderr.writeLine "[MCP] Processing response: ", $message
  
  if not message.hasKey("id"):
    protocol.onError(newMcpError(ErrorCode.InvalidRequest, "Response missing id"))
    return

  let id = if message["id"].kind == JString:
    RequestId(kind: ridStr, strVal: message["id"].getStr)
  else:
    RequestId(kind: ridInt, intVal: message["id"].getInt)

  let response = if message.hasKey("result"):
    Response(
      kind: rkSuccess,
      success: JsonRpcResponse(
        jsonrpc: message["jsonrpc"].getStr,
        id: id,
        result: message["result"]
      )
    )
  else:
    let error = message["error"]
    Response(
      kind: rkError,
      error: newMcpError(
        error["code"].getInt,
        error["message"].getStr,
        if error.hasKey("data"): error["data"] else: nil
      )
    )

  stderr.writeLine "[MCP] Response processed for id: ", id
  if protocol.responseHandlers.hasKey(id.intVal):
    let handler = protocol.responseHandlers[id.intVal]
    handler.call(response)
    protocol.responseHandlers.del(id.intVal)
  else:
    stderr.writeLine "[MCP] No handler found for response id: ", id

proc onNotification(protocol: Protocol, notification: JsonRpcNotification) {.async.} =
  
  if notification.`method` == "$/progress":
    if notification.params != nil:
      protocol.onProgress(notification.params)
    return

  let handler = 
    if protocol.notificationHandlers.hasKey(notification.`method`):
      protocol.notificationHandlers[notification.`method`]
    elif protocol.fallbackNotificationHandler.isSome:
      protocol.fallbackNotificationHandler.get
    else:
      return

  try:
    await handler(notification)
  except Exception as e:
    protocol.onError(newMcpError(
      ErrorCode.InternalError,
      "Uncaught error in notification handler: " & e.msg
    ))

proc onRequest(protocol: Protocol, request: JsonRpcRequest) {.async.} =
  
  let handler =
    if protocol.requestHandlers.hasKey(request.`method`):
      protocol.requestHandlers[request.`method`]
    elif protocol.fallbackRequestHandler.isSome:
      protocol.fallbackRequestHandler.get
    else:
      try:
        let errorResponse = %*{
          "jsonrpc": JSONRPC_VERSION,
          "id": request.id,
          "error": {
            "code": ErrorCode.MethodNotFound.int,
            "message": "Method not found"
          }
        }
        await protocol.transport.send(errorResponse)
      except Exception as e:
        stderr.writeLine "[MCP] Failed to send error response: ", e.msg
        protocol.onError(newMcpError(
          ErrorCode.InternalError,
          "Failed to send error response: " & e.msg
        ))
      return

  let abortSignal = newAbortSignal()
  let extra = RequestHandlerExtra(signal: abortSignal)

  try:
    let result = await handler(request, extra)

    let response = %*{
      "jsonrpc": JSONRPC_VERSION,
      "id": request.id,
      "result": result
    }
    await protocol.transport.send(response)
  except McpError as e:
    stderr.writeLine "[MCP] Handler returned error: ", e.msg
    let errorResponse = %*{
      "jsonrpc": JSONRPC_VERSION,
      "id": request.id,
      "error": {
        "code": e.code,
        "message": e.msg,
        "data": if e.data.isSome: e.data.get else: nil
      }
    }
    await protocol.transport.send(errorResponse)
  except Exception as e:
    stderr.writeLine "[MCP] Uncaught error in request handler: ", e.msg
    let errorResponse = %*{
      "jsonrpc": JSONRPC_VERSION,
      "id": request.id,
      "error": {
        "code": ErrorCode.InternalError.int,
        "message": "Internal error: " & e.msg
      }
    }
    await protocol.transport.send(errorResponse)

proc connect*(protocol: Protocol, transport: Transport): Future[void] {.async.} =
  protocol.transport = transport
  await transport.start()

  transport.setMessageHandler(proc(message: JsonNode) =
    if not message.hasKey("jsonrpc") or message["jsonrpc"].getStr != JSONRPC_VERSION:
      protocol.onError(newMcpError(ErrorCode.InvalidRequest, "Invalid JSON-RPC version"))
      return

    if message.hasKey("method"):
      if message.hasKey("id"):
        let request = JsonRpcRequest(
          jsonrpc: message["jsonrpc"].getStr,
          id: if message["id"].kind == JString: 
              RequestId(kind: ridStr, strVal: message["id"].getStr)
            else: 
              RequestId(kind: ridInt, intVal: message["id"].getInt),
          `method`: message["method"].getStr,
          params: if message.hasKey("params"): message["params"] else: newJObject()
        )
        asyncCheck onRequest(protocol, request)
      else:
        let notification = JsonRpcNotification(
          jsonrpc: message["jsonrpc"].getStr,
          `method`: message["method"].getStr,
          params: if message.hasKey("params"): message["params"] else: newJObject()
        )
        asyncCheck onNotification(protocol, notification)
    elif message.hasKey("result") or message.hasKey("error"):
      protocol.onResponse(message)
    else:
      protocol.onError(newMcpError(ErrorCode.InvalidRequest, "Invalid message format"))
  )

  transport.setErrorHandler(proc(error: McpError) =
    protocol.onError(error)
  )

  transport.setCloseHandler(proc() =
    if protocol.onclose.isSome:
      protocol.onclose.get()()
  )

proc close*(protocol: Protocol) {.async.} =
  if not protocol.transport.isNil:
    await protocol.transport.close()
    protocol.transport = nil

  # Cancel all pending requests
  for id, request in protocol.pendingRequests:
    if not request.promise.finished:
      request.promise.fail(newMcpError(ErrorCode.ConnectionClosed, "Connection closed"))
  protocol.pendingRequests.clear()
  protocol.responseHandlers.clear()

proc processRequest*(protocol: Protocol, request: JsonNode): Future[JsonNode] {.async.} =
  let methodName = request["method"].getStr
  let params = if request.hasKey("params"): request["params"] else: newJObject()
  let id = if request.hasKey("id"): 
    RequestId(kind: ridInt, intVal: request["id"].getInt) 
  else: 
    RequestId(kind: ridInt, intVal: 0)
  
  if protocol.requestHandlers.hasKey(methodName):
    let handler = protocol.requestHandlers[methodName]
    let jsonRpcRequest = JsonRpcRequest(
      jsonrpc: JSONRPC_VERSION,
      id: id,
      `method`: methodName,
      params: params
    )
    result = await handler(jsonRpcRequest, RequestHandlerExtra())
  else:
    raise newMcpError(ErrorCode.MethodNotFound, "Method not found: " & methodName)

proc processNotification*(protocol: Protocol, notification: JsonNode): Future[void] {.async.} =
  let jsonrpcNotification = %*{
    "jsonrpc": JSONRPC_VERSION,
    "method": notification["method"].getStr
  }

  if notification.hasKey("params"):
    jsonrpcNotification["params"] = notification["params"]

  await protocol.transport.send(jsonrpcNotification)

proc setRequestHandler*(protocol: Protocol, `method`: string, handler: RequestHandler) =
  protocol.requestHandlers[`method`] = handler

proc setNotificationHandler*(protocol: Protocol, `method`: string, handler: NotificationHandler) =
  protocol.notificationHandlers[`method`] = handler

proc setFallbackRequestHandler*(protocol: Protocol, handler: RequestHandler) =
  protocol.fallbackRequestHandler = some(handler)

proc setFallbackNotificationHandler*(protocol: Protocol, handler: NotificationHandler) =
  protocol.fallbackNotificationHandler = some(handler)

proc removeRequestHandler*(protocol: Protocol, `method`: string) =
  protocol.requestHandlers.del(`method`)

proc removeNotificationHandler*(protocol: Protocol, `method`: string) =
  protocol.notificationHandlers.del(`method`)

proc request*(protocol: Protocol, message: JsonNode, T: typedesc, options: Option[RequestOptions] = none(RequestOptions)): Future[JsonNode] {.async.} =
  if not protocol.transport.isNil and not protocol.transport.isConnected():
    raise newMcpError(ErrorCode.ConnectionClosed, "Transport not connected")

  let id = protocol.nextId
  inc protocol.nextId

  let requestMessage = %*{
    "jsonrpc": JSONRPC_VERSION,
    "id": id,
    "method": message["method"].getStr,
    "params": if message.hasKey("params"): message["params"] else: newJObject()
  }

  var promise = newFuture[JsonNode]("request")
  let startTime = getTime()

  let responseHandler = newResponseHandler(proc(response: Response) {.gcsafe.} =
    case response.kind
    of rkSuccess:
      promise.complete(response.success.result)
    of rkError:
      promise.fail(response.error)
  )

  protocol.responseHandlers[id] = responseHandler

  let timeout = if options.isSome and options.get.timeout.isSome:
    options.get.timeout.get
  else:
    DEFAULT_REQUEST_TIMEOUT_MSEC

  let timeoutFuture = sleepAsync(timeout)
  protocol.pendingRequests[id] = PendingRequest(
    promise: promise,
    startTime: startTime,
    options: options
  )

  try:
    await protocol.transport.send(requestMessage)
  except Exception as e:
    protocol.responseHandlers.del(id)
    protocol.pendingRequests.del(id)
    raise newMcpError(ErrorCode.InternalError, "Failed to send request: " & e.msg)

  try:
    if await race(promise, timeoutFuture):
      result = await promise
    else:
      protocol.responseHandlers.del(id)
      protocol.pendingRequests.del(id)
      raise newMcpError(ErrorCode.RequestTimeout, "Request timed out")
  except Exception as e:
    protocol.responseHandlers.del(id)
    protocol.pendingRequests.del(id)
    raise e

proc race*[T](promise: Future[T], timeout: Future[void]): Future[bool] {.async.} =
  var promiseCompleted = false
  var timeoutCompleted = false
  
  proc checkPromise() {.async.} =
    try:
      discard await promise
      promiseCompleted = true
    except:
      promiseCompleted = true  # Consider failed promise as completed
      
  proc checkTimeout() {.async.} =
    try:
      await timeout
      timeoutCompleted = true
    except:
      timeoutCompleted = true
      
  asyncCheck checkPromise()
  asyncCheck checkTimeout()
  
  while not promiseCompleted and not timeoutCompleted:
    await sleepAsync(1)
    
  result = promiseCompleted and not timeoutCompleted

export Protocol, ProtocolOptions, RequestOptions, RequestHandlerExtra
export newProtocol, connect, close, request, processNotification
export setRequestHandler, setNotificationHandler
export setFallbackRequestHandler, setFallbackNotificationHandler
export removeRequestHandler, removeNotificationHandler
export assertCapabilityForMethod, assertNotificationCapability, assertRequestHandlerCapability