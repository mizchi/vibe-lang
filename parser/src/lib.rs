mod lexer;

use lexer::{Lexer, Token};
use xs_core::{Expr, Ident, Literal, Span, Type, XsError};

pub struct Parser<'a> {
    lexer: Lexer<'a>,
    current_token: Option<(Token, Span)>,
}

impl<'a> Parser<'a> {
    pub fn new(input: &'a str) -> Self {
        let mut parser = Parser {
            lexer: Lexer::new(input),
            current_token: None,
        };
        parser.advance().ok();
        parser
    }

    pub fn parse(&mut self) -> Result<Expr, XsError> {
        self.parse_expr()
    }

    fn advance(&mut self) -> Result<(), XsError> {
        self.current_token = self.lexer.next_token()?;
        Ok(())
    }

    fn parse_expr(&mut self) -> Result<Expr, XsError> {
        match &self.current_token {
            Some((Token::LeftParen, _)) => self.parse_list(),
            Some((Token::Int(n), span)) => {
                let expr = Expr::Literal(Literal::Int(*n), span.clone());
                self.advance()?;
                Ok(expr)
            }
            Some((Token::Bool(b), span)) => {
                let expr = Expr::Literal(Literal::Bool(*b), span.clone());
                self.advance()?;
                Ok(expr)
            }
            Some((Token::String(s), span)) => {
                let expr = Expr::Literal(Literal::String(s.clone()), span.clone());
                self.advance()?;
                Ok(expr)
            }
            Some((Token::Symbol(s), span)) => {
                let expr = Expr::Ident(Ident(s.clone()), span.clone());
                self.advance()?;
                Ok(expr)
            }
            Some((_, span)) => Err(XsError::ParseError(
                span.start,
                "Expected expression".to_string(),
            )),
            None => Err(XsError::ParseError(0, "Unexpected end of input".to_string())),
        }
    }

    fn parse_list(&mut self) -> Result<Expr, XsError> {
        let start_span = match &self.current_token {
            Some((Token::LeftParen, span)) => span.clone(),
            _ => unreachable!(),
        };
        self.advance()?;

        if let Some((Token::RightParen, end_span)) = &self.current_token {
            let span = Span::new(start_span.start, end_span.end);
            self.advance()?;
            return Ok(Expr::List(vec![], span));
        }

        match &self.current_token {
            Some((Token::Let, _)) => self.parse_let(start_span.start),
            Some((Token::LetRec, _)) => self.parse_let_rec(start_span.start),
            Some((Token::Lambda, _)) => self.parse_lambda(start_span.start),
            Some((Token::If, _)) => self.parse_if(start_span.start),
            Some((Token::List, _)) => self.parse_list_literal(start_span.start),
            Some((Token::Cons, _)) => self.parse_cons(start_span.start),
            _ => self.parse_application(start_span.start),
        }
    }

    fn parse_let(&mut self, start: usize) -> Result<Expr, XsError> {
        self.advance()?; // consume 'let'

        let name = match &self.current_token {
            Some((Token::Symbol(s), _)) => {
                let ident = Ident(s.clone());
                self.advance()?;
                ident
            }
            _ => return Err(XsError::ParseError(
                self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                "Expected variable name after 'let'".to_string(),
            )),
        };

        let type_ann = if let Some((Token::Colon, _)) = &self.current_token {
            self.advance()?;
            Some(self.parse_type()?)
        } else {
            None
        };

        let value = Box::new(self.parse_expr()?);

        let end = match &self.current_token {
            Some((Token::RightParen, span)) => {
                let end = span.end;
                self.advance()?;
                end
            }
            _ => return Err(XsError::ParseError(
                self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                "Expected ')' after let expression".to_string(),
            )),
        };

        Ok(Expr::Let {
            name,
            type_ann,
            value,
            span: Span::new(start, end),
        })
    }

