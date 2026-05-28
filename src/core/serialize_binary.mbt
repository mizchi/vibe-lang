// Compact binary serializer for @core.Module.
//
// Wire format spec: docs/ast_binary_abi.md (v1)
//
// Both this MoonBit implementation and the selfhost vibe
// implementation at vibe/compiler/ast_binary.vibe MUST agree
// byte-for-byte. Whenever a new AST variant is added, update the spec
// FIRST (it's the source of truth), then sync both sides in
// lock-step.

///|
/// Wire format version. Bump only when the on-wire layout of an
/// existing record changes shape (pure additions get new tag numbers
/// and don't require a version bump — old readers raise UnknownTag).
pub const AST_BINARY_VERSION : Int = 1

///|
const AST_BINARY_MAGIC_0 : Byte = b'v'

///|
const AST_BINARY_MAGIC_1 : Byte = b'A'

///|
const AST_BINARY_MAGIC_2 : Byte = b'S'

///|
const AST_BINARY_MAGIC_3 : Byte = b'T'

///|
/// Serialize a module to the binary ABI v1. Inverse of
/// `deserialize_module_binary`.
pub fn serialize_module_binary(m : Module) -> Bytes {
  let buf = @buffer.Buffer(size_hint=4096)
  buf.write_byte(AST_BINARY_MAGIC_0)
  buf.write_byte(AST_BINARY_MAGIC_1)
  buf.write_byte(AST_BINARY_MAGIC_2)
  buf.write_byte(AST_BINARY_MAGIC_3)
  write_varint(buf, AST_BINARY_VERSION.to_int64())
  write_stmt_array(buf, m.stmts)
  buf.to_bytes()
}

// ---------------------------------------------------------------------------
// Primitives
// ---------------------------------------------------------------------------

///|
/// LEB128-unsigned varint of a non-negative int64. Up to 10 bytes.
fn write_varint(buf : @buffer.Buffer, v : Int64) -> Unit {
  let mut x = v
  while true {
    let b = (x & 0x7FL).to_int()
    x = (x >> 7) & 0x01FFFFFFFFFFFFFFL
    if x == 0L {
      buf.write_byte(b.to_byte())
      break
    } else {
      buf.write_byte((b | 0x80).to_byte())
    }
  }
}

///|
fn write_varint_int(buf : @buffer.Buffer, v : Int) -> Unit {
  write_varint(buf, v.to_int64())
}

///|
/// Standard signed LEB128 (sleb128). Used for spans and any field
/// that can be negative (e.g. Type::Var ids — currently non-negative
/// but cheap to future-proof). Aligns with wasm/DWARF and matches
/// selfhost's `leb128_encode_s64`.
fn write_svarint(buf : @buffer.Buffer, v : Int64) -> Unit {
  let mut value = v
  while true {
    let byte = (value & 0x7FL).to_int()
    // Arithmetic right shift to preserve sign bit.
    value = value >> 7
    let sign_bit = (byte & 0x40) != 0
    if (value == 0L && !sign_bit) || (value == -1L && sign_bit) {
      buf.write_byte(byte.to_byte())
      break
    } else {
      buf.write_byte((byte | 0x80).to_byte())
    }
  }
}

///|
fn write_bool(buf : @buffer.Buffer, v : Bool) -> Unit {
  buf.write_byte(if v { b'\x01' } else { b'\x00' })
}

///|
fn write_string(buf : @buffer.Buffer, s : String) -> Unit {
  let scratch = @buffer.Buffer(size_hint=s.length() * 2)
  scratch.write_string_utf8(s[:])
  let bytes = scratch.to_bytes()
  write_varint_int(buf, bytes.length())
  buf.write_bytes(bytes)
}

///|
fn write_optstr(buf : @buffer.Buffer, s : String?) -> Unit {
  match s {
    None => buf.write_byte(b'\x00')
    Some(v) => {
      buf.write_byte(b'\x01')
      write_string(buf, v)
    }
  }
}

///|
/// IEEE-754 binary32, little-endian. We pull bits via `reinterpret_as_uint`
/// rather than serializing through string format to keep round-tripping
/// bit-exact (including NaN payloads).
fn write_f32(buf : @buffer.Buffer, v : Float) -> Unit {
  let bits = v.reinterpret_as_uint()
  buf.write_byte((bits & 0xFFU).to_byte())
  buf.write_byte(((bits >> 8) & 0xFFU).to_byte())
  buf.write_byte(((bits >> 16) & 0xFFU).to_byte())
  buf.write_byte(((bits >> 24) & 0xFFU).to_byte())
}

