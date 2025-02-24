import std/[asyncdispatch, json, options, streams, strutils, strformat]
import ./base_types
import ./transport

type
  MessageHandler* = proc(message: JsonNode) {.closure.}
  ErrorHandler* = proc(error: McpError) {.closure.}
  CloseHandler* = proc() {.closure.}

  StdioTransport* = ref object of Transport
    inStream: FileStream
    outStream: FileStream
    buffer: string
    messageQueue: seq[JsonNode]
    connected: bool
    onmessage: Option[MessageHandler]
    onerror: Option[ErrorHandler]
    onclose: Option[CloseHandler]

const 
  BUFFER_SIZE = 8192
  MAX_MESSAGE_SIZE = 8192  

proc newStdioTransport*(): StdioTransport =
  stderr.writeLine "[MCP] Creating new StdioTransport"
  new(result)
  init(Transport(result))  # Initialize base class
  result.buffer = ""
  result.messageQueue = @[]
  result.connected = false
  stderr.writeLine "[MCP] StdioTransport created successfully"

proc appendToBuffer(transport: StdioTransport, data: string) =
  transport.buffer.add(data)
  if transport.buffer.len > MAX_MESSAGE_SIZE:
    if Transport(transport).getErrorHandler().isSome:
      Transport(transport).getErrorHandler().get()(newMcpError(ErrorCode.InternalError, "Message too large"))
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
    if Transport(transport).getErrorHandler().isSome:
      Transport(transport).getErrorHandler().get()(newMcpError(ErrorCode.ParseError, "Invalid JSON message"))
    return nil

proc processMessages(transport: StdioTransport) =
  while true:
    let message = transport.readMessage()
    if message == nil:
      break
      
    if Transport(transport).getMessageHandler().isSome:
      try:
        let handler = Transport(transport).getMessageHandler().get()
        handler(message)
      except Exception as e:
        stderr.writeLine "[MCP] Error processing message: ", e.msg, "\n", getStackTrace(e)
        if Transport(transport).getErrorHandler().isSome:
          Transport(transport).getErrorHandler().get()(newMcpError(ErrorCode.InternalError, "Error processing message: " & e.msg))

method start*(transport: StdioTransport): Future[void] {.async.} =
  stderr.writeLine "[MCP] Starting StdioTransport"
  if transport.isConnected():
    raise newMcpError(ErrorCode.InvalidRequest, "Transport already started")
  
  # 设置无缓冲模式
  stdout.flushFile()
  stderr.flushFile()
  
  transport.setConnected(true)
  stderr.writeLine "[MCP] Transport connected"
  
  # Create a promise that will be resolved when the message loop is ready
  var readyPromise = newFuture[void]("messageLoopReady")
  var ioReady = false
  
  # Start message receiving loop
  proc messageLoop() {.async.} =
    stderr.writeLine "[MCP] Starting message receiving loop"
    var buffer = newString(BUFFER_SIZE)
    
    try:
      # 尝试第一次读取以确保I/O正常工作
      let initialRead = stdin.readBuffer(addr buffer[0], 1)
      if initialRead > 0:
        ioReady = true
        transport.appendToBuffer(buffer[0 ..< initialRead])
      elif initialRead == 0:  # stdin closed
        stderr.writeLine "[MCP] stdin closed, initiating shutdown"
        transport.setConnected(false)
        if transport.getCloseHandler().isSome:
          transport.getCloseHandler().get()()
        return
    except Exception as e:
      stderr.writeLine "[MCP] Error in initial read: ", e.msg
      return
    
    # Signal that we're ready to receive messages
    readyPromise.complete()
    stderr.writeLine "[MCP] Message loop ready"
    
    while transport.isConnected():
      try:
        var bytesRead = stdin.readAll()
        if bytesRead.len == 0:  # stdin closed
          stderr.writeLine "[MCP] stdin closed, initiating shutdown"
          transport.setConnected(false)
          if transport.getCloseHandler().isSome:
            transport.getCloseHandler().get()()
          break
        transport.appendToBuffer(bytesRead)
        transport.processMessages()
            
      except Exception as e:
        stderr.writeLine "[MCP] Error in message loop: ", e.msg, "\n", getStackTrace(e)
        if transport.getErrorHandler().isSome:
          transport.getErrorHandler().get()(newMcpError(ErrorCode.InternalError, "Error receiving message: " & e.msg))
  
  asyncCheck messageLoop()
  
  stderr.writeLine "[MCP] Waiting for message loop to be ready"
  await readyPromise
  
  # 确保I/O正常工作
  if not ioReady:
    raise newMcpError(ErrorCode.InternalError, "Failed to initialize I/O")
    
  stderr.writeLine "[MCP] StdioTransport start completed"

method send*(transport: StdioTransport, message: JsonNode): Future[void] {.async.} =
  if not transport.isConnected():
    raise newMcpError(ErrorCode.ConnectionClosed, "Transport not connected")
  
  try:
    let messageStr = $message & "\n"
    # Only write JSON message to stdout
    discard stdout.writeBuffer(cstring(messageStr), messageStr.len)
    stdout.flushFile()
    
    # Debug message only to stderr
    stderr.writeLine "[MCP] Message sent successfully"
    stderr.flushFile()
  except Exception as e:
    stderr.writeLine "[MCP] Failed to send message: ", e.msg
    raise newMcpError(ErrorCode.InternalError, "Failed to send message: " & e.msg)

method close*(transport: StdioTransport): Future[void] {.async.} =
  if transport.isConnected():
    transport.setConnected(false)
    
    if not transport.inStream.isNil:
      transport.inStream.close()
    if not transport.outStream.isNil:
      transport.outStream.close()
    
    if transport.getCloseHandler().isSome:
      transport.getCloseHandler().get()()

method isClosed*(transport: StdioTransport): bool =
  result = not transport.isConnected() or
           transport.inStream.isNil or transport.outStream.isNil

proc setMessageHandler*(transport: StdioTransport, handler: proc(message: JsonNode)) =
  transport.onmessage = some(handler)

proc setErrorHandler*(transport: StdioTransport, handler: proc(error: McpError)) =
  transport.onerror = some(handler)

proc setCloseHandler*(transport: StdioTransport, handler: proc()) =
  transport.onclose = some(handler)

proc debug(msg: string) =
  stderr.writeLine(&"[STDIO] {msg}")
  stderr.flushFile()

proc write*(transport: StdioTransport, message: JsonNode) {.async.} =
  try:
    let messageStr = $message & "\n"
    stdout.write(messageStr)
    stdout.flushFile()  # Ensure message is sent immediately
    debug("Message sent successfully")
  except Exception as e:
    debug(&"Error writing message: {e.msg}")
    raise newMcpError(ErrorCode.InternalError, &"Failed to write message: {e.msg}")

export StdioTransport, newStdioTransport