//! Automatic recursion detection for let-bound functions

use crate::{DoStatement, Expr, Ident};
use std::collections::HashSet;

/// Detect if a function body references the given name (indicating recursion)
pub fn is_recursive(name: &Ident, body: &Expr) -> bool {
    let mut visitor = RecursionVisitor {
        target_name: name,
        found: false,
        bound_vars: HashSet::new(),
    };
    visitor.visit_expr(body);
    visitor.found
}

struct RecursionVisitor<'a> {
    target_name: &'a Ident,
    found: bool,
    bound_vars: HashSet<String>,
}

impl<'a> RecursionVisitor<'a> {
    fn visit_expr(&mut self, expr: &Expr) {
        if self.found {
            return; // Early exit if already found
        }

        match expr {
            Expr::Ident(id, _) => {
                // Check if this identifier matches our target and isn't shadowed
                if id == self.target_name && !self.bound_vars.contains(&id.0) {
                    self.found = true;
                }
            }

            Expr::Apply { func, args, .. } => {
                self.visit_expr(func);
                for arg in args {
                    self.visit_expr(arg);
                }
            }

            Expr::Lambda { params, body, .. } => {
                // Shadow parameters in lambda
                let old_bound = self.bound_vars.clone();
                for (param, _) in params {
                    self.bound_vars.insert(param.0.clone());
                }
                self.visit_expr(body);
                self.bound_vars = old_bound;
            }

            Expr::Let { value, .. } => {
                // Check value first (before name is bound)
                self.visit_expr(value);
                // Note: for top-level let, we don't shadow the name
                // This handles let expressions differently from let statements
            }

            Expr::LetIn { name, value, body, .. } => {
                // Check value first
                self.visit_expr(value);
                // Then shadow the name for the body
                let old_bound = self.bound_vars.clone();
                self.bound_vars.insert(name.0.clone());
                self.visit_expr(body);
                self.bound_vars = old_bound;
            }

            Expr::If { cond, then_expr, else_expr, .. } => {
                self.visit_expr(cond);
                self.visit_expr(then_expr);
                self.visit_expr(else_expr);
            }

            Expr::Match { expr, cases, .. } => {
                self.visit_expr(expr);
                for (pattern, case_expr) in cases {
                    let old_bound = self.bound_vars.clone();
                    // Extract bound variables from pattern
                    self.add_pattern_bindings(pattern);
                    self.visit_expr(case_expr);
                    self.bound_vars = old_bound;
                }
            }

            Expr::List(exprs, _) => {
                for expr in exprs {
                    self.visit_expr(expr);
                }
            }

            // Rec is already explicitly recursive, skip
            Expr::Rec { .. } => {}

            // Other expressions that don't contain sub-expressions
            Expr::Literal(_, _) | Expr::TypeDef { .. } | Expr::Module { .. } 
            | Expr::Import { .. } | Expr::Use { .. } | Expr::QualifiedIdent { .. } => {}

            // Recursive let is already handled
            Expr::LetRec { .. } => {}
            
            // LetRecIn - recursion is already handled by using LetRecIn
            Expr::LetRecIn { value, body, .. } => {
                self.visit_expr(value);
                self.visit_expr(body);
            }
            
            // Effect-related expressions
            Expr::Constructor { .. } => {}
            Expr::Handler { .. } => {}
            Expr::WithHandler { .. } => {}
            Expr::HandleExpr { expr, handlers, return_handler, .. } => {
                self.visit_expr(expr);
                for handler in handlers {
                    self.visit_expr(&handler.body);
                }
                if let Some((_, body)) = return_handler {
                    self.visit_expr(body);
                }
            }
            Expr::Perform { .. } => {}
            Expr::Pipeline { .. } => {}
            Expr::Block { exprs, .. } => {
                for expr in exprs {
                    self.visit_expr(expr);
                }
            }
            Expr::Hole { .. } => {}
            Expr::Do { statements, .. } => {
                for statement in statements {
                    match statement {
                        DoStatement::Bind { expr, .. } => {
                            self.visit_expr(expr);
                        }
                        DoStatement::Expression(expr) => {
                            self.visit_expr(expr);
                        }
                    }
                }
            }
            Expr::RecordLiteral { fields, .. } => {
                for (_, value) in fields {
                    self.visit_expr(value);
                }
            }
            Expr::RecordAccess { record, .. } => {
                self.visit_expr(record);
            }
            Expr::RecordUpdate { record, updates, .. } => {
                self.visit_expr(record);
                for (_, value) in updates {
                    self.visit_expr(value);
                }
            }
            
            Expr::FunctionDef { body, .. } => {
                self.visit_expr(body);
            }
            
            Expr::HashRef { .. } => {
                // Hash references don't contain recursive references
            }
        }
    }

    fn add_pattern_bindings(&mut self, pattern: &crate::Pattern) {
        use crate::Pattern;
        match pattern {
            Pattern::Variable(ident, _) => {
                self.bound_vars.insert(ident.0.clone());
            }
            Pattern::Constructor { patterns, .. } => {
                for p in patterns {
                    self.add_pattern_bindings(p);
                }
            }
            Pattern::List { patterns, .. } => {
                for p in patterns {
                    self.add_pattern_bindings(p);
                }
            }
            Pattern::Wildcard(_) | Pattern::Literal(_, _) => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_and_check(code: &str, name: &str) -> bool {
        let expr = crate::parser::parse(code).unwrap();
        is_recursive(&Ident(name.to_string()), &expr)
    }

    #[test]
    fn test_simple_recursion() {
        assert!(parse_and_check("factorial (n - 1)", "factorial"));
        assert!(!parse_and_check("other (n - 1)", "factorial"));
    }

    #[test]
    fn test_nested_recursion() {
        assert!(parse_and_check(
            "if (eq n 0) { 1 } else { n * (factorial (n - 1)) }",
            "factorial"
        ));
    }

    #[test]
    fn test_shadowed_name() {
        // Lambda parameter shadows the name
        assert!(!parse_and_check(
            "fn factorial = factorial 5",
            "factorial"
        ));
    }

    #[test]
    fn test_let_in_shadowing() {
        // let-in shadows the name
        assert!(!parse_and_check(
            "let factorial = 5 in factorial + 1",
            "factorial"
        ));
    }
}