// Public binary-codec facade over the private `@core` serializer primitives.
//
// The AST serializer (`serialize_binary.mbt` / `deserialize_binary.mbt`)
// already implements a battle-tested encoding for `@core.Type` and the
// LEB128 primitives, but those functions are private to this package. The
// checker's TypeEnv snapshot serializer (issue #476) needs to reuse the
// SAME `Type` encoding rather than duplicate a second copy that could drift.
//
// This facade exposes a deliberately small, purpose-built surface — a
// streaming writer and reader — that wraps the private primitives so other
// packages can compose `Type` values into their own binary records without
// seeing the rest of the serializer internals.

///|
/// Streaming binary writer. Wraps a `@buffer.Buffer` and the package-private
/// encoding primitives.
pub struct TypeBinWriter {
  priv buf : @buffer.Buffer
}

///|
pub fn TypeBinWriter::new() -> TypeBinWriter {
  { buf: @buffer.Buffer(size_hint=4096) }
}

///|
/// Unsigned LEB128 of a non-negative int (counts, tags, lengths).
pub fn TypeBinWriter::uint(self : TypeBinWriter, v : Int) -> Unit {
  write_varint_int(self.buf, v)
}

///|
/// Signed LEB128 of an int that may be negative.
pub fn TypeBinWriter::int(self : TypeBinWriter, v : Int) -> Unit {
  write_svarint(self.buf, v.to_int64())
}

///|
pub fn TypeBinWriter::bool(self : TypeBinWriter, v : Bool) -> Unit {
  write_bool(self.buf, v)
}

///|
pub fn TypeBinWriter::str(self : TypeBinWriter, s : String) -> Unit {
  write_string(self.buf, s)
}

///|
pub fn TypeBinWriter::optstr(self : TypeBinWriter, s : String?) -> Unit {
  write_optstr(self.buf, s)
}

///|
/// Encode a `@core.Type` using the canonical AST wire encoding.
pub fn TypeBinWriter::ty(self : TypeBinWriter, t : Type) -> Unit {
  write_type(self.buf, t)
}

///|
pub fn TypeBinWriter::to_bytes(self : TypeBinWriter) -> Bytes {
  self.buf.to_bytes()
}

///|
/// Streaming binary reader. Wraps the package-private `BinReader`. All reads
/// raise `BinaryDeserializeError` on underrun / malformed input, matching the
/// AST deserializer's contract.
pub struct TypeBinReader {
  priv r : BinReader
}

///|
pub fn TypeBinReader::new(bytes : Bytes) -> TypeBinReader {
  { r: BinReader::new(bytes) }
}

///|
pub fn TypeBinReader::uint(
  self : TypeBinReader,
) -> Int raise BinaryDeserializeError {
  read_varint(self.r).to_int()
}

///|
pub fn TypeBinReader::int(
  self : TypeBinReader,
) -> Int raise BinaryDeserializeError {
  read_svarint(self.r).to_int()
}

///|
pub fn TypeBinReader::bool(
  self : TypeBinReader,
) -> Bool raise BinaryDeserializeError {
  read_bool(self.r)
}

///|
pub fn TypeBinReader::str(
  self : TypeBinReader,
) -> String raise BinaryDeserializeError {
  read_string(self.r)
}

///|
pub fn TypeBinReader::optstr(
  self : TypeBinReader,
) -> String? raise BinaryDeserializeError {
  read_optstr(self.r)
}

///|
pub fn TypeBinReader::ty(
  self : TypeBinReader,
) -> Type raise BinaryDeserializeError {
  read_type(self.r)
}

///|
pub fn TypeBinReader::remaining(self : TypeBinReader) -> Int {
  self.r.remaining()
}
