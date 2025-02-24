import std/[os, osproc, strformat]

const 
  NimCache = "nimcache"
  OutputDir = "bin"

proc ensureDirectoryExists(dir: string) =
  if not dirExists(dir):
    createDir(dir)
  
proc cleanDirectory(dir: string) =
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)

proc main() =
  ensureDirectoryExists(OutputDir)
  
  cleanDirectory(NimCache)
  
  let serverCmd = &"nim c -d:release --nimcache:{NimCache} --out:{OutputDir}/claude_server.exe examples/claude_server.nim"
  echo "Building server: ", serverCmd
  let serverResult = execCmd(serverCmd)
  if serverResult != 0:
    echo "Failed to build server"
    quit(1)
  
  echo "Build completed successfully"
  echo "Server executable: ", absolutePath(OutputDir / "claude_server.exe")

when isMainModule:
  main() 