///|
/// IEEE-754 binary64, little-endian.
fn write_f64(buf : @buffer.Buffer, v : Double) -> Unit {
  let bits = v.reinterpret_as_uint64()
  let mut i = 0
  while i < 8 {
    buf.write_byte(((bits >> (i * 8)) & 0xFFUL).to_int().to_byte())
    i = i + 1
  }
}

///|
fn write_char(buf : @buffer.Buffer, c : Char) -> Unit {
  write_varint_int(buf, c.to_int())
}

///|
fn write_span(buf : @buffer.Buffer, span : Span) -> Unit {
  write_svarint(buf, span.start.to_int64())
  write_svarint(buf, span.end.to_int64())
}

// ---------------------------------------------------------------------------
// Stmt
// ---------------------------------------------------------------------------

///|
fn write_stmt_array(buf : @buffer.Buffer, stmts : Array[Stmt]) -> Unit {
  write_varint_int(buf, stmts.length())
  for s in stmts {
    write_stmt(buf, s)
  }
}

///|
fn write_stmt(buf : @buffer.Buffer, stmt : Stmt) -> Unit {
  match stmt {
    Stmt::Let(rec~, name~, expr~, span~) => {
      buf.write_byte(b'\x01')
      write_bool(buf, rec)
      write_string(buf, name)
      write_expr(buf, expr)
      write_span(buf, span)
    }
    Stmt::EnumDef(name~, params~, ctors~, span~) => {
      buf.write_byte(b'\x02')
      write_string(buf, name)
      write_string_array(buf, params)
      write_type_ctor_array(buf, ctors)
      write_span(buf, span)
    }
    Stmt::TypeAlias(name~, params~, target~, span~) => {
      buf.write_byte(b'\x03')
      write_string(buf, name)
      write_string_array(buf, params)
      write_type(buf, target)
      write_span(buf, span)
    }
    Stmt::TraitDef(name~, supertraits~, methods~, open_impl~, exported~, span~) => {
      buf.write_byte(b'\x04')
      write_string(buf, name)
      write_string_array(buf, supertraits)
      write_trait_method_array(buf, methods)
      write_bool(buf, open_impl)
      write_bool(buf, exported)
      write_span(buf, span)
    }
    Stmt::TraitImpl(
      type_params~,
      type_bounds~,
      trait_name~,
      target~,
      methods~,
      span~
    ) => {
      buf.write_byte(b'\x05')
      write_string_array(buf, type_params)
      write_type_bounds_map(buf, type_bounds)
      write_string(buf, trait_name)
      write_type(buf, target)
      write_impl_method_array(buf, methods)
      write_span(buf, span)
    }
    Stmt::Expr(expr~, span~) => {
      buf.write_byte(b'\x06')
      write_expr(buf, expr)
      write_span(buf, span)
    }
    Stmt::Import(spec~, source~, span~) => {
      buf.write_byte(b'\x07')
      write_import_spec(buf, spec)
      write_module_ref(buf, source)
      write_span(buf, span)
    }
    Stmt::Test(name~, body~, span~) => {
      buf.write_byte(b'\x08')
      write_optstr(buf, name)
      write_module(buf, body)
      write_span(buf, span)
    }
    Stmt::Bench(name~, body~, span~) => {
      buf.write_byte(b'\x09')
      write_optstr(buf, name)
      write_module(buf, body)
      write_span(buf, span)
    }
    Stmt::LetMut(name~, expr~, span~) => {
      buf.write_byte(b'\x0A')
      write_string(buf, name)
      write_expr(buf, expr)
      write_span(buf, span)
    }
    Stmt::ExternLet(name~, ty~, span~) => {
      buf.write_byte(b'\x0B')
      write_string(buf, name)
      write_type(buf, ty)
      write_span(buf, span)
    }
    Stmt::Assign(name~, expr~, span~) => {
      buf.write_byte(b'\x0C')
      write_string(buf, name)
      write_expr(buf, expr)
      write_span(buf, span)
    }
    Stmt::IndexAssign(target~, index~, value~, span~) => {
      buf.write_byte(b'\x0D')
      write_expr(buf, target)
      write_expr(buf, index)
      write_expr(buf, value)
      write_span(buf, span)
    }
    Stmt::LetPat(pat~, expr~, span~) => {
      buf.write_byte(b'\x0E')
      write_pat(buf, pat)
      write_expr(buf, expr)
      write_span(buf, span)
    }
    Stmt::LetPatElse(pat~, expr~, else_body~, span~) => {
      buf.write_byte(b'\x0F')
      write_pat(buf, pat)
      write_expr(buf, expr)
      write_module(buf, else_body)
      write_span(buf, span)
    }
    Stmt::ExportLet(rec~, name~, expr~, span~) => {
      buf.write_byte(b'\x10')
      write_bool(buf, rec)
      write_string(buf, name)
      write_expr(buf, expr)
      write_span(buf, span)
    }
    Stmt::InternalExportLet(rec~, name~, expr~, span~) => {
      buf.write_byte(b'\x11')
      write_bool(buf, rec)
      write_string(buf, name)
      write_expr(buf, expr)
      write_span(buf, span)
    }
    Stmt::ExportEnumDef(name~, params~, ctors~, span~) => {
      buf.write_byte(b'\x12')
      write_string(buf, name)
      write_string_array(buf, params)
      write_type_ctor_array(buf, ctors)
      write_span(buf, span)
    }
    Stmt::InternalExportEnumDef(name~, params~, ctors~, span~) => {
      buf.write_byte(b'\x13')
      write_string(buf, name)
      write_string_array(buf, params)
      write_type_ctor_array(buf, ctors)
      write_span(buf, span)
    }
    Stmt::ExportTypeAlias(name~, params~, target~, span~) => {
      buf.write_byte(b'\x14')
      write_string(buf, name)
      write_string_array(buf, params)
      write_type(buf, target)
      write_span(buf, span)
    }
    Stmt::InternalExportTypeAlias(name~, params~, target~, span~) => {
      buf.write_byte(b'\x15')
      write_string(buf, name)
      write_string_array(buf, params)
      write_type(buf, target)
      write_span(buf, span)
    }
    Stmt::InternalTraitDef(name~, supertraits~, methods~, open_impl~, span~) => {
      buf.write_byte(b'\x16')
      write_string(buf, name)
      write_string_array(buf, supertraits)
      write_trait_method_array(buf, methods)
      write_bool(buf, open_impl)
      write_span(buf, span)
    }
    Stmt::Export(names~, span~) => {
      buf.write_byte(b'\x17')
      write_string_array(buf, names)
      write_span(buf, span)
    }
    Stmt::ReExport(spec~, source~, span~) => {
      buf.write_byte(b'\x18')
      write_import_spec(buf, spec)
      write_module_ref(buf, source)
      write_span(buf, span)
    }
    Stmt::AliasDecl(alias_name~, source~, span~) => {
      buf.write_byte(b'\x19')
      write_string(buf, alias_name)
      write_module_ref(buf, source)
      write_span(buf, span)
    }
    Stmt::StructDef(name~, params~, fields~, span~) => {
      buf.write_byte(b'\x1A')
      write_string(buf, name)
      write_string_array(buf, params)
      write_struct_field_array(buf, fields)
      write_span(buf, span)
    }
    Stmt::ExportStructDef(name~, params~, fields~, span~) => {
      buf.write_byte(b'\x1B')
      write_string(buf, name)
      write_string_array(buf, params)
      write_struct_field_array(buf, fields)
      write_span(buf, span)
    }
    Stmt::InternalExportStructDef(name~, params~, fields~, span~) => {
      buf.write_byte(b'\x1C')
      write_string(buf, name)
      write_string_array(buf, params)
      write_struct_field_array(buf, fields)
      write_span(buf, span)
    }
    Stmt::EffectDef(name~, params~, ops~, import_path~, span~) => {
      buf.write_byte(b'\x1D')
      write_string(buf, name)
      write_string_array(buf, params)
      write_effect_op_array(buf, ops)
      write_optstr(buf, import_path)
      write_span(buf, span)
    }
    Stmt::ExportEffectDef(name~, params~, ops~, import_path~, span~) => {
      buf.write_byte(b'\x1E')
      write_string(buf, name)
      write_string_array(buf, params)
      write_effect_op_array(buf, ops)
      write_optstr(buf, import_path)
      write_span(buf, span)
    }
  }
}

