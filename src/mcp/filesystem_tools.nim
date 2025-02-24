import std/[asyncdispatch, json, options, os, strformat, strutils, times, tables]
import ./tools
import ./validation
import ./shared/base_types

type
  FileSystemTools* = object
    listDirectory*: Tool
    getFileInfo*: Tool
    directoryTree*: Tool
    searchFiles*: Tool
    deleteFile*: Tool
    editFile*: Tool
    writeFile*: Tool
    readFile*: Tool
    createDirectory*: Tool

proc validatePath*(requestedPath: string, allowedPaths: seq[string]): string =
  let normalizedPath = normalizedPath(absolutePath(requestedPath))
  for allowedPath in allowedPaths:
    if normalizedPath.startsWith(allowedPath):
      return normalizedPath
  raise newMcpError(ErrorCode.InvalidRequest, "Path not allowed: " & requestedPath)

proc getFileInfo*(path: string): JsonNode =
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

proc normalizeLineEndings(text: string): string =
  text.replace("\r\n", "\n")

proc createSimpleDiff(originalContent, newContent: string): string =
  let originalLines = originalContent.splitLines()
  let newLines = newContent.splitLines()
  
  var diff = "--- original\n+++ modified\n"
  var i = 0
  var j = 0
  
  while i < originalLines.len or j < newLines.len:
    if i >= originalLines.len:
      # Remaining lines are additions
      diff &= &"+{newLines[j]}\n"
      inc j
    elif j >= newLines.len:
      # Remaining lines are deletions
      diff &= &"-{originalLines[i]}\n"
      inc i
    elif originalLines[i] == newLines[j]:
      # Lines are identical
      diff &= &" {originalLines[i]}\n"
      inc i
      inc j
    else:
      # Lines differ
      diff &= &"-{originalLines[i]}\n"
      diff &= &"+{newLines[j]}\n"
      inc i
      inc j
  
  return diff

proc getIndentation(line: string): string =
  var indent = ""
  for c in line:
    if c in Whitespace:
      indent.add(c)
    else:
      break
  return indent

proc applyFileEdits(filePath: string, edits: seq[tuple[oldText, newText: string]], dryRun = false): Future[string] {.async.} =
  var content = ""
  if fileExists(filePath):
    content = normalizeLineEndings(readFile(filePath))
  
  var modifiedContent = content
  for edit in edits:
    let normalizedOld = normalizeLineEndings(edit.oldText)
    let normalizedNew = normalizeLineEndings(edit.newText)
    
    # Try exact match first
    if modifiedContent.contains(normalizedOld):
      modifiedContent = modifiedContent.replace(normalizedOld, normalizedNew)
      continue
    
    # Try line-by-line matching with whitespace flexibility
    let oldLines = normalizedOld.splitLines()
    var contentLines = modifiedContent.splitLines()
    var matchFound = false
    
    block matchBlock:
      for i in 0 .. contentLines.len - oldLines.len:
        let potentialMatch = contentLines[i ..< i + oldLines.len]
        var isMatch = true
        
        # Compare lines with normalized whitespace
        for j, oldLine in oldLines:
          if oldLine.strip() != potentialMatch[j].strip():
            isMatch = false
            break
        
        if isMatch:
          # Preserve original indentation
          let originalIndent = getIndentation(contentLines[i])
          var newLines = newSeq[string]()
          let newLineParts = normalizedNew.splitLines()
          
          # Process first line
          if newLineParts.len > 0:
            newLines.add(originalIndent & newLineParts[0].strip(leading=true))
          
          # Process remaining lines
          for idx in 1 ..< newLineParts.len:
            let line = newLineParts[idx]
            let oldIndent = if idx < oldLines.len: getIndentation(oldLines[idx]) else: ""
            let newIndent = getIndentation(line)
            
            if oldIndent.len > 0 and newIndent.len > 0:
              let relativeIndent = max(0, newIndent.len - oldIndent.len)
              newLines.add(originalIndent & " ".repeat(relativeIndent) & line.strip(leading=true))
            else:
              newLines.add(line)
          
          # Apply the changes
          for i in countdown(i + oldLines.len - 1, i):
            contentLines.delete(i)
          for idx, newLine in newLines:
            contentLines.insert(newLine, i + idx)
          
          modifiedContent = contentLines.join("\n")
          matchFound = true
          break matchBlock
    
    if not matchFound:
      raise newMcpError(ErrorCode.InvalidRequest, "Could not find exact match for edit:\n" & edit.oldText)
  
  # Create diff
  let diff = createSimpleDiff(content, modifiedContent)
  
  if not dryRun:
    writeFile(filePath, modifiedContent)
  
  return diff