    fn parse_let_rec(&mut self, start: usize) -> Result<Expr, XsError> {
        self.advance()?; // consume 'let-rec'

        let name = match &self.current_token {
            Some((Token::Symbol(s), _)) => {
                let ident = Ident(s.clone());
                self.advance()?;
                ident
            }
            _ => return Err(XsError::ParseError(
                self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                "Expected variable name after 'let-rec'".to_string(),
            )),
        };

        let type_ann = if let Some((Token::Colon, _)) = &self.current_token {
            self.advance()?;
            Some(self.parse_type()?)
        } else {
            None
        };

        let value = Box::new(self.parse_expr()?);

        let end = match &self.current_token {
            Some((Token::RightParen, span)) => {
                let end = span.end;
                self.advance()?;
                end
            }
            _ => return Err(XsError::ParseError(
                self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                "Expected ')' after let-rec expression".to_string(),
            )),
        };

        Ok(Expr::LetRec {
            name,
            type_ann,
            value,
            span: Span::new(start, end),
        })
    }

    fn parse_lambda(&mut self, start: usize) -> Result<Expr, XsError> {
        self.advance()?; // consume 'lambda'

        // Parse parameter list
        if let Some((Token::LeftParen, _)) = &self.current_token {
            self.advance()?;
        } else {
            return Err(XsError::ParseError(
                self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                "Expected '(' after 'lambda'".to_string(),
            ));
        }

        let mut params = Vec::new();
        while let Some((Token::Symbol(name), _)) = &self.current_token {
            let ident = Ident(name.clone());
            self.advance()?;

            let type_ann = if let Some((Token::Colon, _)) = &self.current_token {
                self.advance()?;
                Some(self.parse_type()?)
            } else {
                None
            };

            params.push((ident, type_ann));
        }

        if let Some((Token::RightParen, _)) = &self.current_token {
            self.advance()?;
        } else {
            return Err(XsError::ParseError(
                self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                "Expected ')' after lambda parameters".to_string(),
            ));
        }

        let body = Box::new(self.parse_expr()?);

        let end = match &self.current_token {
            Some((Token::RightParen, span)) => {
                let end = span.end;
                self.advance()?;
                end
            }
            _ => return Err(XsError::ParseError(
                self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                "Expected ')' after lambda body".to_string(),
            )),
        };

        Ok(Expr::Lambda {
            params,
            body,
            span: Span::new(start, end),
        })
    }

    fn parse_if(&mut self, start: usize) -> Result<Expr, XsError> {
        self.advance()?; // consume 'if'

        let cond = Box::new(self.parse_expr()?);
        let then_expr = Box::new(self.parse_expr()?);
        let else_expr = Box::new(self.parse_expr()?);

        let end = match &self.current_token {
            Some((Token::RightParen, span)) => {
                let end = span.end;
                self.advance()?;
                end
            }
            _ => return Err(XsError::ParseError(
                self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                "Expected ')' after if expression".to_string(),
            )),
        };

        Ok(Expr::If {
            cond,
            then_expr,
            else_expr,
            span: Span::new(start, end),
        })
    }

    fn parse_list_literal(&mut self, start: usize) -> Result<Expr, XsError> {
        self.advance()?; // consume 'list'
        
        let mut args = Vec::new();
        
        while let Some((token, _)) = &self.current_token {
            if matches!(token, Token::RightParen) {
                break;
            }
            args.push(self.parse_expr()?);
        }
        
        let end = match &self.current_token {
            Some((Token::RightParen, span)) => {
                let end = span.end;
                self.advance()?;
                end
            }
            _ => return Err(XsError::ParseError(
                self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                "Expected ')' after list".to_string(),
            )),
        };
        
        Ok(Expr::List(args, Span::new(start, end)))
    }

    fn parse_cons(&mut self, start: usize) -> Result<Expr, XsError> {
        self.advance()?; // consume 'cons'
        
        let args = vec![self.parse_expr()?, self.parse_expr()?];
        
        let end = match &self.current_token {
            Some((Token::RightParen, span)) => {
                let end = span.end;
                self.advance()?;
                end
            }
            _ => return Err(XsError::ParseError(
                self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                "Expected ')' after cons".to_string(),
            )),
        };
        
        Ok(Expr::Apply {
            func: Box::new(Expr::Ident(Ident("cons".to_string()), Span::new(start + 1, start + 5))),
            args,
            span: Span::new(start, end),
        })
    }

