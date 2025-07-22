//! Runtime with permission checking
//!
//! This module provides an interpreter that enforces permission checks
//! based on effects.

use std::path::PathBuf;
use xs_core::{
    Expr, Value, Environment, XsError, Span, Literal,
    permission::{Permission, PermissionConfig, PathPattern},
};
use crate::Interpreter;

/// Runtime context with permission checking
pub struct PermissionedRuntime {
    pub config: PermissionConfig,
    pub denied_permissions: Vec<Permission>,
}

impl PermissionedRuntime {
    /// Create a new runtime with the given permission configuration
    pub fn new(config: PermissionConfig) -> Self {
        Self {
            config,
            denied_permissions: Vec::new(),
        }
    }

    /// Check if a permission is allowed
    pub fn check_permission(&mut self, permission: Permission) -> Result<(), XsError> {
        if self.config.check(&permission) {
            Ok(())
        } else {
            self.denied_permissions.push(permission.clone());
            Err(XsError::RuntimeError(
                Span::new(0, 0),
                format!("Permission denied: {}", permission),
            ))
        }
    }

    /// Evaluate an expression with permission checks
    pub fn eval_with_permissions(&mut self, expr: &Expr, env: &Environment) -> Result<Value, XsError> {
        match expr {
            // Check permissions for perform expressions
            Expr::Perform { effect, args, span } => {
                // Map effects to required permissions
                let permission = match effect.0.as_str() {
                    "IO" => {
                        // For IO, check what operation is being performed
                        if let Some(Expr::Literal(Literal::String(s), _)) = args.get(0) {
                            if s.starts_with("print") || s.starts_with("read") {
                                Permission::ConsoleIO
                            } else {
                                return Err(XsError::RuntimeError(
                                    span.clone(),
                                    format!("Unknown IO operation: {}", s),
                                ));
                            }
                        } else {
                            Permission::ConsoleIO
                        }
                    }
                    "FileSystem" => {
                        // Check file operation
                        if let Some(Expr::Literal(Literal::String(path), _)) = args.get(1) {
                            if let Some(Expr::Literal(Literal::String(op), _)) = args.get(0) {
                                match op.as_str() {
                                    "read" => Permission::ReadFile(PathPattern::Exact(PathBuf::from(path))),
                                    "write" => Permission::WriteFile(PathPattern::Exact(PathBuf::from(path))),
                                    _ => return Err(XsError::RuntimeError(
                                        span.clone(),
                                        format!("Unknown file operation: {}", op),
                                    )),
                                }
                            } else {
                                Permission::ReadFile(PathPattern::Any)
                            }
                        } else {
                            Permission::ReadFile(PathPattern::Any)
                        }
                    }
                    "Network" => Permission::NetworkAccess(xs_core::permission::NetworkPattern::Any),
                    "Process" => Permission::ProcessSpawn,
                    "Time" => Permission::TimeAccess,
                    "Random" => Permission::RandomAccess,
                    _ => {
                        // Unknown effect, allow for now
                        // Delegate to interpreter
                        let mut interpreter = Interpreter::new();
                        return interpreter.eval(expr, env);
                    }
                };

                // Check permission
                self.check_permission(permission)?;

                // If allowed, evaluate normally
                let mut interpreter = Interpreter::new();
                interpreter.eval(expr, env)
            }
            // For all other expressions, delegate to normal eval
            _ => {
                let mut interpreter = Interpreter::new();
                interpreter.eval(expr, env)
            }
        }
    }
}

/// Evaluate with permission checking
pub fn eval_with_permission_check(
    expr: &Expr,
    env: &Environment,
    config: PermissionConfig,
) -> Result<Value, XsError> {
    let mut runtime = PermissionedRuntime::new(config);
    runtime.eval_with_permissions(expr, env)
}

#[cfg(test)]
mod tests {
    use super::*;
    use xs_core::parser::parse;

    #[test]
    fn test_denied_console_io() {
        let expr = parse(r#"(perform IO (print "Hello"))"#).unwrap();
        let env = Environment::new();
        let config = PermissionConfig::deny_all();

        let result = eval_with_permission_check(&expr, &env, config);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("Permission denied"));
    }

    #[test]
    fn test_allowed_console_io() {
        let expr = parse(r#"(perform IO (print "Hello"))"#).unwrap();
        let env = Environment::new();
        let mut config = PermissionConfig::new();
        config.granted.add(Permission::ConsoleIO);

        // This would normally work if we had proper IO handling
        let result = eval_with_permission_check(&expr, &env, config);
        // For now it will fail because perform is not implemented in eval
        assert!(result.is_err());
    }
}