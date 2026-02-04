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
