//! Content hashing for definitions
//!
//! Provides deterministic hashing of XS definitions for content addressing.

use sha2::{Digest, Sha256};
use std::fmt;
use vibe_language::{DoStatement, Expr, Literal, Pattern, Type};

/// A hash identifying a definition by its content
#[derive(Debug, Clone, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
pub struct DefinitionHash(pub [u8; 32]);

impl DefinitionHash {
    /// Compute hash for a definition
    pub fn compute(content: &crate::namespace::DefinitionContent, type_signature: &Type) -> Self {
        let mut hasher = Sha256::new();

        // Hash the content
        match content {
            crate::namespace::DefinitionContent::Function { params, body } => {
                hasher.update(b"function");
                hasher.update(params.len().to_le_bytes());
                for param in params {
                    hasher.update(param.as_bytes());
                    hasher.update(b"\0");
                }
                hash_expr(&mut hasher, body);
            }
            crate::namespace::DefinitionContent::Type {
                params,
                constructors,
            } => {
                hasher.update(b"type");
                hasher.update(params.len().to_le_bytes());
                for param in params {
                    hasher.update(param.as_bytes());
                    hasher.update(b"\0");
                }
                hasher.update(constructors.len().to_le_bytes());
                for (name, types) in constructors {
                    hasher.update(name.as_bytes());
                    hasher.update(b"\0");
                    hasher.update(types.len().to_le_bytes());
                    for ty in types {
                        hash_type(&mut hasher, ty);
                    }
                }
            }
            crate::namespace::DefinitionContent::Value(expr) => {
                hasher.update(b"value");
                hash_expr(&mut hasher, expr);
            }
        }

        // Hash the type signature
        hash_type(&mut hasher, type_signature);

        let result = hasher.finalize();
        let mut hash_bytes = [0u8; 32];
        hash_bytes.copy_from_slice(&result);
        Self(hash_bytes)
    }

    /// Create from hex string
    pub fn from_hex(hex: &str) -> Option<Self> {
        if hex.len() != 64 {
            return None;
        }

        let mut bytes = [0u8; 32];
        for i in 0..32 {
            let byte_str = &hex[i * 2..i * 2 + 2];
            bytes[i] = u8::from_str_radix(byte_str, 16).ok()?;
        }

        Some(Self(bytes))
    }

    /// Convert to hex string
    pub fn to_hex(&self) -> String {
        self.0.iter().map(|b| format!("{b:02x}")).collect()
    }

    /// Get a short prefix for display (first 8 chars)
    pub fn short(&self) -> String {
        self.to_hex()[..8].to_string()
    }
}

impl fmt::Display for DefinitionHash {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.to_hex())
    }
}

