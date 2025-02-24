import std/[asyncdispatch, json, options, os, strutils, times, strformat, algorithm]
import ./shared/base_types

type
  AuditEventKind* = enum
    aeAccess,    # Resource access events
    aeModify,    # Resource modification events
    aeSecurity,  # Security-related events (login, permission changes, etc.)
    aeSystem     # System events (startup, shutdown, etc.)

  AuditEvent* = object
    id*: string
    kind*: AuditEventKind
    timestamp*: Time
    userId*: string
    resource*: string
    action*: string
    details*: JsonNode
    success*: bool
    errorMessage*: Option[string]

  AuditLogger* = ref object
    logDir*: string
    currentLogFile*: File
    maxFileSize*: int64
    maxFiles*: int
    onEvent*: Option[proc(event: AuditEvent) {.async.}]

proc newAuditEvent*(
  kind: AuditEventKind,
  userId: string,
  resource: string,
  action: string,
  details: JsonNode = newJObject(),
  success = true,
  errorMessage: Option[string] = none(string)
): AuditEvent =
  AuditEvent(
    id: $getTime().toUnix,
    kind: kind,
    timestamp: getTime(),
    userId: userId,
    resource: resource,
    action: action,
    details: details,
    success: success,
    errorMessage: errorMessage
  )

proc newAuditLogger*(logDir: string, maxFileSize = 10_000_000, maxFiles = 10): AuditLogger =
  result = AuditLogger(
    logDir: logDir,
    maxFileSize: maxFileSize,
    maxFiles: maxFiles,
    onEvent: none(proc(event: AuditEvent) {.async.})
  )
  createDir(logDir)
  let currentLogPath = logDir / "audit.log"
  result.currentLogFile = open(currentLogPath, fmAppend)

proc rotateLogFile(logger: AuditLogger) =
  # Close current log file
  logger.currentLogFile.close()

  # Get list of existing log files
  var logFiles = newSeq[string]()
  for entry, path in walkDir(logger.logDir):
    if entry == pcFile and path.endsWith(".log"):
      logFiles.add(path)

  # Sort by modification time (newest first)
  logFiles.sort(proc(a, b: string): int =
    let timeA = getFileInfo(a).lastWriteTime
    let timeB = getFileInfo(b).lastWriteTime
    if timeA < timeB: 1
    elif timeA > timeB: -1
    else: 0
  )

  # Remove oldest files if we exceed maxFiles
  while logFiles.len >= logger.maxFiles:
    let oldestFile = logFiles.pop()
    removeFile(oldestFile)

  # Rename current log file
  let timestamp = times.utc(now()).format("yyyy-MM-dd-HH-mm-ss")
  let newPath = logger.logDir / fmt"audit-{timestamp}.log"
  moveFile(logger.logDir / "audit.log", newPath)

  # Open new log file
  logger.currentLogFile = open(logger.logDir / "audit.log", fmAppend)

proc toJson*(event: AuditEvent): JsonNode =
  result = %*{
    "id": event.id,
    "kind": $event.kind,
    "timestamp": event.timestamp.toUnix,
    "userId": event.userId,
    "resource": event.resource,
    "action": event.action,
    "details": event.details,
    "success": event.success
  }
  if event.errorMessage.isSome:
    result["errorMessage"] = %event.errorMessage.get

proc log*(logger: AuditLogger, event: AuditEvent) {.async.} =
  # Write event to log file
  let logLine = $event.toJson & "\n"
  logger.currentLogFile.write(logLine)
  logger.currentLogFile.flushFile()

  # Check if we need to rotate
  if getFileSize(logger.logDir / "audit.log") > logger.maxFileSize:
    logger.rotateLogFile()

  # Notify event handler if registered
  if logger.onEvent.isSome:
    await logger.onEvent.get()(event)

proc close*(logger: AuditLogger) =
  if not logger.currentLogFile.isNil:
    logger.currentLogFile.close()

proc searchLogs*(logger: AuditLogger, 
                startTime: Option[Time] = none(Time),
                endTime: Option[Time] = none(Time),
                userId: Option[string] = none(string),
                resource: Option[string] = none(string),
                action: Option[string] = none(string),
                eventKind: Option[AuditEventKind] = none(AuditEventKind)
               ): seq[AuditEvent] =
  result = @[]
  
  # Search through all log files
  for entry, path in walkDir(logger.logDir):
    if entry != pcFile or not path.endsWith(".log"):
      continue

    let file = open(path)
    defer: file.close()

    # Read and parse each line
    for line in file.lines:
      let eventJson = parseJson(line)
      let event = AuditEvent(
        id: eventJson["id"].getStr,
        kind: parseEnum[AuditEventKind](eventJson["kind"].getStr),
        timestamp: fromUnix(eventJson["timestamp"].getInt),
        userId: eventJson["userId"].getStr,
        resource: eventJson["resource"].getStr,
        action: eventJson["action"].getStr,
        details: eventJson["details"],
        success: eventJson["success"].getBool,
        errorMessage: if eventJson.hasKey("errorMessage"): some(eventJson["errorMessage"].getStr) else: none(string)
      )

      # Apply filters
      if startTime.isSome and event.timestamp < startTime.get:
        continue
      if endTime.isSome and event.timestamp > endTime.get:
        continue
      if userId.isSome and event.userId != userId.get:
        continue
      if resource.isSome and event.resource != resource.get:
        continue
      if action.isSome and event.action != action.get:
        continue
      if eventKind.isSome and event.kind != eventKind.get:
        continue

      result.add(event) 