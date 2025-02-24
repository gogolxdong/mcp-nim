import std/[json, options, strutils, tables]

type
  ValidationErrorKind* = enum
    vekInvalidType,
    vekMissingField,
    vekInvalidValue,
    vekCustom

  ValidationError* = object
    kind*: ValidationErrorKind
    path*: seq[string]
    message*: string

  ValidationResult*[T] = object
    case isValid*: bool
    of true:
      value*: T
    of false:
      errors*: seq[ValidationError]

  SchemaType* = enum
    stString,
    stNumber,
    stBoolean,
    stObject,
    stArray,
    stNull

  SchemaConstraints* = object
    required*: seq[string]
    properties*: Table[string, Schema]
    minLength*: Option[int]
    maxLength*: Option[int]
    pattern*: Option[string]
    minimum*: Option[float]
    maximum*: Option[float]
    items*: Option[Schema]

  Schema* = ref object
    schemaType*: SchemaType
    description*: string
    constraints*: SchemaConstraints
    validate*: proc(input: JsonNode): ValidationResult[JsonNode]

proc newValidationError*(kind: ValidationErrorKind, message: string, path: seq[string] = @[]): ValidationError =
  ValidationError(kind: kind, message: message, path: path)

proc success*[T](value: T): ValidationResult[T] =
  ValidationResult[T](isValid: true, value: value)

proc failure*[T](errors: seq[ValidationError]): ValidationResult[T] =
  ValidationResult[T](isValid: false, errors: errors)

proc validateSchema*(schema: Schema, input: JsonNode, path: seq[string] = @[]): ValidationResult[JsonNode] =
  # Basic type validation
  case schema.schemaType
  of stString:
    if input.kind != JString:
      return failure[JsonNode](@[newValidationError(vekInvalidType, "Expected string", path)])
    if schema.constraints.minLength.isSome and input.getStr.len < schema.constraints.minLength.get:
      return failure[JsonNode](@[newValidationError(vekInvalidValue, "String too short", path)])
    if schema.constraints.maxLength.isSome and input.getStr.len > schema.constraints.maxLength.get:
      return failure[JsonNode](@[newValidationError(vekInvalidValue, "String too long", path)])
    if schema.constraints.pattern.isSome:
      # TODO: Add regex pattern validation
      discard
  of stNumber:
    if input.kind notin {JInt, JFloat}:
      return failure[JsonNode](@[newValidationError(vekInvalidType, "Expected number", path)])
    let value = if input.kind == JInt: input.getFloat else: input.getFloat
    if schema.constraints.minimum.isSome and value < schema.constraints.minimum.get:
      return failure[JsonNode](@[newValidationError(vekInvalidValue, "Value too small", path)])
    if schema.constraints.maximum.isSome and value > schema.constraints.maximum.get:
      return failure[JsonNode](@[newValidationError(vekInvalidValue, "Value too large", path)])
  of stBoolean:
    if input.kind != JBool:
      return failure[JsonNode](@[newValidationError(vekInvalidType, "Expected boolean", path)])
  of stObject:
    if input.kind != JObject:
      return failure[JsonNode](@[newValidationError(vekInvalidType, "Expected object", path)])
    var errors: seq[ValidationError] = @[]
    # Check required fields
    for field in schema.constraints.required:
      if not input.hasKey(field):
        errors.add(newValidationError(vekMissingField, "Missing required field: " & field, path & @[field]))
    # Validate properties
    for key, value in input.pairs:
      if schema.constraints.properties.hasKey(key):
        let fieldPath = path & @[key]
        let propSchema = schema.constraints.properties[key]
        let fieldResult = validateSchema(propSchema, value, fieldPath)
        if not fieldResult.isValid:
          errors.add(fieldResult.errors)
    if errors.len > 0:
      return failure[JsonNode](errors)
  of stArray:
    if input.kind != JArray:
      return failure[JsonNode](@[newValidationError(vekInvalidType, "Expected array", path)])
    if schema.constraints.items.isSome:
      var errors: seq[ValidationError] = @[]
      for i, item in input.getElems:
        let itemPath = path & @[$i]
        let itemResult = validateSchema(schema.constraints.items.get, item, itemPath)
        if not itemResult.isValid:
          errors.add(itemResult.errors)
      if errors.len > 0:
        return failure[JsonNode](errors)
  of stNull:
    if input.kind != JNull:
      return failure[JsonNode](@[newValidationError(vekInvalidType, "Expected null", path)])

  # Custom validation if provided
  if schema.validate != nil:
    return schema.validate(input)

  success[JsonNode](input)

proc newSchema*(schemaType: SchemaType, description: string = "", constraints: SchemaConstraints = SchemaConstraints()): Schema =
  Schema(
    schemaType: schemaType,
    description: description,
    constraints: constraints
  )

proc newStringSchema*(description: string = "", minLength: Option[int] = none(int), maxLength: Option[int] = none(int), pattern: Option[string] = none(string)): Schema =
  newSchema(
    stString,
    description,
    SchemaConstraints(
      minLength: minLength,
      maxLength: maxLength,
      pattern: pattern
    )
  )

proc newNumberSchema*(description: string = "", minimum: Option[float] = none(float), maximum: Option[float] = none(float)): Schema =
  newSchema(
    stNumber,
    description,
    SchemaConstraints(
      minimum: minimum,
      maximum: maximum
    )
  )

proc newBooleanSchema*(description: string = ""): Schema =
  newSchema(stBoolean, description)

proc newObjectSchema*(description: string = "", required: seq[string] = @[], properties: Table[string, Schema] = initTable[string, Schema]()): Schema =
  newSchema(
    stObject,
    description,
    SchemaConstraints(
      required: required,
      properties: properties
    )
  )

proc newArraySchema*(description: string = "", items: Schema): Schema =
  newSchema(
    stArray,
    description,
    SchemaConstraints(
      items: some(items)
    )
  )

proc newNullSchema*(description: string = ""): Schema =
  newSchema(stNull, description) 