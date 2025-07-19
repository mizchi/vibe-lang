use xs_core::{Environment, Expr, Ident, Literal, Pattern, TypeDefinition, Value, XsError};
use std::collections::HashMap;

pub struct Interpreter {
    type_definitions: HashMap<String, TypeDefinition>,
}

impl Interpreter {
    pub fn new() -> Self {
        Interpreter {
            type_definitions: HashMap::new(),
        }
    }

    pub fn eval(&mut self, expr: &Expr, env: &Environment) -> Result<Value, XsError> {
        match expr {
            Expr::Literal(lit, _) => Ok(match lit {
                Literal::Int(n) => Value::Int(*n),
                Literal::Float(f) => Value::Float(f.0),
                Literal::Bool(b) => Value::Bool(*b),
                Literal::String(s) => Value::String(s.clone()),
            }),

            Expr::Ident(name, span) => {
                env.lookup(name)
                    .cloned()
                    .ok_or_else(|| XsError::RuntimeError(
                        span.clone(),
                        format!("Undefined variable: {}", name),
                    ))
            }

            Expr::List(elems, _) => {
                let mut values = Vec::new();
                for elem in elems {
                    values.push(self.eval(elem, env)?);
                }
                Ok(Value::List(values))
            }

            Expr::Let { name, value, .. } => {
                let val = self.eval(value, env)?;
                let _new_env = env.extend(name.clone(), val.clone());
                Ok(val)
            }

            Expr::LetRec { name, value, .. } => {
                // For recursive bindings, we need to create a placeholder environment
                // where the function can refer to itself
                match value.as_ref() {
                    Expr::Lambda { params, body, .. } => {
                        // Create a recursive closure
                        let rec_closure = Value::RecClosure {
                            name: name.clone(),
                            params: params.iter().map(|(name, _)| name.clone()).collect(),
                            body: (**body).clone(),
                            env: env.clone(),
                        };
                        
                        Ok(rec_closure)
                    }
                    _ => {
                        // For non-lambda expressions, just evaluate normally
                        // (though this shouldn't happen with proper type checking)
                        let val = self.eval(value, env)?;
                        Ok(val)
                    }
                }
            }

            Expr::Rec { name, params, body, .. } => {
                // rec creates a special recursive closure
                let param_names: Vec<Ident> = params.iter().map(|(name, _)| name.clone()).collect();
                
                // Create a recursive closure that knows its own name
                let rec_closure = Value::RecClosure {
                    name: name.clone(),
                    params: param_names,
                    body: (**body).clone(),
                    env: env.clone(),
                };
                
                Ok(rec_closure)
            }

            Expr::Lambda { params, body, .. } => {
                Ok(Value::Closure {
                    params: params.iter().map(|(name, _)| name.clone()).collect(),
                    body: (**body).clone(),
                    env: env.clone(),
                })
            }

            Expr::If { cond, then_expr, else_expr, span } => {
                let cond_val = self.eval(cond, env)?;
                match cond_val {
                    Value::Bool(true) => self.eval(then_expr, env),
                    Value::Bool(false) => self.eval(else_expr, env),
                    _ => Err(XsError::RuntimeError(
                        span.clone(),
                        "If condition must be a boolean".to_string(),
                    )),
                }
            }

            Expr::Apply { func, args, span } => {
                // Handle built-in functions first
                if let Expr::Ident(Ident(name), _) = func.as_ref() {
                    if let Some(result) = self.apply_builtin(name, args, env, span)? {
                        return Ok(result);
                    }
                }
                
                // Handle user-defined functions
                let func_val = self.eval(func, env)?;
                match &func_val {
                    Value::Closure { params, body, env: closure_env } => {
                        if params.len() != args.len() {
                            return Err(XsError::RuntimeError(
                                span.clone(),
                                format!("Function expects {} arguments, got {}", params.len(), args.len()),
                            ));
                        }
                        
                        let mut new_env = closure_env.clone();
                        for (param, arg) in params.iter().zip(args.iter()) {
                            let arg_val = self.eval(arg, env)?;
                            new_env = new_env.extend(param.clone(), arg_val);
                        }
                        
                        self.eval(body, &new_env)
                    }
                    Value::RecClosure { name, params, body, env: closure_env } => {
                        if params.len() != args.len() {
                            return Err(XsError::RuntimeError(
                                span.clone(),
                                format!("Function expects {} arguments, got {}", params.len(), args.len()),
                            ));
                        }
                        
                        // For recursive closures, add the function itself to the environment
                        let mut new_env = closure_env.clone();
                        new_env = new_env.extend(name.clone(), func_val.clone());
                        
                        for (param, arg) in params.iter().zip(args.iter()) {
                            let arg_val = self.eval(arg, env)?;
                            new_env = new_env.extend(param.clone(), arg_val);
                        }
                        
                        self.eval(body, &new_env)
                    }
                    _ => Err(XsError::RuntimeError(
                        span.clone(),
                        "Cannot apply non-function value".to_string(),
                    )),
                }
            }
            
            Expr::Match { expr, cases, span } => {
                let value = self.eval(expr, env)?;
                
                for (pattern, case_expr) in cases {
                    if let Some(bindings) = self.match_pattern(pattern, &value)? {
                        // Create new environment with pattern bindings
                        let mut new_env = env.clone();
                        for (name, val) in bindings {
                            new_env = new_env.extend(name, val);
                        }
                        return self.eval(case_expr, &new_env);
                    }
                }
                
                Err(XsError::RuntimeError(
                    span.clone(),
                    "No matching pattern in match expression".to_string(),
                ))
            }
            
            Expr::Constructor { name, args, .. } => {
                let mut values = Vec::new();
                for arg in args {
                    values.push(self.eval(arg, env)?);
                }
                Ok(Value::Constructor {
                    name: name.clone(),
                    values,
                })
            }
            
            Expr::TypeDef { definition, .. } => {
                // Store the type definition
                self.type_definitions.insert(definition.name.clone(), definition.clone());
                // Type definitions don't have a runtime value, return a placeholder
                Ok(Value::Int(0)) // Using 0 as unit value
            }
            
            Expr::Module { name: _, exports: _, body, .. } => {
                // For now, just evaluate the body expressions
                // TODO: Implement proper module evaluation with export handling
                let mut result = Value::Int(0); // unit value
                for expr in body {
                    result = self.eval(expr, env)?;
                }
                Ok(result)
            }
            
            Expr::Import { .. } => {
                // Import statements don't have a runtime value
                // TODO: Implement proper import handling
                Ok(Value::Int(0)) // unit value
            }
            
            Expr::QualifiedIdent { module_name: _, name: _, span } => {
                // TODO: Implement proper module member lookup
                Err(XsError::RuntimeError(
                    span.clone(),
                    "Module member lookup not yet implemented".to_string(),
                ))
            }
        }
    }

