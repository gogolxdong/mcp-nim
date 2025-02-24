import std/[json, options]
import ./base_types

proc toMcp*[T](node: JsonNode, _: typedesc[T]): T =
  when T is JsonNode:
    result = node
  elif T is base_types.JsonRpcRequest:
    result = base_types.JsonRpcRequest(
      jsonrpc: node["jsonrpc"].getStr,
      id: node["id"].toMcp(base_types.RequestId),
      `method`: node["method"].getStr
    )
    if node.hasKey("params"):
      let rawParams = node["params"]
      stderr.writeLine "[DEBUG] Raw request params: ", $rawParams
      
      result.params = some(BaseRequestParams(
        meta: if rawParams.hasKey("meta"): some(rawParams["meta"].toMcp(base_types.MetaData)) else: none(base_types.MetaData),
        rawParams: rawParams
      ))
      stderr.writeLine "[DEBUG] Converted request with raw params: ", $(%*{
        "meta": result.params.get.meta,
        "rawParams": result.params.get.rawParams
      })
  elif T is base_types.JsonRpcResponse:
    result = base_types.JsonRpcResponse(
      jsonrpc: node["jsonrpc"].getStr,
      id: node["id"].toMcp(base_types.RequestId),
      result: node["result"]
    )
  elif T is base_types.JsonRpcNotification:
    result = base_types.JsonRpcNotification(
      jsonrpc: node["jsonrpc"].getStr,
      `method`: node["method"].getStr
    )
    if node.hasKey("params"):
      let rawParams = node["params"]
      stderr.writeLine "[DEBUG] Raw notification params: ", $rawParams
      
      result.params = some(BaseNotificationParams(
        meta: if rawParams.hasKey("meta"): some(rawParams["meta"].toMcp(base_types.MetaData)) else: none(base_types.MetaData),
        rawParams: rawParams
      ))
      stderr.writeLine "[DEBUG] Converted notification with raw params: ", $(%*{
        "meta": result.params.get.meta,
        "rawParams": result.params.get.rawParams
      })
  elif T is base_types.RequestId:
    if node.kind == JString:
      result = newRequestId(node.getStr)
    else:
      result = newRequestId(node.getInt)
  elif T is base_types.ProgressToken:
    if node.kind == JString:
      result = newProgressToken(node.getStr)
    else:
      result = newProgressToken(node.getInt)
  elif T is base_types.MetaData:
    result = base_types.MetaData()
    if node.hasKey("progressToken"):
      result.progressToken = some(node["progressToken"].toMcp(base_types.ProgressToken))
  elif T is base_types.BaseRequestParams:
    result = base_types.BaseRequestParams(
      meta: if node.hasKey("meta"): some(node["meta"].toMcp(base_types.MetaData)) else: none(base_types.MetaData),
      rawParams: node
    )
  elif T is base_types.BaseNotificationParams:
    result = base_types.BaseNotificationParams(
      meta: if node.hasKey("meta"): some(node["meta"].toMcp(base_types.MetaData)) else: none(base_types.MetaData),
      rawParams: node
    )
  else:
    {.error: "Unsupported type for conversion: " & $T.}

proc toMcp*[T](node: Option[JsonNode], _: typedesc[T]): T =
  if node.isNone:
    raise newException(ValueError, "Cannot convert None to " & $T)
  result = node.get.toMcp(T)

export toMcp 