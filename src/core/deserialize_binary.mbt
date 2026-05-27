// Compact binary deserializer for @core.Module.
//
// Wire format: docs/ast_binary_abi.md (v1).
//
// MUST roundtrip with serialize_binary.mbt and with the selfhost
// implementation at vibe/compiler/ast_binary.vibe.

///|
pub(all) suberror BinaryDeserializeError {
  /// File didn't start with the expected `'v','A','S','T'` magic.
  BadMagic
  /// Version field was something we don't speak (yet).
  UnsupportedVersion(Int)
  /// Walked off the end of the buffer mid-record.
  UnexpectedEof
  /// A bool byte was something other than 0x00 or 0x01.
  BadBool(Byte)
  /// `<context>::<tag>` — an enum tag we don't recognize.
  UnknownTag(String, Byte)
  /// UTF-8 decoding failed for a string field.
  BadUtf8
} derive(Debug)

///|
pub impl Show for BinaryDeserializeError with output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
/// Mutable cursor over the input bytes. `pos` advances as we consume
/// bytes; deserializer functions read forward and never seek back.
priv struct BinReader {
  bytes : Bytes
  mut pos : Int
}

///|
fn BinReader::new(bytes : Bytes) -> BinReader {
  { bytes, pos: 0 }
}

///|
fn BinReader::remaining(self : BinReader) -> Int {
  self.bytes.length() - self.pos
}

///|
/// Deserialize a Module from a buffer written by
/// `serialize_module_binary`.
pub fn deserialize_module_binary(
  bytes : Bytes,
) -> Module raise BinaryDeserializeError {
  let r = BinReader::new(bytes)
  if r.remaining() < 4 {
    raise UnexpectedEof
  }
  if read_byte(r) != AST_BINARY_MAGIC_0 ||
    read_byte(r) != AST_BINARY_MAGIC_1 ||
    read_byte(r) != AST_BINARY_MAGIC_2 ||
    read_byte(r) != AST_BINARY_MAGIC_3 {
    raise BadMagic
  }
  let version = read_varint(r).to_int()
  if version != AST_BINARY_VERSION {
    raise UnsupportedVersion(version)
  }
  let stmts = read_stmt_array(r)
  Module::{ stmts, }
}

// ---------------------------------------------------------------------------
// Primitives
// ---------------------------------------------------------------------------

///|
fn read_byte(r : BinReader) -> Byte raise BinaryDeserializeError {
  if r.pos >= r.bytes.length() {
    raise UnexpectedEof
  }
  let b = r.bytes[r.pos]
  r.pos = r.pos + 1
  b
}

///|
fn read_varint(r : BinReader) -> Int64 raise BinaryDeserializeError {
  let mut result : Int64 = 0L
  let mut shift = 0
  while true {
    let b = read_byte(r)
    let bint = b.to_int()
    result = result | ((bint & 0x7F).to_int64() << shift)
    if (bint & 0x80) == 0 {
      break
    }
    shift = shift + 7
    if shift > 63 {
      // Overflow — refuse to keep reading.
      raise UnexpectedEof
    }
  }
  result
}

///|
/// Standard sleb128 decode (matches encoder in serialize_binary.mbt).
fn read_svarint(r : BinReader) -> Int64 raise BinaryDeserializeError {
  let mut result : Int64 = 0L
  let mut shift = 0
  let mut last_byte : Int = 0
  while true {
    let b = read_byte(r)
    let bint = b.to_int()
    last_byte = bint
    result = result | ((bint & 0x7F).to_int64() << shift)
    shift = shift + 7
    if (bint & 0x80) == 0 {
      break
    }
    if shift > 63 {
      raise UnexpectedEof
    }
  }
  // Sign-extend the result if the sign bit (bit 6 of last byte) is set
  // and we haven't filled all 64 bits.
  if shift < 64 && (last_byte & 0x40) != 0 {
    result = result | (-1L << shift)
  }
  result
}

///|
fn read_bool(r : BinReader) -> Bool raise BinaryDeserializeError {
  let b = read_byte(r)
  match b {
    b'\x00' => false
    b'\x01' => true
    _ => raise BadBool(b)
  }
}

///|
fn read_string(r : BinReader) -> String raise BinaryDeserializeError {
  let n = read_varint(r).to_int()
  if n < 0 || r.pos + n > r.bytes.length() {
    raise UnexpectedEof
  }
  let view = r.bytes[r.pos:r.pos + n]
  r.pos = r.pos + n
  // UTF-8 decode. The host runtime's @utf8.decode raises on invalid
  // sequences; we surface that as BadUtf8 to keep our error vocab tight.
  let result = try @utf8.decode(view) catch {
    _ => raise BadUtf8
  }
  result
}

