///|
/// Token for vibe lexer
pub struct Token {
  kind : @cst.SyntaxKind
  text : String
  width : Int
} derive(Eq)

///|
pub impl Show for Token with output(self, logger) {
  logger.write_string("Token(kind=")
  logger.write_string(self.kind.raw().to_string())
  logger.write_string(", text=")
  logger.write_string(self.text.to_string())
  logger.write_string(", width=")
  logger.write_string(self.width.to_string())
  logger.write_string(")")
}

///|
pub fn Token::new(kind : @cst.SyntaxKind, text : String) -> Token {
  Token::{ kind, text, width: text.length() }
}

///|
pub fn Token::new_with_width(
  kind : @cst.SyntaxKind,
  text : String,
  width : Int,
) -> Token {
  let safe_width = if width < 0 { 0 } else { width }
  Token::{ kind, text, width: safe_width }
}

///|
pub fn Token::kind(self : Token) -> @cst.SyntaxKind {
  self.kind
}

///|
pub fn Token::text(self : Token) -> String {
  self.text
}

///|
pub fn Token::width(self : Token) -> Int {
  self.width
}
