trait Eq

struct Point {
  x: Int;
  y: Int;
} derive(Eq)

let same = [T: Eq](a: T, b: T) -> Bool {
  true
}

same(Point::{
  x: 1,
  y: 1
}, Point::{
  x: 1,
  y: 1
})

__DATA__
{"last":"true"}
