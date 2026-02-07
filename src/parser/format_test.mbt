///|
/// Formatter tests
test "xsh format basic" {
  let input =
    #|let x=1
    #|let y = {
    #|let a=1
    #|  add(a,2)
    #|}
  let expected =
    #|let x = 1
    #|let y = {
    #|  let a = 1
    #|  add(a, 2)
    #|}
  inspect(format_script(input), content=expected)
}

///|
test "xsh format collections" {
  let input =
    #|let arr=[1,2]
    #|let r = record { a:1, b:2 }
    #|let m = map { a:1, b:2 }
  let expected =
    #|let arr = [
    #|  1,
    #|  2
    #|]
    #|let r = record {
    #|  a: 1,
    #|  b: 2
    #|}
    #|let m = map {
    #|  a: 1,
    #|  b: 2
    #|}
  inspect(format_script(input), content=expected)
}

///|
test "xsh format match" {
  let input =
    #|match v { Ok(v)=>1, None if true=>0 }
  let expected =
    #|match v {
    #|  Ok(v) => 1,
    #|  None if true => 0
    #|}
  inspect(format_script(input), content=expected)
}

///|
test "xsh format type args and index" {
  let input =
    #|let x: Option[Int] = none
    #|let y = xs[0]
    #|let z = foo()[0]
    #|type Box[T] = Array[T]
  let expected =
    #|let x: Option[Int] = none
    #|let y = xs[0]
    #|let z = foo()[0]
    #|type Box[T] = Array[T]
  inspect(format_script(input), content=expected)
}

///|
test "xsh format enum uses semicolon separator" {
  let input =
    #|enum Result[T] { Ok(T), Err }
  let expected =
    #|enum Result[T] {
    #|  Ok(T);
    #|  Err
    #|}
  inspect(format_script(input), content=expected)
}

///|
test "xsh format keeps enum payload commas" {
  let input =
    #|enum List { Nil, Cons(Int, List) }
  let expected =
    #|enum List {
    #|  Nil;
    #|  Cons(Int,
    #|  List)
    #|}
  inspect(format_script(input), content=expected)
}

///|
test "xsh format normalizes struct literal separator" {
  let input =
    #|let p = Point::{x:1,y:1}
    #|let q = Point {x:1,y:1}
  let expected =
    #|let p = Point::{
    #|  x: 1, y: 1
    #|}
    #|let q = Point::{
    #|  x: 1, y: 1
    #|}
  inspect(format_script(input), content=expected)
}

///|
test "xsh format is idempotent" {
  let input =
    #|enum Result[T] { Ok(T), Err }
    #|struct Point { x : Int; y : Int }
    #|let p = Point {x:1,y:1}
    #|let q = Point::{x:2,y:2}
    #|match p { Point::{x,y} => add(x,y), _ => 0 }
  let once = format_script(input)
  let twice = format_script(once)
  inspect(twice, content=once)
}

///|
test "xsh format keeps declaration braces and return type blocks" {
  let input =
    #|struct Point { x : Int; y : Int }
    #|let make = () -> Int { 1 }
    #|let p = Point {x:1,y:1}
    #|let eff = () -> Int with { Error } { 0 }
  let expected =
    #|struct Point {
    #|  x: Int; y: Int
    #|}
    #|let make = () -> Int {
    #|  1
    #|}
    #|let p = Point::{
    #|  x: 1, y: 1
    #|}
    #|let eff = () -> Int with {
    #|  Error
    #|} {
    #|  0
    #|}
  inspect(format_script(input), content=expected)
}
