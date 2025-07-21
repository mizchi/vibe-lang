//! Parser that preserves metadata (comments, source locations, etc.)

use super::lexer::{Lexer, Token};
use crate::{
    metadata::{MetadataKind, MetadataStore, NodeId},
    Expr, Ident, Literal, Span, Type, XsError,
};

pub struct MetadataParser<'a> {
    lexer: Lexer<'a>,
    current_token: Option<(Token, Span)>,
    metadata_store: MetadataStore,
    pending_comments: Vec<(String, Span)>,
}

impl<'a> MetadataParser<'a> {
    pub fn new(input: &'a str) -> Self {
        let mut lexer = Lexer::with_comments(input);
        let mut current_token = lexer.next_token().ok().flatten();
        let mut pending_comments = Vec::new();

        // Skip initial comments
        while let Some((Token::Comment(comment), span)) = &current_token {
            pending_comments.push((comment.clone(), span.clone()));
            current_token = lexer.next_token().ok().flatten();
        }

        Self {
            lexer,
            current_token,
            metadata_store: MetadataStore::new(),
            pending_comments,
        }
    }

    pub fn parse(mut self) -> Result<(Expr, MetadataStore), XsError> {
        let expr = self.parse_expr()?;
        Ok((expr, self.metadata_store))
    }

    fn advance(&mut self) -> Result<(), XsError> {
        self.current_token = self.lexer.next_token()?;

        // コメントトークンを収集
        while let Some((Token::Comment(comment), span)) = &self.current_token {
            self.pending_comments.push((comment.clone(), span.clone()));
            self.current_token = self.lexer.next_token()?;
        }

        Ok(())
    }

    fn consume_pending_comments(&mut self, node_id: &NodeId) {
        for (comment, span) in self.pending_comments.drain(..) {
            self.metadata_store.add_metadata(
                node_id.clone(),
                MetadataKind::Comment(comment),
                Some(span),
            );
        }
    }

    fn parse_expr(&mut self) -> Result<Expr, XsError> {
        let node_id = NodeId::new();
        self.consume_pending_comments(&node_id);

        match &self.current_token {
            Some((Token::LeftParen, _)) => self.parse_list(node_id),
            Some((Token::Int(n), span)) => {
                let expr = Expr::Literal(Literal::Int(*n), span.clone());
                self.metadata_store.register_expr(&expr, node_id);
                self.advance()?;
                Ok(expr)
            }
            Some((Token::Float(f), span)) => {
                let expr = Expr::Literal(Literal::Float((*f).into()), span.clone());
                self.metadata_store.register_expr(&expr, node_id);
                self.advance()?;
                Ok(expr)
            }
            Some((Token::Bool(b), span)) => {
                let expr = Expr::Literal(Literal::Bool(*b), span.clone());
                self.metadata_store.register_expr(&expr, node_id);
                self.advance()?;
                Ok(expr)
            }
            Some((Token::String(s), span)) => {
                let expr = Expr::Literal(Literal::String(s.clone()), span.clone());
                self.metadata_store.register_expr(&expr, node_id);
                self.advance()?;
                Ok(expr)
            }
            Some((Token::Symbol(s), span)) => {
                let expr = Expr::Ident(Ident(s.clone()), span.clone());
                self.metadata_store.register_expr(&expr, node_id);
                self.advance()?;
                Ok(expr)
            }
            Some((token, span)) => Err(XsError::ParseError(
                span.start,
                format!("Unexpected token: {token:?}"),
            )),
            None => Err(XsError::ParseError(
                0,
                "Unexpected end of input".to_string(),
            )),
        }
    }

    fn parse_list(&mut self, node_id: NodeId) -> Result<Expr, XsError> {
        let start_span = match &self.current_token {
            Some((_, span)) => span.clone(),
            None => {
                return Err(XsError::ParseError(
                    0,
                    "Expected opening parenthesis".to_string(),
                ))
            }
        };

        self.advance()?; // consume '('

        // 空のリスト
        if matches!(&self.current_token, Some((Token::RightParen, _))) {
            self.advance()?;
            let expr = Expr::List(vec![], start_span);
            self.metadata_store.register_expr(&expr, node_id);
            return Ok(expr);
        }

        // 最初の要素を確認
        match &self.current_token {
            Some((Token::Let, _)) => self.parse_let(node_id, start_span),
            Some((Token::Fn, _)) => self.parse_lambda(node_id, start_span),
            Some((Token::If, _)) => self.parse_if(node_id, start_span),
            Some((Token::List, _)) => self.parse_list_literal(node_id, start_span),
            Some((Token::Cons, _)) => self.parse_cons(node_id, start_span),
            Some((Token::Rec, _)) => self.parse_rec(node_id, start_span),
            Some((Token::Match, _)) => self.parse_match(node_id, start_span),
            Some((Token::Type, _)) => self.parse_type_def(node_id, start_span),
            Some((Token::Module, _)) => self.parse_module(node_id, start_span),
            Some((Token::Import, _)) => self.parse_import(node_id, start_span),
            _ => self.parse_application(node_id, start_span),
        }
    }

