trait Eq
trait Ord: Eq

struct Token {
  value: Int;
} derive(Ord)

let same = [T: Ord](a: T, b: T) -> Bool {
  true
}

let accepts_eq = [T: Eq](value: T) -> Bool {
  true
}

same(Token::{ value: 1 }, Token::{ value: 1 }) && accepts_eq(Token::{ value: 1 })

__DATA__
{"last":"true"}
