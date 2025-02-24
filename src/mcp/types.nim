import std/[options, json, strformat] 
import std/jsonutils except JsonParsingError
import shared/base_types
export base_types

const
  LATEST_PROTOCOL_VERSION* = "2024-11-05"
  SUPPORTED_PROTOCOL_VERSIONS* = [
    LATEST_PROTOCOL_VERSION,
    "2024-10-07"
  ]
  JSONRPC_VERSION* = "2.0"

type
  Progress* = object
    title*: Option[string]
    message*: Option[string]
    percentage*: Option[float]
    cancellable*: bool
    progressToken*: Option[base_types.ProgressToken]

  ProgressNotification* = object
    `method`*: string
    params*: Progress

  Cursor* = distinct string

  Request* = object
    `method`*: string
    params*: JsonNode

  Notification* = object
    `method`*: string
    params*: JsonNode

  McpResult* = object
    meta*: Option[JsonNode]
    data*: Option[JsonNode]

  ClientInfo* = object
    name*: string
    version*: string
  
  ServerCapabilities* = object
    tools*: JsonNode

  MessageCallback* = proc(message: JsonNode) {.closure.}

  JsonTypeError* = object of JsonParsingError

# Constructor helpers for Cursor
proc newCursor*(value: string): Cursor =
  Cursor(value)

proc `$`*(cursor: Cursor): string =
  string(cursor)

# JSON serialization helpers
proc `%`*(cursor: Cursor): JsonNode =
  %($cursor)

proc `%`*(progress: Progress): JsonNode =
  result = newJObject()
  if progress.title.isSome:
    result["title"] = %progress.title.get
  if progress.message.isSome:
    result["message"] = %progress.message.get
  if progress.percentage.isSome:
    result["percentage"] = %progress.percentage.get
  result["cancellable"] = %progress.cancellable
  if progress.progressToken.isSome:
    result["progressToken"] = %progress.progressToken.get

proc `%`*(notification: ProgressNotification): JsonNode =
  %*{
    "method": notification.`method`,
    "params": notification.params
  }

proc `%`*(info: ClientInfo): JsonNode =
  %*{
    "name": info.name,
    "version": info.version
  }

proc `%`*(capabilities: ServerCapabilities): JsonNode =
  %*{
    "tools": capabilities.tools
  }

proc raiseTypeError(expected, actual: JsonNodeKind, node: JsonNode) =
  let info = instantiationInfo()
  var msg = &"JSON类型错误：期待{expected}类型，实际收到{actual}类型"
  msg &= &"\n位置：{info.filename}:{info.line}"
  raise newException(JsonTypeError, msg)

proc toMcp*(node: JsonNode, _: typedesc[Progress]): Progress =
  result = Progress(
    title: if node.hasKey("title"): some(node["title"].getStr) else: none(string),
    message: if node.hasKey("message"): some(node["message"].getStr) else: none(string),
    percentage: if node.hasKey("percentage"): some(node["percentage"].getFloat) else: none(float),
    cancellable: if node.hasKey("cancellable"): node["cancellable"].getBool else: false,
    progressToken: if node.hasKey("progressToken"): some(node["progressToken"].fromJson(base_types.ProgressToken)) else: none(base_types.ProgressToken)
  )

proc toMcp*(node: JsonNode, _: typedesc[ProgressNotification]): ProgressNotification =
  result = ProgressNotification(
    `method`: node["method"].getStr,
    params: node["params"].toMcp(Progress)
  )

proc toMcp*(node: JsonNode, _: typedesc[ClientInfo]): ClientInfo =
  result = ClientInfo(
    name: node["name"].getStr,
    version: node["version"].getStr
  )

proc toMcp*(node: JsonNode, _: typedesc[ServerCapabilities]): ServerCapabilities =
  result = ServerCapabilities(
    tools: if node.hasKey("tools"): node["tools"] else: newJObject()
  )

export 
  Progress, ProgressNotification,
  Cursor, Request, Notification,
  McpResult, ClientInfo, ServerCapabilities,
  MessageCallback,
  newCursor,
  toMcp