import { parse_ok, parse_err } from "./json.xsh"

let input = "{\"name\":\"xsh\",\"nums\":[1.5,2,3.25],\"ok\":true,\"meta\":null}"

test "json_parser_complex" {
  assert(parse_ok(input))
}

test "json_parser_numbers" {
  assert(parse_ok("0"))
  assert(parse_ok("-12"))
  assert(parse_ok("3.5"))
  assert(parse_ok("1e3"))
  assert(parse_ok("1.25e-2"))
  assert(parse_ok("1E+2"))
  assert(parse_ok("-0.0"))
}

test "json_parser_whitespace_nested_string" {
  assert(parse_ok(" \n\t{\"a\": 1}\n "))
  assert(parse_ok("{\"a\":[true,false,null,{\"b\":2}],\"c\":{}}"))
  assert(parse_ok("\"he\\\\llo\\n\\t\\\"/\""))
}

test "json_parser_errors" {
  assert(parse_ok("[]"))
  assert(parse_err("\"abc"))
  assert(parse_err("true false"))
  assert(parse_err("1e"))
  assert(parse_err("1e+"))
  assert(parse_err("1e-"))
  assert(parse_err("[1,]"))
  assert(parse_err("{\"a\":1,}"))
  assert(parse_err("\"a\\b\""))
  assert(parse_err("01"))
  assert(parse_err("-01"))
  assert(parse_err("00"))
  assert(parse_err(".1"))
  assert(parse_err("1."))
  assert(parse_err("+1"))
  assert(parse_err("-"))
  assert(parse_err("\"a\nb\""))
}
