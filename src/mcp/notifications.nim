import std/[asyncdispatch, json, options, times, sequtils, algorithm]
import ./shared/base_types

type
  NotificationKind* = enum
    nkInfo,
    nkWarning,
    nkError,
    nkProgress,
    nkResource,
    nkSystem

  Notification* = object
    id*: string
    kind*: NotificationKind
    timestamp*: Time
    title*: string
    message*: string
    data*: Option[JsonNode]
    persistent*: bool

  NotificationManager* = ref object
    notifications*: seq[Notification]
    maxSize*: int
    onNotify*: Option[proc(notification: Notification) {.async.}]

proc newNotification*(kind: NotificationKind, title, message: string, data: Option[JsonNode] = none(JsonNode), persistent = false): Notification =
  Notification(
    id: $getTime().toUnix,
    kind: kind,
    timestamp: getTime(),
    title: title,
    message: message,
    data: data,
    persistent: persistent
  )

proc newNotificationManager*(maxSize = 1000): NotificationManager =
  NotificationManager(
    notifications: @[],
    maxSize: maxSize,
    onNotify: none(proc(notification: Notification) {.async.})
  )

proc findNonPersistent(notifications: seq[Notification]): int =
  for i, n in notifications:
    if not n.persistent:
      return i
  return -1

proc add*(manager: NotificationManager, notification: Notification) {.async.} =
  # Add notification to the list
  manager.notifications.add(notification)

  # Remove oldest non-persistent notifications if we exceed maxSize
  while manager.notifications.len > manager.maxSize:
    let idx = findNonPersistent(manager.notifications)
    if idx == -1:
      break
    manager.notifications.delete(idx)

  # Notify listeners
  if manager.onNotify.isSome:
    await manager.onNotify.get()(notification)

proc clear*(manager: NotificationManager) =
  # Clear all non-persistent notifications
  var newNotifications: seq[Notification] = @[]
  for n in manager.notifications:
    if n.persistent:
      newNotifications.add(n)
  manager.notifications = newNotifications

proc toJson*(notification: Notification): JsonNode =
  result = %*{
    "id": notification.id,
    "kind": $notification.kind,
    "timestamp": notification.timestamp.toUnix,
    "title": notification.title,
    "message": notification.message,
    "persistent": notification.persistent
  }
  if notification.data.isSome:
    result["data"] = notification.data.get

proc toJson*(manager: NotificationManager): JsonNode =
  var notifications = newJArray()
  for n in manager.notifications:
    notifications.add(n.toJson)
  
  %*{
    "notifications": notifications,
    "maxSize": manager.maxSize
  } 