///|
fn read_optstr(r : BinReader) -> String? raise BinaryDeserializeError {
  let tag = read_byte(r)
  match tag {
    b'\x00' => None
    b'\x01' => Some(read_string(r))
    _ => raise UnknownTag("optstr", tag)
  }
}

///|
fn read_f32(r : BinReader) -> Float raise BinaryDeserializeError {
  let b0 = read_byte(r).to_int().reinterpret_as_uint()
  let b1 = read_byte(r).to_int().reinterpret_as_uint()
  let b2 = read_byte(r).to_int().reinterpret_as_uint()
  let b3 = read_byte(r).to_int().reinterpret_as_uint()
  let bits = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
  Float::reinterpret_from_uint(bits)
}

///|
fn read_f64(r : BinReader) -> Double raise BinaryDeserializeError {
  let mut bits : UInt64 = 0UL
  let mut i = 0
  while i < 8 {
    let b = read_byte(r).to_int().reinterpret_as_uint().to_uint64()
    bits = bits | (b << (i * 8))
    i = i + 1
  }
  UInt64::reinterpret_as_double(bits)
}

///|
fn read_char(r : BinReader) -> Char raise BinaryDeserializeError {
  let code = read_varint(r).to_int()
  match code.to_char() {
    Some(c) => c
    None => raise BadUtf8
  }
}

///|
fn read_span(r : BinReader) -> Span raise BinaryDeserializeError {
  let start = read_svarint(r).to_int()
  let end = read_svarint(r).to_int()
  Span::{ start, end }
}

// ---------------------------------------------------------------------------
// Stmt
// ---------------------------------------------------------------------------

///|
fn read_stmt_array(r : BinReader) -> Array[Stmt] raise BinaryDeserializeError {
  let n = read_varint(r).to_int()
  let out : Array[Stmt] = []
  let mut i = 0
  while i < n {
    out.push(read_stmt(r))
    i = i + 1
  }
  out
}

