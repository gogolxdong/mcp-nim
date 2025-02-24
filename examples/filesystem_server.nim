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
  stderr.writeLine "[MCP] Starting Filesystem MCP Server..."
  
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
  stderr.writeLine "[MCP] Created server info: ", $(%*{
    "name": serverInfo.name,
    "version": serverInfo.version
  })
  
  let capabilities = mcp_types.ServerCapabilities(
    tools: newJObject()
  )
  stderr.writeLine "[MCP] Created server capabilities: ", $(%*{
    "tools": capabilities.tools
  })
  
  stderr.writeLine "[MCP] Creating MCP server..."
  let server = newMcpServer(serverInfo, capabilities)
  stderr.writeLine "[MCP] MCP server created successfully"
  
  let fsCapabilities = FilesystemCapabilities(
    allowedPaths: allowedDirs
  )
  stderr.writeLine "[MCP] Filesystem capabilities configured with allowed paths: ", $allowedDirs
  
  # Set up request handlers
  server.protocol.setRequestHandler("initialize", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    stderr.writeLine "[MCP] Handling initialize request"
    result = %*{
      "protocolVersion": mcp_types.LATEST_PROTOCOL_VERSION,
      "capabilities": {
        "tools": {}
      },
      "serverInfo": {
        "name": serverInfo.name,
        "version": serverInfo.version
      }
    }
  )

  # Tool handlers
  server.protocol.setRequestHandler("tools/read_file", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    let path = validatePath(request.params["path"].getStr, allowedDirs)
    result = %*{"content": readFile(path)}
  )

  server.protocol.setRequestHandler("tools/read_multiple_files", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    var results = newJArray()
    for pathNode in request.params["paths"]:
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

  server.protocol.setRequestHandler("tools/write_file", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    let path = validatePath(request.params["path"].getStr, allowedDirs)
    let content = request.params["content"].getStr
    writeFile(path, content)
    result = %*{"success": true}
  )

  server.protocol.setRequestHandler("tools/create_directory", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    let path = validatePath(request.params["path"].getStr, allowedDirs)
    createDir(path)
    result = %*{"success": true}
  )

  server.protocol.setRequestHandler("tools/list_directory", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    let path = validatePath(request.params["path"].getStr, allowedDirs)
    var entries = newJArray()
    for kind, name in walkDir(path):
      entries.add(%*{
        "name": name,
        "type": if kind == pcDir: "directory" else: "file"
      })
    result = %*{"entries": entries}
  )

  server.protocol.setRequestHandler("tools/directory_tree", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
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

    let path = validatePath(request.params["path"].getStr, allowedDirs)
    result = %*{"tree": buildTree(path)}
  )

  server.protocol.setRequestHandler("tools/move_file", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    let source = validatePath(request.params["source"].getStr, allowedDirs)
    let destination = validatePath(request.params["destination"].getStr, allowedDirs)
    moveFile(source, destination)
    result = %*{"success": true}
  )

  server.protocol.setRequestHandler("tools/search_files", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    let path = validatePath(request.params["path"].getStr, allowedDirs)
    let pattern = request.params["pattern"].getStr
    let excludePatterns = if request.params.hasKey("excludePatterns"): 
                           request.params["excludePatterns"].to(seq[string])
                         else: 
                           @[]
    
    var matches = newJArray()
    for file in walkDirRec(path):
      let relativePath = relativePath(file, path)
      if relativePath.contains(pattern) and not excludePatterns.anyIt(it in relativePath):
        matches.add(%*file)
    
    result = %*{"matches": matches}
  )

  server.protocol.setRequestHandler("tools/get_file_info", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    let path = validatePath(request.params["path"].getStr, allowedDirs)
    result = %*{"info": getFileInfo(path)}
  )

  server.protocol.setRequestHandler("tools/list_allowed_directories", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    result = %*{"directories": allowedDirs}
  )

  # Tools list handler
  server.protocol.setRequestHandler("tools/list", proc(request: base_types.JsonRpcRequest, extra: protocol.RequestHandlerExtra): Future[JsonNode] {.async.} =
    stderr.writeLine "[MCP] Handling tools/list request"
    result = %*{
      "tools": [
        {
          "name": "read_file",
          "description": "Read the complete contents of a file from the file system. Handles various text encodings and provides detailed error messages if the file cannot be read. Use this tool when you need to examine the contents of a single file. Only works within allowed directories.",
          "inputSchema": {
            "type": "object",
            "properties": {
              "path": {"type": "string"}
            },
            "required": ["path"],
            "additionalProperties": false,
            "$schema": "http://json-schema.org/draft-07/schema#"
          }
        },
        {
          "name": "read_multiple_files",
          "description": "Read the contents of multiple files simultaneously. This is more efficient than reading files one by one when you need to analyze or compare multiple files. Each file's content is returned with its path as a reference. Failed reads for individual files won't stop the entire operation. Only works within allowed directories.",
          "inputSchema": {
            "type": "object",
            "properties": {
              "paths": {
                "type": "array",
                "items": {"type": "string"}
              }
            },
            "required": ["paths"],
            "additionalProperties": false,
            "$schema": "http://json-schema.org/draft-07/schema#"
          }
        },
        {
          "name": "write_file",
          "description": "Create a new file or completely overwrite an existing file with new content. Use with caution as it will overwrite existing files without warning. Handles text content with proper encoding. Only works within allowed directories.",
          "inputSchema": {
            "type": "object",
            "properties": {
              "path": {"type": "string"},
              "content": {"type": "string"}
            },
            "required": ["path", "content"],
            "additionalProperties": false,
            "$schema": "http://json-schema.org/draft-07/schema#"
          }
        },
        {
          "name": "create_directory",
          "description": "Create a new directory or ensure a directory exists. Can create multiple nested directories in one operation. If the directory already exists, this operation will succeed silently. Perfect for setting up directory structures for projects or ensuring required paths exist. Only works within allowed directories.",
          "inputSchema": {
            "type": "object",
            "properties": {
              "path": {"type": "string"}
            },
            "required": ["path"],
            "additionalProperties": false,
            "$schema": "http://json-schema.org/draft-07/schema#"
          }
        },
        {
          "name": "list_directory",
          "description": "Get a detailed listing of all files and directories in a specified path. Results clearly distinguish between files and directories with [FILE] and [DIR] prefixes. This tool is essential for understanding directory structure and finding specific files within a directory. Only works within allowed directories.",
          "inputSchema": {
            "type": "object",
            "properties": {
              "path": {"type": "string"}
            },
            "required": ["path"],
            "additionalProperties": false,
            "$schema": "http://json-schema.org/draft-07/schema#"
          }
        },
        {
          "name": "directory_tree",
          "description": "Get a recursive tree view of files and directories as a JSON structure. Each entry includes 'name', 'type' (file/directory), and 'children' for directories. Files have no children array, while directories always have a children array (which may be empty). The output is formatted with 2-space indentation for readability. Only works within allowed directories.",
          "inputSchema": {
            "type": "object",
            "properties": {
              "path": {"type": "string"}
            },
            "required": ["path"],
            "additionalProperties": false,
            "$schema": "http://json-schema.org/draft-07/schema#"
          }
        },
        {
          "name": "move_file",
          "description": "Move or rename files and directories. Can move files between directories and rename them in a single operation. If the destination exists, the operation will fail. Works across different directories and can be used for simple renaming within the same directory. Both source and destination must be within allowed directories.",
          "inputSchema": {
            "type": "object",
            "properties": {
              "source": {"type": "string"},
              "destination": {"type": "string"}
            },
            "required": ["source", "destination"],
            "additionalProperties": false,
            "$schema": "http://json-schema.org/draft-07/schema#"
          }
        },
        {
          "name": "search_files",
          "description": "Recursively search for files and directories matching a pattern. Searches through all subdirectories from the starting path. The search is case-insensitive and matches partial names. Returns full paths to all matching items. Great for finding files when you don't know their exact location. Only searches within allowed directories.",
          "inputSchema": {
            "type": "object",
            "properties": {
              "path": {"type": "string"},
              "pattern": {"type": "string"},
              "excludePatterns": {
                "type": "array",
                "items": {"type": "string"},
                "default": []
              }
            },
            "required": ["path", "pattern"],
            "additionalProperties": false,
            "$schema": "http://json-schema.org/draft-07/schema#"
          }
        },
        {
          "name": "get_file_info",
          "description": "Retrieve detailed metadata about a file or directory. Returns comprehensive information including size, creation time, last modified time, permissions, and type. This tool is perfect for understanding file characteristics without reading the actual content. Only works within allowed directories.",
          "inputSchema": {
            "type": "object",
            "properties": {
              "path": {"type": "string"}
            },
            "required": ["path"],
            "additionalProperties": false,
            "$schema": "http://json-schema.org/draft-07/schema#"
          }
        },
        {
          "name": "list_allowed_directories",
          "description": "Returns the list of directories that this server is allowed to access. Use this to understand which directories are available before trying to access files.",
          "inputSchema": {
            "type": "object",
            "properties": {},
            "required": [],
            "additionalProperties": false,
            "$schema": "http://json-schema.org/draft-07/schema#"
          }
        }
      ]
    }
  )
  
  stderr.writeLine "[MCP] Creating stdio transport"
  let transport = stdio.newStdioTransport()
  
  # Set up transport handlers
  transport.setCloseHandler(proc() =
    stderr.writeLine "[MCP] Transport closed, initiating shutdown"
    stderr.flushFile()
    quit(0)
  )
  
  transport.setErrorHandler(proc(error: McpError) =
    stderr.writeLine "[MCP] Transport error: ", error.msg
    stderr.flushFile()
    if error.code == ErrorCode.ConnectionClosed.int:
      stderr.writeLine "[MCP] Connection closed, initiating shutdown"
      stderr.flushFile()
      quit(0)
  )
  
  transport.setMessageHandler(proc(message: JsonNode) =
    stderr.writeLine "[MCP] Transport message: ", message
    stderr.flushFile()
  )
  
  stderr.writeLine "[MCP] Connecting server to transport"
  await server.connect(transport)
  
  stderr.writeLine "[MCP] Server ready"
  stderr.flushFile()
  
  while true:
    try:
      await sleepAsync(100)  # Check every 100ms instead of 1000ms
      if transport.isClosed():
        stderr.writeLine "[MCP] Transport closed, initiating shutdown"
        stderr.flushFile()
        break
    except Exception as e:
      stderr.writeLine "[MCP] Error in main loop: ", e.msg
      stderr.writeLine getStackTrace(e)
      stderr.flushFile()
      break

  # Clean shutdown
  stderr.writeLine "[MCP] Server shutting down"
  stderr.flushFile()
  await server.close()
  quit(0)

when isMainModule:
  waitFor main()