    fn apply_builtin(&mut self, name: &str, args: &[Expr], env: &Environment, span: &xs_core::Span) -> Result<Option<Value>, XsError> {
        match name {
            "+" => {
                if args.len() != 2 {
                    return Err(XsError::RuntimeError(span.clone(), "+ requires exactly 2 arguments".to_string()));
                }
                let a = self.eval(&args[0], env)?;
                let b = self.eval(&args[1], env)?;
                match (a, b) {
                    (Value::Int(x), Value::Int(y)) => Ok(Some(Value::Int(x + y))),
                    _ => Err(XsError::RuntimeError(span.clone(), "+ requires integer arguments".to_string())),
                }
            }
            "-" => {
                if args.len() != 2 {
                    return Err(XsError::RuntimeError(span.clone(), "- requires exactly 2 arguments".to_string()));
                }
                let a = self.eval(&args[0], env)?;
                let b = self.eval(&args[1], env)?;
                match (a, b) {
                    (Value::Int(x), Value::Int(y)) => Ok(Some(Value::Int(x - y))),
                    _ => Err(XsError::RuntimeError(span.clone(), "- requires integer arguments".to_string())),
                }
            }
            "*" => {
                if args.len() != 2 {
                    return Err(XsError::RuntimeError(span.clone(), "* requires exactly 2 arguments".to_string()));
                }
                let a = self.eval(&args[0], env)?;
                let b = self.eval(&args[1], env)?;
                match (a, b) {
                    (Value::Int(x), Value::Int(y)) => Ok(Some(Value::Int(x * y))),
                    _ => Err(XsError::RuntimeError(span.clone(), "* requires integer arguments".to_string())),
                }
            }
            "/" => {
                if args.len() != 2 {
                    return Err(XsError::RuntimeError(span.clone(), "/ requires exactly 2 arguments".to_string()));
                }
                let a = self.eval(&args[0], env)?;
                let b = self.eval(&args[1], env)?;
                match (a, b) {
                    (Value::Int(x), Value::Int(y)) => {
                        if y == 0 {
                            Err(XsError::RuntimeError(span.clone(), "Division by zero".to_string()))
                        } else {
                            Ok(Some(Value::Int(x / y)))
                        }
                    }
                    _ => Err(XsError::RuntimeError(span.clone(), "/ requires integer arguments".to_string())),
                }
            }
            "<" => {
                if args.len() != 2 {
                    return Err(XsError::RuntimeError(span.clone(), "< requires exactly 2 arguments".to_string()));
                }
                let a = self.eval(&args[0], env)?;
                let b = self.eval(&args[1], env)?;
                match (a, b) {
                    (Value::Int(x), Value::Int(y)) => Ok(Some(Value::Bool(x < y))),
                    _ => Err(XsError::RuntimeError(span.clone(), "< requires integer arguments".to_string())),
                }
            }
            ">" => {
                if args.len() != 2 {
                    return Err(XsError::RuntimeError(span.clone(), "> requires exactly 2 arguments".to_string()));
                }
                let a = self.eval(&args[0], env)?;
                let b = self.eval(&args[1], env)?;
                match (a, b) {
                    (Value::Int(x), Value::Int(y)) => Ok(Some(Value::Bool(x > y))),
                    _ => Err(XsError::RuntimeError(span.clone(), "> requires integer arguments".to_string())),
                }
            }
            "<=" => {
                if args.len() != 2 {
                    return Err(XsError::RuntimeError(span.clone(), "<= requires exactly 2 arguments".to_string()));
                }
                let a = self.eval(&args[0], env)?;
                let b = self.eval(&args[1], env)?;
                match (a, b) {
                    (Value::Int(x), Value::Int(y)) => Ok(Some(Value::Bool(x <= y))),
                    _ => Err(XsError::RuntimeError(span.clone(), "<= requires integer arguments".to_string())),
                }
            }
            ">=" => {
                if args.len() != 2 {
                    return Err(XsError::RuntimeError(span.clone(), ">= requires exactly 2 arguments".to_string()));
                }
                let a = self.eval(&args[0], env)?;
                let b = self.eval(&args[1], env)?;
                match (a, b) {
                    (Value::Int(x), Value::Int(y)) => Ok(Some(Value::Bool(x >= y))),
                    _ => Err(XsError::RuntimeError(span.clone(), ">= requires integer arguments".to_string())),
                }
            }
            "=" => {
                if args.len() != 2 {
                    return Err(XsError::RuntimeError(span.clone(), "= requires exactly 2 arguments".to_string()));
                }
                let a = self.eval(&args[0], env)?;
                let b = self.eval(&args[1], env)?;
                match (a, b) {
                    (Value::Int(x), Value::Int(y)) => Ok(Some(Value::Bool(x == y))),
                    _ => Err(XsError::RuntimeError(span.clone(), "= requires integer arguments".to_string())),
                }
            }
            "cons" => {
                if args.len() != 2 {
                    return Err(XsError::RuntimeError(span.clone(), "cons requires exactly 2 arguments".to_string()));
                }
                let head = self.eval(&args[0], env)?;
                let tail = self.eval(&args[1], env)?;
                match tail {
                    Value::List(elems) => {
                        let mut result = vec![head];
                        result.extend(elems);
                        Ok(Some(Value::List(result)))
                    }
                    _ => Err(XsError::RuntimeError(span.clone(), "cons requires a list as second argument".to_string())),
                }
            }
            _ => Ok(None),
        }
    }
    
