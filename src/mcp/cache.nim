import std/[asyncdispatch, json, options, times, tables, hashes]
import ./shared/base_types

type
  CacheEntryKind* = enum
    cekValue,
    cekError

  CacheEntry*[T] = object
    case kind*: CacheEntryKind
    of cekValue:
      value*: T
    of cekError:
      error*: string
    createdAt*: Time
    expiresAt*: Option[Time]
    lastAccessed*: Time
    accessCount*: int

  CachePolicy* = object
    maxSize*: int
    defaultTTL*: Option[Duration]
    evictionStrategy*: EvictionStrategy

  EvictionStrategy* = enum
    esLRU,  # Least Recently Used
    esLFU,  # Least Frequently Used
    esFIFO  # First In First Out

  Cache*[K, V] = ref object
    entries*: Table[K, CacheEntry[V]]
    policy*: CachePolicy
    size*: int
    hits*: int
    misses*: int

proc hash*[T](entry: CacheEntry[T]): Hash =
  var h: Hash = 0
  h = h !& hash(entry.kind)
  case entry.kind
  of cekValue:
    h = h !& hash(entry.value)
  of cekError:
    h = h !& hash(entry.error)
  h = h !& hash(entry.createdAt)
  if entry.expiresAt.isSome:
    h = h !& hash(entry.expiresAt.get)
  h = h !& hash(entry.lastAccessed)
  h = h !& hash(entry.accessCount)
  result = !$h

proc newCacheEntry*[T](value: T, ttl: Option[Duration] = none(Duration)): CacheEntry[T] =
  let now = getTime()
  CacheEntry[T](
    kind: cekValue,
    value: value,
    createdAt: now,
    expiresAt: if ttl.isSome: some(now + ttl.get) else: none(Time),
    lastAccessed: now,
    accessCount: 0
  )

proc newErrorCacheEntry*[T](error: string, ttl: Option[Duration] = none(Duration)): CacheEntry[T] =
  let now = getTime()
  CacheEntry[T](
    kind: cekError,
    error: error,
    createdAt: now,
    expiresAt: if ttl.isSome: some(now + ttl.get) else: none(Time),
    lastAccessed: now,
    accessCount: 0
  )

proc newCache*[K, V](policy: CachePolicy): Cache[K, V] =
  Cache[K, V](
    entries: initTable[K, CacheEntry[V]](),
    policy: policy,
    size: 0,
    hits: 0,
    misses: 0
  )

proc isExpired*[T](entry: CacheEntry[T]): bool =
  entry.expiresAt.isSome and entry.expiresAt.get <= getTime()

proc evictOne*[K, V](cache: Cache[K, V]) =
  if cache.entries.len == 0:
    return

  var keyToEvict: K
  case cache.policy.evictionStrategy
  of esLRU:
    # Find least recently used entry
    var oldestAccess = high(Time)
    for k, v in cache.entries:
      if v.lastAccessed < oldestAccess:
        oldestAccess = v.lastAccessed
        keyToEvict = k
  of esLFU:
    # Find least frequently used entry
    var lowestCount = high(int)
    for k, v in cache.entries:
      if v.accessCount < lowestCount:
        lowestCount = v.accessCount
        keyToEvict = k
  of esFIFO:
    # Find oldest entry
    var oldestCreation = high(Time)
    for k, v in cache.entries:
      if v.createdAt < oldestCreation:
        oldestCreation = v.createdAt
        keyToEvict = k

  cache.entries.del(keyToEvict)
  dec cache.size

proc set*[K, V](cache: Cache[K, V], key: K, value: V, ttl: Option[Duration] = none(Duration)) =
  while cache.size >= cache.policy.maxSize:
    cache.evictOne()

  let entry = newCacheEntry[V](value, if ttl.isSome: ttl else: cache.policy.defaultTTL)
  cache.entries[key] = entry
  inc cache.size

proc setError*[K, V](cache: Cache[K, V], key: K, error: string, ttl: Option[Duration] = none(Duration)) =
  while cache.size >= cache.policy.maxSize:
    cache.evictOne()

  let entry = newErrorCacheEntry[V](error, if ttl.isSome: ttl else: cache.policy.defaultTTL)
  cache.entries[key] = entry
  inc cache.size

proc get*[K, V](cache: Cache[K, V], key: K): Option[CacheEntry[V]] =
  if not cache.entries.hasKey(key):
    inc cache.misses
    return none(CacheEntry[V])

  var entry = cache.entries[key]
  if entry.isExpired():
    cache.entries.del(key)
    dec cache.size
    inc cache.misses
    return none(CacheEntry[V])

  inc cache.hits
  entry.lastAccessed = getTime()
  inc entry.accessCount
  cache.entries[key] = entry
  some(entry)

proc clear*[K, V](cache: Cache[K, V]) =
  cache.entries.clear()
  cache.size = 0

proc getStats*[K, V](cache: Cache[K, V]): JsonNode =
  %*{
    "size": cache.size,
    "maxSize": cache.policy.maxSize,
    "hits": cache.hits,
    "misses": cache.misses,
    "hitRatio": if cache.hits + cache.misses > 0: cache.hits / (cache.hits + cache.misses) else: 0.0
  } 