    // 他のparse_*メソッドも同様にnode_idを受け取り、メタデータを登録する
    fn parse_let(&mut self, node_id: NodeId, start_span: Span) -> Result<Expr, XsError> {
        self.advance()?; // consume 'let'

        let name = self.parse_identifier()?;
        let value = Box::new(self.parse_expr()?);

        self.expect_right_paren()?;

        let expr = Expr::Let {
            name,
            type_ann: None,
            value,
            span: start_span,
        };
        self.metadata_store.register_expr(&expr, node_id);
        Ok(expr)
    }

    fn parse_lambda(&mut self, node_id: NodeId, start_span: Span) -> Result<Expr, XsError> {
        self.advance()?; // consume 'lambda'

        let params = self.parse_parameters()?;
        let body = Box::new(self.parse_expr()?);

        self.expect_right_paren()?;

        let expr = Expr::Lambda {
            params,
            body,
            span: start_span,
        };
        self.metadata_store.register_expr(&expr, node_id);
        Ok(expr)
    }

    // 残りのメソッドも同様に実装...

    fn parse_identifier(&mut self) -> Result<Ident, XsError> {
        match &self.current_token {
            Some((Token::Symbol(s), _)) => {
                let ident = Ident(s.clone());
                self.advance()?;
                Ok(ident)
            }
            Some((token, span)) => Err(XsError::ParseError(
                span.start,
                format!("Expected identifier, found {token:?}"),
            )),
            None => Err(XsError::ParseError(
                0,
                "Expected identifier, found end of input".to_string(),
            )),
        }
    }

    fn parse_parameters(&mut self) -> Result<Vec<(Ident, Option<Type>)>, XsError> {
        self.expect_left_paren()?;

        let mut params = Vec::new();
        while !matches!(&self.current_token, Some((Token::RightParen, _))) {
            let ident = self.parse_identifier()?;
            params.push((ident, None)); // 型アノテーションは今のところサポートしない
        }

        self.expect_right_paren()?;
        Ok(params)
    }

    fn expect_left_paren(&mut self) -> Result<(), XsError> {
        match &self.current_token {
            Some((Token::LeftParen, _)) => {
                self.advance()?;
                Ok(())
            }
            Some((token, span)) => Err(XsError::ParseError(
                span.start,
                format!("Expected '(', found {token:?}"),
            )),
            None => Err(XsError::ParseError(
                0,
                "Expected '(', found end of input".to_string(),
            )),
        }
    }

    fn expect_right_paren(&mut self) -> Result<(), XsError> {
        match &self.current_token {
            Some((Token::RightParen, _)) => {
                self.advance()?;
                Ok(())
            }
            Some((token, span)) => Err(XsError::ParseError(
                span.start,
                format!("Expected ')', found {token:?}"),
            )),
            None => Err(XsError::ParseError(
                0,
                "Expected ')', found end of input".to_string(),
            )),
        }
    }

    // 簡略化のため、他のメソッドはプレースホルダーとして実装
    fn parse_if(&mut self, _node_id: NodeId, _start_span: Span) -> Result<Expr, XsError> {
        todo!("parse_if")
    }

    fn parse_list_literal(&mut self, _node_id: NodeId, _start_span: Span) -> Result<Expr, XsError> {
        todo!("parse_list_literal")
    }

    fn parse_cons(&mut self, _node_id: NodeId, _start_span: Span) -> Result<Expr, XsError> {
        todo!("parse_cons")
    }

    fn parse_rec(&mut self, _node_id: NodeId, _start_span: Span) -> Result<Expr, XsError> {
        todo!("parse_rec")
    }

    fn parse_match(&mut self, _node_id: NodeId, _start_span: Span) -> Result<Expr, XsError> {
        todo!("parse_match")
    }

    fn parse_type_def(&mut self, _node_id: NodeId, _start_span: Span) -> Result<Expr, XsError> {
        todo!("parse_type_def")
    }

    fn parse_module(&mut self, _node_id: NodeId, _start_span: Span) -> Result<Expr, XsError> {
        todo!("parse_module")
    }

    fn parse_import(&mut self, _node_id: NodeId, _start_span: Span) -> Result<Expr, XsError> {
        todo!("parse_import")
    }

    fn parse_application(&mut self, _node_id: NodeId, _start_span: Span) -> Result<Expr, XsError> {
        todo!("parse_application")
    }
}

/// Parse with metadata preservation
pub fn parse_with_metadata(input: &str) -> Result<(Expr, MetadataStore), XsError> {
    MetadataParser::new(input).parse()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_with_comments() {
        let input = r#"; This is a comment
(let x 42)  ; x is the answer"#;

        let (expr, _metadata) = parse_with_metadata(input).unwrap();

        // Verify the expression is parsed correctly
        match expr {
            Expr::Let { name, .. } => assert_eq!(name.0, "x"),
            _ => panic!("Expected Let expression"),
        }

        // TODO: Verify comments are captured in metadata
    }

    #[test]
    fn test_parse_literal_with_metadata() {
        let input = "42";
        let (expr, _metadata) = parse_with_metadata(input).unwrap();

        match expr {
            Expr::Literal(Literal::Int(42), _) => (),
            _ => panic!("Expected Int literal"),
        }
    }
}
