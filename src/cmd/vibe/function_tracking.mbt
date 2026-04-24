///|
struct FunctionTrackingSemver {
  major : Int
  minor : Int
  patch : Int
}

///|
struct FunctionTrackingRecordState {
  path : String
  name : String
  def_id : String
  signature : String
  version : FunctionTrackingSemver
  ty : @vibe_core.Type
  content_hash : String
  content_norm : String
  renamed_from : String?
}

///|
struct FunctionTrackingSnapshot {
  key : String
  path : String
  name : String
  def_id : String
  signature : String
  ty : @vibe_core.Type
  content_hash : String
  content_norm : String
  env : @checker.TypeEnv
}

///|
let function_tracking_schema_version : Int = 1

///|
let function_tracking_similarity_threshold : Double = 0.9

///|
fn tracking_symbol_key(path : String, name : String) -> String {
  path + "#" + name
}

///|
fn function_tracking_semver_init() -> FunctionTrackingSemver {
  { major: 1, minor: 0, patch: 0 }
}

///|
fn function_tracking_semver_to_string(
  version : FunctionTrackingSemver,
) -> String {
  version.major.to_string() +
  "." +
  version.minor.to_string() +
  "." +
  version.patch.to_string()
}

///|
fn function_tracking_parse_semver(text : String) -> FunctionTrackingSemver? {
  let parts : Array[String] = []
  for piece in text.split(".") {
    parts.push(piece.to_string())
  }
  if parts.length() != 3 {
    return None
  }
  let major = @strconv.parse_int(parts[0].trim()) catch { _ => return None }
  let minor = @strconv.parse_int(parts[1].trim()) catch { _ => return None }
  let patch = @strconv.parse_int(parts[2].trim()) catch { _ => return None }
  Some({ major, minor, patch })
}

///|
fn function_tracking_semver_apply(
  version : FunctionTrackingSemver,
  bump : @checker.ApiVersionBump,
) -> FunctionTrackingSemver {
  match bump {
    @checker.ApiVersionBump::Patch =>
      { major: version.major, minor: version.minor, patch: version.patch + 1 }
    @checker.ApiVersionBump::Minor =>
      { major: version.major, minor: version.minor + 1, patch: 0 }
    @checker.ApiVersionBump::Major =>
      { major: version.major + 1, minor: 0, patch: 0 }
  }
}

///|
fn function_tracking_label_to_string(label : @vibe_core.ParamLabel) -> String {
  match label {
    @vibe_core.ParamLabel::Positional => "positional"
    @vibe_core.ParamLabel::Variadic => "variadic"
    @vibe_core.ParamLabel::Required => "required"
    @vibe_core.ParamLabel::Optional => "optional"
  }
}

///|
fn function_tracking_label_from_string(text : String) -> @vibe_core.ParamLabel? {
  match text {
    "positional" => Some(@vibe_core.ParamLabel::Positional)
    "variadic" => Some(@vibe_core.ParamLabel::Variadic)
    "required" => Some(@vibe_core.ParamLabel::Required)
    "optional" => Some(@vibe_core.ParamLabel::Optional)
    _ => None
  }
}

///|
fn function_tracking_effect_to_json(effect : @vibe_core.EffectAtom) -> Json {
  let out : Map[String, Json] = {}
  match effect {
    @vibe_core.EffectAtom::Const(name) => out["Const"] = Json::string(name)
    @vibe_core.EffectAtom::Var(name) => out["Var"] = Json::string(name)
  }
  Json::object(out)
}

///|
fn function_tracking_effect_from_json(json : Json) -> @vibe_core.EffectAtom? {
  let obj = match json {
    Json::Object(map) => map
    _ => return None
  }
  for key, value in obj {
    match key {
      "Const" =>
        match value {
          Json::String(name) => return Some(@vibe_core.EffectAtom::Const(name))
          _ => return None
        }
      "Var" =>
        match value {
          Json::String(name) => return Some(@vibe_core.EffectAtom::Var(name))
          _ => return None
        }
      _ => ()
    }
  }
  None
}

