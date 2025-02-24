import std/[asyncdispatch, json, options, os, strformat, strutils, times, sequtils, tables, sets]
import ./filesystem_tools except getFileInfo
import ./tools
import ./events
import ./audit
import ./security
import ./shared/[protocol, transport, base_types, stdio]
import ./types as mcp_types
import ./validation

type
  FilesystemCapabilities* = object
    allowedPaths*: seq[string]
    maxFileSize*: int64
    supportedOperations*: seq[string]

  FileSystemServer* = ref object
    allowedDirectories*: seq[string]
    tools*: FileSystemTools
    registry*: ToolRegistry
    protocol*: Protocol
    events*: EventEmitter
    audit*: AuditLogger
    security*: AccessControl
    running*: bool
    capabilities*: FilesystemCapabilities

proc validatePath(server: FileSystemServer, path: string): string =
  let normalizedPath = os.normalizedPath(os.absolutePath(path))
  for allowedPath in server.allowedDirectories:
    if normalizedPath.startsWith(allowedPath):
      return normalizedPath
  raise newMcpError(ErrorCode.InvalidRequest, "Path not allowed: " & path)

proc schemaToJson(schema: Schema): JsonNode =
  if schema.isNil:
    return newJObject()
  
  result = %*{
    "type": $schema.schemaType,
    "description": schema.description,
    "required": schema.constraints.required
  }
  
  var properties = newJObject()
  for name, propSchema in schema.constraints.properties:
    properties[name] = schemaToJson(propSchema)
  result["properties"] = properties

proc getFileMetadata(path: string): JsonNode =
  let info = os.getFileInfo(path, followSymlink = true)
  result = %*{
    "size": info.size,
    "modified": info.lastWriteTime.toUnix,
    "created": info.creationTime.toUnix,
    "isDirectory": info.kind == os.pcDir,
    "isFile": info.kind == os.pcFile
  }

proc newFileSystemServer*(allowedDirs: seq[string]): FileSystemServer =
  let serverInfo = mcp_types.ClientInfo(
    name: "secure-filesystem-server",
    version: "0.2.0"
  )

  let capabilities = mcp_types.ServerCapabilities(
    tools: %*{
      "filesystem": {
        "read": true,
        "write": true,
        "delete": true
      }
    }
  )

  result = FileSystemServer(
    allowedDirectories: allowedDirs,
    tools: createFileSystemTools(allowedDirs),
    registry: newToolRegistry(),
    protocol: newProtocol(nil, serverInfo, capabilities),
    events: newEventEmitter(),
    audit: newAuditLogger(getCurrentDir() / "logs"),
    security: newAccessControl(),
    running: false,
    capabilities: FilesystemCapabilities(
      allowedPaths: allowedDirs,
      maxFileSize: 100_000_000, # 100MB
      supportedOperations: @["read", "write", "delete", "list", "create", "move", "copy"]
    )
  )

proc logAuditEvent(server: FileSystemServer, event: AuditEvent) {.async.} =
  await server.audit.log(event)
  let eventJson = %*{
    "type": "audit",
    "data": event.toJson
  }
  await server.events.emit(newCustomEvent("audit", eventJson))

proc handleListDirectory(server: FileSystemServer, params: JsonNode): Future[JsonNode] {.async.} =
  let path = server.validatePath(params["path"].getStr)
  var entries = newJArray()
  
  for kind, name in os.walkDir(path):
    let fullPath = os.joinPath(path, name)
    let info = getFileMetadata(fullPath)
    entries.add(%*{
      "name": os.extractFilename(name),
      "path": name,
      "type": if kind == os.pcDir: "directory" else: "file",
      "metadata": info
    })

  await server.logAuditEvent(newAuditEvent(
    aeAccess,
    "system",
    path,
    "list_directory",
    details = %*{"entries": entries.len}
  ))

  return %*{"entries": entries}

proc handleReadFile(server: FileSystemServer, params: JsonNode): Future[JsonNode] {.async.} =
  let path = server.validatePath(params["path"].getStr)
  let content = readFile(path)

  await server.logAuditEvent(newAuditEvent(
    aeAccess,
    "system",
    path,
    "read_file",
    details = %*{"size": content.len}
  ))

  return %*{"content": content}

proc handleWriteFile(server: FileSystemServer, params: JsonNode): Future[JsonNode] {.async.} =
  let path = server.validatePath(params["path"].getStr)
  let content = params["content"].getStr
  
  if content.len > server.capabilities.maxFileSize:
    raise newMcpError(ErrorCode.InvalidRequest, "File too large")

  writeFile(path, content)

  await server.logAuditEvent(newAuditEvent(
    aeModify,
    "system",
    path,
    "write_file",
    details = %*{"size": content.len}
  ))

  return %*{"success": true}

