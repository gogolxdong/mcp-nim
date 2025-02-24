import std/[asyncdispatch, json, options, os, strformat, strutils, times, sequtils]
import ../src/mcp/types as mcp_types
import ../src/mcp/shared/[protocol, transport, stdio, base_types]
import ../src/mcp/server

type
  FilesystemCapabilities = object
    allowedPaths: seq[string]

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

proc main() {.async.} =
  let now = times.now()
  var formatNow = times.utc(now).format("yyyy-MM-dd HH:mm:ss'Z'")
  
  var server: McpServer
  var transport: Transport
  
  proc shutdown() {.async.} =
    if not isNil(server):
      server.running = false
      await server.close()
    if not isNil(transport):
      await transport.close()
    quit(0)  # Exit the process after cleanup
  

  
  try:
    # Parse command line arguments
    let args = commandLineParams()
    if args.len == 0:
      stderr.writeLine "Usage: filesystem_server <allowed-directory> [additional-directories...]"
      quit(1)
    
    # Store allowed directories in normalized form
    var allowedDirs = args.mapIt(normalizedPath(absolutePath(it)))
    stderr.writeLine "[MCP] Allowed directories: ", $allowedDirs
    
    let serverInfo = mcp_types.ClientInfo(
      name: "secure-filesystem-server",
      version: "0.2.0"
    )

    
    let capabilities = mcp_types.ServerCapabilities(
      tools: newJObject()
    )
    
    server = newMcpServer(serverInfo, capabilities)
    
    let fsCapabilities = FilesystemCapabilities(
      allowedPaths: allowedDirs
    )
    
    server.addTool("read_file", proc(params: JsonNode): Future[JsonNode] {.async.} =
      let path = validatePath(params["path"].getStr, allowedDirs)
      result = %*{"content": readFile(path)}
    )

    server.addTool("read_multiple_files", proc(params: JsonNode): Future[JsonNode] {.async.} =
      var results = newJArray()
      for pathNode in params["paths"]:
        let path = validatePath(pathNode.getStr, allowedDirs)
        try:
          results.add(%*{
            "path": path,
            "content": readFile(path),
            "error": nil
          })
        except Exception as e:
          results.add(%*{
            "path": path,
            "content": nil,
            "error": e.msg
          })
      result = %*{"files": results}
    )

    server.addTool("write_file", proc(params: JsonNode): Future[JsonNode] {.async.} =
      let path = validatePath(params["path"].getStr, allowedDirs)
      let content = params["content"].getStr
      writeFile(path, content)
      result = %*{"success": true}
    )

    server.addTool("create_directory", proc(params: JsonNode): Future[JsonNode] {.async.} =
      let path = validatePath(params["path"].getStr, allowedDirs)
      createDir(path)
      result = %*{"success": true}
    )

    server.addTool("list_directory", proc(params: JsonNode): Future[JsonNode] {.async.} =
      let path = validatePath(params["path"].getStr, allowedDirs)
      var entries = newJArray()
      for kind, name in walkDir(path):
        entries.add(%*{
          "name": name,
          "type": if kind == pcDir: "directory" else: "file"
        })
      result = %*{"entries": entries}
    )

    server.addTool("directory_tree", proc(params: JsonNode): Future[JsonNode] {.async.} =
      proc buildTree(path: string): JsonNode =
        result = %*{
          "name": extractFilename(path),
          "type": if dirExists(path): "directory" else: "file"
        }
        if dirExists(path):
          var children = newJArray()
          for kind, name in walkDir(path):
            children.add(buildTree(name))
          result["children"] = children

      let path = validatePath(params["path"].getStr, allowedDirs)
      result = %*{"tree": buildTree(path)}
    )

    server.addTool("move_file", proc(params: JsonNode): Future[JsonNode] {.async.} =
      let source = validatePath(params["source"].getStr, allowedDirs)
      let destination = validatePath(params["destination"].getStr, allowedDirs)
      moveFile(source, destination)
      result = %*{"success": true}
    )

    server.addTool("search_files", proc(params: JsonNode): Future[JsonNode] {.async.} =
      let path = validatePath(params["path"].getStr, allowedDirs)
      let pattern = params["pattern"].getStr
      let excludePatterns = if params.hasKey("excludePatterns"): 
                             params["excludePatterns"].to(seq[string])
                           else: 
                             @[]
      
      var matches = newJArray()
      for file in walkDirRec(path):
        let relativePath = relativePath(file, path)
        if relativePath.contains(pattern) and not excludePatterns.anyIt(it in relativePath):
          matches.add(%*file)
      
      result = %*{"matches": matches}
    )

    server.addTool("get_file_info", proc(params: JsonNode): Future[JsonNode] {.async.} =
      let path = validatePath(params["path"].getStr, allowedDirs)
      result = %*{"info": getFileInfo(path)}
    )

    server.addTool("list_allowed_directories", proc(params: JsonNode): Future[JsonNode] {.async.} =
      result = %*{"directories": allowedDirs}
    )

    # Start the server
    stderr.writeLine "[MCP] Creating stdio transport..."
    transport = stdio.newStdioTransport()

    # Set up error handler
    transport.setErrorHandler(proc(error: McpError) =
      stderr.writeLine &"[{formatNow}][MCP] Transport error: ", error.msg
      if error.data.isSome:
        stderr.writeLine &"[{formatNow}][MCP] Error data: ", error.data.get
      asyncCheck shutdown()
    )

    # Set up close handler
    transport.setCloseHandler(proc() =
      stderr.writeLine &"[{formatNow}][MCP] Transport closed"
      asyncCheck shutdown()
    )

    # Register standard request handlers
    server.start()

    await server.connect(transport)

    # Keep the server running and process events
    while server.running:
      try:
        await sleepAsync(1)  # Process events frequently
        poll(1)  # Process events with a timeout
        
        if not transport.isConnected():
          stderr.writeLine &"[{formatNow}][MCP] Transport disconnected"
          break
          
      except Exception as e:
        stderr.writeLine &"[{formatNow}][MCP] Error in main loop: ", e.msg
        stderr.writeLine &"[{formatNow}][MCP] Stack trace: ", getStackTrace(e)
        break

  except Exception as e:
    stderr.writeLine &"[{formatNow}][MCP] Fatal error: ", e.msg
    stderr.writeLine &"[{formatNow}][MCP] Stack trace: ", getStackTrace(e)
  finally:
    # Ensure cleanup happens
    await shutdown()

when isMainModule:
  waitFor main()