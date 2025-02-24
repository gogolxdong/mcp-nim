import std/[options, re, strformat, strutils, tables]

type
  UriTemplateError* = object of CatchableError

  VariableSpec = object
    name: string
    explode: bool
    prefix: Option[int]

  UriTemplate* = object
    template: string
    variables: seq[VariableSpec]
    parts: seq[string]

proc parseVariableSpec(spec: string): VariableSpec =
  var name = spec
  result.explode = false
  result.prefix = none(int)

  if name.endsWith("*"):
    result.explode = true
    name.setLen(name.len - 1)

  if ':' in name:
    let parts = name.split(':')
    name = parts[0]
    try:
      result.prefix = some(parseInt(parts[1]))
    except ValueError:
      raise newException(UriTemplateError, 
        &"Invalid prefix in variable specification: {spec}")

  result.name = name

proc newUriTemplate*(template: string): UriTemplate =
  result.template = template
  result.variables = @[]
  result.parts = @[]

  var current = 0
  var matches: array[2, string]
  let pattern = re"\{([^}]+)\}"

  while current < template.len:
    let match = template.findBounds(pattern, matches, current)
    if match.first < 0:
      result.parts.add(template[current..^1])
      break

    if match.first > current:
      result.parts.add(template[current..<match.first])

    let varSpec = matches[1]
    try:
      result.variables.add(parseVariableSpec(varSpec))
    except UriTemplateError as e:
      raise e
    except Exception as e:
      raise newException(UriTemplateError,
        &"Failed to parse variable specification: {e.msg}")

    current = match.last + 1

proc encodeValue(value: string, spec: VariableSpec): string =
  if spec.prefix.isSome:
    let prefix = spec.prefix.get
    if value.len > prefix:
      result = encodeUrl(value[0..<prefix])
    else:
      result = encodeUrl(value)
  else:
    result = encodeUrl(value)

proc expand*(template: UriTemplate, variables: Table[string, string]): string =
  result = ""
  var partIndex = 0
  var varIndex = 0

  while partIndex < template.parts.len or varIndex < template.variables.len:
    if partIndex < template.parts.len:
      result.add(template.parts[partIndex])
      inc partIndex

    if varIndex < template.variables.len:
      let spec = template.variables[varIndex]
      if variables.hasKey(spec.name):
        let value = variables[spec.name]
        if value.len > 0:
          result.add(encodeValue(value, spec))
      inc varIndex

proc match*(template: UriTemplate, uri: string): Option[Table[string, string]] =
  var variables = initTable[string, string]()
  var pattern = template.template

  # Escape special regex characters in the template parts
  for c in ['.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '\\', '|']:
    pattern = pattern.replace($c, "\\" & $c)

  # Replace variable specifications with capture groups
  for spec in template.variables:
    let varPattern = 
      if spec.prefix.isSome:
        &"([^/]{{{spec.prefix.get}}})"
      else:
        "([^/]+)"
    pattern = pattern.replace(&"{{{spec.name}}}", varPattern)

  let regex = re('^' & pattern & '$')
  var matches: array[20, string]  # Support up to 20 variables
  if uri.match(regex, matches):
    for i, spec in template.variables:
      if i >= matches.len:
        break
      if matches[i+1].len > 0:  # +1 because first match is whole string
        variables[spec.name] = decodeUrl(matches[i+1])
    return some(variables)

  return none(Table[string, string])

proc extractVariables*(template: UriTemplate): seq[string] =
  for spec in template.variables:
    result.add(spec.name)