    fn parse_application(&mut self, start: usize) -> Result<Expr, XsError> {
        let func = Box::new(self.parse_expr()?);
        let mut args = Vec::new();

        while let Some((token, _)) = &self.current_token {
            if matches!(token, Token::RightParen) {
                break;
            }
            args.push(self.parse_expr()?);
        }

        let end = match &self.current_token {
            Some((Token::RightParen, span)) => {
                let end = span.end;
                self.advance()?;
                end
            }
            _ => return Err(XsError::ParseError(
                self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                "Expected ')' after application".to_string(),
            )),
        };

        Ok(Expr::Apply {
            func,
            args,
            span: Span::new(start, end),
        })
    }

    fn parse_type(&mut self) -> Result<Type, XsError> {
        match &self.current_token {
            Some((Token::Symbol(s), _)) => {
                let type_name = s.clone();
                self.advance()?;
                match type_name.as_str() {
                    "Int" => Ok(Type::Int),
                    "Bool" => Ok(Type::Bool),
                    "String" => Ok(Type::String),
                    _ => Ok(Type::Var(type_name)),
                }
            }
            Some((Token::LeftParen, _)) => {
                self.advance()?;
                match &self.current_token {
                    Some((Token::Arrow, _)) => {
                        self.advance()?;
                        let from = Box::new(self.parse_type()?);
                        let to = Box::new(self.parse_type()?);
                        if let Some((Token::RightParen, _)) = &self.current_token {
                            self.advance()?;
                            Ok(Type::Function(from, to))
                        } else {
                            Err(XsError::ParseError(
                                self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                                "Expected ')' after function type".to_string(),
                            ))
                        }
                    }
                    Some((Token::Symbol(s), _)) if s == "List" => {
                        self.advance()?;
                        let elem_type = Box::new(self.parse_type()?);
                        if let Some((Token::RightParen, _)) = &self.current_token {
                            self.advance()?;
                            Ok(Type::List(elem_type))
                        } else {
                            Err(XsError::ParseError(
                                self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                                "Expected ')' after List type".to_string(),
                            ))
                        }
                    }
                    _ => Err(XsError::ParseError(
                        self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                        "Expected type constructor".to_string(),
                    )),
                }
            }
            _ => Err(XsError::ParseError(
                self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                "Expected type".to_string(),
            )),
        }
    }
}

