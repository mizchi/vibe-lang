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
pub(all) enum DiagnosticStage {
  Parse
  Type
  Warning
  Check
  Import
  Lint
} derive(Show, Eq)

///|
pub fn DiagnosticStage::from_string(s : String) -> DiagnosticStage {
  match s {
    "parse" => Parse
    "type" => Type
    "warning" => Warning
    "check" => Check
    "import" => Import
    "lint" => Lint
    _ => Check
  }
}

///|
pub fn DiagnosticStage::to_string(self : DiagnosticStage) -> String {
  match self {
    Parse => "parse"
    Type => "type"
    Warning => "warning"
    Check => "check"
    Import => "import"
    Lint => "lint"
  }
}

///|
/// Returns severity level: 1=Error, 2=Warning, 3=Info
pub fn DiagnosticStage::severity(self : DiagnosticStage) -> Int {
  match self {
    Parse | Type | Check | Import => 1
    Warning | Lint => 2
  }
}

///|
pub(all) struct Diagnostic {
  stage : String
  message : String
  span : Span?
  hint : String?
  note : String?
} derive(Show, Eq)

///|
pub fn Diagnostic::staged(self : Diagnostic) -> DiagnosticStage {
  DiagnosticStage::from_string(self.stage)
}
