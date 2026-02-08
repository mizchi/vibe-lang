// Match on enum with wrong variant
enum Color { Red; Green; Blue }
let c = Red
match c {
  Yellow => 1
  _ => 0
}

__DATA__
{"error_contains": "unknown ctor"}
