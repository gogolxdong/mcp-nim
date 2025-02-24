import std/[asyncdispatch, json, options, uri, strutils]
import pkg/ws
import ./base_types
import ./transport

const SUBPROTOCOL = "mcp"

type
  WebSocketClientTransport* = ref object of Transport
    url*: string
    ws: WebSocket
    isConnected: bool

proc newWebSocketClientTransport*(url: string): WebSocketClientTransport =
  new(result)
  result.url = url
  result.isConnected = false

method start*(transport: WebSocketClientTransport): Future[void] {.async.} =
  if transport.isConnected:
    raise newMcpError(ErrorCode.InvalidRequest, "WebSocket transport already started")

  try:
    transport.ws = await newWebSocket(transport.url, SUBPROTOCOL)
    transport.isConnected = true

    # Start message receiving loop
    asyncCheck (proc() {.async.} =
      while transport.isConnected:
        try:
          let data = await transport.ws.receiveStrPacket()
          let message = parseJson(data)
          if transport.onmessage.isSome:
            transport.onmessage.get()(message)
        except WebSocketError:
          if transport.isConnected:
            transport.isConnected = false
            if transport.onclose.isSome:
              transport.onclose.get()()
            break
        except JsonParsingError as e:
          if transport.onerror.isSome:
            transport.onerror.get()(newMcpError(ErrorCode.ParseError, "Failed to parse message: " & e.msg))
        except Exception as e:
          if transport.onerror.isSome:
            transport.onerror.get()(newMcpError(ErrorCode.InternalError, "Error receiving message: " & e.msg))
    )()
  except Exception as e:
    raise newMcpError(ErrorCode.ConnectionClosed, "Failed to connect: " & e.msg)

method close*(transport: WebSocketClientTransport): Future[void] {.async.} =
  if transport.isConnected:
    transport.isConnected = false
    await transport.ws.close()
    if transport.onclose.isSome:
      transport.onclose.get()()

method send*(transport: WebSocketClientTransport, message: JsonNode): Future[void] {.async.} =
  if not transport.isConnected:
    raise newMcpError(ErrorCode.ConnectionClosed, "Transport not connected")

  try:
    await transport.ws.send($message)
  except Exception as e:
    raise newMcpError(ErrorCode.InternalError, "Failed to send message: " & e.msg)

export WebSocketClientTransport, newWebSocketClientTransport 