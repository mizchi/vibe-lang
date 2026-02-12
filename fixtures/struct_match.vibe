struct Point { x : Int; y : Int }
let p = Point::{ x: 3, y: 4 }
let sum = match p { Point::{ x, y } => add(x, y), _ => 0 }
test "struct_match" {
  assert(eq(sum, 7))
}

__DATA__
{}
