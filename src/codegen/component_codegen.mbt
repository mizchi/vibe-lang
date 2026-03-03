///|
/// Component Model codegen for vibe
/// Wraps Core WASM in Component Model format for wkg/wa.dev/mwac compatibility

///|
/// Write unsigned LEB128 encoded integer
fn component_write_uleb128(buf : Array[Byte], n : Int) -> Unit {
  let mut val = n
  while true {
    let byte = val & 0x7f
    val = val >> 7
    if val == 0 {
      buf.push(byte.to_byte())
      break
    } else {
      buf.push((byte | 0x80).to_byte())
    }
  }
}

///|
/// Write a name (length-prefixed UTF-8 string)
fn component_write_name(buf : Array[Byte], name : String) -> Unit {
  let bytes = @utf8.encode(name).to_array()
  component_write_uleb128(buf, bytes.length())
  for b in bytes {
    buf.push(b)
  }
}

///|
/// Component Model magic and version
let component_magic : Array[Byte] = [
  b'\x00', b'\x61', b'\x73', b'\x6d', // \0asm
   b'\x0d', b'\x00', b'\x01', b'\x00', // version 13 (component model)
]

///|
/// Component section IDs (from Component Model Binary Format spec)
/// https://github.com/WebAssembly/component-model/blob/main/design/mvp/Binary.md
let component_section_module : Byte = b'\x01' // section_1: core module

///|
let component_section_core_instance : Byte = b'\x02' // core instance

///|
let component_section_alias : Byte = b'\x06' // alias

///|
let component_section_type : Byte = b'\x07' // component type section

///|
let component_section_canon : Byte = b'\x08' // canon section

///|
let component_section_import : Byte = b'\x0a' // component import section

///|
let component_section_export : Byte = b'\x0b' // component export section

///|
/// Core sort values for alias
let core_sort_func : Byte = b'\x00'

///|
let core_sort_mem : Byte = b'\x02'

///|
let component_extern_func : Byte = b'\x01'

///|
let component_instantiation_arg_instance : Byte = b'\x12'

///|
let component_valtype_s32 : Byte = b'\x7a'

///|
let component_valtype_s64 : Byte = b'\x78'

///|
let component_valtype_f32 : Byte = b'\x76'

///|
let component_valtype_f64 : Byte = b'\x75'

///|
priv struct CoreFuncSig {
  params : Array[Byte]
  results : Array[Byte]
}

///|
priv struct CoreImportFunc {
  module_name : String
  func_name : String
  sig : CoreFuncSig
}

///|
priv struct ComponentFuncSig {
  params : Array[Byte]
  results : Array[Byte]
}

///|
priv struct CoreImportBinding {
  import_name : String
  func_name : String
  sig : ComponentFuncSig
  func_idx : Int
}

///|
priv struct CoreImportPlan {
  bindings : Array[CoreImportBinding]
  module_names : Array[String]
  module_bindings : Array[Array[CoreImportBinding]]
}

///|
/// Emit core module section (section id 1)
/// Format: section_1(<core:module binary>)
fn emit_core_module_section(buf : Array[Byte], core_wasm : Bytes) -> Unit {
  buf.push(component_section_module)
  // Content: core wasm binary directly
  component_write_uleb128(buf, core_wasm.length())
  for b in core_wasm.iter() {
    buf.push(b)
  }
}

///|
/// Emit core instance section with one instantiate definition.
fn emit_core_instance_instantiate_section(
  buf : Array[Byte],
  module_index : Int,
  module_names : Array[String],
) -> Unit {
  buf.push(component_section_core_instance)
  let content : Array[Byte] = []
  component_write_uleb128(content, 1)
  content.push(b'\x00') // instantiate
  component_write_uleb128(content, module_index)
  component_write_uleb128(content, module_names.length())
  for i, module_name in module_names {
    component_write_name(content, module_name)
    content.push(component_instantiation_arg_instance)
    component_write_uleb128(content, i)
  }
  component_write_uleb128(buf, content.length())
  for b in content {
    buf.push(b)
  }
}

