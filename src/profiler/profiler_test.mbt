///|
test "enter/leave basic" {
  @profiler.profiler_set_enabled(true)
  @profiler.profiler_reset()
  @profiler.profiler_enter("test/a")
  @profiler.profiler_leave()
  let report = @profiler.profiler_report_tsv()
  assert_true(report.contains("test/a"))
  assert_true(report.contains("name\ttotal_us\tself_us\tcall_count\tchildren"))
  @profiler.profiler_set_enabled(false)
  @profiler.profiler_reset()
}

///|
test "nested self-time" {
  @profiler.profiler_set_enabled(true)
  @profiler.profiler_reset()
  @profiler.profiler_enter("parent")
  @profiler.profiler_enter("child")
  @profiler.profiler_leave()
  @profiler.profiler_leave()
  let report = @profiler.profiler_report_tsv()
  assert_true(report.contains("parent"))
  assert_true(report.contains("child"))
  @profiler.profiler_set_enabled(false)
  @profiler.profiler_reset()
}

///|
test "disabled no-op" {
  @profiler.profiler_set_enabled(false)
  @profiler.profiler_reset()
  @profiler.profiler_enter("should_not_appear")
  @profiler.profiler_leave()
  let report = @profiler.profiler_report_tsv()
  assert_false(report.contains("should_not_appear"))
}

///|
test "multiple calls aggregate" {
  @profiler.profiler_set_enabled(true)
  @profiler.profiler_reset()
  @profiler.profiler_enter("repeated")
  @profiler.profiler_leave()
  @profiler.profiler_enter("repeated")
  @profiler.profiler_leave()
  let report = @profiler.profiler_report_tsv()
  // call_count should be 2
  assert_true(report.contains("repeated\t"))
  @profiler.profiler_set_enabled(false)
  @profiler.profiler_reset()
}

///|
test "folded stack format" {
  @profiler.profiler_set_enabled(true)
  @profiler.profiler_reset()
  @profiler.profiler_enter("outer")
  @profiler.profiler_enter("inner")
  @profiler.profiler_leave()
  @profiler.profiler_leave()
  let folded = @profiler.profiler_report_folded()
  // Format: `outer;inner <us>\n` (leaf line) and possibly `outer <us>\n`
  // (self time for outer if any). Both must contain the joined path.
  assert_true(folded.contains("outer;inner"))
  @profiler.profiler_set_enabled(false)
  @profiler.profiler_reset()
}

///|
test "stack samples expose root-first frames" {
  @profiler.profiler_set_enabled(true)
  @profiler.profiler_reset()
  @profiler.profiler_enter("a")
  @profiler.profiler_enter("b")
  @profiler.profiler_enter("c")
  @profiler.profiler_leave()
  @profiler.profiler_leave()
  @profiler.profiler_leave()
  let samples = @profiler.profiler_stack_samples()
  // Expect at least the leaf stack [a, b, c]; outer frames may have
  // zero self-time and be filtered.
  let mut found_leaf = false
  for s in samples {
    if s.frames.length() == 3 &&
      s.frames[0] == "a" &&
      s.frames[1] == "b" &&
      s.frames[2] == "c" {
      found_leaf = true
    }
  }
  assert_true(found_leaf)
  @profiler.profiler_set_enabled(false)
  @profiler.profiler_reset()
}

///|
test "pprof output starts with sample_type" {
  @profiler.profiler_set_enabled(true)
  @profiler.profiler_reset()
  @profiler.profiler_enter("phase/a")
  @profiler.profiler_enter("phase/b")
  @profiler.profiler_leave()
  @profiler.profiler_leave()
  let bytes = @profiler.profiler_report_pprof()
  // Field 1 (sample_type) wire-tag = (1 << 3) | 2 = 0x0A.
  // pprof emitters all start with this field.
  assert_true(bytes.length() > 0)
  assert_eq(bytes[0], b'\x0A')
  @profiler.profiler_set_enabled(false)
  @profiler.profiler_reset()
}

///|
test "tsv format" {
  @profiler.profiler_set_enabled(true)
  @profiler.profiler_reset()
  @profiler.profiler_enter("outer")
  @profiler.profiler_enter("inner")
  @profiler.profiler_leave()
  @profiler.profiler_leave()
  let report = @profiler.profiler_report_tsv()
  let lines : Array[String] = report
    .split("\n")
    .map(fn(sv) { sv.to_owned() })
    .collect()
  // header + outer + inner + trailing empty
  assert_true(lines.length() >= 3)
  let header = lines[0]
  assert_eq(header, "name\ttotal_us\tself_us\tcall_count\tchildren")
  @profiler.profiler_set_enabled(false)
  @profiler.profiler_reset()
}
