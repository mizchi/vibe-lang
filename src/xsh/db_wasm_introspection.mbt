///|
priv struct WasmFuncType {
  params : Array[Int]
  results : Array[Int]
}

///|
priv struct WasmCursor {
  bytes : Array[Byte]
  mut pos : Int
  end : Int
}

///|
fn WasmCursor::new(bytes : Array[Byte], start : Int, end : Int) -> WasmCursor {
  { bytes, pos: start, end }
}

///|
fn WasmCursor::remaining(self : WasmCursor) -> Int {
  self.end - self.pos
}

///|
fn WasmCursor::read_u8(self : WasmCursor) -> Int? {
  if self.pos >= self.end {
    return None
  }
  let value = self.bytes[self.pos].to_int()
  self.pos += 1
  Some(value)
}

///|
fn WasmCursor::read_u32_leb(self : WasmCursor) -> Int? {
  let mut result = 0
  let mut shift = 0
  for _ in 0..<5 {
    let byte = match self.read_u8() {
      Some(v) => v
      None => return None
    }
    result = result | ((byte & 0x7f) << shift)
    if (byte & 0x80) == 0 {
      return Some(result)
    }
    shift += 7
  }
  None
}

///|
fn wasm_read_name_ascii(cursor : WasmCursor) -> String? {
  let name_len = match cursor.read_u32_leb() {
    Some(v) => v
    None => return None
  }
  if name_len < 0 || cursor.remaining() < name_len {
    return None
  }
  let buf = StringBuilder::new()
  for _ in 0..<name_len {
    let byte = match cursor.read_u8() {
      Some(v) => v
      None => return None
    }
    buf.write_char(byte.unsafe_to_char())
  }
  Some(buf.to_string())
}

///|
fn wasm_skip_limits(cursor : WasmCursor) -> Bool {
  let flags = match cursor.read_u8() {
    Some(v) => v
    None => return false
  }
  let _ = match cursor.read_u32_leb() {
    Some(v) => v
    None => return false
  }
  if (flags & 0x01) != 0 {
    let _ = match cursor.read_u32_leb() {
      Some(v) => v
      None => return false
    }

  }
  true
}

///|
fn wasm_skip_import_desc(kind : Int, cursor : WasmCursor) -> Bool {
  match kind {
    0 => cursor.read_u32_leb() is Some(_)
    1 => {
      if cursor.read_u8() is None {
        return false
      }
      wasm_skip_limits(cursor)
    }
    2 => wasm_skip_limits(cursor)
    3 => {
      if cursor.read_u8() is None {
        return false
      }
      cursor.read_u8() is Some(_)
    }
    4 => {
      if cursor.read_u8() is None {
        return false
      }
      cursor.read_u32_leb() is Some(_)
    }
    _ => false
  }
}

///|
fn wasm_valtype_to_xsh_type(code : Int) -> @core.Type? {
  match code {
    0x7f => Some(@core.Type::Int)
    0x7e => Some(@core.Type::Int)
    0x7d => Some(@core.Type::Float)
    0x7c => Some(@core.Type::Double)
    0x70 => Some(@core.Type::Named(name="funcref", args=[]))
    0x6f => Some(@core.Type::Named(name="externref", args=[]))
    0x7b => Some(@core.Type::Named(name="v128", args=[]))
    _ => None
  }
}

///|
fn wasm_func_type_to_xsh_type(func_type : WasmFuncType) -> @core.Type? {
  let params : Array[@core.FuncParam] = []
  for i in 0..<func_type.params.length() {
    let param_ty = match wasm_valtype_to_xsh_type(func_type.params[i]) {
      Some(ty) => ty
      None => return None
    }
    params.push(@core.FuncParam::{
      name: "p" + i.to_string(),
      label: @core.ParamLabel::Positional,
      ty: param_ty,
      bounds: [],
    })
  }
  let ret_ty = if func_type.results.length() == 0 {
    @core.Type::Unit
  } else if func_type.results.length() == 1 {
    match wasm_valtype_to_xsh_type(func_type.results[0]) {
      Some(ty) => ty
      None => return None
    }
  } else {
    let tuple_items : Array[@core.Type] = []
    for result_code in func_type.results {
      let item_ty = match wasm_valtype_to_xsh_type(result_code) {
        Some(ty) => ty
        None => return None
      }
      tuple_items.push(item_ty)
    }
    @core.Type::Tuple(tuple_items)
  }
  Some(@core.Type::Func(params~, ret=ret_ty, effects=[]))
}

