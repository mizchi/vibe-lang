///|
struct BenchCase {
  name : String
  expr : String
} derive(Debug, Eq)

///|
fn is_valid_bench_case_name(name : String) -> Bool {
  if name.length() == 0 {
    return false
  }
  let mut first = true
  for _, c in name {
    if first {
      first = false
      if !(Char::is_ascii_alphabetic(c) || c == '_') {
        return false
      }
      continue
    }
    if !((Char::is_ascii_alphabetic(c) || Char::is_ascii_digit(c)) ||
      c == '_' ||
      c == '-') {
      return false
    }
  }
  true
}

///|
pub fn parse_bench_case_arg(
  raw : String,
  case_index : Int,
) -> Result[BenchCase, String] {
  let trimmed = raw.trim().to_owned()
  if trimmed.length() == 0 {
    return Err("empty case expression")
  }
  let mut eq_pos : Int? = None
  for i, c in trimmed {
    if c == '=' {
      eq_pos = Some(i)
      break
    }
  }
  match eq_pos {
    Some(pos) => {
      if pos <= 0 || pos + 1 >= trimmed.length() {
        return Ok({ name: "case" + case_index.to_string(), expr: trimmed })
      }
      let left = trimmed.unsafe_substring(start=0, end=pos).trim().to_owned()
      let right = trimmed
        .unsafe_substring(start=pos + 1, end=trimmed.length())
        .trim()
        .to_owned()
      if right.length() == 0 ||
        right.has_prefix("=") ||
        !is_valid_bench_case_name(left) {
        return Ok({ name: "case" + case_index.to_string(), expr: trimmed })
      }
      Ok({ name: left, expr: right })
    }
    None => Ok({ name: "case" + case_index.to_string(), expr: trimmed })
  }
}

///|
pub fn parse_bench_case_source(
  source : String,
  start_case_index : Int,
) -> Result[Array[BenchCase], String] {
  let out : Array[BenchCase] = []
  let mut next_case_index = start_case_index
  let mut line_no = 0
  for line_view in source.split("\n") {
    line_no += 1
    let line = line_view.to_owned().trim().to_owned()
    if line.length() == 0 || line.has_prefix("#") {
      continue
    }
    match parse_bench_case_arg(line, next_case_index) {
      Ok(case_item) => {
        out.push(case_item)
        next_case_index += 1
      }
      Err(msg) => return Err("line " + line_no.to_string() + ": " + msg)
    }
  }
  Ok(out)
}
