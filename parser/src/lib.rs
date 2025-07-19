mod lexer;

use lexer::{Lexer, Token};
use xs_core::{Expr, Ident, Literal, Pattern, Span, Type, XsError};

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
            Some((Token::Rec, _)) => self.parse_rec(start_span.start),
            Some((Token::Match, _)) => self.parse_match(start_span.start),
            Some((Token::Type, _)) => self.parse_type_definition(start_span.start),
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

    fn parse_rec(&mut self, start: usize) -> Result<Expr, XsError> {
        self.advance()?; // consume 'rec'

        // Parse function name
        let name = match &self.current_token {
            Some((Token::Symbol(s), _)) => {
                let ident = Ident(s.clone());
                self.advance()?;
                ident
            }
            _ => return Err(XsError::ParseError(
                self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                "Expected function name after 'rec'".to_string(),
            )),
        };

        // Parse parameter list
        if let Some((Token::LeftParen, _)) = &self.current_token {
            self.advance()?;
        } else {
            return Err(XsError::ParseError(
                self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                "Expected '(' after function name".to_string(),
            ));
        }

        let mut params = Vec::new();
        while let Some((Token::Symbol(param_name), _)) = &self.current_token {
            let ident = Ident(param_name.clone());
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
                "Expected ')' after parameters".to_string(),
            ));
        }

        // Parse optional return type
        let return_type = if let Some((Token::Colon, _)) = &self.current_token {
            self.advance()?;
            Some(self.parse_type()?)
        } else {
            None
        };

        // Parse body
        let body = Box::new(self.parse_expr()?);

        let end = match &self.current_token {
            Some((Token::RightParen, span)) => {
                let end = span.end;
                self.advance()?;
                end
            }
            _ => return Err(XsError::ParseError(
                self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                "Expected ')' after rec body".to_string(),
            )),
        };

        Ok(Expr::Rec {
            name,
            params,
            return_type,
            body,
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
        let first_expr = self.parse_expr()?;
        
        // Check if it's a constructor (starts with uppercase)
        if let Expr::Ident(Ident(name), _) = &first_expr {
            if name.chars().next().map_or(false, |c| c.is_uppercase()) {
                // Parse as constructor
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
                        "Expected ')' after constructor".to_string(),
                    )),
                };
                
                return Ok(Expr::Constructor {
                    name: Ident(name.clone()),
                    args,
                    span: Span::new(start, end),
                });
            }
        }
        
        // Otherwise, parse as regular application
        let func = Box::new(first_expr);
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

    fn parse_match(&mut self, start: usize) -> Result<Expr, XsError> {
        self.advance()?; // consume 'match'
        
        // Parse the expression to match
        let expr = Box::new(self.parse_expr()?);
        
        // Parse cases
        let mut cases = Vec::new();
        
        while let Some((token, _)) = &self.current_token {
            if matches!(token, Token::RightParen) {
                break;
            }
            
            // Each case should be (pattern expr)
            if let Some((Token::LeftParen, _)) = &self.current_token {
                self.advance()?;
                
                let pattern = self.parse_pattern()?;
                let case_expr = self.parse_expr()?;
                
                if let Some((Token::RightParen, _)) = &self.current_token {
                    self.advance()?;
                } else {
                    return Err(XsError::ParseError(
                        self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                        "Expected ')' after match case".to_string(),
                    ));
                }
                
                cases.push((pattern, case_expr));
            } else {
                return Err(XsError::ParseError(
                    self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                    "Expected '(' for match case".to_string(),
                ));
            }
        }
        
        let end = match &self.current_token {
            Some((Token::RightParen, span)) => {
                let end = span.end;
                self.advance()?;
                end
            }
            _ => return Err(XsError::ParseError(
                self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                "Expected ')' after match expression".to_string(),
            )),
        };
        
        Ok(Expr::Match {
            expr,
            cases,
            span: Span::new(start, end),
        })
    }
    
    fn parse_pattern(&mut self) -> Result<Pattern, XsError> {
        match &self.current_token {
            Some((Token::Underscore, span)) => {
                let pattern = Pattern::Wildcard(span.clone());
                self.advance()?;
                Ok(pattern)
            }
            Some((Token::Int(n), span)) => {
                let pattern = Pattern::Literal(Literal::Int(*n), span.clone());
                self.advance()?;
                Ok(pattern)
            }
            Some((Token::Bool(b), span)) => {
                let pattern = Pattern::Literal(Literal::Bool(*b), span.clone());
                self.advance()?;
                Ok(pattern)
            }
            Some((Token::String(s), span)) => {
                let pattern = Pattern::Literal(Literal::String(s.clone()), span.clone());
                self.advance()?;
                Ok(pattern)
            }
            Some((Token::LeftParen, _)) => {
                self.advance()?;
                
                // Check if it's a constructor pattern or list pattern
                if let Some((Token::Symbol(name), name_span)) = &self.current_token {
                    let constructor_name = Ident(name.clone());
                    let constructor_span = name_span.clone();
                    self.advance()?;
                    
                    let mut patterns = Vec::new();
                    while let Some((token, _)) = &self.current_token {
                        if matches!(token, Token::RightParen) {
                            break;
                        }
                        patterns.push(self.parse_pattern()?);
                    }
                    
                    let end = match &self.current_token {
                        Some((Token::RightParen, span)) => {
                            let end = span.end;
                            self.advance()?;
                            end
                        }
                        _ => return Err(XsError::ParseError(
                            self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                            "Expected ')' after constructor pattern".to_string(),
                        )),
                    };
                    
                    Ok(Pattern::Constructor {
                        name: constructor_name,
                        patterns,
                        span: Span::new(constructor_span.start, end),
                    })
                } else if let Some((Token::List, _)) = &self.current_token {
                    self.advance()?;
                    
                    let mut patterns = Vec::new();
                    while let Some((token, _)) = &self.current_token {
                        if matches!(token, Token::RightParen) {
                            break;
                        }
                        patterns.push(self.parse_pattern()?);
                    }
                    
                    let end = match &self.current_token {
                        Some((Token::RightParen, span)) => {
                            let end = span.end;
                            self.advance()?;
                            end
                        }
                        _ => return Err(XsError::ParseError(
                            self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                            "Expected ')' after list pattern".to_string(),
                        )),
                    };
                    
                    Ok(Pattern::List {
                        patterns,
                        span: Span::new(0, end), // TODO: proper span
                    })
                } else {
                    Err(XsError::ParseError(
                        self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                        "Expected constructor name or 'list' in pattern".to_string(),
                    ))
                }
            }
            Some((Token::Symbol(name), span)) => {
                // Variable pattern
                let pattern = Pattern::Variable(Ident(name.clone()), span.clone());
                self.advance()?;
                Ok(pattern)
            }
            _ => Err(XsError::ParseError(
                self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                "Expected pattern".to_string(),
            )),
        }
    }
    
    fn parse_type_definition(&mut self, start: usize) -> Result<Expr, XsError> {
        use xs_core::{TypeDefinition, Constructor};
        
        self.advance()?; // consume 'type'
        
        // Parse type name
        let type_name = match &self.current_token {
            Some((Token::Symbol(name), _)) => {
                let name = name.clone();
                self.advance()?;
                name
            }
            _ => return Err(XsError::ParseError(
                self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                "Expected type name after 'type'".to_string(),
            )),
        };
        
        // Parse type parameters (optional)
        let mut type_params = Vec::new();
        while let Some((Token::Symbol(param), _)) = &self.current_token {
            if param.chars().next().map_or(false, |c| c.is_lowercase()) {
                type_params.push(param.clone());
                self.advance()?;
            } else {
                break;
            }
        }
        
        // Parse constructors
        let mut constructors = Vec::new();
        
        while let Some((token, _)) = &self.current_token {
            if matches!(token, Token::RightParen) {
                break;
            }
            
            // Each constructor should be (Name field1 field2 ...)
            if let Some((Token::LeftParen, _)) = &self.current_token {
                self.advance()?;
                
                let constructor_name = match &self.current_token {
                    Some((Token::Symbol(name), _)) => {
                        if !name.chars().next().map_or(false, |c| c.is_uppercase()) {
                            return Err(XsError::ParseError(
                                self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                                "Constructor name must start with uppercase letter".to_string(),
                            ));
                        }
                        let name = name.clone();
                        self.advance()?;
                        name
                    }
                    _ => return Err(XsError::ParseError(
                        self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                        "Expected constructor name".to_string(),
                    )),
                };
                
                // Parse constructor fields
                let mut fields = Vec::new();
                while let Some((token, _)) = &self.current_token {
                    if matches!(token, Token::RightParen) {
                        break;
                    }
                    fields.push(self.parse_type()?);
                }
                
                if let Some((Token::RightParen, _)) = &self.current_token {
                    self.advance()?;
                } else {
                    return Err(XsError::ParseError(
                        self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                        "Expected ')' after constructor".to_string(),
                    ));
                }
                
                constructors.push(Constructor {
                    name: constructor_name,
                    fields,
                });
            } else {
                return Err(XsError::ParseError(
                    self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                    "Expected '(' for constructor definition".to_string(),
                ));
            }
        }
        
        let end = match &self.current_token {
            Some((Token::RightParen, span)) => {
                let end = span.end;
                self.advance()?;
                end
            }
            _ => return Err(XsError::ParseError(
                self.current_token.as_ref().map(|(_, span)| span.start).unwrap_or(0),
                "Expected ')' after type definition".to_string(),
            )),
        };
        
        let definition = TypeDefinition {
            name: type_name,
            type_params,
            constructors,
        };
        
        Ok(Expr::TypeDef {
            definition,
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
    fn test_parse_rec() {
        let expr = parse("(rec factorial (n) (* n 2))").unwrap();
        match expr {
            Expr::Rec { name, params, return_type, body, .. } => {
                assert_eq!(name.0, "factorial");
                assert_eq!(params.len(), 1);
                assert_eq!(params[0].0.0, "n");
                assert!(return_type.is_none());
                // body should be (* n 2)
                match body.as_ref() {
                    Expr::Apply { .. } => {},
                    _ => panic!("Expected apply in body"),
                }
            },
            _ => panic!("Expected Rec expression"),
        }

        // Test with type annotations
        let expr = parse("(rec add (x : Int y : Int) : Int (+ x y))").unwrap();
        match expr {
            Expr::Rec { name, params, return_type, .. } => {
                assert_eq!(name.0, "add");
                assert_eq!(params.len(), 2);
                assert_eq!(params[0].0.0, "x");
                assert_eq!(params[1].0.0, "y");
                assert!(params[0].1.is_some());
                assert!(params[1].1.is_some());
                assert_eq!(return_type, Some(Type::Int));
            },
            _ => panic!("Expected Rec expression"),
        }
    }

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
    
    #[test]
    fn test_parse_match() {
        let expr = parse("(match x (0 \"zero\") (1 \"one\") (_ \"other\"))").unwrap();
        match expr {
            Expr::Match { cases, .. } => {
                assert_eq!(cases.len(), 3);
                // Check first case
                match &cases[0].0 {
                    Pattern::Literal(Literal::Int(0), _) => {},
                    _ => panic!("Expected literal 0 pattern"),
                }
                // Check last case
                match &cases[2].0 {
                    Pattern::Wildcard(_) => {},
                    _ => panic!("Expected wildcard pattern"),
                }
            },
            _ => panic!("Expected Match expression"),
        }
    }
    
    #[test]
    fn test_parse_constructor() {
        let expr = parse("(Some 42)").unwrap();
        match expr {
            Expr::Constructor { name, args, .. } => {
                assert_eq!(name.0, "Some");
                assert_eq!(args.len(), 1);
            },
            _ => panic!("Expected Constructor expression"),
        }
    }
    
    #[test]
    fn test_parse_pattern() {
        // Test parsing a pattern directly within a match expression
        let expr = parse("(match x ((Some y) y))").unwrap();
        match expr {
            Expr::Match { cases, .. } => {
                assert_eq!(cases.len(), 1);
                match &cases[0].0 {
                    Pattern::Constructor { name, patterns, .. } => {
                        assert_eq!(name.0, "Some");
                        assert_eq!(patterns.len(), 1);
                        match &patterns[0] {
                            Pattern::Variable(Ident(v), _) => assert_eq!(v, "y"),
                            _ => panic!("Expected variable pattern"),
                        }
                    },
                    _ => panic!("Expected constructor pattern"),
                }
            },
            _ => panic!("Expected Match expression"),
        }
    }
    
    #[test]
    fn test_parse_type_definition() {
        // Simple type without parameters
        let expr = parse("(type Option (Some value) (None))").unwrap();
        match expr {
            Expr::TypeDef { definition, .. } => {
                assert_eq!(definition.name, "Option");
                assert_eq!(definition.type_params.len(), 0);
                assert_eq!(definition.constructors.len(), 2);
                assert_eq!(definition.constructors[0].name, "Some");
                assert_eq!(definition.constructors[0].fields.len(), 1);
                assert_eq!(definition.constructors[1].name, "None");
                assert_eq!(definition.constructors[1].fields.len(), 0);
            },
            _ => panic!("Expected TypeDef expression"),
        }
        
        // Type with type parameters
        let expr = parse("(type Result a b (Ok a) (Err b))").unwrap();
        match expr {
            Expr::TypeDef { definition, .. } => {
                assert_eq!(definition.name, "Result");
                assert_eq!(definition.type_params, vec!["a", "b"]);
                assert_eq!(definition.constructors.len(), 2);
                assert_eq!(definition.constructors[0].fields.len(), 1);
                assert_eq!(definition.constructors[1].fields.len(), 1);
            },
            _ => panic!("Expected TypeDef expression"),
        }
    }
}