// ---------------------------------------------------------------------------
// Expr
// ---------------------------------------------------------------------------

///|
fn write_expr_array(buf : @buffer.Buffer, exprs : Array[Expr]) -> Unit {
  write_varint_int(buf, exprs.length())
  for e in exprs {
    write_expr(buf, e)
  }
}

///|
fn write_expr(buf : @buffer.Buffer, expr : Expr) -> Unit {
  match expr {
    Expr::Int(value~, span~) => {
      buf.write_byte(b'\x01')
      write_svarint(buf, value)
      write_span(buf, span)
    }
    Expr::Float(value~, span~) => {
      buf.write_byte(b'\x02')
      write_f32(buf, value)
      write_span(buf, span)
    }
    Expr::Double(value~, span~) => {
      buf.write_byte(b'\x03')
      write_f64(buf, value)
      write_span(buf, span)
    }
    Expr::Bool(value~, span~) => {
      buf.write_byte(b'\x04')
      write_bool(buf, value)
      write_span(buf, span)
    }
    Expr::Char(value~, span~) => {
      buf.write_byte(b'\x05')
      write_char(buf, value)
      write_span(buf, span)
    }
    Expr::String(value~, span~) => {
      buf.write_byte(b'\x06')
      write_string(buf, value)
      write_span(buf, span)
    }
    Expr::StringInterp(parts~, span~) => {
      buf.write_byte(b'\x07')
      write_varint_int(buf, parts.length())
      for p in parts {
        write_string_interp_part(buf, p)
      }
      write_span(buf, span)
    }
    Expr::Ident(name~, span~) => {
      buf.write_byte(b'\x08')
      write_string(buf, name)
      write_span(buf, span)
    }
    Expr::Placeholder(index~, span~) => {
      buf.write_byte(b'\x09')
      write_varint_int(buf, index)
      write_span(buf, span)
    }
    Expr::Call(name~, type_args~, args~, span~) => {
      buf.write_byte(b'\x0A')
      write_string(buf, name)
      write_type_array(buf, type_args)
      write_call_arg_array(buf, args)
      write_span(buf, span)
    }
    Expr::Tuple(items~, span~) => {
      buf.write_byte(b'\x0B')
      write_expr_array(buf, items)
      write_span(buf, span)
    }
    Expr::TupleIndex(expr~, index~, span~) => {
      buf.write_byte(b'\x0C')
      write_expr(buf, expr)
      write_varint_int(buf, index)
      write_span(buf, span)
    }
    Expr::Record(fields~, span~) => {
      buf.write_byte(b'\x0D')
      write_record_field_expr_array(buf, fields)
      write_span(buf, span)
    }
    Expr::Array(items~, span~) => {
      buf.write_byte(b'\x0E')
      write_expr_array(buf, items)
      write_span(buf, span)
    }
    Expr::Map(fields~, span~) => {
      buf.write_byte(b'\x0F')
      write_map_field_expr_array(buf, fields)
      write_span(buf, span)
    }
    Expr::If(cond~, then_body~, else_body~, span~) => {
      buf.write_byte(b'\x10')
      write_expr(buf, cond)
      write_module(buf, then_body)
      write_module(buf, else_body)
      write_span(buf, span)
    }
    Expr::Block(body~, span~) => {
      buf.write_byte(b'\x11')
      write_module(buf, body)
      write_span(buf, span)
    }
    Expr::Match(scrutinee~, arms~, span~) => {
      buf.write_byte(b'\x12')
      write_expr(buf, scrutinee)
      write_match_arm_array(buf, arms)
      write_span(buf, span)
    }
    Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      buf.write_byte(b'\x13')
      write_string(buf, value_name)
      write_optstr(buf, index_name)
      write_expr(buf, iterable)
      write_module(buf, body)
      write_span(buf, span)
    }
    Expr::Fn(type_params~, type_bounds~, params~, ret~, effects~, body~, span~) => {
      buf.write_byte(b'\x14')
      write_string_array(buf, type_params)
      write_type_bounds_map(buf, type_bounds)
      write_func_param_array(buf, params)
      // Optional type
      match ret {
        None => buf.write_byte(b'\x00')
        Some(t) => {
          buf.write_byte(b'\x01')
          write_type(buf, t)
        }
      }
      write_effect_atom_array(buf, effects)
      write_module(buf, body)
      write_span(buf, span)
    }
    Expr::While(cond~, body~, span~) => {
      buf.write_byte(b'\x15')
      write_expr(buf, cond)
      write_module(buf, body)
      write_span(buf, span)
    }
    Expr::Loop(params~, body~, span~) => {
      buf.write_byte(b'\x16')
      write_loop_param_array(buf, params)
      write_module(buf, body)
      write_span(buf, span)
    }
    Expr::Break(value~, span~) => {
      buf.write_byte(b'\x17')
      write_opt_expr(buf, value)
      write_span(buf, span)
    }
    Expr::Continue(args~, span~) => {
      buf.write_byte(b'\x18')
      write_expr_array(buf, args)
      write_span(buf, span)
    }
    Expr::Return(value~, span~) => {
      buf.write_byte(b'\x19')
      write_opt_expr(buf, value)
      write_span(buf, span)
    }
    Expr::Yield(expr~, span~) => {
      buf.write_byte(b'\x1A')
      write_expr(buf, expr)
      write_span(buf, span)
    }
    Expr::Handle(body~, arms~, span~) => {
      buf.write_byte(b'\x1B')
      write_module(buf, body)
      write_match_arm_array(buf, arms)
      write_span(buf, span)
    }
    Expr::StructLit(name~, type_args~, fields~, span~) => {
      buf.write_byte(b'\x1C')
      write_string(buf, name)
      write_type_array(buf, type_args)
      write_record_field_expr_array(buf, fields)
      write_span(buf, span)
    }
    Expr::Spread(expr~, span~) => {
      buf.write_byte(b'\x1D')
      write_expr(buf, expr)
      write_span(buf, span)
    }
    Expr::Perform(effect_name~, op_name~, args~, span~) => {
      buf.write_byte(b'\x1E')
      write_string(buf, effect_name)
      write_string(buf, op_name)
      write_call_arg_array(buf, args)
      write_span(buf, span)
    }
  }
}