///|
fn read_stmt(r : BinReader) -> Stmt raise BinaryDeserializeError {
  let tag = read_byte(r)
  match tag {
    b'\x01' => {
      let rec = read_bool(r)
      let name = read_string(r)
      let expr = read_expr(r)
      let span = read_span(r)
      Stmt::Let(rec~, name~, expr~, span~)
    }
    b'\x02' => {
      let name = read_string(r)
      let params = read_string_array(r)
      let ctors = read_type_ctor_array(r)
      let span = read_span(r)
      Stmt::EnumDef(name~, params~, ctors~, span~)
    }
    b'\x03' => {
      let name = read_string(r)
      let params = read_string_array(r)
      let target = read_type(r)
      let span = read_span(r)
      Stmt::TypeAlias(name~, params~, target~, span~)
    }
    b'\x04' => {
      let name = read_string(r)
      let supertraits = read_string_array(r)
      let methods = read_trait_method_array(r)
      let open_impl = read_bool(r)
      let exported = read_bool(r)
      let span = read_span(r)
      Stmt::TraitDef(
        name~,
        supertraits~,
        methods~,
        open_impl~,
        exported~,
        span~,
      )
    }
    b'\x05' => {
      let type_params = read_string_array(r)
      let type_bounds = read_type_bounds_map(r)
      let trait_name = read_string(r)
      let target = read_type(r)
      let methods = read_impl_method_array(r)
      let span = read_span(r)
      Stmt::TraitImpl(
        type_params~,
        type_bounds~,
        trait_name~,
        target~,
        methods~,
        span~,
      )
    }
    b'\x06' => {
      let expr = read_expr(r)
      let span = read_span(r)
      Stmt::Expr(expr~, span~)
    }
    b'\x07' => {
      let spec = read_import_spec(r)
      let source = read_module_ref(r)
      let span = read_span(r)
      Stmt::Import(spec~, source~, span~)
    }
    b'\x08' => {
      let name = read_optstr(r)
      let body = read_module(r)
      let span = read_span(r)
      Stmt::Test(name~, body~, span~)
    }
    b'\x09' => {
      let name = read_optstr(r)
      let body = read_module(r)
      let span = read_span(r)
      Stmt::Bench(name~, body~, span~)
    }
    b'\x0A' => {
      let name = read_string(r)
      let expr = read_expr(r)
      let span = read_span(r)
      Stmt::LetMut(name~, expr~, span~)
    }
    b'\x0B' => {
      let name = read_string(r)
      let ty = read_type(r)
      let span = read_span(r)
      Stmt::ExternLet(name~, ty~, span~)
    }
    b'\x0C' => {
      let name = read_string(r)
      let expr = read_expr(r)
      let span = read_span(r)
      Stmt::Assign(name~, expr~, span~)
    }
    b'\x0D' => {
      let target = read_expr(r)
      let index = read_expr(r)
      let value = read_expr(r)
      let span = read_span(r)
      Stmt::IndexAssign(target~, index~, value~, span~)
    }
    b'\x0E' => {
      let pat = read_pat(r)
      let expr = read_expr(r)
      let span = read_span(r)
      Stmt::LetPat(pat~, expr~, span~)
    }
    b'\x0F' => {
      let pat = read_pat(r)
      let expr = read_expr(r)
      let else_body = read_module(r)
      let span = read_span(r)
      Stmt::LetPatElse(pat~, expr~, else_body~, span~)
    }
    b'\x10' => {
      let rec = read_bool(r)
      let name = read_string(r)
      let expr = read_expr(r)
      let span = read_span(r)
      Stmt::ExportLet(rec~, name~, expr~, span~)
    }
    b'\x11' => {
      let rec = read_bool(r)
      let name = read_string(r)
      let expr = read_expr(r)
      let span = read_span(r)
      Stmt::InternalExportLet(rec~, name~, expr~, span~)
    }
    b'\x12' => {
      let name = read_string(r)
      let params = read_string_array(r)
      let ctors = read_type_ctor_array(r)
      let span = read_span(r)
      Stmt::ExportEnumDef(name~, params~, ctors~, span~)
    }
    b'\x13' => {
      let name = read_string(r)
      let params = read_string_array(r)
      let ctors = read_type_ctor_array(r)
      let span = read_span(r)
      Stmt::InternalExportEnumDef(name~, params~, ctors~, span~)
    }
    b'\x14' => {
      let name = read_string(r)
      let params = read_string_array(r)
      let target = read_type(r)
      let span = read_span(r)
      Stmt::ExportTypeAlias(name~, params~, target~, span~)
    }
    b'\x15' => {
      let name = read_string(r)
      let params = read_string_array(r)
      let target = read_type(r)
      let span = read_span(r)
      Stmt::InternalExportTypeAlias(name~, params~, target~, span~)
    }
    b'\x16' => {
      let name = read_string(r)
      let supertraits = read_string_array(r)
      let methods = read_trait_method_array(r)
      let open_impl = read_bool(r)
      let span = read_span(r)
      Stmt::InternalTraitDef(
        name~,
        supertraits~,
        methods~,
        open_impl~,
        span~,
      )
    }
    b'\x17' => {
      let names = read_string_array(r)
      let span = read_span(r)
      Stmt::Export(names~, span~)
    }
    b'\x18' => {
      let spec = read_import_spec(r)
      let source = read_module_ref(r)
      let span = read_span(r)
      Stmt::ReExport(spec~, source~, span~)
    }
    b'\x19' => {
      let alias_name = read_string(r)
      let source = read_module_ref(r)
      let span = read_span(r)
      Stmt::AliasDecl(alias_name~, source~, span~)
    }
    b'\x1A' => {
      let name = read_string(r)
      let params = read_string_array(r)
      let fields = read_struct_field_array(r)
      let span = read_span(r)
      Stmt::StructDef(name~, params~, fields~, span~)
    }
    b'\x1B' => {
      let name = read_string(r)
      let params = read_string_array(r)
      let fields = read_struct_field_array(r)
      let span = read_span(r)
      Stmt::ExportStructDef(name~, params~, fields~, span~)
    }
    b'\x1C' => {
      let name = read_string(r)
      let params = read_string_array(r)
      let fields = read_struct_field_array(r)
      let span = read_span(r)
      Stmt::InternalExportStructDef(name~, params~, fields~, span~)
    }
    b'\x1D' => {
      let name = read_string(r)
      let params = read_string_array(r)
      let ops = read_effect_op_array(r)
      let import_path = read_optstr(r)
      let span = read_span(r)
      Stmt::EffectDef(name~, params~, ops~, import_path~, span~)
    }
    b'\x1E' => {
      let name = read_string(r)
      let params = read_string_array(r)
      let ops = read_effect_op_array(r)
      let import_path = read_optstr(r)
      let span = read_span(r)
      Stmt::ExportEffectDef(name~, params~, ops~, import_path~, span~)
    }
    _ => raise UnknownTag("Stmt", tag)
  }
}

