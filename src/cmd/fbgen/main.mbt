///|
fn postprocess_generated(src : String) -> String {
  let lines : Array[String] = []
  for line_view in src.split("\n") {
    lines.push(line_view.to_string())
  }
  let out = StringBuilder::new()
  for i in 0..<lines.length() {
    out.write_string(lines[i])
    if lines[i].contains("::finish_fields(self : FbDefBuilder) -> Unit {") {
      out.write_char('\n')
      out.write_string("  ignore(self)")
    }
    if i + 1 < lines.length() {
      out.write_char('\n')
    }
  }
  out.to_string()
}

///|
fn main {
  let schema_src = @os_fs.read_file_to_string(
    "src/xsh/advanced_graph_flatbuffers.fbs",
  ) catch {
    e => abort("read schema failed: " + e.to_string())
  }
  let schema = @flatbuffers.parse_schema(schema_src)
  let generated = postprocess_generated(@flatbuffers.generate_moonbit(schema))
  @os_fs.write_string_to_file(
    "src/xsh/advanced_graph_flatbuffers_generated.mbt", generated,
  ) catch {
    e => abort("write generated failed: " + e.to_string())
  }
}