/// Hash an expression deterministically
fn hash_expr(hasher: &mut Sha256, expr: &Expr) {
    match expr {
        Expr::Literal(lit, _) => match lit {
            Literal::Int(n) => {
                hasher.update(b"int");
                hasher.update(n.to_le_bytes());
            }
            Literal::Float(f) => {
                hasher.update(b"float");
                hasher.update(f.to_le_bytes());
            }
            Literal::String(s) => {
                hasher.update(b"string");
                hasher.update(s.as_bytes());
            }
            Literal::Bool(b) => {
                hasher.update(b"bool");
                hasher.update(if *b { &[1u8] } else { &[0u8] });
            }
        },
        Expr::Ident(ident, _) => {
            hasher.update(b"ident");
            hasher.update(ident.0.as_bytes());
        }
        Expr::List(items, _) => {
            hasher.update(b"list");
            hasher.update(items.len().to_le_bytes());
            for item in items {
                hash_expr(hasher, item);
            }
        }
        Expr::Lambda { params, body, .. } => {
            hasher.update(b"lambda");
            hasher.update(params.len().to_le_bytes());
            for (param, _) in params {
                hasher.update(param.0.as_bytes());
                hasher.update(b"\0");
            }
            hash_expr(hasher, body);
        }
        Expr::Let { name, value, .. } => {
            hasher.update(b"let");
            hasher.update(name.0.as_bytes());
            hasher.update(b"\0");
            hash_expr(hasher, value);
        }
        Expr::LetRec { name, value, .. } => {
            hasher.update(b"letrec");
            hasher.update(name.0.as_bytes());
            hasher.update(b"\0");
            hash_expr(hasher, value);
        }
        Expr::LetIn {
            name, value, body, ..
        } => {
            hasher.update(b"letin");
            hasher.update(name.0.as_bytes());
            hasher.update(b"\0");
            hash_expr(hasher, value);
            hash_expr(hasher, body);
        }
        Expr::If {
            cond,
            then_expr,
            else_expr,
            ..
        } => {
            hasher.update(b"if");
            hash_expr(hasher, cond);
            hash_expr(hasher, then_expr);
            hash_expr(hasher, else_expr);
        }
        Expr::Apply { func, args, .. } => {
            hasher.update(b"apply");
            hash_expr(hasher, func);
            hasher.update(args.len().to_le_bytes());
            for arg in args {
                hash_expr(hasher, arg);
            }
        }
        Expr::Match { expr, cases, .. } => {
            hasher.update(b"match");
            hash_expr(hasher, expr);
            hasher.update(cases.len().to_le_bytes());
            for (pattern, body) in cases {
                hash_pattern(hasher, pattern);
                hash_expr(hasher, body);
            }
        }
        Expr::Constructor { name, args, .. } => {
            hasher.update(b"constructor");
            hasher.update(name.0.as_bytes());
            hasher.update(args.len().to_le_bytes());
            for arg in args {
                hash_expr(hasher, arg);
            }
        }
        Expr::Module {
            name,
            exports,
            body,
            ..
        } => {
            hasher.update(b"module");
            hasher.update(name.0.as_bytes());
            hasher.update(b"\0");

            // Sort exports for deterministic ordering
            let mut sorted_exports: Vec<_> = exports.iter().map(|i| &i.0).collect();
            sorted_exports.sort();

            hasher.update(sorted_exports.len().to_le_bytes());
            for export in sorted_exports {
                hasher.update(export.as_bytes());
                hasher.update(b"\0");
            }

            hasher.update(body.len().to_le_bytes());
            for expr in body {
                hash_expr(hasher, expr);
            }
        }
        Expr::Import {
            module_name,
            items,
            as_name,
            hash,
            ..
        } => {
            hasher.update(b"import");
            hasher.update(module_name.0.as_bytes());
            hasher.update(b"\0");

            if let Some(items) = items {
                hasher.update(b"1");
                hasher.update(items.len().to_le_bytes());
                let mut sorted_items: Vec<_> = items.iter().map(|i| &i.0).collect();
                sorted_items.sort();
                for item in sorted_items {
                    hasher.update(item.as_bytes());
                    hasher.update(b"\0");
                }
            } else {
                hasher.update(b"0");
            }

            if let Some(alias) = as_name {
                hasher.update(b"1");
                hasher.update(alias.0.as_bytes());
            } else {
                hasher.update(b"0");
            }

            if let Some(h) = hash {
                hasher.update(b"1");
                hasher.update(h.as_bytes());
            } else {
                hasher.update(b"0");
            }
        }
        Expr::TypeDef { definition, .. } => {
            hasher.update(b"typedef");
            hasher.update(definition.name.as_bytes());
            hasher.update(b"\0");
            hasher.update(definition.type_params.len().to_le_bytes());
            for param in &definition.type_params {
                hasher.update(param.as_bytes());
                hasher.update(b"\0");
            }
            hasher.update(definition.constructors.len().to_le_bytes());
            for constructor in &definition.constructors {
                hasher.update(constructor.name.as_bytes());
                hasher.update(b"\0");
                hasher.update(constructor.fields.len().to_le_bytes());
                for field_type in &constructor.fields {
                    hash_type(hasher, field_type);
                }
            }
        }
        Expr::Rec {
            name, params, body, ..
        } => {
            hasher.update(b"rec");
            hasher.update(name.0.as_bytes());
            hasher.update(b"\0");
            hasher.update(params.len().to_le_bytes());
            for (param, _) in params {
                hasher.update(param.0.as_bytes());
                hasher.update(b"\0");
            }
            hash_expr(hasher, body);
        }
        Expr::QualifiedIdent {
            module_name, name, ..
        } => {
            hasher.update(b"qualified_ident");
            hasher.update(module_name.0.as_bytes());
            hasher.update(b"\0");
            hasher.update(name.0.as_bytes());
        }
        Expr::Handler { cases, body, .. } => {
            hasher.update(b"handler");
            hasher.update(cases.len().to_le_bytes());
            for (effect_name, patterns, continuation, handler_body) in cases {
                hasher.update(effect_name.0.as_bytes());
                hasher.update(b"\0");
                hasher.update(patterns.len().to_le_bytes());
                for pattern in patterns {
                    hash_pattern(hasher, pattern);
                }
                hasher.update(continuation.0.as_bytes());
                hasher.update(b"\0");
                hash_expr(hasher, handler_body);
            }
            hash_expr(hasher, body);
        }
        Expr::WithHandler { handler, body, .. } => {
            hasher.update(b"with_handler");
            hash_expr(hasher, handler);
            hash_expr(hasher, body);
        }
        Expr::Perform { effect, args, .. } => {
            hasher.update(b"perform");
            hasher.update(effect.0.as_bytes());
            hasher.update(args.len().to_le_bytes());
            for arg in args {
                hash_expr(hasher, arg);
            }
        }
        Expr::Pipeline { expr, func, .. } => {
            hasher.update(b"pipeline");
            hash_expr(hasher, expr);
            hash_expr(hasher, func);
        }

        Expr::Use { path, items, .. } => {
            hasher.update(b"use");
            for p in path {
                hasher.update(p.as_bytes());
            }
            if let Some(items) = items {
                for item in items {
                    hasher.update(item.0.as_bytes());
                }
            }
        }

        Expr::Block { exprs, .. } => {
            hasher.update(b"block");
            hasher.update(exprs.len().to_le_bytes());
            for expr in exprs {
                hash_expr(hasher, expr);
            }
        }

        Expr::Hole {
            name, type_hint, ..
        } => {
            hasher.update(b"hole");
            if let Some(name) = name {
                hasher.update(name.as_bytes());
            }
            if let Some(_type_hint) = type_hint {
                // TODO: Add type hashing when needed
                hasher.update(b"typed");
            }
        }

        Expr::Do { statements, .. } => {
            hasher.update(b"do");
            hasher.update(statements.len().to_le_bytes());
            for statement in statements {
                match statement {
                    DoStatement::Bind { name, expr, .. } => {
                        hasher.update(b"bind");
                        hasher.update(name.0.as_bytes());
                        hasher.update(b"\0");
                        hash_expr(hasher, expr);
                    }
                    DoStatement::Expression(expr) => {
                        hasher.update(b"expr");
                        hash_expr(hasher, expr);
                    }
                }
            }
        }

        Expr::RecordLiteral { fields, .. } => {
            hasher.update(b"record_literal");
            // Sort fields for deterministic ordering
            let mut sorted_fields: Vec<_> = fields.iter().collect();
            sorted_fields.sort_by_key(|(ident, _)| &ident.0);
            hasher.update(sorted_fields.len().to_le_bytes());
            for (ident, expr) in sorted_fields {
                hasher.update(ident.0.as_bytes());
                hasher.update(b"\0");
                hash_expr(hasher, expr);
            }
        }

        Expr::RecordAccess { record, field, .. } => {
            hasher.update(b"record_access");
            hash_expr(hasher, record);
            hasher.update(field.0.as_bytes());
        }

        Expr::RecordUpdate {
            record, updates, ..
        } => {
            hasher.update(b"record_update");
            hash_expr(hasher, record);
            // Sort updates for deterministic ordering
            let mut sorted_updates: Vec<_> = updates.iter().collect();
            sorted_updates.sort_by_key(|(ident, _)| &ident.0);
            hasher.update(sorted_updates.len().to_le_bytes());
            for (ident, expr) in sorted_updates {
                hasher.update(ident.0.as_bytes());
                hasher.update(b"\0");
                hash_expr(hasher, expr);
            }
        }

        Expr::LetRecIn {
            name,
            type_ann,
            value,
            body,
            ..
        } => {
            hasher.update(b"letrec_in");
            hasher.update(name.0.as_bytes());
            hasher.update(b"\0");
            if let Some(t) = type_ann {
                hasher.update(b"1");
                hash_type(hasher, t);
            } else {
                hasher.update(b"0");
            }
            hash_expr(hasher, value);
            hash_expr(hasher, body);
        }

        Expr::HandleExpr {
            expr,
            handlers,
            return_handler,
            ..
        } => {
            hasher.update(b"handle");
            hash_expr(hasher, expr);
            hasher.update(handlers.len().to_le_bytes());
            for handler in handlers {
                hasher.update(handler.effect.0.as_bytes());
                hasher.update(b"\0");
                if let Some(op) = &handler.operation {
                    hasher.update(op.0.as_bytes());
                    hasher.update(b"\0");
                }
                hash_expr(hasher, &handler.body);
            }
            if let Some((var, body)) = return_handler {
                hasher.update(b"return");
                hasher.update(var.0.as_bytes());
                hasher.update(b"\0");
                hash_expr(hasher, body);
            }
        }

        Expr::FunctionDef {
            name,
            params,
            return_type,
            effects,
            body,
            ..
        } => {
            hasher.update(b"function_def");
            hasher.update(name.0.as_bytes());
            hasher.update(b"\0");
            hasher.update(params.len().to_le_bytes());
            for param in params {
                hasher.update(param.name.0.as_bytes());
                hasher.update(b"\0");
                if let Some(typ) = &param.typ {
                    hasher.update(b"1");
                    hash_type(hasher, typ);
                } else {
                    hasher.update(b"0");
                }
            }
            if let Some(ret_type) = return_type {
                hasher.update(b"1");
                hash_type(hasher, ret_type);
            } else {
                hasher.update(b"0");
            }
            if let Some(eff) = effects {
                hasher.update(b"1");
                hasher.update(eff.to_string().as_bytes());
            } else {
                hasher.update(b"0");
            }
            hash_expr(hasher, body);
        }
        Expr::HashRef { hash, .. } => {
            hasher.update(b"hashref");
            hasher.update(hash.as_bytes());
        }
    }
}

