///|
/// vibe public API
suberror VibeError {
  Parse(@parser.ParseError)
  Type(@checker.TypeError)
  Eval(EvalError)
} derive(Show, Eq)

///|
pub(all) enum ParserMode {
  VibeMode
  PosixMode
  PosixStrictMode
} derive(Show, Eq)

///|
/// Detect vibe by leading keyword token
pub fn is_vibe_script(script : String) -> Bool {
  let tokens = @parser.tokenize(script)
  for tok in tokens {
    if @parser.is_trivia(tok.kind()) {
      continue
    }
    let kind = tok.kind()
    return kind == @parser.let_kw() ||
      kind == @parser.test_kw() ||
      kind == @parser.bench_kw() ||
      kind == @parser.type_kw() ||
      kind == @parser.enum_kw() ||
      kind == @parser.lbracket()
  }
  false
}