///|
fn emit_core_instance_from_exports_section(
  buf : Array[Byte],
  module_bindings : Array[Array[CoreImportBinding]],
) -> Unit {
  if module_bindings.length() == 0 {
    return
  }
  buf.push(component_section_core_instance)
  let content : Array[Byte] = []
  component_write_uleb128(content, module_bindings.length())
  for bindings in module_bindings {
    content.push(b'\x01') // from exports
    component_write_uleb128(content, bindings.length())
    for binding in bindings {
      component_write_name(content, binding.func_name)
      content.push(core_sort_func)
      component_write_uleb128(content, binding.func_idx)
    }
  }
  component_write_uleb128(buf, content.length())
  for b in content {
    buf.push(b)
  }
}

///|
/// Emit alias section for run function and memory
/// Format: 0x00 sort 0x01 instance_idx name (for each alias)
fn emit_alias_section_run_and_memory(
  buf : Array[Byte],
  core_instance_idx : Int,
) -> Unit {
  buf.push(component_section_alias)
  let content : Array[Byte] = []
  component_write_uleb128(content, 2) // count = 2 aliases

  // Alias 0: run function from the core instance
  content.push(b'\x00') // core export from instance
  content.push(core_sort_func) // sort: func (0x00)
  content.push(b'\x01') // aliaskind marker
  component_write_uleb128(content, core_instance_idx)
  component_write_name(content, "run") // export name

  // Alias 1: memory from the core instance
  content.push(b'\x00') // core export from instance
  content.push(core_sort_mem) // sort: memory (0x02)
  content.push(b'\x01') // aliaskind marker
  component_write_uleb128(content, core_instance_idx)
  component_write_name(content, "memory") // export name
  component_write_uleb128(buf, content.length())
  for b in content {
    buf.push(b)
  }
}

///|
/// Emit a Core WASM module wrapped in Component Model format
/// Creates a component that embeds the core wasm with run and memory aliased.
/// The aliased run function can be composed with other components using mwac.
pub fn emit_component_wasm(core_wasm : Bytes) -> Bytes {
  let buf : Array[Byte] = []
  // Component header
  for b in component_magic {
    buf.push(b)
  }
  // Section 1: Core module (embed the core wasm)
  emit_core_module_section(buf, core_wasm)
  // Section 2: Core instance (instantiate module 0 without imports)
  emit_core_instance_instantiate_section(buf, 0, [])
  // Section 6: Alias run and memory from core instance
  emit_alias_section_run_and_memory(buf, 0)
  Bytes::from_iter(buf.iter())
}

///|
fn core_read_uleb_u32(bytes : Array[Byte], start : Int) -> (Int, Int) {
  let mut value = 0
  let mut shift = 0
  let mut i = start
  while i < bytes.length() {
    let b = bytes[i].to_int()
    value = value | ((b & 0x7f) << shift)
    i += 1
    if (b & 0x80) == 0 {
      return (value, i)
    }
    shift += 7
  }
  (value, i)
}

///|
fn core_read_name(bytes : Array[Byte], start : Int) -> (String, Int) {
  let (len, after_len) = core_read_uleb_u32(bytes, start)
  let end = after_len + len
  if end > bytes.length() {
    return ("", bytes.length())
  }
  let decoded : Result[String, @utf8.Malformed] = try? @utf8.decode(
    Bytes::from_array(bytes[after_len:end]),
  )
  let name = match decoded {
    Ok(v) => v
    Err(_) => ""
  }
  (name, end)
}

///|
fn skip_wasm_limits(bytes : Array[Byte], start : Int, end : Int) -> Int {
  let mut i = start
  if i >= end {
    return end
  }
  let flags = bytes[i].to_int()
  i += 1
  let (_, after_min) = core_read_uleb_u32(bytes, i)
  i = after_min
  if (flags & 0x01) != 0 {
    let (_, after_max) = core_read_uleb_u32(bytes, i)
    i = after_max
  }
  if (flags & 0x04) != 0 {
    let (_, after_page_size) = core_read_uleb_u32(bytes, i)
    i = after_page_size
  }
  if i > end {
    end
  } else {
    i
  }
}

///|
fn skip_core_import_desc(
  bytes : Array[Byte],
  start : Int,
  kind : Int,
  end : Int,
) -> Int {
  let mut i = start
  match kind {
    1 => {
      // table: reftype + limits
      if i < end {
        i += 1
      }
      i = skip_wasm_limits(bytes, i, end)
    }
    2 =>
      // memory: limits
      i = skip_wasm_limits(bytes, i, end)
    3 =>
      // global: valtype + mutability
      if i + 2 <= end {
        i += 2
      } else {
        i = end
      }
    4 => {
      // tag: attr + type index
      if i < end {
        i += 1
      }
      let (_, after_type_idx) = core_read_uleb_u32(bytes, i)
      i = after_type_idx
    }
    _ => i = end
  }
  if i > end {
    end
  } else {
    i
  }
}

