//! Backend trait and implementations

use xs_core::{Value, Environment, BuiltinRegistry, Literal};
use xs_core::ir::TypedIrExpr;
use crate::RuntimeError;

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
            
            TypedIrExpr::Var { name, .. } => {
                env.lookup(&xs_core::Ident(name.clone()))
                    .cloned()
                    .ok_or_else(|| RuntimeError::UndefinedVariable(name.clone()))
            }
            
            TypedIrExpr::Let { name, value, body, .. } => {
                let val = self.eval_ir(value, env)?;
                let new_env = env.extend(xs_core::Ident(name.clone()), val);
                self.eval_ir(body, &new_env)
            }
            
            TypedIrExpr::Lambda { params, body, .. } => {
                // Create closure
                let param_names: Vec<xs_core::Ident> = params.iter()
                    .map(|(name, _)| xs_core::Ident(name.clone()))
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
                        let arg_values: Result<Vec<_>, _> = args.iter()
                            .map(|arg| self.eval_ir(arg, env))
                            .collect();
                        let arg_values = arg_values?;
                        
                        // Now get the builtin and call it
                        let builtin = self.builtins.get(name).unwrap();
                        return builtin.interpret(&arg_values)
                            .map_err(|e| RuntimeError::XsError(e));
                    }
                }
                
                // Regular function application
                let func_val = self.eval_ir(func, env)?;
                let arg_values: Result<Vec<_>, _> = args.iter()
                    .map(|arg| self.eval_ir(arg, env))
                    .collect();
                let arg_values = arg_values?;
                
                match func_val {
                    Value::Closure { params, body, env: closure_env } => {
                        if params.len() != arg_values.len() {
                            return Err(RuntimeError::InvalidOperation(
                                format!("Function expects {} arguments, got {}", 
                                    params.len(), arg_values.len())
                            ));
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
                        "Cannot apply non-function value".to_string()
                    )),
                }
            }
            
            TypedIrExpr::If { cond, then_expr, else_expr, .. } => {
                let cond_val = self.eval_ir(cond, env)?;
                match cond_val {
                    Value::Bool(true) => self.eval_ir(then_expr, env),
                    Value::Bool(false) => self.eval_ir(else_expr, env),
                    _ => Err(RuntimeError::TypeMismatch(
                        "If condition must be a boolean".to_string()
                    )),
                }
            }
            
            TypedIrExpr::List { elements, .. } => {
                let values: Result<Vec<_>, _> = elements.iter()
                    .map(|elem| self.eval_ir(elem, env))
                    .collect();
                Ok(Value::List(values?))
            }
            
            _ => Err(RuntimeError::InvalidOperation(
                format!("Unimplemented IR node: {:?}", ir)
            )),
        }
    }
    
    // Temporary helper to convert IR back to Expr for closures
    fn ir_to_expr(&self, _ir: &TypedIrExpr) -> xs_core::Expr {
        // This is a placeholder - in a real implementation we'd store typed IR in closures
        xs_core::Expr::Literal(xs_core::Literal::Int(0), xs_core::Span::new(0, 0))
    }
    
    // Temporary helper to evaluate AST expressions (for closures)
    fn eval_expr(&mut self, _expr: &xs_core::Expr, _env: &Environment) -> Result<Value, RuntimeError> {
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
fn literal_to_value(lit: Literal) -> Value {
    match lit {
        Literal::Int(n) => Value::Int(n),
        Literal::Float(f) => Value::Float(f.0),
        Literal::Bool(b) => Value::Bool(b),
        Literal::String(s) => Value::String(s),
    }
}