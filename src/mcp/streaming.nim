import std/[asyncdispatch, json, options, os, streams, strformat, times]
import ./progress as progress_module
import ./shared/base_types

const
  DEFAULT_CHUNK_SIZE = 1024 * 1024  # 1MB
  DEFAULT_BUFFER_SIZE = 8192  # 8KB

type
  StreamDirection* = enum
    sdRead,
    sdWrite

  StreamState* = enum
    ssReady,
    ssActive,
    ssPaused,
    ssCompleted,
    ssError

  StreamStats* = object
    bytesProcessed*: int64
    chunksProcessed*: int
    startTime*: Time
    endTime*: Option[Time]
    currentSpeed*: float  # bytes per second

  AsyncFileStream* = ref object of RootObj
    fHandle: File
    pos: int64

  FileStreamObj* = ref object
    path*: string
    direction*: StreamDirection
    chunkSize*: int
    state*: StreamState
    stats*: StreamStats
    stream*: AsyncFileStream
    progressToken*: Option[progress_module.ProgressToken]

proc newAsyncFileStream(path: string, mode: FileMode): AsyncFileStream =
  new(result)
  result.fHandle = open(path, mode)
  result.pos = 0

proc readAsync(stream: AsyncFileStream, buffer: var seq[byte]): Future[int] {.async.} =
  result = stream.fHandle.readBuffer(addr buffer[0], buffer.len)
  if result > 0:
    inc(stream.pos, result)

proc writeAsync(stream: AsyncFileStream, data: seq[byte]): Future[int] {.async.} =
  result = stream.fHandle.writeBuffer(unsafeAddr data[0], data.len)
  if result > 0:
    inc(stream.pos, result)

proc close(stream: AsyncFileStream) =
  stream.fHandle.close()

proc newFileStream*(path: string, direction: StreamDirection, chunkSize = DEFAULT_CHUNK_SIZE): FileStreamObj =
  FileStreamObj(
    path: path,
    direction: direction,
    chunkSize: chunkSize,
    state: ssReady,
    stats: StreamStats(
      bytesProcessed: 0,
      chunksProcessed: 0,
      startTime: getTime(),
      endTime: none(Time),
      currentSpeed: 0.0
    ),
    stream: nil,
    progressToken: none(progress_module.ProgressToken)
  )

proc updateStats(stream: FileStreamObj, bytesProcessed: int) =
  stream.stats.bytesProcessed += bytesProcessed
  inc stream.stats.chunksProcessed
  
  let now = getTime()
  let duration = now - stream.stats.startTime
  if duration.inSeconds > 0:
    stream.stats.currentSpeed = float(stream.stats.bytesProcessed) / float(duration.inSeconds)

  if not stream.progressToken.isNone:
    var token = stream.progressToken.get
    asyncCheck token.update(
      int(stream.stats.bytesProcessed),
      &"Processed {stream.stats.bytesProcessed} bytes at {stream.stats.currentSpeed:.2f} B/s"
    )

proc open*(stream: FileStreamObj) {.async.} =
  if stream.state != ssReady:
    raise newMcpError(ErrorCode.InvalidRequest, "Stream is not in ready state")

  try:
    case stream.direction
    of sdRead:
      stream.stream = newAsyncFileStream(stream.path, fmRead)
    of sdWrite:
      stream.stream = newAsyncFileStream(stream.path, fmWrite)
    
    stream.state = ssActive
    
    if stream.progressToken.isNone:
      let info = progress_module.newProgressInfo(
        if stream.direction == sdRead: int(getFileSize(stream.path)) else: high(int)
      )
      stream.progressToken = some(progress_module.newProgressToken(info))
  except:
    stream.state = ssError
    raise

proc close*(stream: FileStreamObj) {.async.} =
  if not stream.stream.isNil:
    stream.stream.close()
    stream.stream = nil
  
  stream.state = ssCompleted
  stream.stats.endTime = some(getTime())
  
  if not stream.progressToken.isNone:
    var token = stream.progressToken.get
    await token.complete()

proc readChunk*(stream: FileStreamObj): Future[seq[byte]] {.async.} =
  if stream.state != ssActive:
    raise newMcpError(ErrorCode.InvalidRequest, "Stream is not active")

  if stream.direction != sdRead:
    raise newMcpError(ErrorCode.InvalidRequest, "Stream is not in read mode")

  var buffer = newSeq[byte](stream.chunkSize)
  let bytesRead = await stream.stream.readAsync(buffer)
  
  if bytesRead == 0:
    await stream.close()
    return @[]

  buffer.setLen(bytesRead)
  stream.updateStats(bytesRead)
  return buffer

proc writeChunk*(stream: FileStreamObj, data: seq[byte]) {.async.} =
  if stream.state != ssActive:
    raise newMcpError(ErrorCode.InvalidRequest, "Stream is not active")

  if stream.direction != sdWrite:
    raise newMcpError(ErrorCode.InvalidRequest, "Stream is not in write mode")

  let bytesWritten = await stream.stream.writeAsync(data)
  if bytesWritten != data.len:
    raise newMcpError(ErrorCode.InternalError, "Failed to write all data")
  stream.updateStats(bytesWritten)

proc pause*(stream: FileStreamObj) =
  if stream.state == ssActive:
    stream.state = ssPaused

proc resume*(stream: FileStreamObj) =
  if stream.state == ssPaused:
    stream.state = ssActive

proc getStats*(stream: FileStreamObj): JsonNode =
  result = %*{
    "bytesProcessed": stream.stats.bytesProcessed,
    "chunksProcessed": stream.stats.chunksProcessed,
    "startTime": stream.stats.startTime.toUnix,
    "currentSpeed": stream.stats.currentSpeed,
    "state": $stream.state
  }
  if stream.stats.endTime.isSome:
    result["endTime"] = %stream.stats.endTime.get.toUnix 