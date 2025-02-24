import std/[asyncdispatch, json, options, sequtils]
import ./base_types
export base_types

type
  Transport* = ref object of RootObj
    isConnected: bool
    closeHandler: Option[proc()]
    errorHandler: Option[proc(error: McpError)]
    messageHandler: Option[proc(message: JsonNode)]

  InMemoryTransport* = ref object of Transport
    base*: Transport
    messageQueue: seq[JsonNode]
    peerTransport: InMemoryTransport
    closed: bool
    onmessage: Option[proc(message: JsonNode)]
    onerror: Option[proc(error: McpError)]
    onclose: Option[proc()]

method init*(transport: Transport) {.base.} =
  transport.isConnected = false
  transport.closeHandler = none(proc())
  transport.errorHandler = none(proc(error: McpError))
  transport.messageHandler = none(proc(message: JsonNode))

method isConnected*(transport: Transport): bool {.base.} =
  transport.isConnected

method start*(transport: Transport): Future[void] {.base.} =
  raiseAssert "Transport.start must be implemented by subclass"

method close*(transport: Transport): Future[void] {.base.} =
  raiseAssert "Transport.close must be implemented by subclass"

method send*(transport: Transport, message: JsonNode): Future[void] {.base.} =
  raiseAssert "Transport.send must be implemented by subclass"

method receive*(transport: Transport): Future[JsonNode] {.base.} =
  raiseAssert "Transport.receive must be implemented by subclass"

method setMessageHandler*(transport: Transport, handler: proc(message: JsonNode)) {.base.} =
  transport.messageHandler = some(handler)

method setErrorHandler*(transport: Transport, handler: proc(error: McpError)) {.base.} =
  transport.errorHandler = some(handler)

method setCloseHandler*(transport: Transport, handler: proc()) {.base.} =
  transport.closeHandler = some(handler)

method getMessageHandler*(transport: Transport): Option[proc(message: JsonNode)] {.base.} =
  transport.messageHandler

method getErrorHandler*(transport: Transport): Option[proc(error: McpError)] {.base.} =
  transport.errorHandler

method getCloseHandler*(transport: Transport): Option[proc()] {.base.} =
  transport.closeHandler

method getConnectionState*(transport: Transport): bool {.base.} =
  transport.isConnected

method setConnectionState*(transport: Transport, value: bool) {.base.} =
  transport.isConnected = value

proc newInMemoryTransport*(): InMemoryTransport =
  new(result)
  init(Transport(result))
  result.messageQueue = @[]
  result.closed = false

proc createLinkedPair*(): (InMemoryTransport, InMemoryTransport) =
  let transport1 = newInMemoryTransport()
  let transport2 = newInMemoryTransport()
  
  transport1.peerTransport = transport2
  transport2.peerTransport = transport1
  
  return (transport1, transport2)

method start*(transport: InMemoryTransport): Future[void] {.async.} =
  if transport.base.isConnected:
    raise newMcpError(ErrorCode.InvalidRequest, "Transport already started")
  
  transport.base.isConnected = true
  
  # Start message receiving loop
  asyncCheck (proc() {.async.} =
    while not transport.closed:
      try:
        await sleepAsync(10) # Check every 10ms
        if transport.messageQueue.len > 0:
          let message = transport.messageQueue[0]
          transport.messageQueue.delete(0)
          if transport.base.messageHandler.isSome:
            transport.base.messageHandler.get()(message)
      except Exception as e:
        if not transport.closed and transport.base.errorHandler.isSome:
          transport.base.errorHandler.get()(newMcpError(
            ErrorCode.InternalError,
            "Error receiving message: " & e.msg
          ))
  )()

method close*(transport: InMemoryTransport): Future[void] {.async.} =
  if not transport.closed:
    transport.closed = true
    transport.base.isConnected = false
    transport.messageQueue = @[]
    if transport.base.closeHandler.isSome:
      transport.base.closeHandler.get()()

method send*(transport: InMemoryTransport, message: JsonNode): Future[void] {.async.} =
  if not transport.base.isConnected:
    raise newMcpError(ErrorCode.ConnectionClosed, "Transport not connected")
  
  if transport.closed:
    raise newMcpError(ErrorCode.ConnectionClosed, "Transport closed")
  
  if transport.peerTransport.isNil:
    raise newMcpError(ErrorCode.InvalidRequest, "No peer transport connected")
    
  if transport.peerTransport.messageHandler.isSome:
    transport.peerTransport.messageHandler.get()(message)

proc handleError*(transport: Transport, error: McpError) =
  stderr.writeLine "[MCP] Transport error: ", error.msg
  if error.data.isSome:
    stderr.writeLine "[MCP] Transport error data: ", error.data.get
  
  if transport.errorHandler.isSome:
    transport.errorHandler.get()(error)

proc processMessage*(transport: Transport, message: JsonNode) =
  if transport.messageHandler.isSome:
    try:
      transport.messageHandler.get()(message)
    except Exception as e:
      let error = newMcpError(ErrorCode.InternalError, "Error processing message: " & e.msg)
      transport.handleError(error)

export Transport, InMemoryTransport
export newInMemoryTransport, createLinkedPair
export handleError, processMessage

method isClosed*(transport: InMemoryTransport): bool =
  not transport.base.isConnected

proc setMessageHandler*(transport: InMemoryTransport, handler: proc(message: JsonNode)) =
  transport.onmessage = some(handler)

proc setErrorHandler*(transport: InMemoryTransport, handler: proc(error: McpError)) =
  transport.onerror = some(handler)

proc setCloseHandler*(transport: InMemoryTransport, handler: proc()) =
  transport.onclose = some(handler)