///|
fn write_opt_expr(buf : @buffer.Buffer, e : Expr?) -> Unit {
  match e {
    None => buf.write_byte(b'\x00')
    Some(v) => {
      buf.write_byte(b'\x01')
      write_expr(buf, v)
    }
  }
}

// ---------------------------------------------------------------------------
// Pat
// ---------------------------------------------------------------------------

///|
fn write_pat_array(buf : @buffer.Buffer, pats : Array[Pat]) -> Unit {
  write_varint_int(buf, pats.length())
  for p in pats {
    write_pat(buf, p)
  }
}

///|
fn write_pat(buf : @buffer.Buffer, pat : Pat) -> Unit {
  match pat {
    Pat::Wildcard(span~) => {
      buf.write_byte(b'\x01')
      write_span(buf, span)
    }
    Pat::Bind(name~, span~) => {
      buf.write_byte(b'\x02')
      write_string(buf, name)
      write_span(buf, span)
    }
    Pat::Ctor(name~, args~, span~) => {
      buf.write_byte(b'\x03')
      write_string(buf, name)
      write_pat_array(buf, args)
      write_span(buf, span)
    }
    Pat::Tuple(items~, span~) => {
      buf.write_byte(b'\x04')
      write_pat_array(buf, items)
      write_span(buf, span)
    }
    Pat::Record(fields~, span~) => {
      buf.write_byte(b'\x05')
      write_record_field_pat_array(buf, fields)
      write_span(buf, span)
    }
    Pat::Struct(name~, fields~, span~) => {
      buf.write_byte(b'\x06')
      write_string(buf, name)
      write_record_field_pat_array(buf, fields)
      write_span(buf, span)
    }
    Pat::Int(value~, span~) => {
      buf.write_byte(b'\x07')
      write_svarint(buf, value)
      write_span(buf, span)
    }
    Pat::Float(value~, span~) => {
      buf.write_byte(b'\x08')
      write_f32(buf, value)
      write_span(buf, span)
    }
    Pat::Double(value~, span~) => {
      buf.write_byte(b'\x09')
      write_f64(buf, value)
      write_span(buf, span)
    }
    Pat::Bool(value~, span~) => {
      buf.write_byte(b'\x0A')
      write_bool(buf, value)
      write_span(buf, span)
    }
    Pat::Char(value~, span~) => {
      buf.write_byte(b'\x0B')
      write_char(buf, value)
      write_span(buf, span)
    }
    Pat::String(value~, span~) => {
      buf.write_byte(b'\x0C')
      write_string(buf, value)
      write_span(buf, span)
    }
    Pat::Or(pats~, span~) => {
      buf.write_byte(b'\x0D')
      write_pat_array(buf, pats)
      write_span(buf, span)
    }
  }
}