    fn match_pattern(&self, pattern: &Pattern, value: &Value) -> Result<Option<Vec<(Ident, Value)>>, XsError> {
        match (pattern, value) {
            (Pattern::Wildcard(_), _) => Ok(Some(vec![])),
            
            (Pattern::Literal(lit, _), _) => {
                let matches = match (lit, value) {
                    (Literal::Int(n), Value::Int(v)) => n == v,
                    (Literal::Float(f), Value::Float(v)) => (f.0 - v).abs() < f64::EPSILON,
                    (Literal::Bool(b), Value::Bool(v)) => b == v,
                    (Literal::String(s), Value::String(v)) => s == v,
                    _ => false,
                };
                if matches {
                    Ok(Some(vec![]))
                } else {
                    Ok(None)
                }
            }
            
            (Pattern::Variable(name, _), _) => {
                Ok(Some(vec![(name.clone(), value.clone())]))
            }
            
            (Pattern::Constructor { name, patterns, .. }, Value::Constructor { name: val_name, values }) => {
                if name != val_name {
                    return Ok(None);
                }
                if patterns.len() != values.len() {
                    return Ok(None);
                }
                
                let mut bindings = vec![];
                for (pattern, value) in patterns.iter().zip(values.iter()) {
                    if let Some(mut pattern_bindings) = self.match_pattern(pattern, value)? {
                        bindings.append(&mut pattern_bindings);
                    } else {
                        return Ok(None);
                    }
                }
                Ok(Some(bindings))
            }
            
            (Pattern::List { patterns, .. }, Value::List(values)) => {
                if patterns.len() != values.len() {
                    return Ok(None);
                }
                
                let mut bindings = vec![];
                for (pattern, value) in patterns.iter().zip(values.iter()) {
                    if let Some(mut pattern_bindings) = self.match_pattern(pattern, value)? {
                        bindings.append(&mut pattern_bindings);
                    } else {
                        return Ok(None);
                    }
                }
                Ok(Some(bindings))
            }
            
            _ => Ok(None),
        }
    }
}

