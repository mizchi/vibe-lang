///|
/// Auto-generated FlatBuffers code
/// DO NOT EDIT

///|
/// FbString reader
pub struct FbString {
  table : @flatbuffers.Table
}

///|
pub fn FbString::from_buffer(buf : @flatbuffers.ByteBuffer) -> FbString {
  { table: @flatbuffers.Table::get_root(buf) }
}

///|
pub fn FbString::value(self : FbString) -> String {
  self.table.get_string(0, "")
}

///|
/// FbString builder
pub struct FbStringBuilder {
  builder : @flatbuffers.Builder
  string_offsets : Map[String, Int]
  vector_offsets : Map[String, Int]
}

///|
pub fn FbStringBuilder::new(builder : @flatbuffers.Builder) -> FbStringBuilder {
  { builder, string_offsets: {}, vector_offsets: {} }
}

///|
pub fn FbStringBuilder::set_value(
  self : FbStringBuilder,
  value : String,
) -> FbStringBuilder {
  let offset = self.builder.create_string(value)
  self.string_offsets.set("value", offset)
  self
}

///|
pub fn FbStringBuilder::start(self : FbStringBuilder) -> Unit {
  self.builder.start_object(1)
}

///|
pub fn FbStringBuilder::finish_fields(self : FbStringBuilder) -> Unit {
  match self.string_offsets.get("value") {
    Some(offset) => self.builder.add_offset(0, offset)
    None => ()
  }
}

///|
pub fn FbStringBuilder::end(self : FbStringBuilder) -> Int {
  self.finish_fields()
  self.builder.end_object()
}

///|
pub fn FbStringBuilder::finish(self : FbStringBuilder) -> Unit {
  let offset = self.end()
  self.builder.finish(offset)
}

///|
/// FbDef reader
pub struct FbDef {
  table : @flatbuffers.Table
}

///|
pub fn FbDef::from_buffer(buf : @flatbuffers.ByteBuffer) -> FbDef {
  { table: @flatbuffers.Table::get_root(buf) }
}

///|
pub fn FbDef::def_id(self : FbDef) -> Int {
  self.table.get_int32(0, 0)
}

///|
pub fn FbDef::name(self : FbDef) -> Int {
  self.table.get_int32(1, 0)
}

///|
pub fn FbDef::kind(self : FbDef) -> Int {
  self.table.get_int32(2, 0)
}

///|
pub fn FbDef::signature(self : FbDef) -> Int {
  self.table.get_int32(3, 0)
}

///|
pub fn FbDef::path(self : FbDef) -> Int {
  self.table.get_int32(4, 0)
}

///|
pub fn FbDef::start(self : FbDef) -> Int {
  self.table.get_int32(5, 0)
}

///|
pub fn FbDef::end(self : FbDef) -> Int {
  self.table.get_int32(6, 0)
}

///|
pub fn FbDef::module_hash(self : FbDef) -> Int {
  self.table.get_int32(7, 0)
}

///|
pub fn FbDef::language_id(self : FbDef) -> Int {
  self.table.get_int32(8, 0)
}

///|
/// FbDef builder
pub struct FbDefBuilder {
  builder : @flatbuffers.Builder
  string_offsets : Map[String, Int]
  vector_offsets : Map[String, Int]
}

///|
pub fn FbDefBuilder::new(builder : @flatbuffers.Builder) -> FbDefBuilder {
  { builder, string_offsets: {}, vector_offsets: {} }
}

///|
pub fn FbDefBuilder::start(self : FbDefBuilder) -> Unit {
  self.builder.start_object(9)
}

///|
pub fn FbDefBuilder::add_def_id(
  self : FbDefBuilder,
  value : Int,
) -> FbDefBuilder {
  self.builder.add_int32(0, value, 0)
  self
}

///|
pub fn FbDefBuilder::add_name(self : FbDefBuilder, value : Int) -> FbDefBuilder {
  self.builder.add_int32(1, value, 0)
  self
}

