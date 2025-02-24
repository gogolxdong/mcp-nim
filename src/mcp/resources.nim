import std/[asyncdispatch, json, options, strutils, tables, uri]
import ./validation
import ./shared/base_types

type
  ResourceKind* = enum
    rkFile,
    rkDirectory,
    rkSymlink,
    rkOther

  ResourceMetadata* = object
    kind*: ResourceKind
    size*: Option[int64]
    created*: Option[int64]
    modified*: Option[int64]
    permissions*: Option[string]

  Resource* = object
    uri*: string
    name*: string
    metadata*: ResourceMetadata

  ResourceHandler* = proc(uri: Uri): Future[Resource] {.async.}
  ResourceListHandler* = proc(): Future[seq[Resource]] {.async.}
  ResourceCompleteHandler* = proc(variable: string, value: string): Future[seq[string]] {.async.}

  ResourceTmpl* = ref object
    pattern*: string
    variables*: seq[string]
    listHandler*: ResourceListHandler
    getHandler*: ResourceHandler
    completeHandler*: ResourceCompleteHandler

  ResourceError* = object of CatchableError
    errorCode*: base_types.ErrorCode

proc newResourceError*(code: base_types.ErrorCode, msg: string): ref ResourceError =
  new(result)
  result.errorCode = code
  result.msg = msg

proc extractVariables*(pattern: string): seq[string] =
  var variables: seq[string] = @[]
  var i = 0
  while i < pattern.len:
    if pattern[i] == '{':
      var j = i + 1
      var varName = ""
      while j < pattern.len and pattern[j] != '}':
        varName.add(pattern[j])
        inc j
      if j < pattern.len and pattern[j] == '}':
        variables.add(varName)
        i = j
    inc i
  variables

proc matchPattern*(pattern: string, uri: string): Table[string, string] =
  result = initTable[string, string]()
  let variables = extractVariables(pattern)
  var patternParts = pattern.split('/')
  var uriParts = uri.split('/')
  
  if patternParts.len != uriParts.len:
    return

  for i in 0..<patternParts.len:
    let patternPart = patternParts[i]
    let uriPart = uriParts[i]
    
    if patternPart.startsWith("{") and patternPart.endsWith("}"):
      let varName = patternPart[1..^2]
      if varName in variables:
        result[varName] = uriPart
    elif patternPart != uriPart:
      result.clear()
      return

proc newResourceTmpl*(pattern: string, listHandler: ResourceListHandler = nil,
                     getHandler: ResourceHandler = nil,
                     completeHandler: ResourceCompleteHandler = nil): ResourceTmpl =
  ResourceTmpl(
    pattern: pattern,
    variables: extractVariables(pattern),
    listHandler: listHandler,
    getHandler: getHandler,
    completeHandler: completeHandler
  )

proc validateUri*(tmpl: ResourceTmpl, uri: string): bool =
  let variables = matchPattern(tmpl.pattern, uri)
  variables.len > 0

proc list*(tmpl: ResourceTmpl): Future[seq[Resource]] {.async.} =
  if tmpl.listHandler.isNil:
    return @[]
  result = await tmpl.listHandler()

proc get*(tmpl: ResourceTmpl, uri: Uri): Future[Resource] {.async.} =
  if tmpl.getHandler.isNil:
    raise newResourceError(base_types.ErrorCode.InvalidRequest, "Resource handler not implemented")
  result = await tmpl.getHandler(uri)

proc complete*(tmpl: ResourceTmpl, variable: string, value: string): Future[seq[string]] {.async.} =
  if tmpl.completeHandler.isNil:
    return @[]
  result = await tmpl.completeHandler(variable, value)

type ResourceRegistry* = ref object
  templates*: seq[ResourceTmpl]

proc newResourceRegistry*(): ResourceRegistry =
  ResourceRegistry(templates: @[])

proc registerTemplate*(registry: ResourceRegistry, tmpl: ResourceTmpl) =
  registry.templates.add(tmpl)

proc findTemplate*(registry: ResourceRegistry, uri: string): Option[ResourceTmpl] =
  for tmpl in registry.templates:
    if tmpl.validateUri(uri):
      return some(tmpl)
  none(ResourceTmpl)

proc listResources*(registry: ResourceRegistry): Future[seq[Resource]] {.async.} =
  var resources: seq[Resource] = @[]
  for tmpl in registry.templates:
    let templateResources = await tmpl.list()
    resources.add(templateResources)
  return resources

proc getResource*(registry: ResourceRegistry, uri: string): Future[Resource] {.async.} =
  let parsedUri = parseUri(uri)
  let templateOpt = registry.findTemplate(uri)
  
  if templateOpt.isNone:
    raise newResourceError(base_types.ErrorCode.InvalidRequest, "Resource not found: " & uri)
    
  let tmpl = templateOpt.get
  result = await tmpl.get(parsedUri)

proc completeResource*(registry: ResourceRegistry, uri: string, variable: string, value: string): Future[seq[string]] {.async.} =
  let templateOpt = registry.findTemplate(uri)
  if templateOpt.isNone:
    return @[]
    
  let tmpl = templateOpt.get
  result = await tmpl.complete(variable, value) 