// ---------------------------------------------------------------------------
// Type
// ---------------------------------------------------------------------------

///|
fn write_type_array(buf : @buffer.Buffer, types : Array[Type]) -> Unit {
  write_varint_int(buf, types.length())
  for t in types {
    write_type(buf, t)
  }
}

///|
fn write_type(buf : @buffer.Buffer, ty : Type) -> Unit {
  match ty {
    Type::Int => buf.write_byte(b'\x01')
    Type::Float => buf.write_byte(b'\x02')
    Type::Double => buf.write_byte(b'\x03')
    Type::Bool => buf.write_byte(b'\x04')
    Type::Char => buf.write_byte(b'\x05')
    Type::String => buf.write_byte(b'\x06')
    Type::Path => buf.write_byte(b'\x07')
    Type::PromptText => buf.write_byte(b'\x08')
    Type::Unit => buf.write_byte(b'\x09')
    Type::Infer => buf.write_byte(b'\x0A')
    Type::Tuple(items) => {
      buf.write_byte(b'\x0B')
      write_type_array(buf, items)
    }
    Type::Record(fields) => {
      buf.write_byte(b'\x0C')
      write_string_type_map(buf, fields)
    }
    Type::Array(elem) => {
      buf.write_byte(b'\x0D')
      write_type(buf, elem)
    }
    Type::Map(k, v) => {
      buf.write_byte(b'\x0E')
      write_type(buf, k)
      write_type(buf, v)
    }
    Type::Set(elem) => {
      buf.write_byte(b'\x0F')
      write_type(buf, elem)
    }
    Type::ArrayBuilder(elem) => {
      buf.write_byte(b'\x10')
      write_type(buf, elem)
    }
    Type::MapBuilder(k, v) => {
      buf.write_byte(b'\x11')
      write_type(buf, k)
      write_type(buf, v)
    }
    Type::StringBuilder => buf.write_byte(b'\x12')
    Type::Bytes => buf.write_byte(b'\x13')
    Type::V128 => buf.write_byte(b'\x14')
    Type::Variant(fields) => {
      buf.write_byte(b'\x15')
      write_string_type_map(buf, fields)
    }
    Type::Named(name~, args~) => {
      buf.write_byte(b'\x16')
      write_string(buf, name)
      write_type_array(buf, args)
    }
    Type::Param(name) => {
      buf.write_byte(b'\x17')
      write_string(buf, name)
    }
    Type::Var(id) => {
      buf.write_byte(b'\x18')
      write_svarint(buf, id.to_int64())
    }
    Type::Func(params~, ret~, effects~) => {
      buf.write_byte(b'\x19')
      write_func_param_array(buf, params)
      write_type(buf, ret)
      write_effect_atom_array(buf, effects)
    }
    Type::Never => buf.write_byte(b'\x1A')
  }
}