///|
pub fn FbDefBuilder::add_kind(self : FbDefBuilder, value : Int) -> FbDefBuilder {
  self.builder.add_int32(2, value, 0)
  self
}

///|
pub fn FbDefBuilder::add_signature(
  self : FbDefBuilder,
  value : Int,
) -> FbDefBuilder {
  self.builder.add_int32(3, value, 0)
  self
}

///|
pub fn FbDefBuilder::add_path(self : FbDefBuilder, value : Int) -> FbDefBuilder {
  self.builder.add_int32(4, value, 0)
  self
}

///|
pub fn FbDefBuilder::add_start(
  self : FbDefBuilder,
  value : Int,
) -> FbDefBuilder {
  self.builder.add_int32(5, value, 0)
  self
}

///|
pub fn FbDefBuilder::add_end(self : FbDefBuilder, value : Int) -> FbDefBuilder {
  self.builder.add_int32(6, value, 0)
  self
}

///|
pub fn FbDefBuilder::add_module_hash(
  self : FbDefBuilder,
  value : Int,
) -> FbDefBuilder {
  self.builder.add_int32(7, value, 0)
  self
}

///|
pub fn FbDefBuilder::add_language_id(
  self : FbDefBuilder,
  value : Int,
) -> FbDefBuilder {
  self.builder.add_int32(8, value, 0)
  self
}

///|
pub fn FbDefBuilder::finish_fields(self : FbDefBuilder) -> Unit {
  ignore(self)
}

///|
pub fn FbDefBuilder::end(self : FbDefBuilder) -> Int {
  self.finish_fields()
  self.builder.end_object()
}

///|
pub fn FbDefBuilder::finish(self : FbDefBuilder) -> Unit {
  let offset = self.end()
  self.builder.finish(offset)
}

///|
/// FbIndexEntry reader
pub struct FbIndexEntry {
  table : @flatbuffers.Table
}

///|
pub fn FbIndexEntry::from_buffer(buf : @flatbuffers.ByteBuffer) -> FbIndexEntry {
  { table: @flatbuffers.Table::get_root(buf) }
}

///|
pub fn FbIndexEntry::key(self : FbIndexEntry) -> Int {
  self.table.get_int32(0, 0)
}

///|
pub fn FbIndexEntry::values_length(self : FbIndexEntry) -> Int {
  self.table.get_vector_length(1)
}

///|
pub fn FbIndexEntry::values(self : FbIndexEntry, index : Int) -> Int {
  self.table.get_vector_int32(1, index)
}

///|
/// FbIndexEntry builder
pub struct FbIndexEntryBuilder {
  builder : @flatbuffers.Builder
  string_offsets : Map[String, Int]
  vector_offsets : Map[String, Int]
}

///|
pub fn FbIndexEntryBuilder::new(
  builder : @flatbuffers.Builder,
) -> FbIndexEntryBuilder {
  { builder, string_offsets: {}, vector_offsets: {} }
}

///|
pub fn FbIndexEntryBuilder::set_values_offset(
  self : FbIndexEntryBuilder,
  offset : Int,
) -> FbIndexEntryBuilder {
  self.vector_offsets.set("values", offset)
  self
}

///|
pub fn FbIndexEntryBuilder::start(self : FbIndexEntryBuilder) -> Unit {
  self.builder.start_object(2)
}

///|
pub fn FbIndexEntryBuilder::add_key(
  self : FbIndexEntryBuilder,
  value : Int,
) -> FbIndexEntryBuilder {
  self.builder.add_int32(0, value, 0)
  self
}

///|
pub fn FbIndexEntryBuilder::finish_fields(self : FbIndexEntryBuilder) -> Unit {
  match self.vector_offsets.get("values") {
    Some(offset) => self.builder.add_offset(1, offset)
    None => ()
  }
}