///|
fn parse_core_import_funcs(core_wasm : Bytes) -> Array[CoreImportFunc] {
  let bytes = core_wasm.to_array()
  let imports : Array[CoreImportFunc] = []
  if bytes.length() < 8 {
    return imports
  }
  let type_sigs : Array[CoreFuncSig] = []
  let mut i = 8
  while i < bytes.length() {
    let section_id = bytes[i].to_int()
    i += 1
    let (section_size, after_size) = core_read_uleb_u32(bytes, i)
    i = after_size
    let section_end = i + section_size
    if section_end > bytes.length() {
      break
    }
    match section_id {
      1 => {
        let mut j = i
        let (type_count, after_count) = core_read_uleb_u32(bytes, j)
        j = after_count
        for _ in 0..<type_count {
          if j >= section_end {
            break
          }
          let form = bytes[j].to_int()
          j += 1
          if form != 0x60 {
            break
          }
          let (param_count, after_param_count) = core_read_uleb_u32(bytes, j)
          j = after_param_count
          let params : Array[Byte] = []
          for _ in 0..<param_count {
            if j >= section_end {
              break
            }
            params.push(bytes[j])
            j += 1
          }
          let (result_count, after_result_count) = core_read_uleb_u32(bytes, j)
          j = after_result_count
          let results : Array[Byte] = []
          for _ in 0..<result_count {
            if j >= section_end {
              break
            }
            results.push(bytes[j])
            j += 1
          }
          type_sigs.push(CoreFuncSig::{ params, results })
        }
      }
      2 => {
        let mut j = i
        let (import_count, after_count) = core_read_uleb_u32(bytes, j)
        j = after_count
        for _ in 0..<import_count {
          if j >= section_end {
            break
          }
          let (module_name, after_module_name) = core_read_name(bytes, j)
          j = after_module_name
          let (func_name, after_func_name) = core_read_name(bytes, j)
          j = after_func_name
          if j >= section_end {
            break
          }
          let kind = bytes[j].to_int()
          j += 1
          if kind == 0 {
            let (type_idx, after_type_idx) = core_read_uleb_u32(bytes, j)
            j = after_type_idx
            if type_idx >= 0 && type_idx < type_sigs.length() {
              let sig = type_sigs[type_idx]
              imports.push(CoreImportFunc::{ module_name, func_name, sig })
            }
          } else {
            j = skip_core_import_desc(bytes, j, kind, section_end)
          }
        }
      }
      _ => ()
    }
    i = section_end
  }
  imports
}

///|
fn core_valtype_to_component_primitive(valtype : Byte) -> Byte? {
  match valtype {
    b'\x7f' => Some(component_valtype_s32)
    b'\x7e' => Some(component_valtype_s64)
    b'\x7d' => Some(component_valtype_f32)
    b'\x7c' => Some(component_valtype_f64)
    _ => None
  }
}

///|
fn component_sig_from_core(sig : CoreFuncSig) -> ComponentFuncSig? {
  let params : Array[Byte] = []
  let results : Array[Byte] = []
  for param in sig.params {
    match core_valtype_to_component_primitive(param) {
      Some(v) => params.push(v)
      None => return None
    }
  }
  for result in sig.results {
    match core_valtype_to_component_primitive(result) {
      Some(v) => results.push(v)
      None => return None
    }
  }
  Some(ComponentFuncSig::{ params, results })
}

///|
fn build_core_import_plan(core_wasm : Bytes) -> CoreImportPlan {
  let parsed_imports = parse_core_import_funcs(core_wasm)
  let bindings : Array[CoreImportBinding] = []
  let module_names : Array[String] = []
  let module_bindings : Array[Array[CoreImportBinding]] = []
  let module_idx_by_name : Map[String, Int] = {}
  let seen_import_names : Map[String, Bool] = {}
  for import_func in parsed_imports {
    let import_key = import_func.module_name + "||" + import_func.func_name
    if seen_import_names.contains(import_key) {
      continue
    }
    let sig = match component_sig_from_core(import_func.sig) {
      Some(v) => v
      None => continue
    }
    let module_idx = match module_idx_by_name.get(import_func.module_name) {
      Some(idx) => idx
      None => {
        let idx = module_names.length()
        module_names.push(import_func.module_name)
        module_bindings.push([])
        module_idx_by_name[import_func.module_name] = idx
        idx
      }
    }
    let func_idx = bindings.length()
    let binding = CoreImportBinding::{
      import_name: "import-" + func_idx.to_string(),
      func_name: import_func.func_name,
      sig,
      func_idx,
    }
    bindings.push(binding)
    module_bindings[module_idx].push(binding)
    seen_import_names[import_key] = true
  }
  CoreImportPlan::{ bindings, module_names, module_bindings }
}