///|
fn function_tracking_type_to_json(ty : @vibe_core.Type) -> Json {
  let obj : Map[String, Json] = {}
  match ty {
    @vibe_core.Type::Int => obj["Int"] = Json::null()
    @vibe_core.Type::Float => obj["Float"] = Json::null()
    @vibe_core.Type::Double => obj["Double"] = Json::null()
    @vibe_core.Type::Bool => obj["Bool"] = Json::null()
    @vibe_core.Type::Char => obj["Char"] = Json::null()
    @vibe_core.Type::String => obj["String"] = Json::null()
    @vibe_core.Type::Path => obj["Path"] = Json::null()
    @vibe_core.Type::PromptText => obj["PromptText"] = Json::null()
    @vibe_core.Type::Unit => obj["Unit"] = Json::null()
    @vibe_core.Type::Infer => obj["Infer"] = Json::null()
    @vibe_core.Type::Never => obj["Never"] = Json::null()
    @vibe_core.Type::Param(name) => obj["Param"] = Json::string(name)
    @vibe_core.Type::Var(id) => obj["Var"] = Json::number(id.to_double())
    @vibe_core.Type::Array(inner) =>
      obj["Array"] = function_tracking_type_to_json(inner)
    @vibe_core.Type::Set(inner) =>
      obj["Set"] = function_tracking_type_to_json(inner)
    @vibe_core.Type::Map(_key, inner) =>
      obj["Map"] = function_tracking_type_to_json(inner)
    @vibe_core.Type::ArrayBuilder(inner) =>
      obj["ArrayBuilder"] = function_tracking_type_to_json(inner)
    @vibe_core.Type::MapBuilder(_key, inner) =>
      obj["MapBuilder"] = function_tracking_type_to_json(inner)
    @vibe_core.Type::StringBuilder => obj["StringBuilder"] = Json::null()
    @vibe_core.Type::Bytes => obj["Bytes"] = Json::null()
    @vibe_core.Type::V128 => obj["V128"] = Json::null()
    @vibe_core.Type::Tuple(items) => {
      let arr : Array[Json] = []
      for item in items {
        arr.push(function_tracking_type_to_json(item))
      }
      obj["Tuple"] = Json::array(arr)
    }
    @vibe_core.Type::Record(fields) => {
      let encoded : Map[String, Json] = {}
      for key, value in fields {
        encoded[key] = function_tracking_type_to_json(value)
      }
      obj["Record"] = Json::object(encoded)
    }
    @vibe_core.Type::Variant(fields) => {
      let encoded : Map[String, Json] = {}
      for key, value in fields {
        encoded[key] = function_tracking_type_to_json(value)
      }
      obj["Variant"] = Json::object(encoded)
    }
    @vibe_core.Type::Named(name~, args~) => {
      let inner : Map[String, Json] = {}
      let encoded_args : Array[Json] = []
      for arg in args {
        encoded_args.push(function_tracking_type_to_json(arg))
      }
      inner["name"] = Json::string(name)
      inner["args"] = Json::array(encoded_args)
      obj["Named"] = Json::object(inner)
    }
    @vibe_core.Type::Func(params~, ret~, effects~) => {
      let inner : Map[String, Json] = {}
      let params_json : Array[Json] = []
      for param in params {
        let param_obj : Map[String, Json] = {}
        let bounds_json : Array[Json] = []
        for bound in param.bounds {
          bounds_json.push(Json::string(bound))
        }
        param_obj["name"] = Json::string(param.name)
        param_obj["label"] = Json::string(
          function_tracking_label_to_string(param.label),
        )
        param_obj["ty"] = function_tracking_type_to_json(param.ty)
        param_obj["bounds"] = Json::array(bounds_json)
        params_json.push(Json::object(param_obj))
      }
      let effects_json : Array[Json] = []
      for effect in effects {
        effects_json.push(function_tracking_effect_to_json(effect))
      }
      inner["params"] = Json::array(params_json)
      inner["ret"] = function_tracking_type_to_json(ret)
      inner["effects"] = Json::array(effects_json)
      obj["Func"] = Json::object(inner)
    }
  }
  Json::object(obj)
}

///|
fn function_tracking_type_array_from_json(
  json : Json,
) -> Array[@vibe_core.Type]? {
  let arr = match json {
    Json::Array(items) => items
    _ => return None
  }
  let out : Array[@vibe_core.Type] = []
  for item in arr {
    match function_tracking_type_from_json(item) {
      Some(ty) => out.push(ty)
      None => return None
    }
  }
  Some(out)
}

///|
fn function_tracking_type_map_from_json(
  json : Json,
) -> Map[String, @vibe_core.Type]? {
  let obj = match json {
    Json::Object(map) => map
    _ => return None
  }
  let out : Map[String, @vibe_core.Type] = {}
  for key, value in obj {
    match function_tracking_type_from_json(value) {
      Some(ty) => out[key] = ty
      None => return None
    }
  }
  Some(out)
}

