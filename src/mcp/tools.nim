import std/[asyncdispatch, json, options, tables]
import ./validation
import ./shared/base_types

type
  ToolResult* = object
    content*: JsonNode
    isError*: bool

  ToolHandler* = proc(args: JsonNode): Future[ToolResult] {.async.}

  Tool* = ref object
    name*: string
    description*: string
    schema*: Schema
    handler*: ToolHandler

  ToolRegistry* = ref object
    tools*: Table[string, Tool]

proc newToolResult*(content: JsonNode, isError: bool = false): ToolResult =
  ToolResult(content: content, isError: isError)

proc newTool*(name: string, description: string, schema: Schema, handler: ToolHandler): Tool =
  Tool(
    name: name,
    description: description,
    schema: schema,
    handler: handler
  )

proc newToolRegistry*(): ToolRegistry =
  ToolRegistry(tools: initTable[string, Tool]())

proc registerTool*(registry: ToolRegistry, tool: Tool) =
  registry.tools[tool.name] = tool

proc unregisterTool*(registry: ToolRegistry, name: string) =
  registry.tools.del(name)

proc getTool*(registry: ToolRegistry, name: string): Option[Tool] =
  if registry.tools.hasKey(name):
    result = some(registry.tools[name])
  else:
    result = none(Tool)

proc listTools*(registry: ToolRegistry): seq[Tool] =
  for tool in registry.tools.values:
    result.add(tool)

proc validateToolArgs*(tool: Tool, args: JsonNode): ValidationResult[JsonNode] =
  if tool.schema.isNil:
    return success[JsonNode](args)
  validateSchema(tool.schema, args)

proc executeTool*(registry: ToolRegistry, name: string, args: JsonNode): Future[ToolResult] {.async.} =
  let toolOpt = registry.getTool(name)
  if toolOpt.isNone:
    raise newMcpError(ErrorCode.InvalidRequest, "Tool not found: " & name)
    
  let tool = toolOpt.get
  let validationResult = validateToolArgs(tool, args)
  
  if not validationResult.isValid:
    var errorMsg = "Invalid arguments for tool " & name & ": "
    for error in validationResult.errors:
      errorMsg.add("\n- " & error.message)
    raise newMcpError(ErrorCode.InvalidParams, errorMsg)
  
  result = await tool.handler(args)

# Helper functions for common tool schemas
proc newStringParamSchema*(name: string, description: string, required: bool = true): Schema =
  let schema = newStringSchema(description)
  if required:
    newObjectSchema(
      properties = {name: schema}.toTable,
      required = @[name]
    )
  else:
    newObjectSchema(
      properties = {name: schema}.toTable
    )

proc newNumberParamSchema*(name: string, description: string, required: bool = true,
                          minimum: Option[float] = none(float),
                          maximum: Option[float] = none(float)): Schema =
  let schema = newNumberSchema(description, minimum, maximum)
  if required:
    newObjectSchema(
      properties = {name: schema}.toTable,
      required = @[name]
    )
  else:
    newObjectSchema(
      properties = {name: schema}.toTable
    )

proc newBooleanParamSchema*(name: string, description: string, required: bool = true): Schema =
  let schema = newBooleanSchema(description)
  if required:
    newObjectSchema(
      properties = {name: schema}.toTable,
      required = @[name]
    )
  else:
    newObjectSchema(
      properties = {name: schema}.toTable
    )

proc newArrayParamSchema*(name: string, description: string, itemSchema: Schema,
                         required: bool = true): Schema =
  let schema = newArraySchema(description, itemSchema)
  if required:
    newObjectSchema(
      properties = {name: schema}.toTable,
      required = @[name]
    )
  else:
    newObjectSchema(
      properties = {name: schema}.toTable
    )

proc newObjectParamSchema*(name: string, description: string,
                          properties: Table[string, Schema],
                          required: seq[string] = @[],
                          paramRequired: bool = true): Schema =
  let schema = newObjectSchema(description, required, properties)
  if paramRequired:
    newObjectSchema(
      properties = {name: schema}.toTable,
      required = @[name]
    )
  else:
    newObjectSchema(
      properties = {name: schema}.toTable
    ) 