///|
fn emit_component_func_type(
  content : Array[Byte],
  sig : ComponentFuncSig,
) -> Unit {
  content.push(b'\x40') // component func type
  component_write_uleb128(content, sig.params.length())
  for i, param in sig.params {
    component_write_name(content, "p" + i.to_string())
    content.push(param)
  }
  if sig.results.length() == 0 {
    content.push(b'\x01') // named results
    component_write_uleb128(content, 0)
  } else if sig.results.length() == 1 {
    content.push(b'\x00') // single unnamed result
    content.push(sig.results[0])
  } else {
    content.push(b'\x01') // named results
    component_write_uleb128(content, sig.results.length())
    for i, result in sig.results {
      component_write_name(content, "r" + i.to_string())
      content.push(result)
    }
  }
}

///|
fn emit_component_type_section_for_sigs(
  buf : Array[Byte],
  sigs : Array[ComponentFuncSig],
) -> Unit {
  if sigs.length() == 0 {
    return
  }
  buf.push(component_section_type)
  let content : Array[Byte] = []
  component_write_uleb128(content, sigs.length())
  for sig in sigs {
    emit_component_func_type(content, sig)
  }
  component_write_uleb128(buf, content.length())
  for b in content {
    buf.push(b)
  }
}

///|
fn collect_component_import_sigs(
  bindings : Array[CoreImportBinding],
) -> Array[ComponentFuncSig] {
  let sigs : Array[ComponentFuncSig] = []
  for binding in bindings {
    sigs.push(binding.sig)
  }
  sigs
}

///|
fn emit_component_import_section_for_funcs(
  buf : Array[Byte],
  bindings : Array[CoreImportBinding],
) -> Unit {
  if bindings.length() == 0 {
    return
  }
  buf.push(component_section_import)
  let content : Array[Byte] = []
  component_write_uleb128(content, bindings.length())
  for type_idx, binding in bindings {
    content.push(b'\x00') // plain name
    component_write_name(content, binding.import_name)
    content.push(component_extern_func)
    component_write_uleb128(content, type_idx)
  }
  component_write_uleb128(buf, content.length())
  for b in content {
    buf.push(b)
  }
}

///|
fn emit_canon_lower_section(buf : Array[Byte], count : Int) -> Unit {
  if count == 0 {
    return
  }
  buf.push(component_section_canon)
  let content : Array[Byte] = []
  component_write_uleb128(content, count)
  for i in 0..<count {
    content.push(b'\x01') // canon lower
    content.push(b'\x00') // func
    component_write_uleb128(content, i) // component func index
    component_write_uleb128(content, 0) // no options
  }
  component_write_uleb128(buf, content.length())
  for b in content {
    buf.push(b)
  }
}

///|
/// Extract export names from a bundled module for component interface
pub fn collect_export_names(ast : @core.Module) -> Array[String] {
  let exports : Array[String] = []
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::ExportLet(name~, ..) => exports.push(name)
      @core.Stmt::ExportEnumDef(name~, ..) => exports.push(name)
      @core.Stmt::ExportTypeAlias(name~, ..) => exports.push(name)
      _ => ()
    }
  }
  exports
}

///|
/// Export info with type information
pub(all) struct ExportInfo {
  name : String
  ty : @core.Type
}

///|
/// Infer type from expression (simplified version for WIT generation)
fn infer_export_type(expr : @core.Expr) -> @core.Type {
  match expr {
    @core.Expr::Int(..) => @core.Type::Int
    @core.Expr::Float(..) => @core.Type::Float
    @core.Expr::Double(..) => @core.Type::Double
    @core.Expr::Bool(..) => @core.Type::Bool
    @core.Expr::String(..) => @core.Type::String
    @core.Expr::Fn(params~, ret~, effects~, ..) =>
      match ret {
        Some(t) => @core.Type::Func(params~, ret=t, effects~)
        None => @core.Type::Func(params~, ret=@core.Type::Unit, effects~)
      }
    _ => @core.Type::Int // default to Int for run() result
  }
}