// ---------------------------------------------------------------------------
// Expr
// ---------------------------------------------------------------------------

///|
fn read_expr_array(r : BinReader) -> Array[Expr] raise BinaryDeserializeError {
  let n = read_varint(r).to_int()
  let out : Array[Expr] = []
  let mut i = 0
  while i < n {
    out.push(read_expr(r))
    i = i + 1
  }
  out
}

///|
fn read_expr(r : BinReader) -> Expr raise BinaryDeserializeError {
  let tag = read_byte(r)
  match tag {
    b'\x01' => {
      let value = read_svarint(r)
      let span = read_span(r)
      Expr::Int(value~, span~)
    }
    b'\x02' => {
      let value = read_f32(r)
      let span = read_span(r)
      Expr::Float(value~, span~)
    }
    b'\x03' => {
      let value = read_f64(r)
      let span = read_span(r)
      Expr::Double(value~, span~)
    }
    b'\x04' => {
      let value = read_bool(r)
      let span = read_span(r)
      Expr::Bool(value~, span~)
    }
    b'\x05' => {
      let value = read_char(r)
      let span = read_span(r)
      Expr::Char(value~, span~)
    }
    b'\x06' => {
      let value = read_string(r)
      let span = read_span(r)
      Expr::String(value~, span~)
    }
    b'\x07' => {
      let n = read_varint(r).to_int()
      let parts : Array[StringInterpPart] = []
      let mut i = 0
      while i < n {
        parts.push(read_string_interp_part(r))
        i = i + 1
      }
      let span = read_span(r)
      Expr::StringInterp(parts~, span~)
    }
    b'\x08' => {
      let name = read_string(r)
      let span = read_span(r)
      Expr::Ident(name~, span~)
    }
    b'\x09' => {
      let index = read_varint(r).to_int()
      let span = read_span(r)
      Expr::Placeholder(index~, span~)
    }
    b'\x0A' => {
      let name = read_string(r)
      let type_args = read_type_array(r)
      let args = read_call_arg_array(r)
      let span = read_span(r)
      Expr::Call(name~, type_args~, args~, span~)
    }
    b'\x0B' => {
      let items = read_expr_array(r)
      let span = read_span(r)
      Expr::Tuple(items~, span~)
    }
    b'\x0C' => {
      let expr = read_expr(r)
      let index = read_varint(r).to_int()
      let span = read_span(r)
      Expr::TupleIndex(expr~, index~, span~)
    }
    b'\x0D' => {
      let fields = read_record_field_expr_array(r)
      let span = read_span(r)
      Expr::Record(fields~, span~)
    }
    b'\x0E' => {
      let items = read_expr_array(r)
      let span = read_span(r)
      Expr::Array(items~, span~)
    }
    b'\x0F' => {
      let fields = read_map_field_expr_array(r)
      let span = read_span(r)
      Expr::Map(fields~, span~)
    }
    b'\x10' => {
      let cond = read_expr(r)
      let then_body = read_module(r)
      let else_body = read_module(r)
      let span = read_span(r)
      Expr::If(cond~, then_body~, else_body~, span~)
    }
    b'\x11' => {
      let body = read_module(r)
      let span = read_span(r)
      Expr::Block(body~, span~)
    }
    b'\x12' => {
      let scrutinee = read_expr(r)
      let arms = read_match_arm_array(r)
      let span = read_span(r)
      Expr::Match(scrutinee~, arms~, span~)
    }
    b'\x13' => {
      let value_name = read_string(r)
      let index_name = read_optstr(r)
      let iterable = read_expr(r)
      let body = read_module(r)
      let span = read_span(r)
      Expr::ForIn(value_name~, index_name~, iterable~, body~, span~)
    }
    b'\x14' => {
      let type_params = read_string_array(r)
      let type_bounds = read_type_bounds_map(r)
      let params = read_func_param_array(r)
      let ret = match read_byte(r) {
        b'\x00' => None
        b'\x01' => Some(read_type(r))
        t => raise UnknownTag("Expr::Fn.ret", t)
      }
      let effects = read_effect_atom_array(r)
      let body = read_module(r)
      let span = read_span(r)
      Expr::Fn(
        type_params~,
        type_bounds~,
        params~,
        ret~,
        effects~,
        body~,
        span~,
      )
    }
    b'\x15' => {
      let cond = read_expr(r)
      let body = read_module(r)
      let span = read_span(r)
      Expr::While(cond~, body~, span~)
    }
    b'\x16' => {
      let params = read_loop_param_array(r)
      let body = read_module(r)
      let span = read_span(r)
      Expr::Loop(params~, body~, span~)
    }
    b'\x17' => {
      let value = read_opt_expr(r)
      let span = read_span(r)
      Expr::Break(value~, span~)
    }
    b'\x18' => {
      let args = read_expr_array(r)
      let span = read_span(r)
      Expr::Continue(args~, span~)
    }
    b'\x19' => {
      let value = read_opt_expr(r)
      let span = read_span(r)
      Expr::Return(value~, span~)
    }
    b'\x1A' => {
      let expr = read_expr(r)
      let span = read_span(r)
      Expr::Yield(expr~, span~)
    }
    b'\x1B' => {
      let body = read_module(r)
      let arms = read_match_arm_array(r)
      let span = read_span(r)
      Expr::Handle(body~, arms~, span~)
    }
    b'\x1C' => {
      let name = read_string(r)
      let type_args = read_type_array(r)
      let fields = read_record_field_expr_array(r)
      let span = read_span(r)
      Expr::StructLit(name~, type_args~, fields~, span~)
    }
    b'\x1D' => {
      let expr = read_expr(r)
      let span = read_span(r)
      Expr::Spread(expr~, span~)
    }
    b'\x1E' => {
      let effect_name = read_string(r)
      let op_name = read_string(r)
      let args = read_call_arg_array(r)
      let span = read_span(r)
      Expr::Perform(effect_name~, op_name~, args~, span~)
    }
    _ => raise UnknownTag("Expr", tag)
  }
}

