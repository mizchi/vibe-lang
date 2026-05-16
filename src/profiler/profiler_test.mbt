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