///|
fn parse_wasm_exported_function_types(
  wasm_bytes : Bytes,
) -> Result[Map[String, @core.Type], String] {
  let bytes = wasm_bytes.to_array()
  if bytes.length() < 8 {
    return Err("invalid wasm binary: too short")
  }
  if bytes[0].to_int() != 0x00 ||
    bytes[1].to_int() != 0x61 ||
    bytes[2].to_int() != 0x73 ||
    bytes[3].to_int() != 0x6d {
    return Err("invalid wasm binary: bad magic")
  }
  let types : Array[WasmFuncType] = []
  let imported_func_type_indices : Array[Int] = []
  let defined_func_type_indices : Array[Int] = []
  let exported_func_indices : Map[String, Int] = {}
  let cursor = WasmCursor::new(bytes, 8, bytes.length())
  while cursor.remaining() > 0 {
    let section_id = match cursor.read_u8() {
      Some(v) => v
      None => return Err("invalid wasm binary: truncated section id")
    }
    let section_size = match cursor.read_u32_leb() {
      Some(v) => v
      None => return Err("invalid wasm binary: truncated section size")
    }
    if section_size < 0 || section_size > cursor.remaining() {
      return Err("invalid wasm binary: broken section size")
    }
    let section_start = cursor.pos
    let section_end = section_start + section_size
    let section = WasmCursor::new(bytes, section_start, section_end)
    match section_id {
      1 => {
        let type_count = match section.read_u32_leb() {
          Some(v) => v
          None => return Err("invalid wasm type section")
        }
        for _ in 0..<type_count {
          let form = match section.read_u8() {
            Some(v) => v
            None => return Err("invalid wasm type entry")
          }
          if form != 0x60 {
            return Err("unsupported wasm type form")
          }
          let param_count = match section.read_u32_leb() {
            Some(v) => v
            None => return Err("invalid wasm type params")
          }
          let params : Array[Int] = []
          for _ in 0..<param_count {
            let code = match section.read_u8() {
              Some(v) => v
              None => return Err("invalid wasm param type")
            }
            params.push(code)
          }
          let result_count = match section.read_u32_leb() {
            Some(v) => v
            None => return Err("invalid wasm type results")
          }
          let results : Array[Int] = []
          for _ in 0..<result_count {
            let code = match section.read_u8() {
              Some(v) => v
              None => return Err("invalid wasm result type")
            }
            results.push(code)
          }
          types.push(WasmFuncType::{ params, results })
        }
      }
      2 => {
        let import_count = match section.read_u32_leb() {
          Some(v) => v
          None => return Err("invalid wasm import section")
        }
        for _ in 0..<import_count {
          if wasm_read_name_ascii(section) is None {
            return Err("invalid wasm import module name")
          }
          if wasm_read_name_ascii(section) is None {
            return Err("invalid wasm import field name")
          }
          let kind = match section.read_u8() {
            Some(v) => v
            None => return Err("invalid wasm import kind")
          }
          if kind == 0 {
            let type_idx = match section.read_u32_leb() {
              Some(v) => v
              None => return Err("invalid wasm function import type")
            }
            imported_func_type_indices.push(type_idx)
          } else if not(wasm_skip_import_desc(kind, section)) {
            return Err("invalid wasm import descriptor")
          }
        }
      }
      3 => {
        let function_count = match section.read_u32_leb() {
          Some(v) => v
          None => return Err("invalid wasm function section")
        }
        for _ in 0..<function_count {
          let type_idx = match section.read_u32_leb() {
            Some(v) => v
            None => return Err("invalid wasm function type index")
          }
          defined_func_type_indices.push(type_idx)
        }
      }
      7 => {
        let export_count = match section.read_u32_leb() {
          Some(v) => v
          None => return Err("invalid wasm export section")
        }
        for _ in 0..<export_count {
          let name = match wasm_read_name_ascii(section) {
            Some(v) => v
            None => return Err("invalid wasm export name")
          }
          let kind = match section.read_u8() {
            Some(v) => v
            None => return Err("invalid wasm export kind")
          }
          let index = match section.read_u32_leb() {
            Some(v) => v
            None => return Err("invalid wasm export index")
          }
          if kind == 0 {
            exported_func_indices.set(name, index)
          }
        }
      }
      _ => ()
    }
    cursor.pos = section_end
  }
  let out : Map[String, @core.Type] = {}
  let imported_func_count = imported_func_type_indices.length()
  for export_name, export_index in exported_func_indices {
    let type_idx = if export_index < imported_func_count {
      imported_func_type_indices[export_index]
    } else {
      let defined_index = export_index - imported_func_count
      if defined_index < 0 ||
        defined_index >= defined_func_type_indices.length() {
        continue
      }
      defined_func_type_indices[defined_index]
    }
    if type_idx < 0 || type_idx >= types.length() {
      continue
    }
    match wasm_func_type_to_xsh_type(types[type_idx]) {
      Some(ty) => out.set(export_name, ty)
      None => ()
    }
  }
  Ok(out)
}