///|
fn read_opt_expr(r : BinReader) -> Expr? raise BinaryDeserializeError {
  let tag = read_byte(r)
  match tag {
    b'\x00' => None
    b'\x01' => Some(read_expr(r))
    _ => raise UnknownTag("opt_expr", tag)
  }
}

// ---------------------------------------------------------------------------
// Pat
// ---------------------------------------------------------------------------

///|
fn read_pat_array(r : BinReader) -> Array[Pat] raise BinaryDeserializeError {
  let n = read_varint(r).to_int()
  let out : Array[Pat] = []
  let mut i = 0
  while i < n {
    out.push(read_pat(r))
    i = i + 1
  }
  out
}

///|
fn read_pat(r : BinReader) -> Pat raise BinaryDeserializeError {
  let tag = read_byte(r)
  match tag {
    b'\x01' => Pat::Wildcard(span=read_span(r))
    b'\x02' => {
      let name = read_string(r)
      let span = read_span(r)
      Pat::Bind(name~, span~)
    }
    b'\x03' => {
      let name = read_string(r)
      let args = read_pat_array(r)
      let span = read_span(r)
      Pat::Ctor(name~, args~, span~)
    }
    b'\x04' => {
      let items = read_pat_array(r)
      let span = read_span(r)
      Pat::Tuple(items~, span~)
    }
    b'\x05' => {
      let fields = read_record_field_pat_array(r)
      let span = read_span(r)
      Pat::Record(fields~, span~)
    }
    b'\x06' => {
      let name = read_string(r)
      let fields = read_record_field_pat_array(r)
      let span = read_span(r)
      Pat::Struct(name~, fields~, span~)
    }
    b'\x07' => {
      let value = read_svarint(r)
      let span = read_span(r)
      Pat::Int(value~, span~)
    }
    b'\x08' => {
      let value = read_f32(r)
      let span = read_span(r)
      Pat::Float(value~, span~)
    }
    b'\x09' => {
      let value = read_f64(r)
      let span = read_span(r)
      Pat::Double(value~, span~)
    }
    b'\x0A' => {
      let value = read_bool(r)
      let span = read_span(r)
      Pat::Bool(value~, span~)
    }
    b'\x0B' => {
      let value = read_char(r)
      let span = read_span(r)
      Pat::Char(value~, span~)
    }
    b'\x0C' => {
      let value = read_string(r)
      let span = read_span(r)
      Pat::String(value~, span~)
    }
    b'\x0D' => {
      let pats = read_pat_array(r)
      let span = read_span(r)
      Pat::Or(pats~, span~)
    }
    _ => raise UnknownTag("Pat", tag)
  }
}

// ---------------------------------------------------------------------------
// Type
// ---------------------------------------------------------------------------

///|
fn read_type_array(r : BinReader) -> Array[Type] raise BinaryDeserializeError {
  let n = read_varint(r).to_int()
  let out : Array[Type] = []
  let mut i = 0
  while i < n {
    out.push(read_type(r))
    i = i + 1
  }
  out
}

