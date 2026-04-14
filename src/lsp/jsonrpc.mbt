///|
/// JSON-RPC 2.0 implementation for LSP

///|
pub(all) enum JsonRpcId {
  Num(Int)
  Str(String)
  Null
} derive(Debug, Eq)

///|
pub impl Show for JsonRpcId with output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
pub(all) struct JsonRpcRequest {
  jsonrpc : String
  id : JsonRpcId?
  meth : String
  params : Json?
} derive(Eq)

///|
pub(all) struct JsonRpcResponse {
  jsonrpc : String
  id : JsonRpcId?
  result : Json?
  error : JsonRpcError?
} derive(Eq)

///|
pub(all) struct JsonRpcError {
  code : Int
  message : String
  data : Json?
} derive(Eq)

///|
pub fn parse_request(json : Json) -> JsonRpcRequest? {
  match json {
    Json::Object(obj) => {
      let jsonrpc = match obj.get("jsonrpc") {
        Some(Json::String(s)) => s
        _ => return None
      }
      let id = match obj.get("id") {
        Some(Json::Number(n, ..)) => Some(JsonRpcId::Num(n.to_int()))
        Some(Json::String(s)) => Some(JsonRpcId::Str(s))
        Some(Json::Null) => Some(JsonRpcId::Null)
        None => None
        _ => None
      }
      let meth = match obj.get("method") {
        Some(Json::String(s)) => s
        _ => return None
      }
      let params = obj.get("params")
      Some(JsonRpcRequest::{ jsonrpc, id, meth, params })
    }
    _ => None
  }
}

///|
pub fn response_to_json(resp : JsonRpcResponse) -> Json {
  let obj : Map[String, Json] = {}
  obj["jsonrpc"] = Json::string(resp.jsonrpc)
  match resp.id {
    Some(JsonRpcId::Num(n)) => obj["id"] = Json::number(n.to_double())
    Some(JsonRpcId::Str(s)) => obj["id"] = Json::string(s)
    Some(JsonRpcId::Null) | None => obj["id"] = Json::null()
  }
  match resp.result {
    Some(r) => obj["result"] = r
    None => ()
  }
  match resp.error {
    Some(e) => obj["error"] = error_to_json(e)
    None => ()
  }
  Json::object(obj)
}

///|
fn error_to_json(e : JsonRpcError) -> Json {
  let obj : Map[String, Json] = {}
  obj["code"] = Json::number(e.code.to_double())
  obj["message"] = Json::string(e.message)
  match e.data {
    Some(d) => obj["data"] = d
    None => ()
  }
  Json::object(obj)
}

///|
pub fn make_response(id : JsonRpcId?, result : Json) -> JsonRpcResponse {
  JsonRpcResponse::{ jsonrpc: "2.0", id, result: Some(result), error: None }
}

///|
pub fn make_error_response(
  id : JsonRpcId?,
  code : Int,
  message : String,
) -> JsonRpcResponse {
  JsonRpcResponse::{
    jsonrpc: "2.0",
    id,
    result: None,
    error: Some(JsonRpcError::{ code, message, data: None }),
  }
}

///|
pub fn notification_to_json(meth : String, params : Json) -> Json {
  let obj : Map[String, Json] = {}
  obj["jsonrpc"] = Json::string("2.0")
  obj["method"] = Json::string(meth)
  obj["params"] = params
  Json::object(obj)
}
