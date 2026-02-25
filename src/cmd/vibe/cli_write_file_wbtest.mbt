///|
fn wbtest_make_candidate(
  origin : String,
  name : String,
  path : String,
  def_id : String,
) -> WriteFileCandidate {
  {
    origin,
    def: {
      def_id,
      name,
      kind: "value",
      signature: "sig",
      path,
      start: 0,
      end: 0,
      module_hash: "m",
    },
  }
}

///|
fn write_file_wbtest_substring_index(haystack : String, needle : String) -> Int {
  if needle.length() == 0 {
    return 0
  }
  if needle.length() > haystack.length() {
    return -1
  }
  let max_start = haystack.length() - needle.length()
  for i = 0; i <= max_start; i = i + 1 {
    if haystack.unsafe_substring(start=i, end=i + needle.length()) == needle {
      return i
    }
  }
  -1
}

///|
test "write_file ambiguous error sorts candidates deterministically" {
  let b = wbtest_make_candidate(
    "index",
    "foo",
    "/b.vibe",
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  )
  let a = wbtest_make_candidate(
    "index",
    "foo",
    "/a.vibe",
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  )
  let msg = write_file_ambiguous_error("ambiguous", [b, a])
  let pos_a = write_file_wbtest_substring_index(
    msg,
    "/a.vibe#",
  )
  let pos_b = write_file_wbtest_substring_index(
    msg,
    "/b.vibe#",
  )
  assert_true(pos_a >= 0)
  assert_true(pos_b >= 0)
  assert_true(pos_a < pos_b)
}