///|
/// Find a let binding by name in the AST
fn find_let_expr(ast : @core.Module, name : String) -> @core.Expr? {
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(name=n, expr~, ..)
      | @core.Stmt::ExportLet(name=n, expr~, ..) =>
        if n == name {
          return Some(expr)
        }
      _ => ()
    }
  }
  None
}

///|
/// Collect export info with types from AST
pub fn collect_exports(ast : @core.Module) -> Array[ExportInfo] {
  let exports : Array[ExportInfo] = []
  let seen : Map[String, Bool] = {}
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::ExportLet(name~, expr~, ..) =>
        if not(seen.contains(name)) {
          exports.push(ExportInfo::{ name, ty: infer_export_type(expr) })
          seen[name] = true
        }
      @core.Stmt::Export(names~, ..) =>
        for name in names {
          if not(seen.contains(name)) {
            match find_let_expr(ast, name) {
              Some(expr) => {
                exports.push(ExportInfo::{ name, ty: infer_export_type(expr) })
                seen[name] = true
              }
              None => ()
            }
          }
        }
      _ => ()
    }
  }
  exports
}

///|
/// Convert vibe type to WIT type string
fn type_to_wit(ty : @core.Type) -> String {
  match ty {
    @core.Type::Int => "s32"
    @core.Type::Float => "f32"
    @core.Type::Double => "f64"
    @core.Type::Bool => "bool"
    @core.Type::String => "string"
    @core.Type::Unit => ""
    @core.Type::Tuple(items) => {
      let parts : Array[String] = []
      for item in items {
        parts.push(type_to_wit(item))
      }
      "tuple<" + parts.join(", ") + ">"
    }
    @core.Type::Record(fields) => {
      let parts : Array[String] = []
      for entry in fields.iter() {
        parts.push(entry.0 + ": " + type_to_wit(entry.1))
      }
      "record { " + parts.join(", ") + " }"
    }
    @core.Type::Array(elem) => "list<" + type_to_wit(elem) + ">"
    @core.Type::Func(params~, ret~, effects~) => {
      let _ = effects
      let param_parts : Array[String] = []
      for p in params {
        param_parts.push(p.name + ": " + type_to_wit(p.ty))
      }
      let ret_str = type_to_wit(ret)
      if ret_str == "" {
        "func(" + param_parts.join(", ") + ")"
      } else {
        "func(" + param_parts.join(", ") + ") -> " + ret_str
      }
    }
    @core.Type::Named(name~, args~) =>
      match name {
        "Int" | "i32" => "s32"
        "Float" | "f32" => "f32"
        "Double" | "f64" => "f64"
        "Bool" => "bool"
        "String" => "string"
        "Unit" => ""
        "Array" =>
          if args.length() == 1 {
            "list<" + type_to_wit(args[0]) + ">"
          } else {
            name
          }
        _ =>
          if args.is_empty() {
            name
          } else {
            let arg_parts : Array[String] = []
            for arg in args {
              arg_parts.push(type_to_wit(arg))
            }
            name + "<" + arg_parts.join(", ") + ">"
          }
      }
    _ => "s32" // fallback for unsupported types
  }
}

///|
/// Generate WIT interface definition from AST
pub fn generate_wit(
  ast : @core.Module,
  package_name : String,
  world_name : String,
) -> String {
  let exports = collect_exports(ast)
  let mut wit = "package " + package_name + ";\n\n"
  wit = wit + "world " + world_name + " {\n"
  for exp in exports {
    let ty_str = type_to_wit(exp.ty)
    if ty_str == "" {
      wit = wit + "  export " + exp.name + ": func();\n"
    } else {
      match exp.ty {
        @core.Type::Func(params~, ret~, effects~) => {
          let _ = effects
          let param_parts : Array[String] = []
          for p in params {
            param_parts.push(p.name + ": " + type_to_wit(p.ty))
          }
          let ret_str = type_to_wit(ret)
          if ret_str == "" {
            wit = wit +
              "  export " +
              exp.name +
              ": func(" +
              param_parts.join(", ") +
              ");\n"
          } else {
            wit = wit +
              "  export " +
              exp.name +
              ": func(" +
              param_parts.join(", ") +
              ") -> " +
              ret_str +
              ";\n"
          }
        }
        _ => wit = wit + "  export " + exp.name + ": " + ty_str + ";\n"
      }
    }
  }
  wit = wit + "}\n"
  wit
}

