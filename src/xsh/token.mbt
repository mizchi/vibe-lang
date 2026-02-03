///| Token for xsh lexer
pub struct Token {
  kind : @cst.SyntaxKind
  text : String
} derive(Show, Eq)

///|
pub fn Token::new(kind : @cst.SyntaxKind, text : String) -> Token {
  Token::{ kind, text }
}

///|
pub fn Token::kind(self : Token) -> @cst.SyntaxKind {
  self.kind
}

///|
pub fn Token::text(self : Token) -> String {
  self.text
}
