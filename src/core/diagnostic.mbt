///|
/// Diagnostics utilities for vibe
pub(all) struct Span {
  start : Int
  end : Int
} derive(Show, Eq)

///|
pub fn Span::new(start : Int, end : Int) -> Span {
  if end < start {
    Span::{ start: end, end: start }
  } else {
    Span::{ start, end }
  }
}

///|
pub fn Span::empty(pos : Int) -> Span {
  Span::{ start: pos, end: pos }
}

///|
pub fn Span::merge(a : Span, b : Span) -> Span {
  let start = if a.start < b.start { a.start } else { b.start }
  let end = if a.end > b.end { a.end } else { b.end }
  Span::{ start, end }
}

///|
pub(all) struct Diagnostic {
  stage : String
  message : String
  span : Span?
  hint : String?
  note : String?
} derive(Show, Eq)
