import std/[asyncdispatch, json, options]

type
  ErrorCode* = enum
    # SDK error codes
    ConnectionClosed = -32000
    RequestTimeout = -32001
    InvalidCapability = -32002
    
    # Standard JSON-RPC error codes
    ParseError = -32700
    InvalidRequest = -32600
    MethodNotFound = -32601
    InvalidParams = -32602
    InternalError = -32603

  AbortSignal* = ref object
    triggered*: bool
    reason*: string

  ProgressTokenKind* = enum
    ptkString, ptkInt

  ProgressToken* = object
    case kind*: ProgressTokenKind
    of ptkString:
      strVal*: string
    of ptkInt:
      intVal*: int

  MetaData* = object
    progressToken*: Option[ProgressToken]

  BaseRequestParams* = object
    meta*: Option[MetaData]
    rawParams*: JsonNode

  BaseNotificationParams* = object
    meta*: Option[MetaData]
    rawParams*: JsonNode

  RequestIdKind* = enum
    ridString, ridInt

  RequestId* = object
    case kind*: RequestIdKind
    of ridString: strVal*: string
    of ridInt: intVal*: int

  JsonRpcRequest* = object
    jsonrpc*: string
    id*: RequestId
    `method`*: string
    params*: JsonNode

  JsonRpcNotification* = object
    jsonrpc*: string
    `method`*: string
    params*: JsonNode

  JsonRpcResponse* = object
    jsonrpc*: string
    id*: RequestId
    result*: JsonNode

  JsonRpcError* = object
    code*: int
    message*: string
    data*: Option[JsonNode]

  JsonRpcErrorResponse* = object
    jsonrpc*: string
    id*: RequestId
    error*: JsonRpcError

  McpError* = ref object of CatchableError
    code*: int
    data*: Option[JsonNode]

  BaseTransport* = ref object of RootObj
    connected*: bool
    onclose*: Option[proc()]
    onerror*: Option[proc(error: McpError)]
    onmessage*: Option[proc(message: JsonNode)]

  TransportMessage* = JsonRpcRequest | JsonRpcResponse | JsonRpcNotification

# Constructor for AbortSignal
proc newAbortSignal*(): AbortSignal =
  AbortSignal(triggered: false)

proc abort*(signal: AbortSignal, reason: string = "") =
  signal.triggered = true
  signal.reason = reason

# Error handling
proc newMcpError*(code: ErrorCode, msg: string, data: JsonNode = nil): McpError =
  new(result)
  result.msg = msg
  result.code = code.int
  if not data.isNil:
    result.data = some(data)

proc newMcpError*(code: int, msg: string, data: JsonNode = nil): McpError =
  new(result)
  result.msg = msg
  result.code = code
  if not data.isNil:
    result.data = some(data)

proc `$`*(error: McpError): string =
  result = "McpError(code: " & $error.code & ", msg: " & error.msg
  if error.data.isSome:
    result &= ", data: " & $error.data.get
  result &= ")"

# Progress token helpers
proc newProgressToken*(value: string): ProgressToken =
  ProgressToken(kind: ptkString, strVal: value)

proc newProgressToken*(value: int): ProgressToken =
  ProgressToken(kind: ptkInt, intVal: value)

proc `$`*(token: ProgressToken): string =
  case token.kind
  of ptkString: token.strVal
  of ptkInt: $token.intVal

# Request ID helpers
proc newRequestId*(value: string): RequestId =
  RequestId(kind: ridString, strVal: value)

proc newRequestId*(value: int): RequestId =
  RequestId(kind: ridInt, intVal: value)

proc `$`*(id: RequestId): string =
  case id.kind
  of ridString: id.strVal
  of ridInt: $id.intVal

# JSON serialization helpers
proc `%`*(token: ProgressToken): JsonNode =
  case token.kind
  of ptkString: %token.strVal
  of ptkInt: %token.intVal

proc `%`*(id: RequestId): JsonNode =
  case id.kind
  of ridString: %id.strVal
  of ridInt: %id.intVal

proc `%`*(params: BaseRequestParams): JsonNode =
  result = newJObject()
  if params.meta.isSome:
    result["meta"] = %params.meta.get

proc `%`*(params: BaseNotificationParams): JsonNode =
  result = newJObject()
  if params.meta.isSome:
    result["meta"] = %params.meta.get

proc `%`*(meta: MetaData): JsonNode =
  result = newJObject()
  if meta.progressToken.isSome:
    result["progressToken"] = %meta.progressToken.get

method start*(transport: BaseTransport): Future[void] {.base, async.} =
  raiseAssert "Transport.start must be implemented by subclass"

method close*(transport: BaseTransport): Future[void] {.base, async.} =
  raiseAssert "Transport.close must be implemented by subclass"

method send*(transport: BaseTransport, message: JsonNode): Future[void] {.base, async.} =
  raiseAssert "Transport.send must be implemented by subclass"

method receive*(transport: BaseTransport): Future[JsonNode] {.base, async.} =
  raiseAssert "Transport.receive must be implemented by subclass"

method handleError*(transport: BaseTransport, error: McpError) {.base.} =
  if transport.onerror.isSome:
    transport.onerror.get()(error)

export 
  ErrorCode, McpError, AbortSignal,
  ProgressToken, ProgressTokenKind,
  RequestId, RequestIdKind,
  MetaData, BaseRequestParams, BaseNotificationParams,
  JsonRpcRequest, JsonRpcResponse, JsonRpcNotification,
  BaseTransport, TransportMessage,
  newMcpError, newProgressToken, newRequestId,
  newAbortSignal, abort