// ---------------------------------------------------------------------------
// Auxiliary structs and small enums
// ---------------------------------------------------------------------------

///|
fn write_module(buf : @buffer.Buffer, m : Module) -> Unit {
  write_stmt_array(buf, m.stmts)
}

///|
fn write_string_array(buf : @buffer.Buffer, ss : Array[String]) -> Unit {
  write_varint_int(buf, ss.length())
  for s in ss {
    write_string(buf, s)
  }
}

///|
fn write_string_type_map(
  buf : @buffer.Buffer,
  fields : Map[String, Type],
) -> Unit {
  // Iterate in whatever order the Map yields rather than sorting —
  // selfhost-runtime-parity compares byte-identical compile output,
  // and downstream codegen sometimes iterates fields in the order
  // they appear in the source AST. Sorting here would silently
  // re-order fields on cache reload and break the parity gate.
  let n = fields.length()
  write_varint_int(buf, n)
  for k, v in fields {
    write_string(buf, k)
    write_type(buf, v)
  }
}

///|
fn write_type_bounds_map(
  buf : @buffer.Buffer,
  bounds : Map[String, Array[String]],
) -> Unit {
  // Same iteration-order rationale as `write_string_type_map`.
  let n = bounds.length()
  write_varint_int(buf, n)
  for k, v in bounds {
    write_string(buf, k)
    write_string_array(buf, v)
  }
}

