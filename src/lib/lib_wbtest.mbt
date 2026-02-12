///|
test "check_report_json returns error payload for invalid source" {
  let json = check_report_json("1 + true\n")
  assert_true(json.contains("\"ok\":false"))
  assert_true(json.contains("\"error_count\":1"))
}

///|
test "format_report_json returns formatted payload" {
  let json = format_report_json("let  x=1")
  assert_true(json.contains("\"ok\":true"))
  assert_true(json.contains("\"changed\":true"))
  assert_true(json.contains("let x = 1"))
}

///|
test "ide_outline_report_json returns symbols" {
  let request = "{\"source\":\"let foo = 1\\nlet bar = foo\\n\",\"path\":\"/main.vibe\"}"
  let json = ide_outline_report_json(request)
  assert_true(json.contains("\"ok\":true"))
  assert_true(json.contains("\"name\":\"foo\""))
}

///|
test "ide_search_report_json finds signature text" {
  let request = "{\"source\":\"let foo = 1\\nlet bar = foo\\n\",\"path\":\"/main.vibe\",\"query\":\"foo\"}"
  let json = ide_search_report_json(request)
  assert_true(json.contains("\"ok\":true"))
  assert_true(json.contains("\"matches\""))
}

///|
test "check_project_report_json resolves imports" {
  let request = "{\"entry\":\"/main.vibe\",\"files\":{\"/main.vibe\":\"use \\\"./lib.vibe\\\" { value }\\nlet out = value\\n\",\"/lib.vibe\":\"export let value = 1\\n\"}}"
  let json = check_project_report_json(request)
  assert_true(json.contains("\"ok\":true"))
  assert_true(json.contains("\"entry\":\"/main.vibe\""))
  assert_true(json.contains("\"unsupported_imports\":false"))
}

///|
test "ide_peek_def_report_json resolves imported symbol" {
  let request = "{\"entry\":\"/main.vibe\",\"path\":\"/main.vibe\",\"symbol\":\"value\",\"files\":{\"/main.vibe\":\"use \\\"./lib.vibe\\\" { value }\\nlet out = value\\n\",\"/lib.vibe\":\"export let value = 1\\n\"}}"
  let json = ide_peek_def_report_json(request)
  assert_true(json.contains("\"ok\":true"))
  assert_true(json.contains("\"path\":\"/lib.vibe\""))
}

///|
test "init_state_report_json injects prelude definitions" {
  let _ = init_state_report_json("{}")
  let init = init_state_report_json(
    "{\"prelude\":\"let triple = (x: Int) -> Int { x * 3 }\"}",
  )
  assert_true(init.contains("\"ok\":true"))
  let report = check_report_json("triple(4)\n")
  assert_true(report.contains("\"ok\":true"))
  assert_true(report.contains("\"error_count\":0"))
  let _ = init_state_report_json("{}")
}

///|
test "init_state_report_json injects kv files for project requests" {
  let _ = init_state_report_json("{}")
  let init = init_state_report_json(
    "{\"kv\":{\"/lib.vibe\":\"export let value = 7\\n\"}}",
  )
  assert_true(init.contains("\"ok\":true"))
  let request = "{\"entry\":\"/main.vibe\",\"files\":{\"/main.vibe\":\"use \\\"./lib.vibe\\\" { value }\\nlet out = value\\n\"}}"
  let report = check_project_report_json(request)
  assert_true(report.contains("\"ok\":true"))
  assert_true(report.contains("\"error_count\":0"))
  let _ = init_state_report_json("{}")
}
