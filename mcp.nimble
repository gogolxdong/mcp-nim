# Package
version       = "0.1.0"
author        = "Liu Bicheng"
description   = "Model Context Protocol (MCP) SDK for Nim"
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 2.2.2"
requires "ws >= 0.5.0"  # For WebSocket support

# Tasks
task build, "Build all examples":
  mkDir "bin"
  exec "nim c -d:release --outdir:bin examples/filesystem_server.nim"

task test, "Run the test suite":
  exec "testament pattern 'tests/*.nim'"

task examples, "Run examples":
  exec "nim c -r examples/filesystem_server.nim"

task docs, "Generate documentation":
  exec "nim doc --project --index:on --outdir:docs src/mcp.nim"

backend = "c"