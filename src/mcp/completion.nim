import std/[asyncdispatch, json, options, tables, strutils, algorithm]

type
  CompletionRange* = object
    start*: int
    `end`*: int

  CompletionItem* = object
    label*: string
    detail*: Option[string]
    documentation*: Option[string]
    sortText*: Option[string]
    filterText*: Option[string]
    insertText*: Option[string]
    range*: Option[CompletionRange]

  CompletionContext* = object
    input*: string
    position*: int
    prefix*: string
    suffix*: string

  CompletionResult* = object
    items*: seq[CompletionItem]
    isIncomplete*: bool

  CompletionProvider* = proc(context: CompletionContext): Future[CompletionResult] {.async.}

  CompletionRegistry* = ref object
    providers*: Table[string, CompletionProvider]

proc newCompletionRange*(start: int, `end`: int): CompletionRange =
  CompletionRange(start: start, `end`: `end`)

proc newCompletionItem*(label: string,
                       detail: string = "",
                       documentation: string = "",
                       sortText: string = "",
                       filterText: string = "",
                       insertText: string = "",
                       range: Option[CompletionRange] = none(CompletionRange)): CompletionItem =
  CompletionItem(
    label: label,
    detail: if detail.len > 0: some(detail) else: none(string),
    documentation: if documentation.len > 0: some(documentation) else: none(string),
    sortText: if sortText.len > 0: some(sortText) else: none(string),
    filterText: if filterText.len > 0: some(filterText) else: none(string),
    insertText: if insertText.len > 0: some(insertText) else: none(string),
    range: range
  )

proc newCompletionContext*(input: string, position: int): CompletionContext =
  let prefix = input[0..<position]
  let suffix = if position < input.len: input[position..^1] else: ""
  CompletionContext(
    input: input,
    position: position,
    prefix: prefix,
    suffix: suffix
  )

proc newCompletionResult*(items: seq[CompletionItem], isIncomplete: bool = false): CompletionResult =
  CompletionResult(
    items: items,
    isIncomplete: isIncomplete
  )

proc newCompletionRegistry*(): CompletionRegistry =
  CompletionRegistry(providers: initTable[string, CompletionProvider]())

proc registerProvider*(registry: CompletionRegistry, path: string, provider: CompletionProvider) =
  registry.providers[path] = provider

proc unregisterProvider*(registry: CompletionRegistry, path: string) =
  registry.providers.del(path)

proc getProvider*(registry: CompletionRegistry, path: string): Option[CompletionProvider] =
  if registry.providers.hasKey(path):
    result = some(registry.providers[path])
  else:
    result = none(CompletionProvider)

proc complete*(registry: CompletionRegistry, path: string, context: CompletionContext): Future[CompletionResult] {.async.} =
  let providerOpt = registry.getProvider(path)
  if providerOpt.isNone:
    return CompletionResult(items: @[], isIncomplete: false)
  
  let provider = providerOpt.get
  result = await provider(context)

# Helper functions for common completion scenarios
proc wordAtPosition*(context: CompletionContext): tuple[word: string, range: CompletionRange] =
  var start = context.position
  while start > 0 and context.input[start-1] in IdentChars:
    dec start
  
  var `end` = context.position
  while `end` < context.input.len and context.input[`end`] in IdentChars:
    inc `end`
  
  result = (
    word: context.input[start..`end`-1],
    range: newCompletionRange(start, `end`)
  )

proc filterCompletions*(items: seq[CompletionItem], filter: string,
                       caseSensitive: bool = false): seq[CompletionItem] =
  let filterStr = if caseSensitive: filter else: filter.toLowerAscii
  
  for item in items:
    let label = if caseSensitive: item.label else: item.label.toLowerAscii
    if label.contains(filterStr):
      result.add(item)

proc compareCompletionItems(a, b: CompletionItem): int =
  let sortTextA = if a.sortText.isSome: a.sortText.get else: a.label
  let sortTextB = if b.sortText.isSome: b.sortText.get else: b.label
  cmp(sortTextA, sortTextB)

proc sortCompletions*(items: var seq[CompletionItem]) =
  items.sort(compareCompletionItems)

proc simpleWordCompletion*(words: seq[string], context: CompletionContext): CompletionResult =
  let (word, range) = wordAtPosition(context)
  var items: seq[CompletionItem] = @[]
  
  for w in words:
    if w.toLowerAscii.startsWith(word.toLowerAscii):
      items.add(newCompletionItem(
        label = w,
        filterText = w,
        insertText = w,
        range = some(range)
      ))
  
  sortCompletions(items)
  CompletionResult(items: items, isIncomplete: false) 