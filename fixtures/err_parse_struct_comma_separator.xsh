struct Point { x: Int, y: Int }
let p = Point::{ x: 1, y: 2 }
p.x + p.y

__DATA__
{"error_contains":"struct field separator"}