///|
pub fn FbIndexEntryBuilder::end(self : FbIndexEntryBuilder) -> Int {
  self.finish_fields()
  self.builder.end_object()
}

///|
pub fn FbIndexEntryBuilder::finish(self : FbIndexEntryBuilder) -> Unit {
  let offset = self.end()
  self.builder.finish(offset)
}

///|
/// FbIndex reader
pub struct FbIndex {
  table : @flatbuffers.Table
}

///|
pub fn FbIndex::from_buffer(buf : @flatbuffers.ByteBuffer) -> FbIndex {
  { table: @flatbuffers.Table::get_root(buf) }
}

///|
pub fn FbIndex::schema_version(self : FbIndex) -> Int {
  self.table.get_int32(0, 0)
}

///|
pub fn FbIndex::base_commit(self : FbIndex) -> Int {
  self.table.get_int32(1, 0)
}

///|
pub fn FbIndex::created_at(self : FbIndex) -> Int {
  self.table.get_int32(2, 0)
}

///|
pub fn FbIndex::features_length(self : FbIndex) -> Int {
  self.table.get_vector_length(3)
}

///|
pub fn FbIndex::features(self : FbIndex, index : Int) -> Int {
  self.table.get_vector_int32(3, index)
}

///|
pub fn FbIndex::chunk_roots_length(self : FbIndex) -> Int {
  self.table.get_vector_length(4)
}

///|
pub fn FbIndex::chunk_roots(self : FbIndex, index : Int) -> Int {
  self.table.get_vector_int32(4, index)
}

///|
pub fn FbIndex::defs_length(self : FbIndex) -> Int {
  self.table.get_vector_length(5)
}

///|
pub fn FbIndex::defs_table(self : FbIndex, index : Int) -> @flatbuffers.Table? {
  self.table.get_vector_table(5, index)
}

///|
pub fn FbIndex::symbol_index_length(self : FbIndex) -> Int {
  self.table.get_vector_length(6)
}

///|
pub fn FbIndex::symbol_index_table(
  self : FbIndex,
  index : Int,
) -> @flatbuffers.Table? {
  self.table.get_vector_table(6, index)
}

///|
pub fn FbIndex::type_index_length(self : FbIndex) -> Int {
  self.table.get_vector_length(7)
}

///|
pub fn FbIndex::type_index_table(
  self : FbIndex,
  index : Int,
) -> @flatbuffers.Table? {
  self.table.get_vector_table(7, index)
}

///|
pub fn FbIndex::strings_length(self : FbIndex) -> Int {
  self.table.get_vector_length(8)
}

///|
pub fn FbIndex::strings_table(
  self : FbIndex,
  index : Int,
) -> @flatbuffers.Table? {
  self.table.get_vector_table(8, index)
}

///|
pub fn FbIndex::language_ids_length(self : FbIndex) -> Int {
  self.table.get_vector_length(9)
}

///|
pub fn FbIndex::language_ids(self : FbIndex, index : Int) -> Int {
  self.table.get_vector_int32(9, index)
}

///|
/// FbIndex builder
pub struct FbIndexBuilder {
  builder : @flatbuffers.Builder
  string_offsets : Map[String, Int]
  vector_offsets : Map[String, Int]
}

///|
pub fn FbIndexBuilder::new(builder : @flatbuffers.Builder) -> FbIndexBuilder {
  { builder, string_offsets: {}, vector_offsets: {} }
}

///|
pub fn FbIndexBuilder::set_features_offset(
  self : FbIndexBuilder,
  offset : Int,
) -> FbIndexBuilder {
  self.vector_offsets.set("features", offset)
  self
}

///|
pub fn FbIndexBuilder::set_chunk_roots_offset(
  self : FbIndexBuilder,
  offset : Int,
) -> FbIndexBuilder {
  self.vector_offsets.set("chunk_roots", offset)
  self
}