proc createFileSystemTools*(allowedDirs: seq[string]): FileSystemTools =
  # List Directory Tool
  var properties = initTable[string, Schema]()
  properties["path"] = newStringSchema("Directory path to list")
  let listDirectorySchema = newObjectSchema(
    description = "List contents of a directory",
    required = @["path"],
    properties = properties
  )

  let listDirectoryHandler = proc(args: JsonNode): Future[ToolResult] {.async.} =
    let path = validatePath(args["path"].getStr, allowedDirs)
    var entries = newJArray()
    for kind, path in walkDir(path):
      let name = extractFilename(path)
      let info = getFileInfo(path)
      entries.add(%*{
        "name": name,
        "path": path,
        "type": if kind == pcDir: "directory" else: "file",
        "info": info
      })
    return newToolResult(%*{"entries": entries})

  # Get File Info Tool
  properties = initTable[string, Schema]()
  properties["path"] = newStringSchema("Path to file or directory")
  let getFileInfoSchema = newObjectSchema(
    description = "Retrieve detailed metadata about a file or directory",
    required = @["path"],
    properties = properties
  )

  let getFileInfoHandler = proc(args: JsonNode): Future[ToolResult] {.async.} =
    let path = validatePath(args["path"].getStr, allowedDirs)
    return newToolResult(%*{"info": getFileInfo(path)})

  # Directory Tree Tool
  properties = initTable[string, Schema]()
  properties["path"] = newStringSchema("Root directory path")
  let directoryTreeSchema = newObjectSchema(
    description = "Generate a hierarchical tree representation of a directory",
    required = @["path"],
    properties = properties
  )

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

  let directoryTreeHandler = proc(args: JsonNode): Future[ToolResult] {.async.} =
    let path = validatePath(args["path"].getStr, allowedDirs)
    return newToolResult(%*{"tree": buildTree(path)})

  # Search Files Tool
  properties = initTable[string, Schema]()
  properties["path"] = newStringSchema("Directory to search in")
  properties["pattern"] = newStringSchema("Search pattern")
  properties["excludePatterns"] = newArraySchema("Patterns to exclude", newStringSchema())
  let searchFilesSchema = newObjectSchema(
    description = "Search for files and directories matching a pattern",
    required = @["path", "pattern"],
    properties = properties
  )

  let searchFilesHandler = proc(args: JsonNode): Future[ToolResult] {.async.} =
    let path = validatePath(args["path"].getStr, allowedDirs)
    let pattern = args["pattern"].getStr
    var excludePatterns = newSeq[string]()
    if args.hasKey("excludePatterns"):
      for pattern in args["excludePatterns"]:
        excludePatterns.add(pattern.getStr)
    
    var matches = newJArray()
    for file in walkDirRec(path, {pcFile, pcDir}):
      var excluded = false
      for exclude in excludePatterns:
        if file.contains(exclude):
          excluded = true
          break
      if not excluded and file.contains(pattern):
        matches.add(%*file)
    
    return newToolResult(%*{"matches": matches})

  # Delete File Tool
  properties = initTable[string, Schema]()
  properties["path"] = newStringSchema("Path to file to delete")
  let deleteFileSchema = newObjectSchema(
    description = "Delete a file",
    required = @["path"],
    properties = properties
  )

  let deleteFileHandler = proc(args: JsonNode): Future[ToolResult] {.async.} =
    let path = validatePath(args["path"].getStr, allowedDirs)
    removeFile(path)
    return newToolResult(%*{"success": true})

  # Edit File Tool
  properties = initTable[string, Schema]()
  properties["path"] = newStringSchema("Path to file to edit")
  properties["edits"] = newArraySchema(
    "List of edits to apply",
    newObjectSchema(
      description = "Edit operation",
      required = @["oldText", "newText"],
      properties = {
        "oldText": newStringSchema("Text to replace"),
        "newText": newStringSchema("New text")
      }.toTable
    )
  )
  properties["dryRun"] = newBooleanSchema("Preview changes without applying them")
  let editFileSchema = newObjectSchema(
    description = "Edit a file with the given changes",
    required = @["path", "edits"],
    properties = properties
  )

  let editFileHandler = proc(args: JsonNode): Future[ToolResult] {.async.} =
    let path = validatePath(args["path"].getStr, allowedDirs)
    var edits = newSeq[tuple[oldText, newText: string]]()
    for edit in args["edits"]:
      edits.add((oldText: edit["oldText"].getStr, newText: edit["newText"].getStr))
    let dryRun = if args.hasKey("dryRun"): args["dryRun"].getBool else: false
    
    let diff = await applyFileEdits(path, edits, dryRun)
    return newToolResult(%*{
      "success": true,
      "diff": diff,
      "dryRun": dryRun
    })

  # Write File Tool
  properties = initTable[string, Schema]()
  properties["path"] = newStringSchema("Path to file to write")
  properties["content"] = newStringSchema("Content to write")
  let writeFileSchema = newObjectSchema(
    description = "Write content to a file",
    required = @["path", "content"],
    properties = properties
  )

  let writeFileHandler = proc(args: JsonNode): Future[ToolResult] {.async.} =
    let path = validatePath(args["path"].getStr, allowedDirs)
    let content = args["content"].getStr
    writeFile(path, content)
    return newToolResult(%*{"success": true})

  # Read File Tool
  properties = initTable[string, Schema]()
  properties["path"] = newStringSchema("Path to file to read")
  let readFileSchema = newObjectSchema(
    description = "Read the contents of a file",
    required = @["path"],
    properties = properties
  )

  let readFileHandler = proc(args: JsonNode): Future[ToolResult] {.async.} =
    let path = validatePath(args["path"].getStr, allowedDirs)
    let content = readFile(path)
    return newToolResult(%*{"content": content})

  # Create Directory Tool
  properties = initTable[string, Schema]()
  properties["path"] = newStringSchema("Path to directory to create")
  let createDirectorySchema = newObjectSchema(
    description = "Create a new directory",
    required = @["path"],
    properties = properties
  )

  let createDirectoryHandler = proc(args: JsonNode): Future[ToolResult] {.async.} =
    let path = validatePath(args["path"].getStr, allowedDirs)
    createDir(path)
    return newToolResult(%*{"success": true})

  # Create and return tools
  result = FileSystemTools(
    listDirectory: newTool("list_directory", "List contents of a directory", listDirectorySchema, listDirectoryHandler),
    getFileInfo: newTool("get_file_info", "Get file information", getFileInfoSchema, getFileInfoHandler),
    directoryTree: newTool("directory_tree", "Get directory tree", directoryTreeSchema, directoryTreeHandler),
    searchFiles: newTool("search_files", "Search for files", searchFilesSchema, searchFilesHandler),
    deleteFile: newTool("delete_file", "Delete a file", deleteFileSchema, deleteFileHandler),
    editFile: newTool("edit_file", "Edit a file", editFileSchema, editFileHandler),
    writeFile: newTool("write_file", "Write to a file", writeFileSchema, writeFileHandler),
    readFile: newTool("read_file", "Read from a file", readFileSchema, readFileHandler),
    createDirectory: newTool("create_directory", "Create a directory", createDirectorySchema, createDirectoryHandler)
  ) 