proc handleDeleteFile(server: FileSystemServer, params: JsonNode): Future[JsonNode] {.async.} =
  let path = server.validatePath(params["path"].getStr)
  removeFile(path)

  await server.logAuditEvent(newAuditEvent(
    aeModify,
    "system",
    path,
    "delete_file"
  ))

  return %*{"success": true}

proc handleCreateDirectory(server: FileSystemServer, params: JsonNode): Future[JsonNode] {.async.} =
  let path = server.validatePath(params["path"].getStr)
  createDir(path)

  await server.logAuditEvent(newAuditEvent(
    aeModify,
    "system",
    path,
    "create_directory"
  ))

  return %*{"success": true}

proc handleMoveFile(server: FileSystemServer, params: JsonNode): Future[JsonNode] {.async.} =
  let sourcePath = server.validatePath(params["source"].getStr)
  let destPath = server.validatePath(params["destination"].getStr)
  
  moveFile(sourcePath, destPath)

  await server.logAuditEvent(newAuditEvent(
    aeModify,
    "system",
    sourcePath,
    "move_file",
    details = %*{"destination": destPath}
  ))

  return %*{"success": true}

proc handleCopyFile(server: FileSystemServer, params: JsonNode): Future[JsonNode] {.async.} =
  let sourcePath = server.validatePath(params["source"].getStr)
  let destPath = server.validatePath(params["destination"].getStr)
  
  copyFile(sourcePath, destPath)

  await server.logAuditEvent(newAuditEvent(
    aeModify,
    "system",
    sourcePath,
    "copy_file",
    details = %*{"destination": destPath}
  ))

  return %*{"success": true}

proc handleGetFileInfo(server: FileSystemServer, params: JsonNode): Future[JsonNode] {.async.} =
  let path = server.validatePath(params["path"].getStr)
  let info = getFileInfo(path)

  await server.logAuditEvent(newAuditEvent(
    aeAccess,
    "system",
    path,
    "get_file_info"
  ))

  return %*{
    "size": info.size,
    "created": info.creationTime.toUnix,
    "modified": info.lastWriteTime.toUnix,
    "accessed": info.lastAccessTime.toUnix,
    "isDirectory": info.kind == os.pcDir,
    "isFile": info.kind == os.pcFile
  }

proc handleSearchFiles(server: FileSystemServer, params: JsonNode): Future[JsonNode] {.async.} =
  let path = server.validatePath(params["path"].getStr)
  let pattern = params["pattern"].getStr
  var excludePatterns = newSeq[string]()
  if params.hasKey("excludePatterns"):
    for pattern in params["excludePatterns"]:
      excludePatterns.add(pattern.getStr)
  
  var matches = newJArray()
  for file in walkDirRec(path):
    var excluded = false
    for exclude in excludePatterns:
      if file.contains(exclude):
        excluded = true
        break
    if not excluded and file.contains(pattern):
      matches.add(%file)

  await server.logAuditEvent(newAuditEvent(
    aeAccess,
    "system",
    path,
    "search_files",
    details = %*{
      "pattern": pattern,
      "matches": matches.len
    }
  ))

  return %*{"matches": matches}

