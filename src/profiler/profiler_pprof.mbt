// pprof (Google) protobuf encoder for the profiler.
//
// Wire format reference:
//   https://github.com/google/pprof/blob/main/proto/profile.proto
//
// Proto3 binary encoding rules used here:
//   - tag = (field_number << 3) | wire_type
//     wire_type: 0=varint, 2=length-delimited
//   - all integer fields below are varint; nested messages and
//     `string` fields are length-delimited; `repeated uint64`
//     defaults to packed (one length-delimited run of varints).
//
// We emit a minimal but valid Profile that `go tool pprof` accepts:
//
//   Profile {
//     sample_type: [{type: "samples", unit: "microseconds"}]
//     sample[]:    one per unique stack — value=[self_us],
//                  location_id=[leaf, ..., root]  (top-of-stack first)
//     location[]:  one per unique function name, single Line
//     function[]:  one per unique function name
//     string_table[0] = ""  (mandatory)
//     time_nanos / duration_nanos: from profiler_duration_us
//   }

///|
priv struct PprofEncoderState {
  // Append-only byte buffer.
  buf : @buffer.Buffer
  // String interner — index 0 is always the empty string (proto spec).
  string_table : Array[String]
  string_idx : Map[String, Int]
  // function/location interner keyed by function name. Both share the
  // same id (1-based) since each function maps to exactly one
  // location with a single Line referencing that function.
  func_idx : Map[String, Int]
  func_order : Array[String]
}

///|
fn pprof_new_encoder() -> PprofEncoderState {
  let st : PprofEncoderState = {
    buf: @buffer.Buffer(size_hint=256),
    string_table: [""],
    string_idx: { "": 0 },
    func_idx: {},
    func_order: [],
  }
  st
}

///|
fn pprof_intern_string(st : PprofEncoderState, s : String) -> Int {
  match st.string_idx.get(s) {
    Some(i) => i
    None => {
      let i = st.string_table.length()
      st.string_table.push(s)
      st.string_idx[s] = i
      i
    }
  }
}

///|
fn pprof_intern_func(st : PprofEncoderState, name : String) -> Int {
  match st.func_idx.get(name) {
    Some(i) => i
    None => {
      let i = st.func_order.length() + 1
      st.func_idx[name] = i
      st.func_order.push(name)
      i
    }
  }
}

///|
/// Encode a uint64 / int64 as a base-128 varint into `buf`. We accept
/// `Int64` and treat it as unsigned (negative values wouldn't appear
/// in our pprof fields anyway).
fn pprof_write_varint(buf : @buffer.Buffer, v : Int64) -> Unit {
  let mut x = v
  while true {
    let b = (x & 0x7FL).to_int()
    x = (x >> 7) & 0x01FFFFFFFFFFFFFFL // logical shift right (clear sign bits)
    if x == 0L {
      buf.write_byte(b.to_byte())
      break
    } else {
      buf.write_byte((b | 0x80).to_byte())
    }
  }
}

///|
fn pprof_write_varint_int(buf : @buffer.Buffer, v : Int) -> Unit {
  pprof_write_varint(buf, v.to_int64())
}

///|
fn pprof_write_tag(
  buf : @buffer.Buffer,
  field_no : Int,
  wire_type : Int,
) -> Unit {
  pprof_write_varint_int(buf, (field_no << 3) | wire_type)
}

///|
/// Encode a length-delimited field (wire type 2). `body` is a closure
/// that writes the inner bytes into a scratch buffer; we then prefix
/// with the length and copy to the outer buffer.
fn pprof_write_lendelim(
  outer : @buffer.Buffer,
  field_no : Int,
  body : (@buffer.Buffer) -> Unit,
) -> Unit {
  let scratch = @buffer.Buffer(size_hint=32)
  body(scratch)
  let bytes = scratch.to_bytes()
  pprof_write_tag(outer, field_no, 2)
  pprof_write_varint_int(outer, bytes.length())
  outer.write_bytes(bytes)
}

///|
fn pprof_write_string_field(
  buf : @buffer.Buffer,
  field_no : Int,
  s : String,
) -> Unit {
  pprof_write_tag(buf, field_no, 2)
  // UTF-8 encode the string into bytes via WriteBuffer's
  // write_string, which uses UTF-8 per vibe convention.
  let scratch = @buffer.Buffer(size_hint=32)
  scratch.write_string_utf8(s[:])
  let bytes = scratch.to_bytes()
  pprof_write_varint_int(buf, bytes.length())
  buf.write_bytes(bytes)
}

///|
fn pprof_write_varint_field(
  buf : @buffer.Buffer,
  field_no : Int,
  v : Int64,
) -> Unit {
  pprof_write_tag(buf, field_no, 0)
  pprof_write_varint(buf, v)
}

///|
/// Encode a single ValueType { type: string_idx, unit: string_idx } as
/// a length-delimited submessage at `field_no` in the outer profile.
fn pprof_write_value_type(
  outer : @buffer.Buffer,
  field_no : Int,
  type_str_idx : Int,
  unit_str_idx : Int,
) -> Unit {
  pprof_write_lendelim(outer, field_no, fn(inner) {
    pprof_write_varint_field(inner, 1, type_str_idx.to_int64())
    pprof_write_varint_field(inner, 2, unit_str_idx.to_int64())
  })
}