///|
fn write_param_label(buf : @buffer.Buffer, label : ParamLabel) -> Unit {
  match label {
    ParamLabel::Positional => buf.write_byte(b'\x01')
    ParamLabel::Variadic => buf.write_byte(b'\x02')
    ParamLabel::Required => buf.write_byte(b'\x03')
    ParamLabel::Optional => buf.write_byte(b'\x04')
  }
}

///|
fn write_func_param(buf : @buffer.Buffer, p : FuncParam) -> Unit {
  write_string(buf, p.name)
  write_param_label(buf, p.label)
  write_type(buf, p.ty)
  write_string_array(buf, p.bounds)
}

///|
fn write_func_param_array(buf : @buffer.Buffer, ps : Array[FuncParam]) -> Unit {
  write_varint_int(buf, ps.length())
  for p in ps {
    write_func_param(buf, p)
  }
}

///|
fn write_effect_atom(buf : @buffer.Buffer, e : EffectAtom) -> Unit {
  match e {
    EffectAtom::Const(s) => {
      buf.write_byte(b'\x01')
      write_string(buf, s)
    }
    EffectAtom::Var(s) => {
      buf.write_byte(b'\x02')
      write_string(buf, s)
    }
  }
}

///|
fn write_effect_atom_array(
  buf : @buffer.Buffer,
  effects : Array[EffectAtom],
) -> Unit {
  write_varint_int(buf, effects.length())
  for e in effects {
    write_effect_atom(buf, e)
  }
}

///|
fn write_call_arg(buf : @buffer.Buffer, a : CallArg) -> Unit {
  write_optstr(buf, a.label)
  write_expr(buf, a.expr)
  write_span(buf, a.span)
}

///|
fn write_call_arg_array(buf : @buffer.Buffer, args : Array[CallArg]) -> Unit {
  write_varint_int(buf, args.length())
  for a in args {
    write_call_arg(buf, a)
  }
}

///|
fn write_record_field_expr(buf : @buffer.Buffer, f : RecordFieldExpr) -> Unit {
  write_string(buf, f.name)
  write_expr(buf, f.expr)
  write_span(buf, f.span)
}

///|
fn write_record_field_expr_array(
  buf : @buffer.Buffer,
  fs : Array[RecordFieldExpr],
) -> Unit {
  write_varint_int(buf, fs.length())
  for f in fs {
    write_record_field_expr(buf, f)
  }
}

///|
fn write_map_field_expr(buf : @buffer.Buffer, f : MapFieldExpr) -> Unit {
  write_string(buf, f.key)
  write_expr(buf, f.expr)
  write_span(buf, f.span)
}

///|
fn write_map_field_expr_array(
  buf : @buffer.Buffer,
  fs : Array[MapFieldExpr],
) -> Unit {
  write_varint_int(buf, fs.length())
  for f in fs {
    write_map_field_expr(buf, f)
  }
}

///|
fn write_record_field_pat(buf : @buffer.Buffer, f : RecordFieldPat) -> Unit {
  write_string(buf, f.name)
  write_pat(buf, f.pat)
  write_span(buf, f.span)
}

///|
fn write_record_field_pat_array(
  buf : @buffer.Buffer,
  fs : Array[RecordFieldPat],
) -> Unit {
  write_varint_int(buf, fs.length())
  for f in fs {
    write_record_field_pat(buf, f)
  }
}

///|
fn write_match_arm(buf : @buffer.Buffer, arm : MatchArm) -> Unit {
  write_pat(buf, arm.pat)
  write_opt_expr(buf, arm.cond)
  write_expr(buf, arm.expr)
  write_span(buf, arm.span)
}

///|
fn write_match_arm_array(buf : @buffer.Buffer, arms : Array[MatchArm]) -> Unit {
  write_varint_int(buf, arms.length())
  for a in arms {
    write_match_arm(buf, a)
  }
}

///|
fn write_loop_param(buf : @buffer.Buffer, p : LoopParam) -> Unit {
  write_string(buf, p.name)
  write_expr(buf, p.init)
  write_span(buf, p.span)
}

///|
fn write_loop_param_array(buf : @buffer.Buffer, ps : Array[LoopParam]) -> Unit {
  write_varint_int(buf, ps.length())
  for p in ps {
    write_loop_param(buf, p)
  }
}

///|
fn write_type_ctor(buf : @buffer.Buffer, c : TypeCtor) -> Unit {
  write_string(buf, c.name)
  write_type_array(buf, c.args)
  write_span(buf, c.span)
}