proc registerTools(server: FileSystemServer) =
  # Register all tools with schemas
  server.registry.registerTool(newTool(
    "list_directory",
    "List contents of a directory",
    newObjectSchema(
      required = @["path"],
      properties = {"path": newStringSchema("Directory path")}.toTable
    ),
    proc(args: JsonNode): Future[ToolResult] {.async.} =
      let response = await server.handleListDirectory(args)
      return newToolResult(response)
  ))

  server.registry.registerTool(newTool(
    "read_file",
    "Read file contents",
    newObjectSchema(
      required = @["path"],
      properties = {"path": newStringSchema("File path")}.toTable
    ),
    proc(args: JsonNode): Future[ToolResult] {.async.} =
      let response = await server.handleReadFile(args)
      return newToolResult(response)
  ))

  server.registry.registerTool(newTool(
    "write_file",
    "Write to file",
    newObjectSchema(
      required = @["path", "content"],
      properties = {
        "path": newStringSchema("File path"),
        "content": newStringSchema("File content")
      }.toTable
    ),
    proc(args: JsonNode): Future[ToolResult] {.async.} =
      let response = await server.handleWriteFile(args)
      return newToolResult(response)
  ))

  server.registry.registerTool(newTool(
    "delete_file",
    "Delete file",
    newObjectSchema(
      required = @["path"],
      properties = {"path": newStringSchema("File path")}.toTable
    ),
    proc(args: JsonNode): Future[ToolResult] {.async.} =
      let response = await server.handleDeleteFile(args)
      return newToolResult(response)
  ))

  server.registry.registerTool(newTool(
    "create_directory",
    "Create directory",
    newObjectSchema(
      required = @["path"],
      properties = {"path": newStringSchema("Directory path")}.toTable
    ),
    proc(args: JsonNode): Future[ToolResult] {.async.} =
      let response = await server.handleCreateDirectory(args)
      return newToolResult(response)
  ))

  server.registry.registerTool(newTool(
    "move_file",
    "Move/rename file",
    newObjectSchema(
      required = @["source", "destination"],
      properties = {
        "source": newStringSchema("Source path"),
        "destination": newStringSchema("Destination path")
      }.toTable
    ),
    proc(args: JsonNode): Future[ToolResult] {.async.} =
      let response = await server.handleMoveFile(args)
      return newToolResult(response)
  ))

  server.registry.registerTool(newTool(
    "copy_file",
    "Copy file",
    newObjectSchema(
      required = @["source", "destination"],
      properties = {
        "source": newStringSchema("Source path"),
        "destination": newStringSchema("Destination path")
      }.toTable
    ),
    proc(args: JsonNode): Future[ToolResult] {.async.} =
      let response = await server.handleCopyFile(args)
      return newToolResult(response)
  ))

  server.registry.registerTool(newTool(
    "get_file_info",
    "Get file information",
    newObjectSchema(
      required = @["path"],
      properties = {"path": newStringSchema("File path")}.toTable
    ),
    proc(args: JsonNode): Future[ToolResult] {.async.} =
      let response = await server.handleGetFileInfo(args)
      return newToolResult(response)
  ))

  server.registry.registerTool(newTool(
    "search_files",
    "Search for files",
    newObjectSchema(
      required = @["path", "pattern"],
      properties = {
        "path": newStringSchema("Directory path"),
        "pattern": newStringSchema("Search pattern"),
        "excludePatterns": newArraySchema("Patterns to exclude", newStringSchema())
      }.toTable
    ),
    proc(args: JsonNode): Future[ToolResult] {.async.} =
      let response = await server.handleSearchFiles(args)
      return newToolResult(response)
  ))

proc handleInitialize*(server: FileSystemServer, request: JsonRpcRequest): Future[JsonNode] {.async.} =
  let formatNow = times.utc(now()).format("yyyy-MM-dd HH:mm:ss'Z'")
  stderr.writeLine &"[{formatNow}][MCP] Starting initialization..."
  
  result = %*{
    "protocolVersion": "2024-11-05",
    "capabilities": {
      "tools": {
        "filesystem": {
          "read": true,
          "write": true,
          "delete": true
        }
      }
    },
    "serverInfo": {
      "name": "secure-filesystem-server",
      "version": "0.2.0"
    }
  }

  stderr.writeLine &"[{formatNow}][MCP] Initialization response prepared"

  await server.logAuditEvent(newAuditEvent(
    aeSystem,
    "system",
    "",
    "initialize",
    details = %*{"clientInfo": request.params}
  ))

  stderr.writeLine &"[{formatNow}][MCP] Initialization completed"

proc start*(server: FileSystemServer) =
  # Register request handlers
  server.protocol.setRequestHandler("initialize",
    proc(request: JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
      result = await server.handleInitialize(request)
  )

  server.protocol.setRequestHandler("tools/list",
    proc(request: JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
      var tools = newJArray()
      for tool in server.registry.listTools():
        tools.add(%*{
          "name": tool.name,
          "description": tool.description,
          "inputSchema": schemaToJson(tool.schema)
        })
      return %*{"tools": tools}
  )

  server.protocol.setRequestHandler("executeTool",
    proc(request: JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
      let toolName = request.params["name"].getStr
      let args = request.params["arguments"]
      let result = await server.registry.executeTool(toolName, args)
      return %*{
        "result": result.content,
        "isError": result.isError
      }
  )

  # Register tools
  server.registerTools()

proc connect*(server: FileSystemServer, transport: Transport) {.async.} =
  stderr.writeLine "[MCP] Protocol connecting to transport"
  await server.protocol.connect(transport)
  server.running = true

proc close*(server: FileSystemServer) {.async.} =
  if server.running:
    server.running = false
    if not server.protocol.isNil:
      await server.protocol.close()
    server.audit.close()
    stderr.writeLine "[MCP] Server closed"

when isMainModule:
  proc main() {.async.} =
    let args = commandLineParams()
    if args.len == 0:
      stderr.writeLine "Usage: filesystem_server <allowed-directory> [additional-directories...]"
      quit(1)

    var allowedDirs = newSeq[string]()
    for arg in args:
      allowedDirs.add(normalizedPath(absolutePath(arg)))
    stderr.writeLine "[MCP] Allowed directories: ", $allowedDirs

    let server = newFileSystemServer(allowedDirs)
    server.start()

    let transport = stdio.newStdioTransport()
    await server.connect(transport)

    while server.running:
      await sleepAsync(10)

  waitFor main() 