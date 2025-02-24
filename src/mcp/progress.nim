import std/[asyncdispatch, json, options, times]
import ./shared/base_types

type
  ProgressState* = enum
    psRunning,
    psPaused,
    psCompleted,
    psCancelled,
    psError

  ProgressInfo* = object
    total*: int
    current*: int
    message*: string
    state*: ProgressState
    error*: Option[string]
    startTime*: Time
    updateTime*: Time

  ProgressToken* = object
    id*: string
    info*: ProgressInfo
    onUpdate*: Option[proc(info: ProgressInfo) {.async.}]
    onComplete*: Option[proc() {.async.}]
    onError*: Option[proc(msg: string) {.async.}]
    onCancel*: Option[proc() {.async.}]

  ProgressManager* = ref object
    tokens*: Table[string, ProgressToken]
    nextId*: int

proc newProgressInfo*(total: int): ProgressInfo =
  let now = getTime()
  ProgressInfo(
    total: total,
    current: 0,
    message: "",
    state: psRunning,
    error: none(string),
    startTime: now,
    updateTime: now
  )

proc newProgressToken*(info: ProgressInfo): ProgressToken =
  ProgressToken(
    id: $getTime().toUnix & $rand(1000),
    info: info,
    onUpdate: none(proc(info: ProgressInfo) {.async.}),
    onComplete: none(proc() {.async.}),
    onError: none(proc(msg: string) {.async.}),
    onCancel: none(proc() {.async.})
  )

proc newProgressManager*(): ProgressManager =
  ProgressManager(
    tokens: initTable[string, ProgressToken](),
    nextId: 1
  )

proc registerToken*(manager: ProgressManager, token: ProgressToken) =
  manager.tokens[token.id] = token

proc unregisterToken*(manager: ProgressManager, id: string) =
  manager.tokens.del(id)

proc getToken*(manager: ProgressManager, id: string): Option[ProgressToken] =
  if manager.tokens.hasKey(id):
    some(manager.tokens[id])
  else:
    none(ProgressToken)

proc update*(token: var ProgressToken, current: int, message = "") {.async.} =
  token.info.current = current
  if message != "":
    token.info.message = message
  token.info.updateTime = getTime()
  
  if token.onUpdate.isSome:
    await token.onUpdate.get()(token.info)

proc complete*(token: var ProgressToken) {.async.} =
  token.info.state = psCompleted
  token.info.current = token.info.total
  token.info.updateTime = getTime()
  
  if token.onComplete.isSome:
    await token.onComplete.get()()

proc error*(token: var ProgressToken, msg: string) {.async.} =
  token.info.state = psError
  token.info.error = some(msg)
  token.info.updateTime = getTime()
  
  if token.onError.isSome:
    await token.onError.get()(msg)

proc cancel*(token: var ProgressToken) {.async.} =
  token.info.state = psCancelled
  token.info.updateTime = getTime()
  
  if token.onCancel.isSome:
    await token.onCancel.get()()

proc pause*(token: var ProgressToken) =
  token.info.state = psPaused
  token.info.updateTime = getTime()

proc resume*(token: var ProgressToken) =
  token.info.state = psRunning
  token.info.updateTime = getTime()

proc toJson*(info: ProgressInfo): JsonNode =
  %*{
    "total": info.total,
    "current": info.current,
    "message": info.message,
    "state": $info.state,
    "error": if info.error.isSome: info.error.get else: nil,
    "startTime": info.startTime.toUnix,
    "updateTime": info.updateTime.toUnix
  }

proc toJson*(token: ProgressToken): JsonNode =
  %*{
    "id": token.id,
    "info": token.info.toJson
  } 