///|
pub(all) struct ComponentWitImports {
  mut need_path : Bool
  mut need_dynamic_path_resolve : Bool
  mut need_sh : Bool
  mut need_sleep : Bool
  mut need_stdout_write_char : Bool
  mut need_stdin_read_char : Bool
  mut need_fs : Bool
  mut need_socket : Bool
  mut need_http : Bool
}

///|
fn collect_component_wit_imports(ast : @core.Module) -> ComponentWitImports {
  let acc = ComponentWitImports::{
    need_path: false,
    need_dynamic_path_resolve: false,
    need_sh: false,
    need_sleep: false,
    need_stdout_write_char: false,
    need_stdin_read_char: false,
    need_fs: false,
    need_socket: false,
    need_http: false,
  }
  scan_component_wit_imports_block(ast, acc)
  acc
}

///|
fn scan_component_wit_imports_block(
  body : @core.Module,
  acc : ComponentWitImports,
) -> Unit {
  for stmt in body.stmts {
    scan_component_wit_imports_stmt(stmt, acc)
  }
}

///|
fn scan_component_wit_imports_stmt(
  stmt : @core.Stmt,
  acc : ComponentWitImports,
) -> Unit {
  match stmt {
    @core.Stmt::Let(expr~, ..) => scan_component_wit_imports_expr(expr, acc)
    @core.Stmt::ExportLet(expr~, ..) =>
      scan_component_wit_imports_expr(expr, acc)
    @core.Stmt::Expr(expr~, ..) => scan_component_wit_imports_expr(expr, acc)
    @core.Stmt::LetPat(expr~, ..) => scan_component_wit_imports_expr(expr, acc)
    @core.Stmt::LetPatElse(expr~, else_body~, ..) => {
      scan_component_wit_imports_expr(expr, acc)
      scan_component_wit_imports_block(else_body, acc)
    }
    @core.Stmt::LetMut(expr~, ..) => scan_component_wit_imports_expr(expr, acc)
    @core.Stmt::Assign(expr~, ..) => scan_component_wit_imports_expr(expr, acc)
    @core.Stmt::IndexAssign(target~, index~, value~, ..) => {
      scan_component_wit_imports_expr(target, acc)
      scan_component_wit_imports_expr(index, acc)
      scan_component_wit_imports_expr(value, acc)
    }
    @core.Stmt::Test(body~, ..) => scan_component_wit_imports_block(body, acc)
    @core.Stmt::Bench(body~, ..) => scan_component_wit_imports_block(body, acc)
    _ => ()
  }
}