///|
fn function_tracking_parse_param(json : Json) -> @vibe_core.FuncParam? {
  let obj = match json {
    Json::Object(map) => map
    _ => return None
  }
  let name = match obj.get("name") {
    Some(Json::String(value)) => value
    _ => return None
  }
  let label = match obj.get("label") {
    Some(Json::String(value)) =>
      match function_tracking_label_from_string(value) {
        Some(v) => v
        None => return None
      }
    _ => return None
  }
  let ty = match obj.get("ty") {
    Some(value) =>
      match function_tracking_type_from_json(value) {
        Some(v) => v
        None => return None
      }
    _ => return None
  }
  let bounds = match obj.get("bounds") {
    Some(Json::Array(items)) => {
      let out : Array[String] = []
      for item in items {
        match item {
          Json::String(value) => out.push(value)
          _ => return None
        }
      }
      out
    }
    _ => return None
  }
  Some(@vibe_core.FuncParam::{ name, label, ty, bounds })
}

///|
fn function_tracking_parse_effects(
  json : Json,
) -> Array[@vibe_core.EffectAtom]? {
  let arr = match json {
    Json::Array(items) => items
    _ => return None
  }
  let out : Array[@vibe_core.EffectAtom] = []
  for item in arr {
    match function_tracking_effect_from_json(item) {
      Some(effect) => out.push(effect)
      None => return None
    }
  }
  Some(out)
}

///|
fn function_tracking_type_from_json(json : Json) -> @vibe_core.Type? {
  let obj = match json {
    Json::Object(map) => map
    _ => return None
  }
  for key, value in obj {
    match key {
      "Int" => return Some(@vibe_core.Type::Int)
      "Float" => return Some(@vibe_core.Type::Float)
      "Double" => return Some(@vibe_core.Type::Double)
      "Bool" => return Some(@vibe_core.Type::Bool)
      "String" => return Some(@vibe_core.Type::String)
      "Path" => return Some(@vibe_core.Type::Path)
      "Unit" => return Some(@vibe_core.Type::Unit)
      "Never" => return Some(@vibe_core.Type::Never)
      "Param" =>
        match value {
          Json::String(name) => return Some(@vibe_core.Type::Param(name))
          _ => return None
        }
      "Var" =>
        match value {
          Json::Number(number, ..) =>
            return Some(@vibe_core.Type::Var(number.to_int()))
          _ => return None
        }
      "Array" =>
        match function_tracking_type_from_json(value) {
          Some(inner) => return Some(@vibe_core.Type::Array(inner))
          None => return None
        }
      "Set" =>
        match function_tracking_type_from_json(value) {
          Some(inner) => return Some(@vibe_core.Type::Set(inner))
          None => return None
        }
      "Map" =>
        match function_tracking_type_from_json(value) {
          Some(inner) =>
            return Some(@vibe_core.Type::Map(@vibe_core.Type::String, inner))
          None => return None
        }
      "ArrayBuilder" =>
        match function_tracking_type_from_json(value) {
          Some(inner) => return Some(@vibe_core.Type::ArrayBuilder(inner))
          None => return None
        }
      "MapBuilder" =>
        match function_tracking_type_from_json(value) {
          Some(inner) =>
            return Some(
              @vibe_core.Type::MapBuilder(@vibe_core.Type::String, inner),
            )
          None => return None
        }
      "StringBuilder" => return Some(@vibe_core.Type::StringBuilder)
      "Tuple" =>
        match function_tracking_type_array_from_json(value) {
          Some(items) => return Some(@vibe_core.Type::Tuple(items))
          None => return None
        }
      "Record" =>
        match function_tracking_type_map_from_json(value) {
          Some(fields) => return Some(@vibe_core.Type::Record(fields))
          None => return None
        }
      "Variant" =>
        match function_tracking_type_map_from_json(value) {
          Some(fields) => return Some(@vibe_core.Type::Variant(fields))
          None => return None
        }
      "Named" => {
        let inner = match value {
          Json::Object(map) => map
          _ => return None
        }
        let name = match inner.get("name") {
          Some(Json::String(v)) => v
          _ => return None
        }
        let args = match inner.get("args") {
          Some(v) =>
            match function_tracking_type_array_from_json(v) {
              Some(items) => items
              None => return None
            }
          _ => return None
        }
        return Some(@vibe_core.Type::Named(name~, args~))
      }
      "Func" => {
        let inner = match value {
          Json::Object(map) => map
          _ => return None
        }
        let params = match inner.get("params") {
          Some(Json::Array(items)) => {
            let out : Array[@vibe_core.FuncParam] = []
            for item in items {
              match function_tracking_parse_param(item) {
                Some(param) => out.push(param)
                None => return None
              }
            }
            out
          }
          _ => return None
        }
        let ret = match inner.get("ret") {
          Some(v) =>
            match function_tracking_type_from_json(v) {
              Some(ty) => ty
              None => return None
            }
          _ => return None
        }
        let effects = match inner.get("effects") {
          Some(v) =>
            match function_tracking_parse_effects(v) {
              Some(items) => items
              None => return None
            }
          _ => return None
        }
        return Some(@vibe_core.Type::Func(params~, ret~, effects~))
      }
      _ => ()
    }
  }
  None
}