///|
pub fn FbIndexBuilder::set_defs_offset(
  self : FbIndexBuilder,
  offset : Int,
) -> FbIndexBuilder {
  self.vector_offsets.set("defs", offset)
  self
}

///|
pub fn FbIndexBuilder::set_symbol_index_offset(
  self : FbIndexBuilder,
  offset : Int,
) -> FbIndexBuilder {
  self.vector_offsets.set("symbol_index", offset)
  self
}

///|
pub fn FbIndexBuilder::set_type_index_offset(
  self : FbIndexBuilder,
  offset : Int,
) -> FbIndexBuilder {
  self.vector_offsets.set("type_index", offset)
  self
}

///|
pub fn FbIndexBuilder::set_strings_offset(
  self : FbIndexBuilder,
  offset : Int,
) -> FbIndexBuilder {
  self.vector_offsets.set("strings", offset)
  self
}

///|
pub fn FbIndexBuilder::set_language_ids_offset(
  self : FbIndexBuilder,
  offset : Int,
) -> FbIndexBuilder {
  self.vector_offsets.set("language_ids", offset)
  self
}

///|
pub fn FbIndexBuilder::start(self : FbIndexBuilder) -> Unit {
  self.builder.start_object(10)
}

///|
pub fn FbIndexBuilder::add_schema_version(
  self : FbIndexBuilder,
  value : Int,
) -> FbIndexBuilder {
  self.builder.add_int32(0, value, 0)
  self
}

///|
pub fn FbIndexBuilder::add_base_commit(
  self : FbIndexBuilder,
  value : Int,
) -> FbIndexBuilder {
  self.builder.add_int32(1, value, 0)
  self
}

///|
pub fn FbIndexBuilder::add_created_at(
  self : FbIndexBuilder,
  value : Int,
) -> FbIndexBuilder {
  self.builder.add_int32(2, value, 0)
  self
}

///|
pub fn FbIndexBuilder::finish_fields(self : FbIndexBuilder) -> Unit {
  match self.vector_offsets.get("features") {
    Some(offset) => self.builder.add_offset(3, offset)
    None => ()
  }
  match self.vector_offsets.get("chunk_roots") {
    Some(offset) => self.builder.add_offset(4, offset)
    None => ()
  }
  match self.vector_offsets.get("defs") {
    Some(offset) => self.builder.add_offset(5, offset)
    None => ()
  }
  match self.vector_offsets.get("symbol_index") {
    Some(offset) => self.builder.add_offset(6, offset)
    None => ()
  }
  match self.vector_offsets.get("type_index") {
    Some(offset) => self.builder.add_offset(7, offset)
    None => ()
  }
  match self.vector_offsets.get("strings") {
    Some(offset) => self.builder.add_offset(8, offset)
    None => ()
  }
  match self.vector_offsets.get("language_ids") {
    Some(offset) => self.builder.add_offset(9, offset)
    None => ()
  }
}

///|
pub fn FbIndexBuilder::end(self : FbIndexBuilder) -> Int {
  self.finish_fields()
  self.builder.end_object()
}

///|
pub fn FbIndexBuilder::finish(self : FbIndexBuilder) -> Unit {
  let offset = self.end()
  self.builder.finish(offset)
}

///|
/// FbDelta reader
pub struct FbDelta {
  table : @flatbuffers.Table
}

///|
pub fn FbDelta::from_buffer(buf : @flatbuffers.ByteBuffer) -> FbDelta {
  { table: @flatbuffers.Table::get_root(buf) }
}

///|
pub fn FbDelta::schema_version(self : FbDelta) -> Int {
  self.table.get_int32(0, 0)
}

///|
pub fn FbDelta::base_schema_version(self : FbDelta) -> Int {
  self.table.get_int32(1, 0)
}

///|
pub fn FbDelta::base_base_commit(self : FbDelta) -> Int {
  self.table.get_int32(2, 0)
}

///|
pub fn FbDelta::base_created_at(self : FbDelta) -> Int {
  self.table.get_int32(3, 0)
}