/// Hash a pattern deterministically
fn hash_pattern(hasher: &mut Sha256, pattern: &Pattern) {
    match pattern {
        Pattern::Variable(ident, _) => {
            hasher.update(b"var");
            hasher.update(ident.0.as_bytes());
        }
        Pattern::Wildcard(_) => {
            hasher.update(b"wildcard");
        }
        Pattern::Literal(lit, _) => match lit {
            Literal::Int(n) => {
                hasher.update(b"int");
                hasher.update(n.to_le_bytes());
            }
            Literal::Float(f) => {
                hasher.update(b"float");
                hasher.update(f.to_le_bytes());
            }
            Literal::Bool(b) => {
                hasher.update(b"bool");
                hasher.update(if *b { &[1u8] } else { &[0u8] });
            }
            Literal::String(s) => {
                hasher.update(b"string");
                hasher.update(s.as_bytes());
            }
        },
        Pattern::List { patterns, .. } => {
            hasher.update(b"list");
            hasher.update(patterns.len().to_le_bytes());
            for p in patterns {
                hash_pattern(hasher, p);
            }
        }
        Pattern::Constructor { name, patterns, .. } => {
            hasher.update(b"constructor");
            hasher.update(name.0.as_bytes());
            hasher.update(b"\0");
            hasher.update(patterns.len().to_le_bytes());
            for p in patterns {
                hash_pattern(hasher, p);
            }
        }
    }
}

