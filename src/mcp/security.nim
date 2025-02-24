import std/[asyncdispatch, json, options, os, strutils, tables, sets, sequtils]
import ./shared/base_types

type
  Permission* = enum
    pRead,
    pWrite,
    pDelete,
    pExecute,
    pAdmin

  Role* = object
    name*: string
    description*: string
    permissions*: HashSet[Permission]
    inherits*: seq[string]

  User* = object
    id*: string
    name*: string
    roles*: seq[string]
    directPermissions*: HashSet[Permission]

  AccessControl* = ref object
    roles*: Table[string, Role]
    users*: Table[string, User]
    resourcePermissions*: Table[string, HashSet[Permission]]

proc newRole*(name, description: string, permissions: HashSet[Permission], inherits: seq[string] = @[]): Role =
  Role(
    name: name,
    description: description,
    permissions: permissions,
    inherits: inherits
  )

proc newUser*(id, name: string, roles: seq[string] = @[], permissions: HashSet[Permission] = initHashSet[Permission]()): User =
  User(
    id: id,
    name: name,
    roles: roles,
    directPermissions: permissions
  )

proc newAccessControl*(): AccessControl =
  AccessControl(
    roles: initTable[string, Role](),
    users: initTable[string, User](),
    resourcePermissions: initTable[string, HashSet[Permission]]()
  )

proc addRole*(ac: AccessControl, role: Role) =
  ac.roles[role.name] = role

proc addUser*(ac: AccessControl, user: User) =
  ac.users[user.id] = user

proc setResourcePermissions*(ac: AccessControl, resource: string, permissions: HashSet[Permission]) =
  ac.resourcePermissions[resource] = permissions

proc getAllPermissions(ac: AccessControl, role: Role): HashSet[Permission] =
  result = role.permissions
  for parentName in role.inherits:
    if parentName in ac.roles:
      let parentPerms = ac.getAllPermissions(ac.roles[parentName])
      result = result + parentPerms

proc getUserPermissions*(ac: AccessControl, userId: string): HashSet[Permission] =
  if userId notin ac.users:
    return initHashSet[Permission]()

  let user = ac.users[userId]
  result = user.directPermissions

  for roleName in user.roles:
    if roleName in ac.roles:
      let rolePerms = ac.getAllPermissions(ac.roles[roleName])
      result = result + rolePerms

proc hasPermission*(ac: AccessControl, userId: string, resource: string, permission: Permission): bool =
  # Check if resource has any permissions defined
  if resource notin ac.resourcePermissions:
    return false

  # Get required permissions for resource
  let requiredPerms = ac.resourcePermissions[resource]
  if permission notin requiredPerms:
    return false

  # Get user's permissions
  let userPerms = ac.getUserPermissions(userId)
  
  # Check if user has required permission
  result = permission in userPerms or pAdmin in userPerms

proc checkPermission*(ac: AccessControl, userId: string, resource: string, permission: Permission) =
  if not ac.hasPermission(userId, resource, permission):
    raise newMcpError(ErrorCode.InvalidRequest, "Permission denied")

proc toJson*(role: Role): JsonNode =
  %*{
    "name": role.name,
    "description": role.description,
    "permissions": toSeq(role.permissions).mapIt($it),
    "inherits": role.inherits
  }

proc toJson*(user: User): JsonNode =
  %*{
    "id": user.id,
    "name": user.name,
    "roles": user.roles,
    "directPermissions": toSeq(user.directPermissions).mapIt($it)
  }

proc toJson*(ac: AccessControl): JsonNode =
  var roles = newJArray()
  for role in ac.roles.values:
    roles.add(role.toJson)

  var users = newJArray()
  for user in ac.users.values:
    users.add(user.toJson)

  var resources = newJObject()
  for resource, perms in ac.resourcePermissions:
    resources[resource] = %toSeq(perms).mapIt($it)

  %*{
    "roles": roles,
    "users": users,
    "resources": resources
  } 