pub fn eval(expr: &Expr) -> Result<Value, XsError> {
    let mut interpreter = Interpreter::new();
    let env = Environment::new();
    interpreter.eval(expr, &env)
}


#[cfg(test)]
mod tests {
    use super::*;
    use parser::parse;
    use checker::type_check;

    fn check_and_eval(program: &str) -> Result<Value, XsError> {
        let expr = parse(program)?;
        let _ = type_check(&expr)?; // Type check first
        eval(&expr)
    }

    #[test]
    fn test_literals() {
        assert_eq!(check_and_eval("42").unwrap(), Value::Int(42));
        assert_eq!(check_and_eval("true").unwrap(), Value::Bool(true));
        assert_eq!(check_and_eval(r#""hello""#).unwrap(), Value::String("hello".to_string()));
    }

    #[test]
    fn test_arithmetic() {
        assert_eq!(check_and_eval("(+ 1 2)").unwrap(), Value::Int(3));
        assert_eq!(check_and_eval("(- 5 3)").unwrap(), Value::Int(2));
        assert_eq!(check_and_eval("(* 4 3)").unwrap(), Value::Int(12));
        assert_eq!(check_and_eval("(/ 10 2)").unwrap(), Value::Int(5));
    }

    #[test]
    fn test_comparison() {
        assert_eq!(check_and_eval("(< 1 2)").unwrap(), Value::Bool(true));
        assert_eq!(check_and_eval("(< 2 1)").unwrap(), Value::Bool(false));
        assert_eq!(check_and_eval("(> 2 1)").unwrap(), Value::Bool(true));
        assert_eq!(check_and_eval("(= 2 2)").unwrap(), Value::Bool(true));
        assert_eq!(check_and_eval("(= 2 3)").unwrap(), Value::Bool(false));
    }

    #[test]
    fn test_if_expression() {
        assert_eq!(check_and_eval("(if true 1 2)").unwrap(), Value::Int(1));
        assert_eq!(check_and_eval("(if false 1 2)").unwrap(), Value::Int(2));
        assert_eq!(check_and_eval("(if (< 1 2) 10 20)").unwrap(), Value::Int(10));
    }

    #[test]
    fn test_let_binding() {
        assert_eq!(check_and_eval("(let x 42)").unwrap(), Value::Int(42));
    }

    #[test]
    fn test_lambda_and_apply() {
        assert_eq!(
            check_and_eval("((lambda (x : Int) (+ x 1)) 5)").unwrap(),
            Value::Int(6)
        );
        
        assert_eq!(
            check_and_eval("((lambda (x : Int y : Int) (+ x y)) 3 4)").unwrap(),
            Value::Int(7)
        );
    }

    #[test]
    fn test_list() {
        let result = check_and_eval("(list 1 2 3)").unwrap();
        match result {
            Value::List(elems) => {
                assert_eq!(elems.len(), 3);
                assert_eq!(elems[0], Value::Int(1));
                assert_eq!(elems[1], Value::Int(2));
                assert_eq!(elems[2], Value::Int(3));
            }
            _ => panic!("Expected list"),
        }
    }

    #[test]
    fn test_cons() {
        let result = check_and_eval("(cons 1 (list 2 3))").unwrap();
        match result {
            Value::List(elems) => {
                assert_eq!(elems.len(), 3);
                assert_eq!(elems[0], Value::Int(1));
                assert_eq!(elems[1], Value::Int(2));
                assert_eq!(elems[2], Value::Int(3));
            }
            _ => panic!("Expected list"),
        }
    }

    #[test]
    fn test_closure_capture() {
        // Lambda captures its environment
        let program = "((lambda (x : Int) (lambda (y : Int) (+ x y))) 10)";
        let result = check_and_eval(program).unwrap();
        match result {
            Value::Closure { .. } => {},
            _ => panic!("Expected closure"),
        }
    }

    #[test]
    fn test_division_by_zero() {
        let result = check_and_eval("(/ 10 0)");
        assert!(matches!(result, Err(XsError::RuntimeError(_, _))));
    }

    #[test]
    fn test_rec_minimal() {
        // Test that rec creates a closure
        let program = "(rec f (x) x)";
        let result = check_and_eval(program).unwrap();
        match result {
            Value::Closure { .. } | Value::RecClosure { .. } => {},
            _ => panic!("Expected closure from rec"),
        }
        
        // Test applying a non-recursive rec
        let result = check_and_eval("((rec f (x) x) 42)").unwrap();
        assert_eq!(result, Value::Int(42));
    }

    #[test]
    fn test_rec_factorial() {
        // rec returns a closure, so we need to apply it
        let program = "(rec factorial (n : Int) : Int (if (<= n 1) 1 (* n (factorial (- n 1)))))";
        let result = check_and_eval(program).unwrap();
        // Should return a closure
        match result {
            Value::Closure { .. } | Value::RecClosure { .. } => {},
            _ => panic!("Expected closure from rec"),
        }
        
        // Now test applying it
        let result = check_and_eval("((rec factorial (n : Int) : Int (if (<= n 1) 1 (* n (factorial (- n 1))))) 5)").unwrap();
        assert_eq!(result, Value::Int(120)); // 5! = 120
    }

    #[test]
    fn test_rec_fibonacci() {
        let result = check_and_eval("((rec fib (n : Int) : Int (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) 6)").unwrap();
        assert_eq!(result, Value::Int(8)); // fib(6) = 8
    }

    #[test]
    fn test_rec_no_type_annotation() {
        // Should work without type annotations due to type inference
        let result = check_and_eval("((rec double (x) (* x 2)) 21)").unwrap();
        assert_eq!(result, Value::Int(42));
    }

    #[test]
    fn test_let_rec_factorial() {
        let program = "(let-rec fact (lambda (n) (if (= n 0) 1 (* n (fact (- n 1))))))";
        let result = check_and_eval(program).unwrap();
        match result {
            Value::Closure { .. } | Value::RecClosure { .. } => {},
            _ => panic!("Expected closure"),
        }
        
        // Test applying the factorial function
        let program = "((let-rec fact (lambda (n) (if (= n 0) 1 (* n (fact (- n 1)))))) 5)";
        assert_eq!(check_and_eval(program).unwrap(), Value::Int(120));
    }

    #[test]
    fn test_let_rec_fibonacci() {
        let program = r#"
            ((let-rec fib (lambda (n)
                (if (< n 2)
                    n
                    (+ (fib (- n 1)) (fib (- n 2))))))
             6)
        "#;
        assert_eq!(check_and_eval(program).unwrap(), Value::Int(8));
    }

    #[test]
    fn test_undefined_variable() {
        let result = check_and_eval("x");
        // This should fail during type checking
        assert!(matches!(result, Err(XsError::UndefinedVariable(_))));
    }
    
    #[test]
    fn test_match_literal() {
        let program = "(match 1 (0 \"zero\") (1 \"one\") (_ \"other\"))";
        assert_eq!(check_and_eval(program).unwrap(), Value::String("one".to_string()));
    }
    
    #[test]
    fn test_match_variable() {
        let program = "(match 42 (x x))";
        assert_eq!(check_and_eval(program).unwrap(), Value::Int(42));
    }
    
    #[test]
    fn test_match_constructor() {
        let program = "(match (Some 42) ((Some x) x) ((None) 0))";
        assert_eq!(check_and_eval(program).unwrap(), Value::Int(42));
    }
    
    #[test]
    fn test_match_list() {
        let program = "(match (list 1 2) ((list x y) (+ x y)))";
        assert_eq!(check_and_eval(program).unwrap(), Value::Int(3));
    }
    
    #[test]
    fn test_match_wildcard() {
        let program = "(match 99 (0 \"zero\") (_ \"not zero\"))";
        assert_eq!(check_and_eval(program).unwrap(), Value::String("not zero".to_string()));
    }
    
    #[test]
    fn test_constructor() {
        let program = "(Some 42)";
        let result = check_and_eval(program).unwrap();
        match result {
            Value::Constructor { name, values } => {
                assert_eq!(name.0, "Some");
                assert_eq!(values.len(), 1);
                assert_eq!(values[0], Value::Int(42));
            },
            _ => panic!("Expected constructor value"),
        }
    }
    
    #[test]
    fn test_adt_with_match() {
        // Create a shared interpreter
        let mut interpreter = Interpreter::new();
        let env = Environment::new();
        
        // First define the type
        let def_program = r#"(type Option (Some value) (None))"#;
        let def_expr = parse(def_program).unwrap();
        interpreter.eval(&def_expr, &env).unwrap();
        
        // Now test with Some
        let some_program = r#"
            (match (Some 42)
                ((Some x) (+ x 10))
                ((None) 0))
        "#;
        let some_expr = parse(some_program).unwrap();
        assert_eq!(interpreter.eval(&some_expr, &env).unwrap(), Value::Int(52));
        
        // Test with None
        let none_program = r#"
            (match (None)
                ((Some x) x)
                ((None) 99))
        "#;
        let none_expr = parse(none_program).unwrap();
        assert_eq!(interpreter.eval(&none_expr, &env).unwrap(), Value::Int(99));
    }
    
    #[test]
    fn test_nested_adt() {
        // Create a shared interpreter
        let mut interpreter = Interpreter::new();
        let env = Environment::new();
        
        // Define Result type
        let result_def = r#"(type Result (Ok value) (Err error))"#;
        interpreter.eval(&parse(result_def).unwrap(), &env).unwrap();
        
        // Define Option type
        let option_def = r#"(type Option (Some value) (None))"#;
        interpreter.eval(&parse(option_def).unwrap(), &env).unwrap();
        
        // Test nested pattern matching
        let match_program = r#"
            (match (Ok (Some 42))
                ((Ok (Some x)) x)
                ((Ok (None)) 0)
                ((Err e) -1))
        "#;
        let match_expr = parse(match_program).unwrap();
        assert_eq!(interpreter.eval(&match_expr, &env).unwrap(), Value::Int(42));
    }
}