///|
pub fn FbDelta::base_features_length(self : FbDelta) -> Int {
  self.table.get_vector_length(4)
}

///|
pub fn FbDelta::base_features(self : FbDelta, index : Int) -> Int {
  self.table.get_vector_int32(4, index)
}

///|
pub fn FbDelta::base_chunk_roots_length(self : FbDelta) -> Int {
  self.table.get_vector_length(5)
}

///|
pub fn FbDelta::base_chunk_roots(self : FbDelta, index : Int) -> Int {
  self.table.get_vector_int32(5, index)
}

///|
pub fn FbDelta::target_schema_version(self : FbDelta) -> Int {
  self.table.get_int32(6, 0)
}

///|
pub fn FbDelta::target_base_commit(self : FbDelta) -> Int {
  self.table.get_int32(7, 0)
}

///|
pub fn FbDelta::target_created_at(self : FbDelta) -> Int {
  self.table.get_int32(8, 0)
}

///|
pub fn FbDelta::target_features_length(self : FbDelta) -> Int {
  self.table.get_vector_length(9)
}

///|
pub fn FbDelta::target_features(self : FbDelta, index : Int) -> Int {
  self.table.get_vector_int32(9, index)
}

///|
pub fn FbDelta::target_chunk_roots_length(self : FbDelta) -> Int {
  self.table.get_vector_length(10)
}

///|
pub fn FbDelta::target_chunk_roots(self : FbDelta, index : Int) -> Int {
  self.table.get_vector_int32(10, index)
}

///|
pub fn FbDelta::removed_def_ids_length(self : FbDelta) -> Int {
  self.table.get_vector_length(11)
}

///|
pub fn FbDelta::removed_def_ids(self : FbDelta, index : Int) -> Int {
  self.table.get_vector_int32(11, index)
}

///|
pub fn FbDelta::upsert_defs_length(self : FbDelta) -> Int {
  self.table.get_vector_length(12)
}

///|
pub fn FbDelta::upsert_defs_table(
  self : FbDelta,
  index : Int,
) -> @flatbuffers.Table? {
  self.table.get_vector_table(12, index)
}

///|
pub fn FbDelta::symbol_upserts_length(self : FbDelta) -> Int {
  self.table.get_vector_length(13)
}

///|
pub fn FbDelta::symbol_upserts_table(
  self : FbDelta,
  index : Int,
) -> @flatbuffers.Table? {
  self.table.get_vector_table(13, index)
}

///|
pub fn FbDelta::symbol_removes_length(self : FbDelta) -> Int {
  self.table.get_vector_length(14)
}

///|
pub fn FbDelta::symbol_removes(self : FbDelta, index : Int) -> Int {
  self.table.get_vector_int32(14, index)
}

///|
pub fn FbDelta::type_upserts_length(self : FbDelta) -> Int {
  self.table.get_vector_length(15)
}

///|
pub fn FbDelta::type_upserts_table(
  self : FbDelta,
  index : Int,
) -> @flatbuffers.Table? {
  self.table.get_vector_table(15, index)
}

///|
pub fn FbDelta::type_removes_length(self : FbDelta) -> Int {
  self.table.get_vector_length(16)
}

///|
pub fn FbDelta::type_removes(self : FbDelta, index : Int) -> Int {
  self.table.get_vector_int32(16, index)
}

///|
pub fn FbDelta::strings_length(self : FbDelta) -> Int {
  self.table.get_vector_length(17)
}

///|
pub fn FbDelta::strings_table(
  self : FbDelta,
  index : Int,
) -> @flatbuffers.Table? {
  self.table.get_vector_table(17, index)
}

///|
pub fn FbDelta::base_language_ids_length(self : FbDelta) -> Int {
  self.table.get_vector_length(18)
}

///|
pub fn FbDelta::base_language_ids(self : FbDelta, index : Int) -> Int {
  self.table.get_vector_int32(18, index)
}

