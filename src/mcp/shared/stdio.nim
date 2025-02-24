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
    stdinFile: File
    stdoutFile: File
    onClose: Option[CloseHandler]
    connected: bool  # 直接在子类中维护连接状态

const 
  BUFFER_SIZE = 8192  # Increased buffer size
  MAX_MESSAGE_SIZE = 8192  # 1MB max message size
  NO_BUFFERING = 0  # 无缓冲模式

proc newStdioTransport*(): StdioTransport =
  new(result)
  init(Transport(result))  # Initialize base class
  result.buffer = ""
  result.stdinFile = stdin
  result.stdoutFile = stdout
  result.onClose = none(CloseHandler)
  result.connected = false  # 初始化为未连接状态

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

proc formatTimestamp(): string =
  let dt = now().utc
  result = dt.format("yyyy-MM-dd HH:mm:ss") & "Z"


method start*(transport: StdioTransport): Future[void] {.async.} =
  stderr.writeLine "[MCP] Starting StdioTransport"
  if transport.connected:
    raise newMcpError(ErrorCode.InvalidRequest, "Transport already started")
  
  # Initialize transport state
  transport.connected = true
  transport.stdinFile = stdin
  transport.stdoutFile = stdout
  
  # Verify transport state
  stderr.writeLine &"[MCP] Transport state - connected: {transport.connected}, stdin: {not transport.stdinFile.isNil}, stdout: {not transport.stdoutFile.isNil}"
  
  # Start message receiving loop
  proc messageLoop() {.async.} =
    let timestamp = formatTimestamp()
    stderr.writeLine &"[{timestamp}][MCP] Starting message receiving loop - isConnected: {transport.connected}, stdin: {not transport.stdinFile.isNil}, stdout: {not transport.stdoutFile.isNil}"
    
    while transport.connected:
      try:
        # Check basic connection status
        if transport.stdinFile.isNil or transport.stdoutFile.isNil:
          stderr.writeLine &"[{timestamp}][MCP] Transport disconnected: file handle is nil - stdin: {transport.stdinFile.isNil}, stdout: {transport.stdoutFile.isNil}"
          transport.connected = false
          break

        # Try to read a line
        var line: string
        try:
          # First try to read without checking EOF
          if transport.stdinFile.readLine(line):
            try:
              let message = parseJson(line)
              if transport.getMessageHandler().isSome:
                transport.getMessageHandler().get()(message)
            except JsonParsingError:
              stderr.writeLine &"[{timestamp}][MCP] Failed to parse message: {line}"
              if transport.getErrorHandler().isSome:
                transport.getErrorHandler().get()(newMcpError(ErrorCode.ParseError, "Invalid JSON message"))
          else:
            # No data available, check if it's really EOF
            if transport.stdinFile.endOfFile:
              stderr.writeLine &"[{timestamp}][MCP] EOF reached after read attempt"
              transport.connected = false
              break
            
            # Just yield to other tasks
            await sleepAsync(10)  # Wait for more data
            
        except IOError as e:
          stderr.writeLine &"[{timestamp}][MCP] IO error while reading: {e.msg}"
          transport.connected = false
          if transport.getErrorHandler().isSome:
            transport.getErrorHandler().get()(newMcpError(ErrorCode.ConnectionClosed, "IO error: " & e.msg))
          break
            
      except EOFError:
        stderr.writeLine &"[{timestamp}][MCP] EOF error caught, closing transport"
        transport.connected = false
        if transport.getCloseHandler().isSome:
          transport.getCloseHandler().get()()
        break
      except Exception as e:
        stderr.writeLine &"[{timestamp}][MCP] Error in message loop: {e.msg}\n{getStackTrace(e)}"
        if transport.getErrorHandler().isSome:
          transport.getErrorHandler().get()(newMcpError(ErrorCode.InternalError, "Error receiving message: " & e.msg))
        break

  # Start the message loop
  await messageLoop()
  stderr.writeLine &"[{formatTimestamp()}][MCP] Message loop ended - isConnected: {transport.connected}"

method send*(transport: StdioTransport, message: JsonNode): Future[void] {.async.} =
  if not transport.connected:
    raise newMcpError(ErrorCode.ConnectionClosed, "Transport not connected")
  
  try:
    # Check if stdout is still open
    if transport.stdoutFile.isNil:
      raise newMcpError(ErrorCode.ConnectionClosed, "stdout is closed")
      
    let serialized = $message & "\n"
    transport.stdoutFile.write(serialized)
    try:
      transport.stdoutFile.flushFile()
    except IOError as e:
      stderr.writeLine "[MCP] Failed to flush stdout: ", e.msg
      transport.connected = false
      if transport.getCloseHandler().isSome:
        transport.getCloseHandler().get()()
      raise newMcpError(ErrorCode.ConnectionClosed, "Failed to flush stdout: " & e.msg)
    
    # Debug message only to stderr
    stderr.flushFile()
  except IOError as e:
    stderr.writeLine "[MCP] Failed to write message: ", e.msg
    transport.connected = false
    if transport.getCloseHandler().isSome:
      transport.getCloseHandler().get()()
    raise newMcpError(ErrorCode.ConnectionClosed, "Failed to write message: " & e.msg)
  except Exception as e:
    stderr.writeLine "[MCP] Error sending message: ", e.msg
    raise newMcpError(ErrorCode.InternalError, "Error sending message: " & e.msg)

method close*(transport: StdioTransport): Future[void] {.async.} =
  if transport.connected:
    transport.connected = false
    transport.buffer = ""
    
    # Log transport state
    stderr.writeLine "[MCP] Transport closing..."
    
    try:
      # Flush and close stdout first
      if not transport.stdoutFile.isNil:
        transport.stdoutFile.flushFile()
        transport.stdoutFile.close()
        stderr.writeLine "[MCP] Stdout closed successfully"
      
      # Then flush and close stdin
      if not transport.stdinFile.isNil:
        transport.stdinFile.flushFile()
        transport.stdinFile.close()
        stderr.writeLine "[MCP] Stdin closed successfully"
        
      # Notify closure only after both streams are closed
      if transport.getCloseHandler().isSome:
        transport.getCloseHandler().get()()
        
    except IOError as e:
      stderr.writeLine "[MCP] Error during transport close: ", e.msg
      # Still try to notify closure even if there was an error
      if transport.getCloseHandler().isSome:
        transport.getCloseHandler().get()()

method isConnected*(transport: StdioTransport): bool =
  transport.connected and
  not transport.stdinFile.isNil and
  not transport.stdoutFile.isNil

method isClosed*(transport: StdioTransport): bool =
  not transport.connected or
  transport.stdinFile.isNil or
  transport.stdoutFile.isNil

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

method setConnectionState*(transport: StdioTransport, value: bool) =
  transport.connected = value

export StdioTransport, newStdioTransport