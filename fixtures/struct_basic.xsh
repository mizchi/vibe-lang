struct Point { x : Int; y : Int }
let p = Point::{ x: 1, y: 2 }
test "struct_field_access" {
  assert(eq(p.x, 1))
  assert(eq(p.y, 2))
}

__DATA__
{}