///|
fn scan_component_wit_imports_expr(
  expr : @core.Expr,
  acc : ComponentWitImports,
) -> Unit {
  match expr {
    @core.Expr::Call(name~, args~, ..) => {
      match name {
        "path" | "path_ref" => acc.need_path = true
        "dynamic_path_resolve" => acc.need_dynamic_path_resolve = true
        "sh" => acc.need_sh = true
        "sleep" => acc.need_sleep = true
        "stdout_write_char" => acc.need_stdout_write_char = true
        "stdout_write_stream" => acc.need_stdout_write_char = true
        "stdin_read_char" => acc.need_stdin_read_char = true
        "stdin_read_stream" => acc.need_stdin_read_char = true
        "fs_read_file" | "fs_write_file" | "fs_exists" => acc.need_fs = true
        "socket_tcp_connect"
        | "socket_tcp_read"
        | "socket_tcp_write"
        | "socket_tcp_close" => acc.need_socket = true
        "http_request"
        | "http_response_status"
        | "http_response_header"
        | "http_response_body"
        | "http_close"
        | "http_listen"
        | "http_accept"
        | "http_request_method"
        | "http_request_url"
        | "http_request_header"
        | "http_request_body"
        | "http_respond" => acc.need_http = true
        _ => ()
      }
      for arg in args {
        scan_component_wit_imports_expr(arg.expr, acc)
      }
    }
    @core.Expr::Tuple(items~, ..) =>
      for item in items {
        scan_component_wit_imports_expr(item, acc)
      }
    @core.Expr::TupleIndex(expr~, ..) =>
      scan_component_wit_imports_expr(expr, acc)
    @core.Expr::Record(fields~, ..) =>
      for field in fields {
        scan_component_wit_imports_expr(field.expr, acc)
      }
    @core.Expr::StructLit(fields~, ..) =>
      for field in fields {
        scan_component_wit_imports_expr(field.expr, acc)
      }
    @core.Expr::Array(items~, ..) =>
      for item in items {
        scan_component_wit_imports_expr(item, acc)
      }
    @core.Expr::Map(fields~, ..) =>
      for field in fields {
        scan_component_wit_imports_expr(field.expr, acc)
      }
    @core.Expr::If(cond~, then_body~, else_body~, ..) => {
      scan_component_wit_imports_expr(cond, acc)
      scan_component_wit_imports_block(then_body, acc)
      scan_component_wit_imports_block(else_body, acc)
    }
    @core.Expr::Block(body~, ..) => scan_component_wit_imports_block(body, acc)
    @core.Expr::Handle(body~, arms~, ..) => {
      scan_component_wit_imports_block(body, acc)
      for arm in arms {
        scan_component_wit_imports_expr(arm.expr, acc)
        match arm.cond {
          Some(cond) => scan_component_wit_imports_expr(cond, acc)
          None => ()
        }
      }
    }
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      scan_component_wit_imports_expr(scrutinee, acc)
      for arm in arms {
        scan_component_wit_imports_expr(arm.expr, acc)
        match arm.cond {
          Some(cond) => scan_component_wit_imports_expr(cond, acc)
          None => ()
        }
      }
    }
    @core.Expr::Fn(body~, ..) => scan_component_wit_imports_block(body, acc)
    @core.Expr::ForIn(iterable~, body~, ..) => {
      scan_component_wit_imports_expr(iterable, acc)
      scan_component_wit_imports_block(body, acc)
    }
    @core.Expr::While(cond~, body~, ..) => {
      scan_component_wit_imports_expr(cond, acc)
      scan_component_wit_imports_block(body, acc)
    }
    @core.Expr::Loop(params~, body~, ..) => {
      for param in params {
        scan_component_wit_imports_expr(param.init, acc)
      }
      scan_component_wit_imports_block(body, acc)
    }
    @core.Expr::Raise(value~, ..) => scan_component_wit_imports_expr(value, acc)
    @core.Expr::Yield(expr~, ..) => scan_component_wit_imports_expr(expr, acc)
    _ => ()
  }
}

///|
/// Generate WIT world for `wasm-tools component embed/new`.
/// Host builtins are split into:
/// - vibe interface: path/sh/sleep
/// - wasi interfaces: stdin/stdout/streams for stdio char/stream builtins
pub fn generate_component_wit(
  ast : @core.Module,
  package_name : String,
  world_name : String,
) -> String {
  let imports = collect_component_wit_imports(ast)
  let mut wit = "package " + package_name + ";\n\n"
  wit = wit + "world " + world_name + " {\n"
  if imports.need_path ||
    imports.need_dynamic_path_resolve ||
    imports.need_sh ||
    imports.need_sleep {
    wit = wit + "  import vibe: interface {\n"
    if imports.need_path {
      wit = wit + "    path: func(value: s32) -> s32;\n"
    }
    if imports.need_dynamic_path_resolve {
      wit = wit + "    resolve-path: func(value: s32) -> s32;\n"
    }
    if imports.need_sh {
      wit = wit + "    sh: func(cmd: s32) -> s32;\n"
    }
    if imports.need_sleep {
      wit = wit + "    sleep: func(ms: s32);\n"
    }
    wit = wit + "  }\n"
  }
  if imports.need_stdout_write_char {
    wit = wit + "  import wasi:cli/stdout@0.2.0;\n"
  }
  if imports.need_stdin_read_char {
    wit = wit + "  import wasi:cli/stdin@0.2.0;\n"
  }
  if imports.need_stdout_write_char || imports.need_stdin_read_char {
    wit = wit + "  import wasi:io/streams@0.2.0;\n"
  }
  if imports.need_fs {
    wit = wit + "  import wasi:filesystem/types@0.3.0;\n"
    wit = wit + "  import wasi:filesystem/preopens@0.3.0;\n"
  }
  if imports.need_socket {
    wit = wit + "  import wasi:sockets/instance-network@0.2.0;\n"
    wit = wit + "  import wasi:sockets/tcp-create-socket@0.2.0;\n"
    wit = wit + "  import wasi:sockets/tcp@0.2.0;\n"
    wit = wit + "  import wasi:io/poll@0.2.0;\n"
    if not(imports.need_stdout_write_char) && not(imports.need_stdin_read_char) {
      wit = wit + "  import wasi:io/streams@0.2.0;\n"
    }
  }
  if imports.need_http {
    // WASI P3 HTTP draft — WIT imports for future use
    wit = wit + "  import wasi:http/types@0.3.0-draft;\n"
    wit = wit + "  import wasi:http/handler@0.3.0-draft;\n"
  }
  // Core `run` export returns tagged Int as i64 in MVP wasm backend.
  wit = wit + "  export run: func() -> s64;\n"
  wit = wit + "}\n"
  wit
}