pub fn parse(input: &str) -> Result<Expr, XsError> {
    let mut parser = Parser::new(input);
    parser.parse()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_literals() {
        let expr = parse("42").unwrap();
        match expr {
            Expr::Literal(Literal::Int(42), _) => {},
            _ => panic!("Expected Int literal"),
        }

        let expr = parse("true").unwrap();
        match expr {
            Expr::Literal(Literal::Bool(true), _) => {},
            _ => panic!("Expected Bool literal"),
        }

        let expr = parse(r#""hello""#).unwrap();
        match expr {
            Expr::Literal(Literal::String(s), _) if s == "hello" => {},
            _ => panic!("Expected String literal"),
        }
    }

    #[test]
    fn test_parse_identifiers() {
        let expr = parse("foo").unwrap();
        match expr {
            Expr::Ident(Ident(name), _) if name == "foo" => {},
            _ => panic!("Expected identifier"),
        }
    }

    #[test]
    fn test_parse_let() {
        let expr = parse("(let x 42)").unwrap();
        match expr {
            Expr::Let { name, type_ann, value, .. } => {
                assert_eq!(name.0, "x");
                assert_eq!(type_ann, None);
                match value.as_ref() {
                    Expr::Literal(Literal::Int(42), _) => {},
                    _ => panic!("Expected Int literal in let binding"),
                }
            },
            _ => panic!("Expected let expression"),
        }

        let expr = parse("(let x : Int 42)").unwrap();
        match expr {
            Expr::Let { name, type_ann, .. } => {
                assert_eq!(name.0, "x");
                assert_eq!(type_ann, Some(Type::Int));
            },
            _ => panic!("Expected let expression with type annotation"),
        }
    }

    #[test]
    fn test_parse_lambda() {
        let expr = parse("(lambda (x) x)").unwrap();
        match expr {
            Expr::Lambda { params, body, .. } => {
                assert_eq!(params.len(), 1);
                assert_eq!(params[0].0.0, "x");
                assert_eq!(params[0].1, None);
                match body.as_ref() {
                    Expr::Ident(Ident(name), _) if name == "x" => {},
                    _ => panic!("Expected identifier in lambda body"),
                }
            },
            _ => panic!("Expected lambda expression"),
        }

        let expr = parse("(lambda (x : Int y : Bool) (+ x 1))").unwrap();
        match expr {
            Expr::Lambda { params, .. } => {
                assert_eq!(params.len(), 2);
                assert_eq!(params[0].0.0, "x");
                assert_eq!(params[0].1, Some(Type::Int));
                assert_eq!(params[1].0.0, "y");
                assert_eq!(params[1].1, Some(Type::Bool));
            },
            _ => panic!("Expected lambda expression with typed parameters"),
        }
    }

    #[test]
    fn test_parse_if() {
        let expr = parse("(if true 1 2)").unwrap();
        match expr {
            Expr::If { cond, then_expr, else_expr, .. } => {
                match cond.as_ref() {
                    Expr::Literal(Literal::Bool(true), _) => {},
                    _ => panic!("Expected Bool literal in condition"),
                }
                match then_expr.as_ref() {
                    Expr::Literal(Literal::Int(1), _) => {},
                    _ => panic!("Expected Int literal in then branch"),
                }
                match else_expr.as_ref() {
                    Expr::Literal(Literal::Int(2), _) => {},
                    _ => panic!("Expected Int literal in else branch"),
                }
            },
            _ => panic!("Expected if expression"),
        }
    }

    #[test]
    fn test_parse_application() {
        let expr = parse("(+ 1 2)").unwrap();
        match expr {
            Expr::Apply { func, args, .. } => {
                match func.as_ref() {
                    Expr::Ident(Ident(name), _) if name == "+" => {},
                    _ => panic!("Expected + function"),
                }
                assert_eq!(args.len(), 2);
            },
            _ => panic!("Expected application"),
        }
    }

    #[test]
    fn test_parse_list() {
        let expr = parse("(list 1 2 3)").unwrap();
        match expr {
            Expr::List(elems, _) => {
                assert_eq!(elems.len(), 3);
            },
            _ => panic!("Expected list"),
        }

        let expr = parse("(list)").unwrap();
        match expr {
            Expr::List(elems, _) => {
                assert_eq!(elems.len(), 0);
            },
            _ => panic!("Expected empty list"),
        }
    }

    #[test]
    fn test_parse_let_rec() {
        let expr = parse("(let-rec fact (lambda (n) (if (= n 0) 1 (* n (fact (- n 1))))))").unwrap();
        match expr {
            Expr::LetRec { name, type_ann, value, .. } => {
                assert_eq!(name.0, "fact");
                assert_eq!(type_ann, None);
                match value.as_ref() {
                    Expr::Lambda { .. } => {},
                    _ => panic!("Expected Lambda in let-rec binding"),
                }
            },
            _ => panic!("Expected let-rec expression"),
        }
    }

    #[test]
    fn test_parse_types() {
        let mut parser = Parser::new("Int");
        let typ = parser.parse_type().unwrap();
        assert_eq!(typ, Type::Int);

        let mut parser = Parser::new("(-> Int Bool)");
        let typ = parser.parse_type().unwrap();
        match typ {
            Type::Function(from, to) => {
                assert_eq!(*from, Type::Int);
                assert_eq!(*to, Type::Bool);
            },
            _ => panic!("Expected function type"),
        }

        let mut parser = Parser::new("(List Int)");
        let typ = parser.parse_type().unwrap();
        match typ {
            Type::List(elem) => {
                assert_eq!(*elem, Type::Int);
            },
            _ => panic!("Expected list type"),
        }
    }
}