///|
fn read_type(r : BinReader) -> Type raise BinaryDeserializeError {
  let tag = read_byte(r)
  match tag {
    b'\x01' => Type::Int
    b'\x02' => Type::Float
    b'\x03' => Type::Double
    b'\x04' => Type::Bool
    b'\x05' => Type::Char
    b'\x06' => Type::String
    b'\x07' => Type::Path
    b'\x08' => Type::PromptText
    b'\x09' => Type::Unit
    b'\x0A' => Type::Infer
    b'\x0B' => Type::Tuple(read_type_array(r))
    b'\x0C' => Type::Record(read_string_type_map(r))
    b'\x0D' => Type::Array(read_type(r))
    b'\x0E' => {
      let k = read_type(r)
      let v = read_type(r)
      Type::Map(k, v)
    }
    b'\x0F' => Type::Set(read_type(r))
    b'\x10' => Type::ArrayBuilder(read_type(r))
    b'\x11' => {
      let k = read_type(r)
      let v = read_type(r)
      Type::MapBuilder(k, v)
    }
    b'\x12' => Type::StringBuilder
    b'\x13' => Type::Bytes
    b'\x14' => Type::V128
    b'\x15' => Type::Variant(read_string_type_map(r))
    b'\x16' => {
      let name = read_string(r)
      let args = read_type_array(r)
      Type::Named(name~, args~)
    }
    b'\x17' => Type::Param(read_string(r))
    b'\x18' => Type::Var(read_svarint(r).to_int())
    b'\x19' => {
      let params = read_func_param_array(r)
      let ret = read_type(r)
      let effects = read_effect_atom_array(r)
      Type::Func(params~, ret~, effects~)
    }
    b'\x1A' => Type::Never
    _ => raise UnknownTag("Type", tag)
  }
}

// ---------------------------------------------------------------------------
// Auxiliary
// ---------------------------------------------------------------------------

///|
fn read_module(r : BinReader) -> Module raise BinaryDeserializeError {
  Module::{ stmts: read_stmt_array(r) }
}

///|
fn read_string_array(r : BinReader) -> Array[String] raise BinaryDeserializeError {
  let n = read_varint(r).to_int()
  let out : Array[String] = []
  let mut i = 0
  while i < n {
    out.push(read_string(r))
    i = i + 1
  }
  out
}

///|
fn read_string_type_map(
  r : BinReader,
) -> Map[String, Type] raise BinaryDeserializeError {
  let n = read_varint(r).to_int()
  let out : Map[String, Type] = {}
  let mut i = 0
  while i < n {
    let k = read_string(r)
    let v = read_type(r)
    out[k] = v
    i = i + 1
  }
  out
}

///|
fn read_type_bounds_map(
  r : BinReader,
) -> Map[String, Array[String]] raise BinaryDeserializeError {
  let n = read_varint(r).to_int()
  let out : Map[String, Array[String]] = {}
  let mut i = 0
  while i < n {
    let k = read_string(r)
    let v = read_string_array(r)
    out[k] = v
    i = i + 1
  }
  out
}

///|
fn read_param_label(
  r : BinReader,
) -> ParamLabel raise BinaryDeserializeError {
  let tag = read_byte(r)
  match tag {
    b'\x01' => ParamLabel::Positional
    b'\x02' => ParamLabel::Variadic
    b'\x03' => ParamLabel::Required
    b'\x04' => ParamLabel::Optional
    _ => raise UnknownTag("ParamLabel", tag)
  }
}

///|
fn read_func_param(r : BinReader) -> FuncParam raise BinaryDeserializeError {
  let name = read_string(r)
  let label = read_param_label(r)
  let ty = read_type(r)
  let bounds = read_string_array(r)
  FuncParam::{ name, label, ty, bounds }
}

///|
fn read_func_param_array(
  r : BinReader,
) -> Array[FuncParam] raise BinaryDeserializeError {
  let n = read_varint(r).to_int()
  let out : Array[FuncParam] = []
  let mut i = 0
  while i < n {
    out.push(read_func_param(r))
    i = i + 1
  }
  out
}

///|
fn read_effect_atom(r : BinReader) -> EffectAtom raise BinaryDeserializeError {
  let tag = read_byte(r)
  match tag {
    b'\x01' => EffectAtom::Const(read_string(r))
    b'\x02' => EffectAtom::Var(read_string(r))
    _ => raise UnknownTag("EffectAtom", tag)
  }
}