///|
fn function_tracking_record_to_json(
  record : FunctionTrackingRecordState,
) -> Json {
  let obj : Map[String, Json] = {}
  obj["path"] = Json::string(record.path)
  obj["name"] = Json::string(record.name)
  obj["def_id"] = Json::string(record.def_id)
  obj["signature"] = Json::string(record.signature)
  obj["version"] = Json::string(
    function_tracking_semver_to_string(record.version),
  )
  obj["type"] = function_tracking_type_to_json(record.ty)
  obj["content_hash"] = Json::string(record.content_hash)
  obj["content_norm"] = Json::string(record.content_norm)
  match record.renamed_from {
    Some(value) => obj["renamed_from"] = Json::string(value)
    None => ()
  }
  Json::object(obj)
}

///|
fn function_tracking_record_from_json(
  json : Json,
) -> FunctionTrackingRecordState? {
  let obj = match json {
    Json::Object(map) => map
    _ => return None
  }
  let path = match obj.get("path") {
    Some(Json::String(value)) => value
    _ => return None
  }
  let name = match obj.get("name") {
    Some(Json::String(value)) => value
    _ => return None
  }
  let def_id = match obj.get("def_id") {
    Some(Json::String(value)) => value
    _ => ""
  }
  let signature = match obj.get("signature") {
    Some(Json::String(value)) => value
    _ => "_"
  }
  let version = match obj.get("version") {
    Some(Json::String(value)) =>
      match function_tracking_parse_semver(value) {
        Some(parsed) => parsed
        None => return None
      }
    _ => return None
  }
  let ty = match obj.get("type") {
    Some(value) =>
      match function_tracking_type_from_json(value) {
        Some(parsed) => parsed
        None => return None
      }
    _ => return None
  }
  let content_hash = match obj.get("content_hash") {
    Some(Json::String(value)) => value
    _ => return None
  }
  let content_norm = match obj.get("content_norm") {
    Some(Json::String(value)) => value
    _ => ""
  }
  let renamed_from = match obj.get("renamed_from") {
    Some(Json::String(value)) =>
      if value.trim().to_string().length() == 0 {
        None
      } else {
        Some(value)
      }
    _ => None
  }
  Some(FunctionTrackingRecordState::{
    path,
    name,
    def_id,
    signature,
    version,
    ty,
    content_hash,
    content_norm,
    renamed_from,
  })
}

///|
fn load_function_tracking_records_from_xdb(
  xdb_obj : Map[String, Json],
) -> Map[String, FunctionTrackingRecordState] {
  let out : Map[String, FunctionTrackingRecordState] = {}
  let tracking = match xdb_obj.get("function_tracking") {
    Some(Json::Object(value)) => value
    _ => return out
  }
  let _schema_version = match tracking.get("schema_version") {
    Some(Json::Number(value, ..)) => value.to_int()
    _ => 0
  }
  let records = match tracking.get("records") {
    Some(Json::Object(value)) => value
    _ => return out
  }
  for key, value in records {
    match function_tracking_record_from_json(value) {
      Some(record) => out[key] = record
      None => ()
    }
  }
  out
}

///|
fn build_function_tracking_json(
  records : Map[String, FunctionTrackingRecordState],
) -> Json {
  let root : Map[String, Json] = {}
  root["schema_version"] = Json::number(
    function_tracking_schema_version.to_double(),
  )
  let entries : Map[String, Json] = {}
  for key, record in records {
    entries[key] = function_tracking_record_to_json(record)
  }
  root["records"] = Json::object(entries)
  Json::object(root)
}

