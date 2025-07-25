//! Search pattern parsing and matching for code search functionality

use anyhow::{anyhow, Result};
use vibe_core::{Expr, Type};

/// Parse a type pattern string into a matcher function
pub fn parse_type_pattern(pattern: &str) -> Result<Box<dyn Fn(&Type) -> bool>> {
    let pattern = pattern.trim();

    // Handle arrow types with wildcards
    if pattern.contains("->") {
        return Ok(Box::new(parse_function_pattern(pattern)?));
    }

    // Handle generic patterns
    match pattern {
        "Int" => Ok(Box::new(|t| matches!(t, Type::Int))),
        "String" => Ok(Box::new(|t| matches!(t, Type::String))),
        "Bool" => Ok(Box::new(|t| matches!(t, Type::Bool))),
        "Float" => Ok(Box::new(|t| matches!(t, Type::Float))),
        "[_]" => Ok(Box::new(|t| matches!(t, Type::List(_)))),
        "[Int]" => Ok(Box::new(|t| {
            if let Type::List(elem) = t {
                matches!(elem.as_ref(), Type::Int)
            } else {
                false
            }
        })),
        "[String]" => Ok(Box::new(|t| {
            if let Type::List(elem) = t {
                matches!(elem.as_ref(), Type::String)
            } else {
                false
            }
        })),
        "_" => Ok(Box::new(|_| true)),
        _ => {
            // Check if it's a type variable or user-defined type
            let name = pattern.to_string();
            Ok(Box::new(move |t| match t {
                Type::Var(v) => v == &name,
                Type::UserDefined { name: n, .. } => n == &name,
                _ => false,
            }))
        }
    }
}

fn parse_function_pattern(pattern: &str) -> Result<impl Fn(&Type) -> bool> {
    let parts: Vec<&str> = pattern.split("->").map(|s| s.trim()).collect();

    if parts.len() == 2 {
        let from_pattern = parts[0];
        let to_pattern = parts[1];

        let from_matcher = parse_type_pattern(from_pattern)?;
        let to_matcher = parse_type_pattern(to_pattern)?;

        Ok(move |t: &Type| {
            if let Type::Function(from, to) = t {
                from_matcher(from) && to_matcher(to)
            } else {
                false
            }
        })
    } else {
        Err(anyhow!("Invalid function pattern: {}", pattern))
    }
}

/// AST pattern matching
pub enum AstPattern {
    Match,
    Lambda,
    If,
    Let,
    LetIn,
    Apply,
    List,
    Record,
    Pipeline,
}

impl AstPattern {
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "match" => Some(AstPattern::Match),
            "lambda" | "fn" => Some(AstPattern::Lambda),
            "if" => Some(AstPattern::If),
            "let" => Some(AstPattern::Let),
            "letin" | "let-in" => Some(AstPattern::LetIn),
            "apply" | "call" => Some(AstPattern::Apply),
            "list" => Some(AstPattern::List),
            "record" => Some(AstPattern::Record),
            "pipeline" | "|>" => Some(AstPattern::Pipeline),
            _ => None,
        }
    }

    pub fn matches(&self, expr: &Expr) -> bool {
        match (self, expr) {
            (AstPattern::Match, Expr::Match { .. }) => true,
            (AstPattern::Lambda, Expr::Lambda { .. }) => true,
            (AstPattern::If, Expr::If { .. }) => true,
            (AstPattern::Let, Expr::Let { .. }) => true,
            (AstPattern::LetIn, Expr::LetIn { .. }) => true,
            (AstPattern::Apply, Expr::Apply { .. }) => true,
            (AstPattern::List, Expr::List(_, _)) => true,
            (AstPattern::Record, Expr::RecordLiteral { .. }) => true,
            (AstPattern::Pipeline, Expr::Pipeline { .. }) => true,
            _ => false,
        }
    }
}

/// Check if an expression contains a specific AST pattern
pub fn expr_contains_pattern(expr: &Expr, pattern: &AstPattern) -> bool {
    if pattern.matches(expr) {
        return true;
    }

    match expr {
        Expr::Lambda { body, .. } => expr_contains_pattern(body, pattern),
        Expr::Apply { func, args, .. } => {
            expr_contains_pattern(func, pattern)
                || args.iter().any(|arg| expr_contains_pattern(arg, pattern))
        }
        Expr::Let { value, .. } | Expr::LetRec { value, .. } => {
            expr_contains_pattern(value, pattern)
        }
        Expr::LetIn { value, body, .. } | Expr::LetRecIn { value, body, .. } => {
            expr_contains_pattern(value, pattern) || expr_contains_pattern(body, pattern)
        }
        Expr::If {
            cond,
            then_expr,
            else_expr,
            ..
        } => {
            expr_contains_pattern(cond, pattern)
                || expr_contains_pattern(then_expr, pattern)
                || expr_contains_pattern(else_expr, pattern)
        }
        Expr::Match { expr, cases, .. } => {
            expr_contains_pattern(expr, pattern)
                || cases.iter().any(|(_, e)| expr_contains_pattern(e, pattern))
        }
        Expr::List(exprs, _) => exprs.iter().any(|e| expr_contains_pattern(e, pattern)),
        Expr::Block { exprs, .. } => exprs.iter().any(|e| expr_contains_pattern(e, pattern)),
        Expr::Pipeline { expr, func, .. } => {
            expr_contains_pattern(expr, pattern) || expr_contains_pattern(func, pattern)
        }
        Expr::RecordLiteral { fields, .. } => fields
            .iter()
            .any(|(_, e)| expr_contains_pattern(e, pattern)),
        Expr::RecordAccess { record, .. } => expr_contains_pattern(record, pattern),
        Expr::RecordUpdate {
            record, updates, ..
        } => {
            expr_contains_pattern(record, pattern)
                || updates
                    .iter()
                    .any(|(_, e)| expr_contains_pattern(e, pattern))
        }
        _ => false,
    }
}

/// Advanced pattern matching for complex queries
pub struct SearchQuery {
    pub type_pattern: Option<Box<dyn Fn(&Type) -> bool>>,
    pub ast_pattern: Option<AstPattern>,
    pub name_pattern: Option<String>,
    pub depends_on: Option<String>,
}

impl SearchQuery {
    pub fn parse(query: &str) -> Result<Self> {
        let mut search_query = SearchQuery {
            type_pattern: None,
            ast_pattern: None,
            name_pattern: None,
            depends_on: None,
        };

        // Parse multiple criteria separated by spaces
        let parts: Vec<&str> = query.split_whitespace().collect();

        for part in parts {
            if let Some(type_pat) = part.strip_prefix("type:") {
                search_query.type_pattern = Some(parse_type_pattern(type_pat)?);
            } else if let Some(ast_pat) = part.strip_prefix("ast:") {
                search_query.ast_pattern = AstPattern::from_str(ast_pat);
            } else if let Some(name_pat) = part.strip_prefix("name:") {
                search_query.name_pattern = Some(name_pat.to_string());
            } else if let Some(dep) = part.strip_prefix("dependsOn:") {
                search_query.depends_on = Some(dep.to_string());
            }
        }

        Ok(search_query)
    }
}