///|
fn read_effect_atom_array(
  r : BinReader,
) -> Array[EffectAtom] raise BinaryDeserializeError {
  let n = read_varint(r).to_int()
  let out : Array[EffectAtom] = []
  let mut i = 0
  while i < n {
    out.push(read_effect_atom(r))
    i = i + 1
  }
  out
}

///|
fn read_call_arg(r : BinReader) -> CallArg raise BinaryDeserializeError {
  let label = read_optstr(r)
  let expr = read_expr(r)
  let span = read_span(r)
  CallArg::{ label, expr, span }
}

///|
fn read_call_arg_array(
  r : BinReader,
) -> Array[CallArg] raise BinaryDeserializeError {
  let n = read_varint(r).to_int()
  let out : Array[CallArg] = []
  let mut i = 0
  while i < n {
    out.push(read_call_arg(r))
    i = i + 1
  }
  out
}

///|
fn read_record_field_expr(
  r : BinReader,
) -> RecordFieldExpr raise BinaryDeserializeError {
  let name = read_string(r)
  let expr = read_expr(r)
  let span = read_span(r)
  RecordFieldExpr::{ name, expr, span }
}

///|
fn read_record_field_expr_array(
  r : BinReader,
) -> Array[RecordFieldExpr] raise BinaryDeserializeError {
  let n = read_varint(r).to_int()
  let out : Array[RecordFieldExpr] = []
  let mut i = 0
  while i < n {
    out.push(read_record_field_expr(r))
    i = i + 1
  }
  out
}

///|
fn read_map_field_expr(
  r : BinReader,
) -> MapFieldExpr raise BinaryDeserializeError {
  let key = read_string(r)
  let expr = read_expr(r)
  let span = read_span(r)
  MapFieldExpr::{ key, expr, span }
}

///|
fn read_map_field_expr_array(
  r : BinReader,
) -> Array[MapFieldExpr] raise BinaryDeserializeError {
  let n = read_varint(r).to_int()
  let out : Array[MapFieldExpr] = []
  let mut i = 0
  while i < n {
    out.push(read_map_field_expr(r))
    i = i + 1
  }
  out
}

///|
fn read_record_field_pat(
  r : BinReader,
) -> RecordFieldPat raise BinaryDeserializeError {
  let name = read_string(r)
  let pat = read_pat(r)
  let span = read_span(r)
  RecordFieldPat::{ name, pat, span }
}

///|
fn read_record_field_pat_array(
  r : BinReader,
) -> Array[RecordFieldPat] raise BinaryDeserializeError {
  let n = read_varint(r).to_int()
  let out : Array[RecordFieldPat] = []
  let mut i = 0
  while i < n {
    out.push(read_record_field_pat(r))
    i = i + 1
  }
  out
}

///|
fn read_match_arm(r : BinReader) -> MatchArm raise BinaryDeserializeError {
  let pat = read_pat(r)
  let cond = read_opt_expr(r)
  let expr = read_expr(r)
  let span = read_span(r)
  MatchArm::{ pat, cond, expr, span }
}

///|
fn read_match_arm_array(
  r : BinReader,
) -> Array[MatchArm] raise BinaryDeserializeError {
  let n = read_varint(r).to_int()
  let out : Array[MatchArm] = []
  let mut i = 0
  while i < n {
    out.push(read_match_arm(r))
    i = i + 1
  }
  out
}

///|
fn read_loop_param(r : BinReader) -> LoopParam raise BinaryDeserializeError {
  let name = read_string(r)
  let init = read_expr(r)
  let span = read_span(r)
  LoopParam::{ name, init, span }
}

///|
fn read_loop_param_array(
  r : BinReader,
) -> Array[LoopParam] raise BinaryDeserializeError {
  let n = read_varint(r).to_int()
  let out : Array[LoopParam] = []
  let mut i = 0
  while i < n {
    out.push(read_loop_param(r))
    i = i + 1
  }
  out
}

///|
fn read_type_ctor(r : BinReader) -> TypeCtor raise BinaryDeserializeError {
  let name = read_string(r)
  let args = read_type_array(r)
  let span = read_span(r)
  TypeCtor::{ name, args, span }
}

///|
fn read_type_ctor_array(
  r : BinReader,
) -> Array[TypeCtor] raise BinaryDeserializeError {
  let n = read_varint(r).to_int()
  let out : Array[TypeCtor] = []
  let mut i = 0
  while i < n {
    out.push(read_type_ctor(r))
    i = i + 1
  }
  out
}

