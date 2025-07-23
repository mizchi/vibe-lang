use crate::{Span, XsError};
use std::iter::Peekable;
use std::str::Chars;

#[derive(Debug, Clone, PartialEq)]
pub enum Token {
    LeftParen,
    RightParen,
    Int(i64),
    Float(f64),
    Bool(bool),
    String(String),
    Symbol(String),
    Let,
    LetRec,
    In,
    Fn,
    If,
    List,
    Cons,
    Colon,
    Arrow,
    Rec,
    Match,
    Type,
    Underscore,
    Module,
    Import,
    Export,
    As,
    Dot,
    Use,
    Define,
    Comment(String), // コメントトークンを追加
    LeftBrace,
    RightBrace,
    Comma,
    Exclamation,
    Pipeline, // |> operator
    #[allow(dead_code)]
    Ident(String), // 識別子トークンを追加
}

pub struct Lexer<'a> {
    chars: Peekable<Chars<'a>>,
    position: usize,
    skip_comments: bool, // コメントをスキップするかどうか
}

impl<'a> Lexer<'a> {
    pub fn new(input: &'a str) -> Self {
        Lexer {
            chars: input.chars().peekable(),
            position: 0,
            skip_comments: true, // デフォルトではコメントをスキップ
        }
    }

    pub fn with_comments(input: &'a str) -> Self {
        Lexer {
            chars: input.chars().peekable(),
            position: 0,
            skip_comments: false, // コメントを保持
        }
    }

    pub fn next_token(&mut self) -> Result<Option<(Token, Span)>, XsError> {
        self.skip_whitespace_and_maybe_comments();

        let start = self.position;

        match self.chars.peek() {
            None => Ok(None),
            Some(&ch) => {
                match ch {
                    ';' if !self.skip_comments => {
                        // コメントをトークンとして読み取る
                        self.read_comment()
                    }
                    '(' => {
                        self.advance();
                        Ok(Some((Token::LeftParen, Span::new(start, self.position))))
                    }
                    ')' => {
                        self.advance();
                        Ok(Some((Token::RightParen, Span::new(start, self.position))))
                    }
                    ':' => {
                        self.advance();
                        Ok(Some((Token::Colon, Span::new(start, self.position))))
                    }
                    '"' => self.read_string(),
                    '-' if self.peek_next() == Some('>') => {
                        self.advance();
                        self.advance();
                        Ok(Some((Token::Arrow, Span::new(start, self.position))))
                    }
                    '-' if self.peek_next().map(|c| c.is_numeric()).unwrap_or(false) => {
                        self.read_number()
                    }
                    '0'..='9' => self.read_number(),
                    '_' => {
                        self.advance();
                        Ok(Some((Token::Underscore, Span::new(start, self.position))))
                    }
                    '.' => {
                        self.advance();
                        Ok(Some((Token::Dot, Span::new(start, self.position))))
                    }
                    '{' => {
                        self.advance();
                        Ok(Some((Token::LeftBrace, Span::new(start, self.position))))
                    }
                    '}' => {
                        self.advance();
                        Ok(Some((Token::RightBrace, Span::new(start, self.position))))
                    }
                    ',' => {
                        self.advance();
                        Ok(Some((Token::Comma, Span::new(start, self.position))))
                    }
                    '!' => {
                        self.advance();
                        Ok(Some((Token::Exclamation, Span::new(start, self.position))))
                    }
                    '|' if self.peek_next() == Some('>') => {
                        self.advance();
                        self.advance();
                        Ok(Some((Token::Pipeline, Span::new(start, self.position))))
                    }
                    _ if ch.is_alphabetic()
                        || ch == '+'
                        || ch == '-'
                        || ch == '*'
                        || ch == '/'
                        || ch == '%'
                        || ch == '<'
                        || ch == '>'
                        || ch == '=' =>
                    {
                        self.read_symbol()
                    }
                    _ => Err(XsError::ParseError(
                        self.position,
                        format!("Unexpected character: {ch}"),
                    )),
                }
            }
        }
    }

    fn advance(&mut self) -> Option<char> {
        let ch = self.chars.next();
        if ch.is_some() {
            self.position += 1;
        }
        ch
    }

    fn peek_next(&mut self) -> Option<char> {
        let mut iter = self.chars.clone();
        iter.next();
        iter.peek().copied()
    }

    fn skip_whitespace_and_maybe_comments(&mut self) {
        while let Some(&ch) = self.chars.peek() {
            if ch.is_whitespace() {
                self.advance();
            } else if ch == ';' && self.skip_comments {
                // コメントをスキップ
                while let Some(&ch) = self.chars.peek() {
                    self.advance();
                    if ch == '\n' {
                        break;
                    }
                }
            } else {
                break;
            }
        }
    }

    fn read_comment(&mut self) -> Result<Option<(Token, Span)>, XsError> {
        let start = self.position;
        self.advance(); // Skip ';'

        let mut comment = String::new();
        while let Some(&ch) = self.chars.peek() {
            if ch == '\n' {
                break;
            }
            comment.push(ch);
            self.advance();
        }

        Ok(Some((
            Token::Comment(comment.trim().to_string()),
            Span::new(start, self.position),
        )))
    }

