///|
pub let sample_script : String =
  #|let add = (x: Int, y: Int) -> Int { x + y }
  #|let sub = (x: Int, y: Int) -> Int { x - y }
  #|let t = (1, 2)
  #|let r = record { b: 2, a: 1 }
  #|let m = map { a: 1, b: 2 }
  #|let arr = [1, 2, 3, 4, 5]
  #|let res = match true { true => add(1, 2), _ => sub(3, 1) }
  #|res

///|
pub let sample_pipeline_script : String =
  #|1 |> add(2) |> mul(3) |> sub(4) |> add(5)

///|
pub let sample_pipeline_js_string_script : String =
  #|"hello" |> String::length |> add(1) |> mul(2)

///|
pub let sample_user_fn_script : String =
  #|let add2 = (x: Int) -> Int { add(x, 2) }
  #|let run = (x: Int) -> Int { add2(x) }
  #|run(40)

///|
pub let sample_effect_ho_script : String =
  #|let effectful = (x: Int) -> Int with {Error} { x }
  #|let apply = (f: (x: Int) -> Int with {e}, x: Int) -> Int with {e} { f(x) }
  #|let chain = (
  #|  f: (x: Int) -> Int with {e},
  #|  g: (x: Int) -> Int with {e},
  #|  x: Int,
  #|) -> Int with {e} { add(f(x), g(x)) }
  #|let run = (x: Int) -> Int with {Error} { chain(effectful, effectful, x) }
  #|handle { run(10) } with Error { Throw(_) => -1 }

///|
pub let sample_numeric_script : String =
  #|let add_i = (x: Int, y: Int) -> Int { x + y }
  #|let add_f = (x: Float, y: Float) -> Float { x + y }
  #|let add_d = (x: Double, y: Double) -> Double { x + y }
  #|let mul_f = (x: Float, y: Float) -> Float { x * y }
  #|let mul_d = (x: Double, y: Double) -> Double { x * y }
  #|let fi = add_f(1.5f, 2.25f)
  #|let di = add_d(1.5, 2.25)
  #|let fi2 = mul_f(-1.0f, fi)
  #|let di2 = mul_d(-1.0, di)
  #|let cmp_f = fi2 < 0.0f
  #|let cmp_d = di2 < 0.0
  #|let res = if cmp_f && cmp_d { add_i(1, 2) } else { 0 }
  #|res

///|
pub fn sample_aliases() -> Map[String, @core.Ref] {
  {
    "math": @core.Ref::{ name: "std.math", hash_prefix: Some("deadbeef") },
    "foo": @core.Ref::{ name: "foo", hash_prefix: None },
  }
}
