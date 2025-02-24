import std/[asyncdispatch, json, options, tables, times]

type
  ServerEventKind* = enum
    sekConnect,
    sekDisconnect,
    sekError,
    sekRequest,
    sekResponse,
    sekNotification,
    sekProgress,
    sekCustom

  ServerEvent* = object
    case kind*: ServerEventKind
    of sekConnect, sekDisconnect:
      discard
    of sekError:
      error*: ref Exception
      errorCode*: int
      errorMessage*: string
    of sekRequest:
      requestId*: string
      requestMethod*: string
      requestParams*: JsonNode
    of sekResponse:
      responseId*: string
      responseResult*: JsonNode
    of sekNotification:
      notificationMethod*: string
      notificationParams*: JsonNode
    of sekProgress:
      progressToken*: string
      progressValue*: float
      progressMessage*: string
    of sekCustom:
      customType*: string
      customData*: JsonNode

  ServerEventContext* = object
    timestamp*: Time
    event*: ServerEvent
    metadata*: JsonNode

  EventHandler* = proc(context: ServerEventContext) {.async.}

  EventEmitter* = ref object
    handlers*: Table[ServerEventKind, seq[EventHandler]]

proc newServerEvent*(kind: ServerEventKind): ServerEvent =
  ServerEvent(kind: kind)

proc newErrorEvent*(error: ref Exception, code: int, message: string): ServerEvent =
  ServerEvent(
    kind: sekError,
    error: error,
    errorCode: code,
    errorMessage: message
  )

proc newRequestEvent*(id: string, `method`: string, params: JsonNode): ServerEvent =
  ServerEvent(
    kind: sekRequest,
    requestId: id,
    requestMethod: `method`,
    requestParams: params
  )

proc newResponseEvent*(id: string, responseResult: JsonNode): ServerEvent =
  ServerEvent(
    kind: sekResponse,
    responseId: id,
    responseResult: responseResult
  )

proc newNotificationEvent*(`method`: string, params: JsonNode): ServerEvent =
  ServerEvent(
    kind: sekNotification,
    notificationMethod: `method`,
    notificationParams: params
  )

proc newProgressEvent*(token: string, value: float, message: string = ""): ServerEvent =
  ServerEvent(
    kind: sekProgress,
    progressToken: token,
    progressValue: value,
    progressMessage: message
  )

proc newCustomEvent*(`type`: string, data: JsonNode): ServerEvent =
  ServerEvent(
    kind: sekCustom,
    customType: `type`,
    customData: data
  )

proc newServerEventContext*(event: ServerEvent, metadata: JsonNode = newJObject()): ServerEventContext =
  ServerEventContext(
    timestamp: getTime(),
    event: event,
    metadata: metadata
  )

proc newEventEmitter*(): EventEmitter =
  EventEmitter(handlers: initTable[ServerEventKind, seq[EventHandler]]())

proc on*(emitter: EventEmitter, kind: ServerEventKind, handler: EventHandler) =
  if not emitter.handlers.hasKey(kind):
    emitter.handlers[kind] = @[]
  emitter.handlers[kind].add(handler)

proc off*(emitter: EventEmitter, kind: ServerEventKind, handler: EventHandler) =
  if emitter.handlers.hasKey(kind):
    let idx = emitter.handlers[kind].find(handler)
    if idx >= 0:
      emitter.handlers[kind].delete(idx)

proc emit*(emitter: EventEmitter, event: ServerEvent, metadata: JsonNode = newJObject()): Future[void] {.async.} =
  if not emitter.handlers.hasKey(event.kind):
    return

  let context = newServerEventContext(event, metadata)
  var futures: seq[Future[void]] = @[]
  
  for handler in emitter.handlers[event.kind]:
    futures.add(handler(context))
  
  await all(futures)

# Helper functions for common event patterns
proc onConnect*(emitter: EventEmitter, handler: EventHandler) =
  emitter.on(sekConnect, handler)

proc onDisconnect*(emitter: EventEmitter, handler: EventHandler) =
  emitter.on(sekDisconnect, handler)

proc onError*(emitter: EventEmitter, handler: EventHandler) =
  emitter.on(sekError, handler)

proc onRequest*(emitter: EventEmitter, handler: EventHandler) =
  emitter.on(sekRequest, handler)

proc onResponse*(emitter: EventEmitter, handler: EventHandler) =
  emitter.on(sekResponse, handler)

proc onNotification*(emitter: EventEmitter, handler: EventHandler) =
  emitter.on(sekNotification, handler)

proc onProgress*(emitter: EventEmitter, handler: EventHandler) =
  emitter.on(sekProgress, handler)

proc onCustom*(emitter: EventEmitter, handler: EventHandler) =
  emitter.on(sekCustom, handler)

# Event filtering helpers
proc filterEventsByKind*(events: seq[ServerEventContext], kind: ServerEventKind): seq[ServerEventContext] =
  var filtered: seq[ServerEventContext] = @[]
  for event in events:
    if event.event.kind == kind:
      filtered.add(event)
  filtered

proc filterEventsByTimeRange*(events: seq[ServerEventContext], start: Time, `end`: Time): seq[ServerEventContext] =
  var filtered: seq[ServerEventContext] = @[]
  for event in events:
    if event.timestamp >= start and event.timestamp <= `end`:
      filtered.add(event)
  filtered

proc filterEventsByMetadata*(events: seq[ServerEventContext], key: string, value: JsonNode): seq[ServerEventContext] =
  var filtered: seq[ServerEventContext] = @[]
  for event in events:
    if event.metadata.hasKey(key) and event.metadata[key] == value:
      filtered.add(event)
  filtered 