///|
fn function_tracking_stmt_norm(stmt : @vibe_core.Stmt) -> String {
  let mod = @vibe_core.Module::{ stmts: [stmt] }
  @vibe_core.serialize_module(@vibe_core.normalize_module(mod))
}

///|
fn function_tracking_collect_def_lookup(
  index : @x_exp.AdvancedGraphIndex,
) -> Map[String, @x_exp.AdvancedGraphDef] {
  let out : Map[String, @x_exp.AdvancedGraphDef] = {}
  for _, def in index.defs {
    if def.kind == "function" {
      out[tracking_symbol_key(def.path, def.name)] = def
    }
  }
  out
}

///|
fn function_tracking_collect_snapshots(
  db : @runtime.VibeDb,
  paths : Array[String],
  index : @x_exp.AdvancedGraphIndex,
) -> Array[FunctionTrackingSnapshot] {
  let def_lookup = function_tracking_collect_def_lookup(index)
  let out : Array[FunctionTrackingSnapshot] = []
  for path in paths {
    let ast = db.ast(path)
    let types = db.types(path)
    for stmt in ast.stmts {
      match stmt {
        @vibe_core.Stmt::Let(name~, expr~, ..)
        | @vibe_core.Stmt::ExportLet(name~, expr~, ..) =>
          match expr {
            @vibe_core.Expr::Fn(..) =>
              match types.get_scheme(name) {
                Some(scheme) => {
                  let key = tracking_symbol_key(path, name)
                  let def = def_lookup.get(key)
                  let def_id = match def {
                    Some(value) => value.def_id
                    None =>
                      @vibe_core.git_blob_hash_string(
                        key +
                        ":" +
                        @vibe_core.serialize_module(@vibe_core.Module::{
                          stmts: [stmt],
                        }),
                      )
                  }
                  let signature = match def {
                    Some(value) => value.signature
                    None => "_"
                  }
                  let content_norm = function_tracking_stmt_norm(stmt)
                  let content_hash = @vibe_core.git_blob_hash_string(
                    content_norm,
                  )
                  out.push(FunctionTrackingSnapshot::{
                    key,
                    path,
                    name,
                    def_id,
                    signature,
                    ty: scheme.ty,
                    content_hash,
                    content_norm,
                    env: types,
                  })
                }
                None => ()
              }
            _ => ()
          }
        _ => ()
      }
    }
  }
  out
}

///|
fn function_tracking_build_similarity_tree(
  text : String,
) -> @similarity.TreeNode {
  let chars = text.to_array()
  let root = @similarity.TreeNode::new("root", "", 0)
  if chars.length() < 3 {
    let mut id = 1
    for c in chars {
      root.add_child(
        @similarity.TreeNode::new("gram", String::from_array([c]), id),
      )
      id += 1
    }
    return root
  }
  let mut i = 0
  let mut id = 1
  while i + 2 < chars.length() {
    root.add_child(
      @similarity.TreeNode::new(
        "gram",
        String::from_array([chars[i], chars[i + 1], chars[i + 2]]),
        id,
      ),
    )
    id += 1
    i += 1
  }
  root
}

///|
fn function_tracking_similarity(left : String, right : String) -> Double {
  if left == right {
    return 1.0
  }
  if left.length() == 0 || right.length() == 0 {
    return 0.0
  }
  let left_tree = function_tracking_build_similarity_tree(left)
  let right_tree = function_tracking_build_similarity_tree(right)
  let options = @similarity.TSEDOptions::default()
  let score = @similarity.calculate_tsed(left_tree, right_tree, options)
  if score < 0.0 {
    0.0
  } else if score > 1.0 {
    1.0
  } else {
    score
  }
}

///|
fn function_tracking_bump(
  prev : FunctionTrackingRecordState,
  next : FunctionTrackingSnapshot,
) -> FunctionTrackingSemver {
  if prev.content_hash == next.content_hash {
    return prev.version
  }
  let bump = @checker.classify_function_api_change(next.env, prev.ty, next.ty)
  function_tracking_semver_apply(prev.version, bump)
}

///|
fn[T] function_tracking_sorted_keys(map : Map[String, T]) -> Array[String] {
  let keys : Array[String] = []
  for key, _ in map {
    keys.push(key)
  }
  keys.sort()
  keys
}