///|
/// Canon lift with options
fn emit_canon_lift_func(
  buf : Array[Byte],
  core_func_idx : Int,
  type_idx : Int,
) -> Unit {
  buf.push(b'\x00') // canon lift
  buf.push(b'\x00') // func
  component_write_uleb128(buf, core_func_idx) // core func index
  component_write_uleb128(buf, 0) // 0 options (no memory/realloc for primitive scalar)
  component_write_uleb128(buf, type_idx) // type index
}

///|
fn emit_component_type_section_run_result(buf : Array[Byte]) -> Unit {
  emit_component_type_section_for_sigs(buf, [
    ComponentFuncSig::{ params: [], results: [component_valtype_s64] },
  ])
}

///|
fn emit_canon_lift_section(
  buf : Array[Byte],
  core_func_idx : Int,
  type_idx : Int,
) -> Unit {
  buf.push(component_section_canon)
  let content : Array[Byte] = []
  component_write_uleb128(content, 1) // 1 canon definition
  emit_canon_lift_func(content, core_func_idx, type_idx)
  component_write_uleb128(buf, content.length())
  for b in content {
    buf.push(b)
  }
}

///|
/// Emit component export section
fn emit_component_export_section(
  buf : Array[Byte],
  name : String,
  func_idx : Int,
) -> Unit {
  buf.push(component_section_export)
  let content : Array[Byte] = []
  component_write_uleb128(content, 1) // 1 export
  // Export name: 0x00 prefix (plain name) + length-prefixed string
  content.push(b'\x00') // plain name discriminator
  component_write_name(content, name)
  // Sort idx: sort (0x01 = func) + index
  content.push(component_extern_func) // sort: func
  component_write_uleb128(content, func_idx)
  // External desc: 0x00 for no type annotation
  component_write_uleb128(content, 0)
  component_write_uleb128(buf, content.length())
  for b in content {
    buf.push(b)
  }
}

///|
/// Emit a Component WASM with proper Canon lift and export
/// This creates a fully valid component that can be used with mwac
pub fn emit_component_wasm_with_lift(
  core_wasm : Bytes,
  export_name : String,
) -> Bytes {
  let import_plan = build_core_import_plan(core_wasm)
  let import_func_count = import_plan.bindings.length()
  let main_instance_idx = import_plan.module_names.length()
  let run_core_func_idx = import_func_count
  let run_type_idx = import_func_count
  let run_func_idx = import_func_count
  let buf : Array[Byte] = []
  // Component header
  for b in component_magic {
    buf.push(b)
  }
  // Section 1: Core module (embed the core wasm)
  emit_core_module_section(buf, core_wasm)
  // Import core dependencies as namespaced component funcs, lower them, then
  // materialize per-module core instances from lowered exports.
  emit_component_type_section_for_sigs(
    buf,
    collect_component_import_sigs(import_plan.bindings),
  )
  emit_component_import_section_for_funcs(buf, import_plan.bindings)
  emit_canon_lower_section(buf, import_func_count)
  emit_core_instance_from_exports_section(buf, import_plan.module_bindings)
  emit_core_instance_instantiate_section(buf, 0, import_plan.module_names)
  emit_alias_section_run_and_memory(buf, main_instance_idx)
  emit_component_type_section_run_result(buf)
  emit_canon_lift_section(buf, run_core_func_idx, run_type_idx)
  // Section 11: Component export
  emit_component_export_section(buf, export_name, run_func_idx)
  Bytes::from_iter(buf.iter())
}