///|
/// Encode one Sample submessage.
///
/// Sample {
///   repeated uint64 location_id = 1;   // packed
///   repeated int64  value       = 2;   // packed
/// }
fn pprof_write_sample(
  outer : @buffer.Buffer,
  location_ids : Array[Int],
  values : Array[Int],
) -> Unit {
  pprof_write_lendelim(outer, 2, fn(inner) {
    // packed location_id
    let packed_loc = @buffer.Buffer(size_hint=32)
    for id in location_ids {
      pprof_write_varint_int(packed_loc, id)
    }
    let loc_bytes = packed_loc.to_bytes()
    if loc_bytes.length() > 0 {
      pprof_write_tag(inner, 1, 2)
      pprof_write_varint_int(inner, loc_bytes.length())
      inner.write_bytes(loc_bytes)
    }
    // packed value
    let packed_val = @buffer.Buffer(size_hint=32)
    for v in values {
      pprof_write_varint_int(packed_val, v)
    }
    let val_bytes = packed_val.to_bytes()
    if val_bytes.length() > 0 {
      pprof_write_tag(inner, 2, 2)
      pprof_write_varint_int(inner, val_bytes.length())
      inner.write_bytes(val_bytes)
    }
  })
}

///|
/// Encode one Location submessage with a single Line referencing
/// `function_id`. We do not emit a Mapping; pprof treats mapping_id=0
/// as "synthetic" which is what we want.
///
/// Location {
///   uint64 id          = 1;
///   uint64 mapping_id  = 2;
///   uint64 address     = 3;
///   repeated Line line = 4;
/// }
/// Line {
///   uint64 function_id = 1;
///   int64  line        = 2;
/// }
fn pprof_write_location(
  outer : @buffer.Buffer,
  id : Int,
  function_id : Int,
) -> Unit {
  pprof_write_lendelim(outer, 4, fn(inner) {
    pprof_write_varint_field(inner, 1, id.to_int64())
    pprof_write_lendelim(inner, 4, fn(line_inner) {
      pprof_write_varint_field(line_inner, 1, function_id.to_int64())
    })
  })
}

///|
/// Encode one Function submessage. `name_str_idx` and
/// `system_name_str_idx` may be the same — pprof's UI uses `name` for
/// display, `system_name` for symbol-table lookup.
///
/// Function {
///   uint64 id          = 1;
///   int64  name        = 2;
///   int64  system_name = 3;
///   int64  filename    = 4;
///   int64  start_line  = 5;
/// }
fn pprof_write_function(
  outer : @buffer.Buffer,
  id : Int,
  name_str_idx : Int,
) -> Unit {
  pprof_write_lendelim(outer, 5, fn(inner) {
    pprof_write_varint_field(inner, 1, id.to_int64())
    pprof_write_varint_field(inner, 2, name_str_idx.to_int64())
    pprof_write_varint_field(inner, 3, name_str_idx.to_int64())
  })
}

///|
/// Build a pprof Profile protobuf from the currently-recorded samples
/// and return the encoded bytes. Empty profile if nothing was
/// recorded.
///
/// We collect every stack first to intern function names, then emit
/// the Profile message in the order pprof expects (samples first,
/// then locations, then functions, then string_table).
pub fn profiler_report_pprof() -> Bytes {
  let samples = profiler_stack_samples()
  let st = pprof_new_encoder()
  // Pre-intern the sample-type label strings.
  let st_samples = pprof_intern_string(st, "samples")
  let st_us = pprof_intern_string(st, "microseconds")
  // Intern function names in the order they're first observed across
  // stacks (root → leaf within each stack), so flame graphs display
  // in a sensible order.
  for sample in samples {
    for frame in sample.frames {
      let _ = pprof_intern_func(st, frame)
      let _ = pprof_intern_string(st, frame)

    }
  }
  let out = st.buf
  // sample_type: {type: "samples", unit: "microseconds"}
  pprof_write_value_type(out, 1, st_samples, st_us)
  // samples
  for sample in samples {
    // pprof wants location_id ordered leaf-first; our `frames` is
    // root-first, so reverse on emit.
    let loc_ids : Array[Int] = []
    let n = sample.frames.length()
    let mut i = n - 1
    while i >= 0 {
      loc_ids.push(pprof_intern_func(st, sample.frames[i]))
      i = i - 1
    }
    pprof_write_sample(out, loc_ids, [sample.self_us])
  }
  // locations (one per function, same id)
  for name in st.func_order {
    let id = st.func_idx.get(name).unwrap()
    pprof_write_location(out, id, id)
  }
  // functions
  for name in st.func_order {
    let id = st.func_idx.get(name).unwrap()
    let name_idx = pprof_intern_string(st, name)
    pprof_write_function(out, id, name_idx)
  }
  // string_table — emit in interning order (index 0 first).
  for s in st.string_table {
    pprof_write_string_field(out, 6, s)
  }
  // time_nanos (field 9) — origin doesn't matter for relative use;
  // we leave it 0. duration_nanos (field 10) is the wall-clock span.
  let duration_ns = profiler_duration_us().to_int64() * 1000L
  if duration_ns > 0L {
    pprof_write_varint_field(out, 10, duration_ns)
  }
  // period_type (field 11) — required by some tools; reuse the sample
  // type so consumers don't choke.
  pprof_write_value_type(out, 11, st_samples, st_us)
  // default_sample_type (field 14) — string_idx for "samples".
  pprof_write_varint_field(out, 14, st_samples.to_int64())
  out.to_bytes()
}