///|
fn write_type_ctor_array(buf : @buffer.Buffer, ctors : Array[TypeCtor]) -> Unit {
  write_varint_int(buf, ctors.length())
  for c in ctors {
    write_type_ctor(buf, c)
  }
}

///|
fn write_struct_field(buf : @buffer.Buffer, f : StructField) -> Unit {
  write_string(buf, f.name)
  write_type(buf, f.ty)
  write_bool(buf, f.is_mut)
  write_span(buf, f.span)
}

///|
fn write_struct_field_array(
  buf : @buffer.Buffer,
  fs : Array[StructField],
) -> Unit {
  write_varint_int(buf, fs.length())
  for f in fs {
    write_struct_field(buf, f)
  }
}

///|
fn write_effect_op(buf : @buffer.Buffer, op : EffectOp) -> Unit {
  write_string(buf, op.name)
  write_type_array(buf, op.params)
  write_type(buf, op.ret)
  write_span(buf, op.span)
}

///|
fn write_effect_op_array(buf : @buffer.Buffer, ops : Array[EffectOp]) -> Unit {
  write_varint_int(buf, ops.length())
  for op in ops {
    write_effect_op(buf, op)
  }
}

///|
fn write_trait_method(buf : @buffer.Buffer, m : TraitMethodSig) -> Unit {
  write_string(buf, m.name)
  write_func_param_array(buf, m.params)
  write_type(buf, m.ret)
  write_span(buf, m.span)
}

///|
fn write_trait_method_array(
  buf : @buffer.Buffer,
  ms : Array[TraitMethodSig],
) -> Unit {
  write_varint_int(buf, ms.length())
  for m in ms {
    write_trait_method(buf, m)
  }
}

///|
fn write_impl_method(buf : @buffer.Buffer, m : ImplMethodDef) -> Unit {
  write_string(buf, m.name)
  write_expr(buf, m.expr)
  write_span(buf, m.span)
}

///|
fn write_impl_method_array(
  buf : @buffer.Buffer,
  ms : Array[ImplMethodDef],
) -> Unit {
  write_varint_int(buf, ms.length())
  for m in ms {
    write_impl_method(buf, m)
  }
}

///|
fn write_import_kind(buf : @buffer.Buffer, k : ImportKind) -> Unit {
  match k {
    ImportKind::Value => buf.write_byte(b'\x01')
    ImportKind::Type => buf.write_byte(b'\x02')
    ImportKind::Struct => buf.write_byte(b'\x03')
    ImportKind::Trait => buf.write_byte(b'\x04')
    ImportKind::Effect => buf.write_byte(b'\x05')
    ImportKind::Suberror => buf.write_byte(b'\x06')
    ImportKind::Module => buf.write_byte(b'\x07')
  }
}

///|
fn write_import_item(buf : @buffer.Buffer, item : ImportItem) -> Unit {
  write_import_kind(buf, item.kind)
  write_string(buf, item.name)
  write_optstr(buf, item.rename)
}

///|
fn write_import_spec(buf : @buffer.Buffer, spec : ImportSpec) -> Unit {
  write_varint_int(buf, spec.items.length())
  for item in spec.items {
    write_import_item(buf, item)
  }
}

///|
fn write_module_ref(buf : @buffer.Buffer, m : ModuleRef) -> Unit {
  match m {
    ModuleRef::Path(path~) => {
      buf.write_byte(b'\x01')
      write_string(buf, path)
    }
    ModuleRef::Hash(hash~) => {
      buf.write_byte(b'\x02')
      write_string(buf, hash)
    }
    ModuleRef::Version(name~) => {
      buf.write_byte(b'\x03')
      write_string(buf, name)
    }
    ModuleRef::Symbol(name~) => {
      buf.write_byte(b'\x04')
      write_string(buf, name)
    }
    ModuleRef::Alias(name~) => {
      buf.write_byte(b'\x05')
      write_string(buf, name)
    }
    ModuleRef::PinnedPath(path~, hash~) => {
      buf.write_byte(b'\x06')
      write_string(buf, path)
      write_string(buf, hash)
    }
  }
}

///|
fn write_string_interp_part(
  buf : @buffer.Buffer,
  part : StringInterpPart,
) -> Unit {
  match part {
    StringInterpPart::Lit(s) => {
      buf.write_byte(b'\x01')
      write_string(buf, s)
    }
    StringInterpPart::Expr(e) => {
      buf.write_byte(b'\x02')
      write_expr(buf, e)
    }
  }
}