    fn read_string(&mut self) -> Result<Option<(Token, Span)>, XsError> {
        let start = self.position;
        self.advance(); // skip opening quote

        let mut value = String::new();
        while let Some(&ch) = self.chars.peek() {
            if ch == '"' {
                self.advance();
                return Ok(Some((
                    Token::String(value),
                    Span::new(start, self.position),
                )));
            } else if ch == '\\' {
                self.advance();
                match self.chars.peek() {
                    Some(&'n') => {
                        self.advance();
                        value.push('\n');
                    }
                    Some(&'t') => {
                        self.advance();
                        value.push('\t');
                    }
                    Some(&'\\') => {
                        self.advance();
                        value.push('\\');
                    }
                    Some(&'"') => {
                        self.advance();
                        value.push('"');
                    }
                    _ => {
                        return Err(XsError::ParseError(
                            self.position,
                            "Invalid escape sequence".to_string(),
                        ))
                    }
                }
            } else {
                value.push(ch);
                self.advance();
            }
        }

        Err(XsError::ParseError(
            start,
            "Unterminated string".to_string(),
        ))
    }

    fn read_number(&mut self) -> Result<Option<(Token, Span)>, XsError> {
        let start = self.position;
        let mut value = String::new();

        if let Some(&'-') = self.chars.peek() {
            value.push('-');
            self.advance();
        }

        while let Some(&ch) = self.chars.peek() {
            if ch.is_numeric() {
                value.push(ch);
                self.advance();
            } else {
                break;
            }
        }

        // Check for decimal point
        if let Some(&'.') = self.chars.peek() {
            // Make sure the next char is a digit to distinguish from dot operator
            let mut peek_chars = self.chars.clone();
            peek_chars.next(); // skip '.'
            if let Some(&next_ch) = peek_chars.peek() {
                if next_ch.is_numeric() {
                    value.push('.');
                    self.advance();

                    while let Some(&ch) = self.chars.peek() {
                        if ch.is_numeric() {
                            value.push(ch);
                            self.advance();
                        } else {
                            break;
                        }
                    }

                    // Parse as float
                    match value.parse::<f64>() {
                        Ok(f) => {
                            return Ok(Some((Token::Float(f), Span::new(start, self.position))))
                        }
                        Err(_) => {
                            return Err(XsError::ParseError(
                                start,
                                format!("Invalid float: {value}"),
                            ))
                        }
                    }
                }
            }
        }

        // Parse as integer
        match value.parse::<i64>() {
            Ok(n) => Ok(Some((Token::Int(n), Span::new(start, self.position)))),
            Err(_) => Err(XsError::ParseError(
                start,
                format!("Invalid number: {value}"),
            )),
        }
    }

    fn read_symbol(&mut self) -> Result<Option<(Token, Span)>, XsError> {
        let start = self.position;
        let mut value = String::new();

        while let Some(&ch) = self.chars.peek() {
            if ch.is_alphanumeric()
                || ch == '-'
                || ch == '_'
                || ch == '+'
                || ch == '*'
                || ch == '/'
                || ch == '%'
                || ch == '<'
                || ch == '>'
                || ch == '='
                || ch == '?'
                || ch == '!'
            {
                value.push(ch);
                self.advance();
            } else {
                break;
            }
        }

        let token = match value.as_str() {
            "let" => Token::Let,
            "let-rec" => Token::LetRec,
            "in" => Token::In,
            "fn" => Token::Fn,
            "lambda" => Token::Fn, // backward compatibility
            "if" => Token::If,
            "list" => Token::List,
            "cons" => Token::Cons,
            "true" => Token::Bool(true),
            "false" => Token::Bool(false),
            "rec" => Token::Rec,
            "match" => Token::Match,
            "type" => Token::Type,
            "_" => Token::Underscore,
            "module" => Token::Module,
            "import" => Token::Import,
            "export" => Token::Export,
            "as" => Token::As,
            "use" => Token::Use,
            "define" => Token::Define,
            _ => Token::Symbol(value),
        };

        Ok(Some((token, Span::new(start, self.position))))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_basic_tokens() {
        let mut lexer = Lexer::new("( ) : ->");

        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::LeftParen, Span::new(0, 1)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::RightParen, Span::new(2, 3)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Colon, Span::new(4, 5)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Arrow, Span::new(6, 8)))
        );
        assert_eq!(lexer.next_token().unwrap(), None);
    }

    #[test]
    fn test_numbers() {
        let mut lexer = Lexer::new("42 -17 0");

        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Int(42), Span::new(0, 2)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Int(-17), Span::new(3, 6)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Int(0), Span::new(7, 8)))
        );
    }

    #[test]
    fn test_strings() {
        let mut lexer = Lexer::new(r#""hello" "world\n""#);

        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::String("hello".to_string()), Span::new(0, 7)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::String("world\n".to_string()), Span::new(8, 17)))
        );
    }

    #[test]
    fn test_symbols_and_keywords() {
        let mut lexer = Lexer::new("let lambda if + - foo-bar true false");

        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Let, Span::new(0, 3)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Fn, Span::new(4, 10)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::If, Span::new(11, 13)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Symbol("+".to_string()), Span::new(14, 15)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Symbol("-".to_string()), Span::new(16, 17)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Symbol("foo-bar".to_string()), Span::new(18, 25)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Bool(true), Span::new(26, 30)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Bool(false), Span::new(31, 36)))
        );
    }

    #[test]
    fn test_comments() {
        let mut lexer = Lexer::new("42 ; this is a comment\n43");

        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Int(42), Span::new(0, 2)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Int(43), Span::new(23, 25)))
        );
    }
}