///|
fn function_tracking_snapshot_record(
  snapshot : FunctionTrackingSnapshot,
  version : FunctionTrackingSemver,
  renamed_from : String?,
) -> FunctionTrackingRecordState {
  FunctionTrackingRecordState::{
    path: snapshot.path,
    name: snapshot.name,
    def_id: snapshot.def_id,
    signature: snapshot.signature,
    version,
    ty: snapshot.ty,
    content_hash: snapshot.content_hash,
    content_norm: snapshot.content_norm,
    renamed_from,
  }
}

///|
fn function_tracking_build_next_records(
  previous : Map[String, FunctionTrackingRecordState],
  snapshots : Array[FunctionTrackingSnapshot],
) -> Map[String, FunctionTrackingRecordState] {
  let next : Map[String, FunctionTrackingRecordState] = {}
  let snapshot_map : Map[String, FunctionTrackingSnapshot] = {}
  for snapshot in snapshots {
    snapshot_map[snapshot.key] = snapshot
  }

  let unmatched_prev : Map[String, FunctionTrackingRecordState] = {}
  for key, record in previous {
    if not(snapshot_map.contains(key)) {
      unmatched_prev[key] = record
    }
  }
  let unmatched_new : Map[String, FunctionTrackingSnapshot] = {}

  for snapshot in snapshots {
    match previous.get(snapshot.key) {
      Some(prev_record) => {
        let version = function_tracking_bump(prev_record, snapshot)
        next[snapshot.key] = function_tracking_snapshot_record(
          snapshot,
          version,
          None,
        )
      }
      None => unmatched_new[snapshot.key] = snapshot
    }
  }

  let consumed_prev : Map[String, Bool] = {}
  let consumed_new : Map[String, Bool] = {}

  // Prefer exact normalized content hash match for rename continuity.
  for new_key in function_tracking_sorted_keys(unmatched_new) {
    if consumed_new.contains(new_key) {
      continue
    }
    let snapshot = unmatched_new[new_key]
    let mut matched_prev_key : String? = None
    for prev_key in function_tracking_sorted_keys(unmatched_prev) {
      if consumed_prev.contains(prev_key) {
        continue
      }
      let prev_record = unmatched_prev[prev_key]
      if prev_record.content_hash == snapshot.content_hash {
        matched_prev_key = Some(prev_key)
        break
      }
    }
    match matched_prev_key {
      Some(prev_key) => {
        let prev_record = unmatched_prev[prev_key]
        let version = function_tracking_bump(prev_record, snapshot)
        next[new_key] = function_tracking_snapshot_record(
          snapshot,
          version,
          Some(prev_key),
        )
        consumed_prev[prev_key] = true
        consumed_new[new_key] = true
      }
      None => ()
    }
  }

  // Fall back to similarity for likely rename/move with content edits.
  for new_key in function_tracking_sorted_keys(unmatched_new) {
    if consumed_new.contains(new_key) {
      continue
    }
    let snapshot = unmatched_new[new_key]
    let mut best_prev_key : String? = None
    let mut best_score = 0.0
    for prev_key in function_tracking_sorted_keys(unmatched_prev) {
      if consumed_prev.contains(prev_key) {
        continue
      }
      let prev_record = unmatched_prev[prev_key]
      let score = function_tracking_similarity(
        prev_record.content_norm,
        snapshot.content_norm,
      )
      if score > best_score {
        best_score = score
        best_prev_key = Some(prev_key)
      }
    }
    match best_prev_key {
      Some(prev_key) =>
        if best_score >= function_tracking_similarity_threshold {
          let prev_record = unmatched_prev[prev_key]
          let version = function_tracking_bump(prev_record, snapshot)
          next[new_key] = function_tracking_snapshot_record(
            snapshot,
            version,
            Some(prev_key),
          )
          consumed_prev[prev_key] = true
          consumed_new[new_key] = true
        }
      None => ()
    }
  }

  // Remaining snapshots are newly introduced functions.
  for new_key, snapshot in unmatched_new {
    if consumed_new.contains(new_key) {
      continue
    }
    next[new_key] = function_tracking_snapshot_record(
      snapshot,
      function_tracking_semver_init(),
      None,
    )
  }

  next
}

///|
pub fn compute_function_tracking_json(
  db : @runtime.VibeDb,
  paths : Array[String],
  index : @x_exp.AdvancedGraphIndex,
  xdb_obj : Map[String, Json],
) -> Json {
  let previous = load_function_tracking_records_from_xdb(xdb_obj)
  let snapshots = function_tracking_collect_snapshots(db, paths, index)
  let next = function_tracking_build_next_records(previous, snapshots)
  build_function_tracking_json(next)
}
