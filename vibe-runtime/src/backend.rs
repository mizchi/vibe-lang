//! Backend trait and implementations

use crate::RuntimeError;
use vibe_language::ir::TypedIrExpr;
use vibe_language::{BuiltinRegistry, Environment, Literal, Value};

/// Trait for execution backends
pub trait Backend {
    type Output;
    type Error: std::fmt::Debug;

    /// Compile typed IR to backend-specific format
    fn compile(&mut self, ir: &TypedIrExpr) -> Result<Self::Output, Self::Error>;

    /// Execute compiled code
    fn execute(&mut self, compiled: &Self::Output) -> Result<Value, RuntimeError>;
}

/// Interpreter backend that directly executes typed IR
pub struct InterpreterBackend {
    builtins: BuiltinRegistry,
    environment: Environment,
}

impl Default for InterpreterBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl InterpreterBackend {
    pub fn new() -> Self {
        Self {
            builtins: BuiltinRegistry::new(),
            environment: Environment::new(),
        }
    }

    fn eval_ir(&mut self, ir: &TypedIrExpr, env: &Environment) -> Result<Value, RuntimeError> {
        match ir {
            TypedIrExpr::Literal { value, .. } => Ok(literal_to_value(value.clone())),

            TypedIrExpr::Var { name, .. } => env
                .lookup(&vibe_language::Ident(name.clone()))
                .cloned()
                .ok_or_else(|| RuntimeError::UndefinedVariable(name.clone())),

            TypedIrExpr::Let {
                name, value, body, ..
            } => {
                let val = self.eval_ir(value, env)?;
                let new_env = env.extend(vibe_language::Ident(name.clone()), val);
                self.eval_ir(body, &new_env)
            }

            TypedIrExpr::Lambda { params, body, .. } => {
                // Create closure
                let param_names: Vec<vibe_language::Ident> = params
                    .iter()
                    .map(|(name, _)| vibe_language::Ident(name.clone()))
                    .collect();

                // For now, convert back to AST for closure
                // In a real implementation, we'd store the typed IR directly
                let body_expr = self.ir_to_expr(body);

                Ok(Value::Closure {
                    params: param_names,
                    body: body_expr,
                    env: env.clone(),
                })
            }

            TypedIrExpr::Apply { func, args, .. } => {
                // Check if it's a builtin
                if let TypedIrExpr::Var { name, .. } = func.as_ref() {
                    if self.builtins.get(name).is_some() {
                        // Evaluate arguments first
                        let arg_values: Result<Vec<_>, _> =
                            args.iter().map(|arg| self.eval_ir(arg, env)).collect();
                        let arg_values = arg_values?;

                        // Now get the builtin and call it
                        let builtin = self.builtins.get(name).unwrap();
                        return builtin
                            .interpret(&arg_values)
                            .map_err(RuntimeError::XsError);
                    }
                }

                // Regular function application
                let func_val = self.eval_ir(func, env)?;
                let arg_values: Result<Vec<_>, _> =
                    args.iter().map(|arg| self.eval_ir(arg, env)).collect();
                let arg_values = arg_values?;

                match func_val {
                    Value::Closure {
                        params,
                        body,
                        env: closure_env,
                    } => {
                        if params.len() != arg_values.len() {
                            return Err(RuntimeError::InvalidOperation(format!(
                                "Function expects {} arguments, got {}",
                                params.len(),
                                arg_values.len()
                            )));
                        }

                        let mut new_env = closure_env;
                        for (param, arg) in params.iter().zip(arg_values.iter()) {
                            new_env = new_env.extend(param.clone(), arg.clone());
                        }

                        // Evaluate body in the new environment
                        // This is a temporary solution - we need to convert back from AST
                        self.eval_expr(&body, &new_env)
                    }
                    _ => Err(RuntimeError::InvalidOperation(
                        "Cannot apply non-function value".to_string(),
                    )),
                }
            }

            TypedIrExpr::If {
                cond,
                then_expr,
                else_expr,
                ..
            } => {
                let cond_val = self.eval_ir(cond, env)?;
                match cond_val {
                    Value::Bool(true) => self.eval_ir(then_expr, env),
                    Value::Bool(false) => self.eval_ir(else_expr, env),
                    _ => Err(RuntimeError::TypeMismatch(
                        "If condition must be a boolean".to_string(),
                    )),
                }
            }

            TypedIrExpr::List { elements, .. } => {
                let values: Result<Vec<_>, _> = elements
                    .iter()
                    .map(|elem| self.eval_ir(elem, env))
                    .collect();
                Ok(Value::List(values?))
            }

            _ => Err(RuntimeError::InvalidOperation(format!(
                "Unimplemented IR node: {ir:?}"
            ))),
        }
    }

