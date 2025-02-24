import std/[asyncdispatch, json, options, os, strformat, strutils, times, tables, sequtils]
import ./events
import ./shared/base_types

type
  FileSystemEventKind* = enum
    fseCreated,
    fseModified,
    fseDeleted,
    fseRenamed,
    fseError

  FileSystemEvent* = object
    timestamp*: Time  # Common field for all variants
    case kind*: FileSystemEventKind
    of fseCreated, fseModified, fseDeleted:
      path*: string
    of fseRenamed:
      oldPath*: string
      newPath*: string
    of fseError:
      errorPath*: string
      errorMsg*: string

  FileSystemWatcher* = ref object
    path*: string
    recursive*: bool
    filters*: seq[string]
    onEvent*: proc(event: FileSystemEvent) {.async.}
    running*: bool

proc newFileSystemEvent*(kind: FileSystemEventKind, path: string): FileSystemEvent =
  case kind
  of fseCreated, fseModified, fseDeleted:
    FileSystemEvent(
      kind: kind,
      path: path,
      timestamp: getTime()
    )
  of fseRenamed:
    raise newException(ValueError, "Use newFileSystemRenameEvent for rename events")
  of fseError:
    raise newException(ValueError, "Use newFileSystemErrorEvent for error events")

proc newFileSystemRenameEvent*(oldPath, newPath: string): FileSystemEvent =
  FileSystemEvent(
    kind: fseRenamed,
    oldPath: oldPath,
    newPath: newPath,
    timestamp: getTime()
  )

proc newFileSystemErrorEvent*(path: string, msg: string): FileSystemEvent =
  FileSystemEvent(
    kind: fseError,
    errorPath: path,
    errorMsg: msg,
    timestamp: getTime()
  )

proc newFileSystemWatcher*(path: string, recursive = false, filters: seq[string] = @[]): FileSystemWatcher =
  FileSystemWatcher(
    path: path,
    recursive: recursive,
    filters: filters,
    running: false
  )

proc matchesFilter(path: string, filters: seq[string]): bool =
  if filters.len == 0:
    return true
  
  let filename = extractFilename(path)
  for filter in filters:
    if filename.contains(filter):
      return true
  return false

proc watch*(watcher: FileSystemWatcher) {.async.} =
  if watcher.running:
    return

  watcher.running = true
  var lastCheck = initTable[string, Time]()

  while watcher.running:
    try:
      # Get all files in the watched directory
      var files = newSeq[(string, Time)]()
      for file in walkDirRec(watcher.path):
        if not watcher.recursive and parentDir(file) != watcher.path:
          continue
        
        if not matchesFilter(file, watcher.filters):
          continue

        let info = getFileInfo(file)
        files.add((file, info.lastWriteTime))

      # Check for changes
      for (file, time) in files:
        if file notin lastCheck:
          # New file
          if watcher.onEvent != nil:
            await watcher.onEvent(newFileSystemEvent(fseCreated, file))
        elif lastCheck[file] != time:
          # Modified file
          if watcher.onEvent != nil:
            await watcher.onEvent(newFileSystemEvent(fseModified, file))

      # Check for deleted files
      for file, time in lastCheck:
        if files.len == 0 or not files.anyIt(it[0] == file):
          if watcher.onEvent != nil:
            await watcher.onEvent(newFileSystemEvent(fseDeleted, file))

      # Update last check
      lastCheck.clear()
      for (file, time) in files:
        lastCheck[file] = time

      await sleepAsync(1000)  # Check every second
    except Exception as e:
      if watcher.onEvent != nil:
        await watcher.onEvent(newFileSystemErrorEvent(watcher.path, e.msg))
      await sleepAsync(5000)  # Wait longer after error

proc stop*(watcher: FileSystemWatcher) =
  watcher.running = false 