///|
pub fn FbDelta::target_language_ids_length(self : FbDelta) -> Int {
  self.table.get_vector_length(19)
}

///|
pub fn FbDelta::target_language_ids(self : FbDelta, index : Int) -> Int {
  self.table.get_vector_int32(19, index)
}

///|
/// FbDelta builder
pub struct FbDeltaBuilder {
  builder : @flatbuffers.Builder
  string_offsets : Map[String, Int]
  vector_offsets : Map[String, Int]
}

///|
pub fn FbDeltaBuilder::new(builder : @flatbuffers.Builder) -> FbDeltaBuilder {
  { builder, string_offsets: {}, vector_offsets: {} }
}

///|
pub fn FbDeltaBuilder::set_base_features_offset(
  self : FbDeltaBuilder,
  offset : Int,
) -> FbDeltaBuilder {
  self.vector_offsets.set("base_features", offset)
  self
}

///|
pub fn FbDeltaBuilder::set_base_chunk_roots_offset(
  self : FbDeltaBuilder,
  offset : Int,
) -> FbDeltaBuilder {
  self.vector_offsets.set("base_chunk_roots", offset)
  self
}

///|
pub fn FbDeltaBuilder::set_target_features_offset(
  self : FbDeltaBuilder,
  offset : Int,
) -> FbDeltaBuilder {
  self.vector_offsets.set("target_features", offset)
  self
}

///|
pub fn FbDeltaBuilder::set_target_chunk_roots_offset(
  self : FbDeltaBuilder,
  offset : Int,
) -> FbDeltaBuilder {
  self.vector_offsets.set("target_chunk_roots", offset)
  self
}

///|
pub fn FbDeltaBuilder::set_removed_def_ids_offset(
  self : FbDeltaBuilder,
  offset : Int,
) -> FbDeltaBuilder {
  self.vector_offsets.set("removed_def_ids", offset)
  self
}

///|
pub fn FbDeltaBuilder::set_upsert_defs_offset(
  self : FbDeltaBuilder,
  offset : Int,
) -> FbDeltaBuilder {
  self.vector_offsets.set("upsert_defs", offset)
  self
}

///|
pub fn FbDeltaBuilder::set_symbol_upserts_offset(
  self : FbDeltaBuilder,
  offset : Int,
) -> FbDeltaBuilder {
  self.vector_offsets.set("symbol_upserts", offset)
  self
}

///|
pub fn FbDeltaBuilder::set_symbol_removes_offset(
  self : FbDeltaBuilder,
  offset : Int,
) -> FbDeltaBuilder {
  self.vector_offsets.set("symbol_removes", offset)
  self
}

///|
pub fn FbDeltaBuilder::set_type_upserts_offset(
  self : FbDeltaBuilder,
  offset : Int,
) -> FbDeltaBuilder {
  self.vector_offsets.set("type_upserts", offset)
  self
}

///|
pub fn FbDeltaBuilder::set_type_removes_offset(
  self : FbDeltaBuilder,
  offset : Int,
) -> FbDeltaBuilder {
  self.vector_offsets.set("type_removes", offset)
  self
}

///|
pub fn FbDeltaBuilder::set_strings_offset(
  self : FbDeltaBuilder,
  offset : Int,
) -> FbDeltaBuilder {
  self.vector_offsets.set("strings", offset)
  self
}

///|
pub fn FbDeltaBuilder::set_base_language_ids_offset(
  self : FbDeltaBuilder,
  offset : Int,
) -> FbDeltaBuilder {
  self.vector_offsets.set("base_language_ids", offset)
  self
}

///|
pub fn FbDeltaBuilder::set_target_language_ids_offset(
  self : FbDeltaBuilder,
  offset : Int,
) -> FbDeltaBuilder {
  self.vector_offsets.set("target_language_ids", offset)
  self
}

