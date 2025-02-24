import std/[asyncdispatch, json, options, times, tables, deques, random]
import ./shared/base_types

type
  OperationPriority* = enum
    opLow,
    opNormal,
    opHigh,
    opCritical

  OperationState* = enum
    osQueued,
    osRunning,
    osCompleted,
    osFailed,
    osCancelled

  Operation*[T] = ref object
    id*: string
    priority*: OperationPriority
    state*: OperationState
    createdAt*: Time
    startedAt*: Option[Time]
    completedAt*: Option[Time]
    task*: proc(): Future[T] {.async.}
    result*: Option[T]
    error*: Option[string]

  RateLimiter* = ref object
    maxOperations*: int
    interval*: Duration
    currentOperations*: int
    lastReset*: Time

  OperationQueue*[T] = ref object
    operations*: Table[string, Operation[T]]
    queues*: array[OperationPriority, Deque[string]]
    rateLimiter*: RateLimiter
    maxConcurrent*: int
    running*: int

proc newOperation*[T](task: proc(): Future[T] {.async.}, priority = opNormal): Operation[T] =
  randomize()  # Initialize random number generator
  Operation[T](
    id: $getTime().toUnix & $rand(1000),
    priority: priority,
    state: osQueued,
    createdAt: getTime(),
    startedAt: none(Time),
    completedAt: none(Time),
    task: task,
    result: none(T),
    error: none(string)
  )

proc newRateLimiter*(maxOperations: int, interval: Duration): RateLimiter =
  RateLimiter(
    maxOperations: maxOperations,
    interval: interval,
    currentOperations: 0,
    lastReset: getTime()
  )

proc newOperationQueue*[T](maxConcurrent = 4): OperationQueue[T] =
  OperationQueue[T](
    operations: initTable[string, Operation[T]](),
    queues: [initDeque[string](), initDeque[string](), initDeque[string](), initDeque[string]()],
    rateLimiter: nil,
    maxConcurrent: maxConcurrent,
    running: 0
  )

proc setRateLimiter*[T](queue: OperationQueue[T], limiter: RateLimiter) =
  queue.rateLimiter = limiter

proc canExecute*(limiter: RateLimiter): bool =
  let now = getTime()
  if now - limiter.lastReset >= limiter.interval:
    limiter.currentOperations = 0
    limiter.lastReset = now
  
  result = limiter.currentOperations < limiter.maxOperations

proc incrementOperations*(limiter: RateLimiter) =
  inc limiter.currentOperations

proc enqueue*[T](queue: OperationQueue[T], operation: Operation[T]) =
  queue.operations[operation.id] = operation
  queue.queues[operation.priority].addLast(operation.id)

proc dequeue*[T](queue: OperationQueue[T]): Option[Operation[T]] =
  # Check rate limiter
  if not queue.rateLimiter.isNil and not queue.rateLimiter.canExecute():
    return none(Operation[T])

  # Check concurrent limit
  if queue.running >= queue.maxConcurrent:
    return none(Operation[T])

  # Try to get next operation from highest priority queue
  for priority in countdown(opCritical, opLow):
    if queue.queues[priority].len > 0:
      let id = queue.queues[priority].popFirst()
      if id in queue.operations:
        inc queue.running
        if not queue.rateLimiter.isNil:
          queue.rateLimiter.incrementOperations()
        return some(queue.operations[id])

  none(Operation[T])

proc complete*[T](queue: OperationQueue[T], operation: Operation[T], result: T) =
  operation.state = osCompleted
  operation.result = some(result)
  operation.completedAt = some(getTime())
  dec queue.running

proc fail*[T](queue: OperationQueue[T], operation: Operation[T], error: string) =
  operation.state = osFailed
  operation.error = some(error)
  operation.completedAt = some(getTime())
  dec queue.running

proc cancel*[T](queue: OperationQueue[T], operation: Operation[T]) =
  operation.state = osCancelled
  operation.completedAt = some(getTime())
  dec queue.running

proc processQueue*[T](queue: OperationQueue[T]) {.async.} =
  while true:
    let opOpt = queue.dequeue()
    if opOpt.isNone:
      await sleepAsync(100)  # Wait before checking again
      continue

    let operation = opOpt.get
    operation.state = osRunning
    operation.startedAt = some(getTime())

    try:
      let result = await operation.task()
      queue.complete(operation, result)
    except Exception as e:
      queue.fail(operation, e.msg)

proc getStats*[T](queue: OperationQueue[T]): JsonNode =
  var queueSizes = newJObject()
  for priority in OperationPriority:
    queueSizes[$priority] = %queue.queues[priority].len

  %*{
    "running": queue.running,
    "maxConcurrent": queue.maxConcurrent,
    "queueSizes": queueSizes,
    "hasRateLimiter": not queue.rateLimiter.isNil
  } 