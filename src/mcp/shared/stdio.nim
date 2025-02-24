import std/[asyncdispatch, json, options, streams, strutils, strformat,os, times]
import ./base_types
import ./transport

type
  MessageHandler* = proc(message: JsonNode) {.closure.}
  ErrorHandler* = proc(error: McpError) {.closure.}
  CloseHandler* = proc() {.closure.}
  TransportError* = object of CatchableError

  StdioTransport* = ref object of Transport
    buffer: string
    msgHandler: MessageHandler
    errHandler: ErrorHandler
    connected: bool
    stdinFile: File
    stdoutFile: File
    onClose: Option[CloseHandler]

const 
  BUFFER_SIZE = 8192  # Increased buffer size
  MAX_MESSAGE_SIZE = 8192  # 1MB max message size
  NO_BUFFERING = 0  # 无缓冲模式

proc newStdioTransport*(): StdioTransport =
  stderr.writeLine "[MCP] Creating new StdioTransport"
  new(result)
  init(Transport(result))  # Initialize base class
  result.buffer = ""
  result.connected = false
  result.stdinFile = stdin
  result.stdoutFile = stdout
  result.onClose = none(CloseHandler)
  stderr.writeLine "[MCP] StdioTransport created successfully"

proc appendToBuffer(transport: StdioTransport, data: string) =
  transport.buffer.add(data)
  if transport.buffer.len > MAX_MESSAGE_SIZE:
    if transport.getErrorHandler().isSome:
      transport.getErrorHandler().get()(newMcpError(ErrorCode.InternalError, "Message too large"))
    transport.buffer = ""

proc readMessage(transport: StdioTransport): JsonNode =
  if transport.buffer.len == 0:
    return nil
  
  let newlinePos = transport.buffer.find('\n')
  if newlinePos == -1:
    return nil
  
  let line = transport.buffer[0 ..< newlinePos]
  transport.buffer = transport.buffer[newlinePos + 1 .. ^1]
  
  try:
    result = parseJson(line)
  except JsonParsingError:
    if transport.getErrorHandler().isSome:
      transport.getErrorHandler().get()(newMcpError(ErrorCode.ParseError, "Invalid JSON message"))
    return nil

proc processMessages(transport: StdioTransport) =
  while true:
    let message = transport.readMessage()
    if message == nil:
      break
      
    if transport.getMessageHandler().isSome:
      try:
        let handler = transport.getMessageHandler().get()
        handler(message)
      except Exception as e:
        stderr.writeLine "[MCP] Error processing message: ", e.msg, "\n", getStackTrace(e)
        if transport.getErrorHandler().isSome:
          transport.getErrorHandler().get()(newMcpError(ErrorCode.InternalError, "Error processing message: " & e.msg))

method start*(transport: StdioTransport): Future[void] {.async.} =
  stderr.writeLine "[MCP] Starting StdioTransport"
  if transport.isConnected():
    raise newMcpError(ErrorCode.InvalidRequest, "Transport already started")
  
  transport.setConnected(true)
  stderr.writeLine "[MCP] Transport connected"
  
  # Start message receiving loop
  proc messageLoop() {.async.} =
    var formatNow = times.utc(times.now()).format("yyyy-MM-dd HH:mm:ss'Z'")
    stderr.writeLine &"[{formatNow}][MCP] Starting message receiving loop"
    
    var line: string
    while transport.isConnected():
      try:
        # Read a line from stdin
        if transport.stdinFile.readLine(line):
          try:
            let message = parseJson(line)
            if transport.getMessageHandler().isSome:
              transport.getMessageHandler().get()(message)
          except JsonParsingError:
            if transport.getErrorHandler().isSome:
              transport.getErrorHandler().get()(newMcpError(ErrorCode.ParseError, "Invalid JSON message"))
        
        # Small delay to prevent CPU spinning
        await sleepAsync(1)
            
      except EOFError:
        stderr.writeLine "[MCP] EOF reached, closing transport"
        transport.setConnected(false)
        if transport.getCloseHandler().isSome:
          transport.getCloseHandler().get()()
        break
      except Exception as e:
        stderr.writeLine "[MCP] Error in message loop: ", e.msg, "\n", getStackTrace(e)
        if transport.getErrorHandler().isSome:
          transport.getErrorHandler().get()(newMcpError(ErrorCode.InternalError, "Error receiving message: " & e.msg))

  asyncCheck messageLoop()
  stderr.writeLine "[MCP] StdioTransport start completed"

method send*(transport: StdioTransport, message: JsonNode): Future[void] {.async.} =
  if not transport.isConnected():
    raise newMcpError(ErrorCode.ConnectionClosed, "Transport not connected")
  
  try:
    let serialized = $message & "\n"
    transport.stdoutFile.write(serialized)
    transport.stdoutFile.flushFile()
    
    # Debug message only to stderr
    stderr.flushFile()
  except Exception as e:
    stderr.writeLine "[MCP] Failed to send message: ", e.msg
    raise newMcpError(ErrorCode.InternalError, "Failed to send message: " & e.msg)

method close*(transport: StdioTransport): Future[void] {.async.} =
  if transport.isConnected():
    transport.setConnected(false)
    transport.buffer = ""
    # Close stdin/stdout
    transport.stdinFile.flushFile()
    transport.stdoutFile.flushFile()
    transport.stdinFile.close()
    transport.stdoutFile.close()
    # Notify closure
    if transport.getCloseHandler().isSome:
      transport.getCloseHandler().get()()

method isClosed*(transport: StdioTransport): bool =
  not transport.isConnected() or
  transport.stdinFile.isNil or transport.stdoutFile.isNil

proc setMessageHandler*(transport: StdioTransport, handler: MessageHandler) =
  transport.msgHandler = handler

proc setErrorHandler*(transport: StdioTransport, handler: ErrorHandler) =
  transport.errHandler = handler

proc setCloseHandler*(transport: StdioTransport, handler: CloseHandler) =
  transport.onClose = some(handler)

proc debug(msg: string) =
  stderr.writeLine(&"[STDIO] {msg}")
  stderr.flushFile()

proc write*(transport: StdioTransport, message: JsonNode) {.async.} =
  try:
    let serialized = $message & "\n"
    transport.stdoutFile.write(serialized)
    transport.stdoutFile.flushFile()
    debug("Message sent successfully")
  except Exception as e:
    debug(&"Error writing message: {e.msg}")
    raise newMcpError(ErrorCode.InternalError, &"Failed to write message: {e.msg}")

proc isConnected*(transport: StdioTransport): bool =
  transport.connected

export StdioTransport, newStdioTransport