import std/[asyncdispatch, json, options, os, strformat, strutils, times, sequtils, tables, algorithm, sugar, sets]
import ../src/mcp/types as mcp_types
import ../src/mcp/shared/[protocol, transport, stdio, base_types]
import ../src/mcp/server
import ../src/mcp/filesystem_server
import ../src/mcp/tools
import ../src/mcp/validation
import ../src/mcp/events
import ../src/mcp/audit
import ../src/mcp/security

type
  FilesystemCapabilities = object
    allowedPaths: seq[string]

var globalShutdownRequested = false

proc validatePath(requestedPath: string, allowedPaths: seq[string]): string =
  let normalizedPath = normalizedPath(absolutePath(requestedPath))
  for allowedPath in allowedPaths:
    if normalizedPath.startsWith(allowedPath):
      return normalizedPath
  raise newMcpError(ErrorCode.InvalidRequest, "Path not allowed: " & requestedPath)

proc getFileInfo(path: string): JsonNode =
  let fi = os.getFileInfo(path)
  let perms = getFilePermissions(path)
  let permStr = cast[int](perms).toOct(3)
  result = %*{
    "size": fi.size.int64,
    "created": fi.creationTime.toUnix.int64,
    "modified": fi.lastWriteTime.toUnix.int64,
    "accessed": fi.lastAccessTime.toUnix.int64,
    "isDirectory": fi.kind == pcDir,
    "isFile": fi.kind == pcFile,
    "permissions": permStr
  }



proc setupLogging(server: FileSystemServer) =
  # 设置日志目录
  let logDir = getCurrentDir() / "logs"
  createDir(logDir)
  
  # 设置审计日志处理器
  proc eventHandler(context: ServerEventContext) {.async.} =
    let formatNow = times.utc(now()).format("yyyy-MM-dd HH:mm:ss'Z'")
    let eventType = case context.event.kind
    of sekCustom:
      if context.event.customType == "audit":
        let data = context.event.customData
        case data["type"].getStr
        of "access": "ACCESS"
        of "modify": "MODIFY"
        of "security": "SECURITY"
        else: "UNKNOWN"
      else: "CUSTOM"
    else: "EVENT"
    
    stderr.writeLine &"[{formatNow}][{eventType}] {context.event.customData}"
  
  server.events.on(sekCustom, eventHandler)

proc setupSecurity(server: FileSystemServer, allowedDirs: seq[string]) =
  # 创建基本角色
  var readPerms = initHashSet[Permission]()
  readPerms.incl(Permission.pRead)
  let readOnlyRole = newRole(
    "readonly",
    "Read-only access to files",
    readPerms
  )
  
  var writePerms = initHashSet[Permission]()
  writePerms.incl(Permission.pRead)
  writePerms.incl(Permission.pWrite)
  let writeRole = newRole(
    "write",
    "Read and write access to files",
    writePerms
  )
  
  var adminPerms = initHashSet[Permission]()
  adminPerms.incl(Permission.pRead)
  adminPerms.incl(Permission.pWrite)
  adminPerms.incl(Permission.pDelete)
  adminPerms.incl(Permission.pExecute)
  adminPerms.incl(Permission.pAdmin)
  let adminRole = newRole(
    "admin",
    "Full access to files",
    adminPerms
  )
  
  # 添加角色
  server.security.addRole(readOnlyRole)
  server.security.addRole(writeRole)
  server.security.addRole(adminRole)
  
  # 为每个允许的目录设置权限
  var dirPerms = initHashSet[Permission]()
  dirPerms.incl(Permission.pRead)
  dirPerms.incl(Permission.pWrite)
  dirPerms.incl(Permission.pDelete)
  for dir in allowedDirs:
    server.security.setResourcePermissions(dir, dirPerms)

proc main() {.async.} =
  var server: FileSystemServer
  var transport: Transport
  var localShutdownRequested = false
  
  proc shutdown() {.async.} =
    if localShutdownRequested:
      return
    
    localShutdownRequested = true
    let formatNow = times.utc(now()).format("yyyy-MM-dd HH:mm:ss'Z'")
    stderr.writeLine &"[{formatNow}][MCP] Initiating shutdown..."
    
    if not isNil(server):
      try:
        await server.close()
        stderr.writeLine &"[{formatNow}][MCP] Server closed successfully"
      except Exception as e:
        stderr.writeLine &"[{formatNow}][MCP] Error closing server: ", e.msg
    
    if not isNil(transport):
      try:
        await transport.close()
        stderr.writeLine &"[{formatNow}][MCP] Transport closed successfully"
      except Exception as e:
        stderr.writeLine &"[{formatNow}][MCP] Error closing transport: ", e.msg
    
    stderr.writeLine &"[{formatNow}][MCP] Shutdown complete, exiting process"
    quit(0)

  try:
    # 解析命令行参数
    let args = commandLineParams()
    if args.len == 0:
      stderr.writeLine "Usage: filesystem_server <allowed-directory> [additional-directories...]"
      quit(1)
    
    # 规范化允许的目录路径
    var allowedDirs = newSeq[string]()
    for arg in args:
      allowedDirs.add(normalizedPath(absolutePath(arg)))
    stderr.writeLine "[MCP] Allowed directories: ", $allowedDirs
    
    # 创建服务器实例
    server = newFileSystemServer(allowedDirs)
    
    # 设置日志和安全
    setupLogging(server)
    setupSecurity(server, allowedDirs)
    
    # 创建传输层
    transport = stdio.newStdioTransport()
    
    # 设置错误处理器
    transport.setErrorHandler(proc(error: McpError) =
      let formatNow = times.utc(now()).format("yyyy-MM-dd HH:mm:ss'Z'")
      stderr.writeLine &"[{formatNow}][MCP] Transport error: ", error.msg
      if error.data.isSome:
        stderr.writeLine &"[{formatNow}][MCP] Error data: ", error.data.get
      asyncCheck shutdown()
    )
    
    # 设置关闭处理器
    transport.setCloseHandler(proc() =
      let formatNow = times.utc(now()).format("yyyy-MM-dd HH:mm:ss'Z'")
      stderr.writeLine &"[{formatNow}][MCP] Transport closed"
      asyncCheck shutdown()
    )
    
    # 启动服务器
    server.start()
    await server.connect(transport)
    
    let formatNow = times.utc(now()).format("yyyy-MM-dd HH:mm:ss'Z'")
    stderr.writeLine &"[{formatNow}][MCP] Server started and connected"
    
    # 主事件循环
    var lastHeartbeat = getTime()
    while server.running and not localShutdownRequested:
      if not transport.isConnected():
        let formatNow = times.utc(now()).format("yyyy-MM-dd HH:mm:ss'Z'")
        stderr.writeLine &"[{formatNow}][MCP] Transport disconnected"
        await shutdown()
        break
      
      # 每30秒发送一次心跳
      if (getTime() - lastHeartbeat).inSeconds >= 30:
        stderr.writeLine &"[{formatNow}][MCP] Sending heartbeat"
        lastHeartbeat = getTime()
      
      await sleepAsync(1000)  # 每秒检查一次连接状态

  except Exception as e:
    let formatNow = times.utc(now()).format("yyyy-MM-dd HH:mm:ss'Z'")
    stderr.writeLine &"[{formatNow}][MCP] Fatal error: ", e.msg
    stderr.writeLine &"[{formatNow}][MCP] Stack trace: ", getStackTrace(e)
    await shutdown()

when isMainModule:
  waitFor main()