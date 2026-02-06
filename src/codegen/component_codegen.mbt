///|
/// Component Model codegen for xsh
/// Wraps Core WASM in Component Model format for wkg/wa.dev compatibility

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
/// Component section IDs
let component_section_module : Byte = b'\x00' // core module

///|
let component_section_core_instance : Byte = b'\x02' // core instance

///|
let component_section_alias : Byte = b'\x06' // alias

///|
let component_section_export : Byte = b'\x0b' // component export

///|
/// Emit core module section (section id 0)
fn emit_core_module_section(buf : Array[Byte], core_wasm : Bytes) -> Unit {
  buf.push(component_section_module)
  // Content: 0x00 (module definition kind) + module bytes
  let content : Array[Byte] = []
  content.push(b'\x00') // module definition inline
  for b in core_wasm.iter() {
    content.push(b)
  }
  component_write_uleb128(buf, content.length())
  for b in content {
    buf.push(b)
  }
}

///|
/// Emit core instance section (instantiate module 0 with no imports)
fn emit_core_instance_section(buf : Array[Byte]) -> Unit {
  buf.push(component_section_core_instance)
  // Content: count=1, instantiate module 0 with 0 imports
  let content : Array[Byte] = []
  component_write_uleb128(content, 1) // count = 1 instance
  content.push(b'\x00') // instantiate
  component_write_uleb128(content, 0) // module index 0
  component_write_uleb128(content, 0) // 0 imports
  component_write_uleb128(buf, content.length())
  for b in content {
    buf.push(b)
  }
}

///|
/// Emit alias section to export 'run' function from core instance
fn emit_alias_section(buf : Array[Byte]) -> Unit {
  buf.push(component_section_alias)
  // Alias: core export from instance 0, function "run"
  let content : Array[Byte] = []
  component_write_uleb128(content, 1) // count = 1 alias
  // alias = core export, instance 0, name "run"
  content.push(b'\x00') // alias kind: core export
  content.push(b'\x01') // sort: func
  component_write_uleb128(content, 0) // instance index 0
  component_write_name(content, "run") // export name
  component_write_uleb128(buf, content.length())
  for b in content {
    buf.push(b)
  }
}

///|
/// Emit component export section
fn emit_component_export_section(buf : Array[Byte]) -> Unit {
  buf.push(component_section_export)
  // Export the aliased function as "run"
  let content : Array[Byte] = []
  component_write_uleb128(content, 1) // count = 1 export
  component_write_name(content, "run") // export name
  content.push(b'\x01') // sort: func
  component_write_uleb128(content, 0) // func index 0
  content.push(b'\x00') // no type ascription
  component_write_uleb128(buf, content.length())
  for b in content {
    buf.push(b)
  }
}

///|
/// Emit a Core WASM module wrapped in Component Model format
pub fn emit_component_wasm(core_wasm : Bytes) -> Bytes {
  let buf : Array[Byte] = []
  // Component header
  for b in component_magic {
    buf.push(b)
  }
  // Section 0: Core module (embed the core wasm)
  emit_core_module_section(buf, core_wasm)
  // Section 2: Core instance (instantiate module 0)
  emit_core_instance_section(buf)
  // Section 6: Alias (export 'run' from core instance)
  emit_alias_section(buf)
  // Section 11: Component export
  emit_component_export_section(buf)
  Bytes::from_iter(buf.iter())
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