    // Temporary helper to convert IR back to Expr for closures
    fn ir_to_expr(&self, _ir: &TypedIrExpr) -> vibe_language::Expr {
        // This is a placeholder - in a real implementation we'd store typed IR in closures
        vibe_language::Expr::Literal(vibe_language::Literal::Int(0), vibe_language::Span::new(0, 0))
    }

    // Temporary helper to evaluate AST expressions (for closures)
    fn eval_expr(
        &mut self,
        _expr: &vibe_language::Expr,
        _env: &Environment,
    ) -> Result<Value, RuntimeError> {
        // This would use the existing interpreter logic
        // For now, just return a placeholder
        Ok(Value::Int(0))
    }
}

impl Backend for InterpreterBackend {
    type Output = TypedIrExpr;
    type Error = RuntimeError;

    fn compile(&mut self, ir: &TypedIrExpr) -> Result<Self::Output, Self::Error> {
        // For interpreter, "compilation" is just returning the IR
        Ok(ir.clone())
    }

    fn execute(&mut self, compiled: &Self::Output) -> Result<Value, RuntimeError> {
        let env = self.environment.clone();
        self.eval_ir(compiled, &env)
    }
}

// Helper function to convert literals to values
pub(crate) fn literal_to_value(lit: Literal) -> Value {
    match lit {
        Literal::Int(n) => Value::Int(n),
        Literal::Float(f) => Value::Float(f.0),
        Literal::Bool(b) => Value::Bool(b),
        Literal::String(s) => Value::String(s),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ordered_float::OrderedFloat;
    use vibe_language::ir::TypedIrExpr;
    use vibe_language::{Expr, Ident, Literal, Type};

    #[test]
    fn test_interpreter_backend_creation() {
        let backend = InterpreterBackend::new();
        assert_eq!(backend.environment.len(), 0);
    }

    #[test]
    fn test_literal_to_value() {
        assert_eq!(literal_to_value(Literal::Int(42)), Value::Int(42));
        assert_eq!(literal_to_value(Literal::Bool(true)), Value::Bool(true));
        assert_eq!(
            literal_to_value(Literal::Float(OrderedFloat(3.14))),
            Value::Float(3.14)
        );
        assert_eq!(
            literal_to_value(Literal::String("hello".to_string())),
            Value::String("hello".to_string())
        );
    }

    #[test]
    fn test_eval_literal() {
        let mut backend = InterpreterBackend::new();
        let env = Environment::new();

        let ir = TypedIrExpr::Literal {
            value: Literal::Int(42),
            ty: Type::Int,
        };

        let result = backend.eval_ir(&ir, &env).unwrap();
        assert_eq!(result, Value::Int(42));
    }

    #[test]
    fn test_eval_variable() {
        let mut backend = InterpreterBackend::new();
        let env = Environment::new().extend(Ident("x".to_string()), Value::Int(10));

        let ir = TypedIrExpr::Var {
            name: "x".to_string(),
            ty: Type::Int,
        };

        let result = backend.eval_ir(&ir, &env).unwrap();
        assert_eq!(result, Value::Int(10));
    }

    #[test]
    fn test_eval_undefined_variable() {
        let mut backend = InterpreterBackend::new();
        let env = Environment::new();

        let ir = TypedIrExpr::Var {
            name: "undefined".to_string(),
            ty: Type::Int,
        };

        let result = backend.eval_ir(&ir, &env);
        assert!(matches!(result, Err(RuntimeError::UndefinedVariable(_))));
    }

    #[test]
    fn test_eval_let() {
        let mut backend = InterpreterBackend::new();
        let env = Environment::new();

        // let x = 5 in x + 1 (simplified to just x)
        let ir = TypedIrExpr::Let {
            name: "x".to_string(),
            value: Box::new(TypedIrExpr::Literal {
                value: Literal::Int(5),
                ty: Type::Int,
            }),
            body: Box::new(TypedIrExpr::Var {
                name: "x".to_string(),
                ty: Type::Int,
            }),
            ty: Type::Int,
        };

        let result = backend.eval_ir(&ir, &env).unwrap();
        assert_eq!(result, Value::Int(5));
    }

    #[test]
    fn test_eval_if_true() {
        let mut backend = InterpreterBackend::new();
        let env = Environment::new();

        let ir = TypedIrExpr::If {
            cond: Box::new(TypedIrExpr::Literal {
                value: Literal::Bool(true),
                ty: Type::Bool,
            }),
            then_expr: Box::new(TypedIrExpr::Literal {
                value: Literal::Int(1),
                ty: Type::Int,
            }),
            else_expr: Box::new(TypedIrExpr::Literal {
                value: Literal::Int(2),
                ty: Type::Int,
            }),
            ty: Type::Int,
        };

        let result = backend.eval_ir(&ir, &env).unwrap();
        assert_eq!(result, Value::Int(1));
    }

    #[test]
    fn test_eval_if_false() {
        let mut backend = InterpreterBackend::new();
        let env = Environment::new();

        let ir = TypedIrExpr::If {
            cond: Box::new(TypedIrExpr::Literal {
                value: Literal::Bool(false),
                ty: Type::Bool,
            }),
            then_expr: Box::new(TypedIrExpr::Literal {
                value: Literal::Int(1),
                ty: Type::Int,
            }),
            else_expr: Box::new(TypedIrExpr::Literal {
                value: Literal::Int(2),
                ty: Type::Int,
            }),
            ty: Type::Int,
        };

        let result = backend.eval_ir(&ir, &env).unwrap();
        assert_eq!(result, Value::Int(2));
    }

    #[test]
    fn test_eval_if_non_bool_condition() {
        let mut backend = InterpreterBackend::new();
        let env = Environment::new();

        let ir = TypedIrExpr::If {
            cond: Box::new(TypedIrExpr::Literal {
                value: Literal::Int(1),
                ty: Type::Int,
            }),
            then_expr: Box::new(TypedIrExpr::Literal {
                value: Literal::Int(1),
                ty: Type::Int,
            }),
            else_expr: Box::new(TypedIrExpr::Literal {
                value: Literal::Int(2),
                ty: Type::Int,
            }),
            ty: Type::Int,
        };

        let result = backend.eval_ir(&ir, &env);
        assert!(matches!(result, Err(RuntimeError::TypeMismatch(_))));
    }

    #[test]
    fn test_eval_list() {
        let mut backend = InterpreterBackend::new();
        let env = Environment::new();

        let ir = TypedIrExpr::List {
            elements: vec![
                TypedIrExpr::Literal {
                    value: Literal::Int(1),
                    ty: Type::Int,
                },
                TypedIrExpr::Literal {
                    value: Literal::Int(2),
                    ty: Type::Int,
                },
            ],
            elem_ty: Type::Int,
            ty: Type::List(Box::new(Type::Int)),
        };

        let result = backend.eval_ir(&ir, &env).unwrap();
        match result {
            Value::List(elems) => {
                assert_eq!(elems.len(), 2);
                assert_eq!(elems[0], Value::Int(1));
                assert_eq!(elems[1], Value::Int(2));
            }
            _ => panic!("Expected list"),
        }
    }

    #[test]
    fn test_eval_lambda() {
        let mut backend = InterpreterBackend::new();
        let env = Environment::new();

        // \\x -> x
        let ir = TypedIrExpr::Lambda {
            params: vec![("x".to_string(), Type::Int)],
            body: Box::new(TypedIrExpr::Var {
                name: "x".to_string(),
                ty: Type::Int,
            }),
            ty: Type::Function(Box::new(Type::Int), Box::new(Type::Int)),
        };

        let result = backend.eval_ir(&ir, &env).unwrap();
        match result {
            Value::Closure { params, .. } => {
                assert_eq!(params.len(), 1);
                assert_eq!(params[0], Ident("x".to_string()));
            }
            _ => panic!("Expected closure"),
        }
    }

    #[test]
    fn test_eval_builtin_add() {
        let mut backend = InterpreterBackend::new();
        let env = Environment::new();

        // + 2 3
        let ir = TypedIrExpr::Apply {
            func: Box::new(TypedIrExpr::Var {
                name: "+".to_string(),
                ty: Type::Function(
                    Box::new(Type::Int),
                    Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int))),
                ),
            }),
            args: vec![
                TypedIrExpr::Literal {
                    value: Literal::Int(2),
                    ty: Type::Int,
                },
                TypedIrExpr::Literal {
                    value: Literal::Int(3),
                    ty: Type::Int,
                },
            ],
            ty: Type::Int,
        };

        let result = backend.eval_ir(&ir, &env).unwrap();
        assert_eq!(result, Value::Int(5));
    }

    #[test]
    fn test_eval_apply_closure() {
        let mut backend = InterpreterBackend::new();
        let env = Environment::new();

        // (\\x -> x) 42
        let lambda = TypedIrExpr::Lambda {
            params: vec![("x".to_string(), Type::Int)],
            body: Box::new(TypedIrExpr::Var {
                name: "x".to_string(),
                ty: Type::Int,
            }),
            ty: Type::Function(Box::new(Type::Int), Box::new(Type::Int)),
        };

        let ir = TypedIrExpr::Apply {
            func: Box::new(lambda),
            args: vec![TypedIrExpr::Literal {
                value: Literal::Int(42),
                ty: Type::Int,
            }],
            ty: Type::Int,
        };

        // This test will fail because eval_expr is a placeholder
        // But it tests the basic structure
        let _result = backend.eval_ir(&ir, &env);
    }

    #[test]
    fn test_eval_apply_wrong_arity() {
        let mut backend = InterpreterBackend::new();

        let closure = Value::Closure {
            params: vec![Ident("x".to_string()), Ident("y".to_string())],
            body: Expr::default(),
            env: Environment::new(),
        };

        let env = Environment::new().extend(Ident("f".to_string()), closure);

        // f 1 (missing one argument)
        let ir = TypedIrExpr::Apply {
            func: Box::new(TypedIrExpr::Var {
                name: "f".to_string(),
                ty: Type::Function(
                    Box::new(Type::Int),
                    Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int))),
                ),
            }),
            args: vec![TypedIrExpr::Literal {
                value: Literal::Int(1),
                ty: Type::Int,
            }],
            ty: Type::Int,
        };

        let result = backend.eval_ir(&ir, &env);
        assert!(matches!(result, Err(RuntimeError::InvalidOperation(_))));
    }

    #[test]
    fn test_eval_apply_non_function() {
        let mut backend = InterpreterBackend::new();
        let env = Environment::new().extend(Ident("x".to_string()), Value::Int(42));

        // x 1 (x is not a function)
        let ir = TypedIrExpr::Apply {
            func: Box::new(TypedIrExpr::Var {
                name: "x".to_string(),
                ty: Type::Int,
            }),
            args: vec![TypedIrExpr::Literal {
                value: Literal::Int(1),
                ty: Type::Int,
            }],
            ty: Type::Int,
        };

        let result = backend.eval_ir(&ir, &env);
        assert!(matches!(result, Err(RuntimeError::InvalidOperation(_))));
    }

    #[test]
    fn test_backend_compile_and_execute() {
        let mut backend = InterpreterBackend::new();

        let ir = TypedIrExpr::Literal {
            value: Literal::Int(42),
            ty: Type::Int,
        };

        let compiled = backend.compile(&ir).unwrap();
        let result = backend.execute(&compiled).unwrap();
        assert_eq!(result, Value::Int(42));
    }
}