///|
fn read_struct_field(
  r : BinReader,
) -> StructField raise BinaryDeserializeError {
  let name = read_string(r)
  let ty = read_type(r)
  let is_mut = read_bool(r)
  let span = read_span(r)
  StructField::{ name, ty, is_mut, span }
}

///|
fn read_struct_field_array(
  r : BinReader,
) -> Array[StructField] raise BinaryDeserializeError {
  let n = read_varint(r).to_int()
  let out : Array[StructField] = []
  let mut i = 0
  while i < n {
    out.push(read_struct_field(r))
    i = i + 1
  }
  out
}

///|
fn read_effect_op(r : BinReader) -> EffectOp raise BinaryDeserializeError {
  let name = read_string(r)
  let params = read_type_array(r)
  let ret = read_type(r)
  let span = read_span(r)
  EffectOp::{ name, params, ret, span }
}

///|
fn read_effect_op_array(
  r : BinReader,
) -> Array[EffectOp] raise BinaryDeserializeError {
  let n = read_varint(r).to_int()
  let out : Array[EffectOp] = []
  let mut i = 0
  while i < n {
    out.push(read_effect_op(r))
    i = i + 1
  }
  out
}

///|
fn read_trait_method(
  r : BinReader,
) -> TraitMethodSig raise BinaryDeserializeError {
  let name = read_string(r)
  let params = read_func_param_array(r)
  let ret = read_type(r)
  let span = read_span(r)
  TraitMethodSig::{ name, params, ret, span }
}

///|
fn read_trait_method_array(
  r : BinReader,
) -> Array[TraitMethodSig] raise BinaryDeserializeError {
  let n = read_varint(r).to_int()
  let out : Array[TraitMethodSig] = []
  let mut i = 0
  while i < n {
    out.push(read_trait_method(r))
    i = i + 1
  }
  out
}

///|
fn read_impl_method(
  r : BinReader,
) -> ImplMethodDef raise BinaryDeserializeError {
  let name = read_string(r)
  let expr = read_expr(r)
  let span = read_span(r)
  ImplMethodDef::{ name, expr, span }
}

///|
fn read_impl_method_array(
  r : BinReader,
) -> Array[ImplMethodDef] raise BinaryDeserializeError {
  let n = read_varint(r).to_int()
  let out : Array[ImplMethodDef] = []
  let mut i = 0
  while i < n {
    out.push(read_impl_method(r))
    i = i + 1
  }
  out
}

///|
fn read_import_kind(r : BinReader) -> ImportKind raise BinaryDeserializeError {
  let tag = read_byte(r)
  match tag {
    b'\x01' => ImportKind::Value
    b'\x02' => ImportKind::Type
    b'\x03' => ImportKind::Struct
    b'\x04' => ImportKind::Trait
    b'\x05' => ImportKind::Effect
    b'\x06' => ImportKind::Suberror
    b'\x07' => ImportKind::Module
    _ => raise UnknownTag("ImportKind", tag)
  }
}

///|
fn read_import_item(r : BinReader) -> ImportItem raise BinaryDeserializeError {
  let kind = read_import_kind(r)
  let name = read_string(r)
  let rename = read_optstr(r)
  ImportItem::{ kind, name, rename }
}

///|
fn read_import_spec(r : BinReader) -> ImportSpec raise BinaryDeserializeError {
  let n = read_varint(r).to_int()
  let items : Array[ImportItem] = []
  let mut i = 0
  while i < n {
    items.push(read_import_item(r))
    i = i + 1
  }
  ImportSpec::{ items, }
}

///|
fn read_module_ref(r : BinReader) -> ModuleRef raise BinaryDeserializeError {
  let tag = read_byte(r)
  match tag {
    b'\x01' => ModuleRef::Path(path=read_string(r))
    b'\x02' => ModuleRef::Hash(hash=read_string(r))
    b'\x03' => ModuleRef::Version(name=read_string(r))
    b'\x04' => ModuleRef::Symbol(name=read_string(r))
    b'\x05' => ModuleRef::Alias(name=read_string(r))
    b'\x06' => {
      let path = read_string(r)
      let hash = read_string(r)
      ModuleRef::PinnedPath(path~, hash~)
    }
    _ => raise UnknownTag("ModuleRef", tag)
  }
}

///|
fn read_string_interp_part(
  r : BinReader,
) -> StringInterpPart raise BinaryDeserializeError {
  let tag = read_byte(r)
  match tag {
    b'\x01' => StringInterpPart::Lit(read_string(r))
    b'\x02' => StringInterpPart::Expr(read_expr(r))
    _ => raise UnknownTag("StringInterpPart", tag)
  }
}
