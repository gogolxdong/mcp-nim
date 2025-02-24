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

    # Define common schema components
    let pathSchema = %*{
      "type": "object",
      "properties": {"path": {"type": "string"}},
      "required": ["path"],
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#"
    }
    
    server.addTool(
      "read_file", 
      proc(params: JsonNode): Future[JsonNode] {.async.} =
        let path = validatePath(params["path"].getStr, allowedDirs)
        result = %*{"content": readFile(path)}
      ,
      "Read the complete contents of a file from the file system. Handles various text encodings and provides detailed error messages if the file cannot be read. Use this tool when you need to examine the contents of a single file. Only works within allowed directories.",
      pathSchema
    )

    server.addTool(
      "read_multiple_files",
      proc(params: JsonNode): Future[JsonNode] {.async.} =
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
      ,
      "Read the contents of multiple files simultaneously. This is more efficient than reading files one by one when you need to analyze or compare multiple files. Each file's content is returned with its path as a reference. Failed reads for individual files won't stop the entire operation. Only works within allowed directories.",
      %*{
        "type": "object",
        "properties": {"paths": {"type": "array", "items": {"type": "string"}}},
        "required": ["paths"],
        "additionalProperties": false,
        "$schema": "http://json-schema.org/draft-07/schema#"
      }
    )

    server.addTool(
      "write_file",
      proc(params: JsonNode): Future[JsonNode] {.async.} =
        let path = validatePath(params["path"].getStr, allowedDirs)
        let content = params["content"].getStr
        writeFile(path, content)
        result = %*{"success": true}
      ,
      "Create a new file or completely overwrite an existing file with new content. Use with caution as it will overwrite existing files without warning. Handles text content with proper encoding. Only works within allowed directories.",
      %*{
        "type": "object",
        "properties": {
          "path": {"type": "string"},
          "content": {"type": "string"}
        },
        "required": ["path", "content"],
        "additionalProperties": false,
        "$schema": "http://json-schema.org/draft-07/schema#"
      }
    )

    server.addTool(
      "create_directory",
      proc(params: JsonNode): Future[JsonNode] {.async.} =
        let path = validatePath(params["path"].getStr, allowedDirs)
        createDir(path)
        result = %*{"success": true}
      ,
      "Create a new directory or ensure a directory exists. Can create multiple nested directories in one operation. If the directory already exists, this operation will succeed silently. Perfect for setting up directory structures for projects or ensuring required paths exist. Only works within allowed directories.",
      pathSchema
    )

    server.addTool(
      "list_directory",
      proc(params: JsonNode): Future[JsonNode] {.async.} =
        let path = validatePath(params["path"].getStr, allowedDirs)
        var entries = newJArray()
        for kind, name in walkDir(path):
          entries.add(%*{
            "name": name,
            "type": if kind == pcDir: "directory" else: "file"
          })
        result = %*{"entries": entries}
      ,
      "Get a detailed listing of all files and directories in a specified path. Results clearly distinguish between files and directories with [FILE] and [DIR] prefixes. This tool is essential for understanding directory structure and finding specific files within a directory. Only works within allowed directories.",
      pathSchema
    )

    server.addTool(
      "directory_tree",
      proc(params: JsonNode): Future[JsonNode] {.async.} =
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
      ,
      "Get a recursive tree view of files and directories as a JSON structure. Each entry includes 'name', 'type' (file/directory), and 'children' for directories. Files have no children array, while directories always have a children array (which may be empty). The output is formatted with 2-space indentation for readability. Only works within allowed directories.",
      pathSchema
    )

    server.addTool(
      "move_file",
      proc(params: JsonNode): Future[JsonNode] {.async.} =
        let source = validatePath(params["source"].getStr, allowedDirs)
        let destination = validatePath(params["destination"].getStr, allowedDirs)
        moveFile(source, destination)
        result = %*{"success": true}
      ,
      "Move or rename files and directories. Can move files between directories and rename them in a single operation. If the destination exists, the operation will fail. Works across different directories and can be used for simple renaming within the same directory. Both source and destination must be within allowed directories.",
      %*{
        "type": "object",
        "properties": {
          "source": {"type": "string"},
          "destination": {"type": "string"}
        },
        "required": ["source", "destination"],
        "additionalProperties": false,
        "$schema": "http://json-schema.org/draft-07/schema#"
      }
    )

    server.addTool(
      "search_files",
      proc(params: JsonNode): Future[JsonNode] {.async.} =
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
      ,
      "Recursively search for files and directories matching a pattern. Searches through all subdirectories from the starting path. The search is case-insensitive and matches partial names. Returns full paths to all matching items. Great for finding files when you don't know their exact location. Only searches within allowed directories.",
      %*{
        "type": "object",
        "properties": {
          "path": {"type": "string"},
          "pattern": {"type": "string"},
          "excludePatterns": {"type": "array", "items": {"type": "string"}, "default": []}
        },
        "required": ["path", "pattern"],
        "additionalProperties": false,
        "$schema": "http://json-schema.org/draft-07/schema#"
      }
    )

    server.addTool(
      "get_file_info",
      proc(params: JsonNode): Future[JsonNode] {.async.} =
        let path = validatePath(params["path"].getStr, allowedDirs)
        result = %*{"info": getFileInfo(path)}
      ,
      "Retrieve detailed metadata about a file or directory. Returns comprehensive information including size, creation time, last modified time, permissions, and type. This tool is perfect for understanding file characteristics without reading the actual content. Only works within allowed directories.",
      pathSchema
    )

    server.addTool(
      "list_allowed_directories",
      proc(params: JsonNode): Future[JsonNode] {.async.} =
        result = %*{"directories": allowedDirs}
      ,
      "Returns the list of directories that this server is allowed to access. Use this to understand which directories are available before trying to access files.",
      %*{
        "type": "object",
        "properties": {},
        "required": [],
        "additionalProperties": false,
        "$schema": "http://json-schema.org/draft-07/schema#"
      }
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