/// Hash a type deterministically
fn hash_type(hasher: &mut Sha256, ty: &Type) {
    match ty {
        Type::Int => hasher.update(b"int"),
        Type::Float => hasher.update(b"float"),
        Type::String => hasher.update(b"string"),
        Type::Bool => hasher.update(b"bool"),
        Type::Unit => hasher.update(b"unit"),
        Type::Var(v) => {
            hasher.update(b"var");
            hasher.update(v.as_bytes());
        }
        Type::Function(from, to) => {
            hasher.update(b"function");
            hash_type(hasher, from);
            hash_type(hasher, to);
        }
        Type::List(elem) => {
            hasher.update(b"list");
            hash_type(hasher, elem);
        }
        Type::UserDefined { name, type_params } => {
            hasher.update(b"user_defined");
            hasher.update(name.as_bytes());
            hasher.update(b"\0");
            hasher.update(type_params.len().to_le_bytes());
            for param in type_params {
                hash_type(hasher, param);
            }
        }
        Type::FunctionWithEffect { from, to, effects } => {
            hasher.update(b"function_with_effect");
            hash_type(hasher, from);
            hash_type(hasher, to);
            // For now, we'll just hash whether it's pure or not
            if effects.is_pure() {
                hasher.update(b"pure");
            } else {
                hasher.update(b"impure");
            }
        }
        Type::Record { fields } => {
            hasher.update(b"record");
            hasher.update(fields.len().to_le_bytes());
            for (name, ty) in fields {
                hasher.update(name.as_bytes());
                hasher.update(b"\0");
                hash_type(hasher, ty);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::namespace::DefinitionContent;

    #[test]
    fn test_deterministic_hashing() {
        let content =
            DefinitionContent::Value(Expr::Literal(Literal::Int(42), vibe_language::Span::new(0, 0)));
        let ty = Type::Int;

        let hash1 = DefinitionHash::compute(&content, &ty);
        let hash2 = DefinitionHash::compute(&content, &ty);

        assert_eq!(hash1, hash2);
    }

    #[test]
    fn test_hash_hex_conversion() {
        let content =
            DefinitionContent::Value(Expr::Literal(Literal::Int(42), vibe_language::Span::new(0, 0)));
        let ty = Type::Int;

        let hash = DefinitionHash::compute(&content, &ty);
        let hex = hash.to_hex();
        let hash2 = DefinitionHash::from_hex(&hex).unwrap();

        assert_eq!(hash, hash2);
    }

    #[test]
    fn test_different_content_different_hash() {
        let content1 =
            DefinitionContent::Value(Expr::Literal(Literal::Int(42), vibe_language::Span::new(0, 0)));
        let content2 =
            DefinitionContent::Value(Expr::Literal(Literal::Int(43), vibe_language::Span::new(0, 0)));
        let ty = Type::Int;

        let hash1 = DefinitionHash::compute(&content1, &ty);
        let hash2 = DefinitionHash::compute(&content2, &ty);

        assert_ne!(hash1, hash2);
    }
}