///|
pub fn FbDeltaBuilder::start(self : FbDeltaBuilder) -> Unit {
  self.builder.start_object(20)
}

///|
pub fn FbDeltaBuilder::add_schema_version(
  self : FbDeltaBuilder,
  value : Int,
) -> FbDeltaBuilder {
  self.builder.add_int32(0, value, 0)
  self
}

///|
pub fn FbDeltaBuilder::add_base_schema_version(
  self : FbDeltaBuilder,
  value : Int,
) -> FbDeltaBuilder {
  self.builder.add_int32(1, value, 0)
  self
}

///|
pub fn FbDeltaBuilder::add_base_base_commit(
  self : FbDeltaBuilder,
  value : Int,
) -> FbDeltaBuilder {
  self.builder.add_int32(2, value, 0)
  self
}

///|
pub fn FbDeltaBuilder::add_base_created_at(
  self : FbDeltaBuilder,
  value : Int,
) -> FbDeltaBuilder {
  self.builder.add_int32(3, value, 0)
  self
}

///|
pub fn FbDeltaBuilder::add_target_schema_version(
  self : FbDeltaBuilder,
  value : Int,
) -> FbDeltaBuilder {
  self.builder.add_int32(6, value, 0)
  self
}

///|
pub fn FbDeltaBuilder::add_target_base_commit(
  self : FbDeltaBuilder,
  value : Int,
) -> FbDeltaBuilder {
  self.builder.add_int32(7, value, 0)
  self
}

///|
pub fn FbDeltaBuilder::add_target_created_at(
  self : FbDeltaBuilder,
  value : Int,
) -> FbDeltaBuilder {
  self.builder.add_int32(8, value, 0)
  self
}

///|
pub fn FbDeltaBuilder::finish_fields(self : FbDeltaBuilder) -> Unit {
  match self.vector_offsets.get("base_features") {
    Some(offset) => self.builder.add_offset(4, offset)
    None => ()
  }
  match self.vector_offsets.get("base_chunk_roots") {
    Some(offset) => self.builder.add_offset(5, offset)
    None => ()
  }
  match self.vector_offsets.get("target_features") {
    Some(offset) => self.builder.add_offset(9, offset)
    None => ()
  }
  match self.vector_offsets.get("target_chunk_roots") {
    Some(offset) => self.builder.add_offset(10, offset)
    None => ()
  }
  match self.vector_offsets.get("removed_def_ids") {
    Some(offset) => self.builder.add_offset(11, offset)
    None => ()
  }
  match self.vector_offsets.get("upsert_defs") {
    Some(offset) => self.builder.add_offset(12, offset)
    None => ()
  }
  match self.vector_offsets.get("symbol_upserts") {
    Some(offset) => self.builder.add_offset(13, offset)
    None => ()
  }
  match self.vector_offsets.get("symbol_removes") {
    Some(offset) => self.builder.add_offset(14, offset)
    None => ()
  }
  match self.vector_offsets.get("type_upserts") {
    Some(offset) => self.builder.add_offset(15, offset)
    None => ()
  }
  match self.vector_offsets.get("type_removes") {
    Some(offset) => self.builder.add_offset(16, offset)
    None => ()
  }
  match self.vector_offsets.get("strings") {
    Some(offset) => self.builder.add_offset(17, offset)
    None => ()
  }
  match self.vector_offsets.get("base_language_ids") {
    Some(offset) => self.builder.add_offset(18, offset)
    None => ()
  }
  match self.vector_offsets.get("target_language_ids") {
    Some(offset) => self.builder.add_offset(19, offset)
    None => ()
  }
}

///|
pub fn FbDeltaBuilder::end(self : FbDeltaBuilder) -> Int {
  self.finish_fields()
  self.builder.end_object()
}

///|
pub fn FbDeltaBuilder::finish(self : FbDeltaBuilder) -> Unit {
  let offset = self.end()
  self.builder.finish(offset)
}
