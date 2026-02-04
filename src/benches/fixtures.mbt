///|
pub let sample_script : String =
  #|let add = fn (x: Int, y: Int) -> Int { x + y }
  #|let sub = fn (x: Int, y: Int) -> Int { x - y }
  #|let t = (1, 2)
  #|let r = record { b: 2, a: 1 }
  #|let m = map { a: 1, b: 2 }
  #|let arr = [1, 2, 3, 4, 5]
  #|let res = match true { true => add(1, 2), _ => sub(3, 1) }
  #|res

///|
pub fn sample_aliases() -> Map[String, @core.Ref] {
  {
    "math": @core.Ref::{ name: "std.math", hash_prefix: Some("deadbeef") },
    "foo": @core.Ref::{ name: "foo", hash_prefix: None },
  }
}
