use std::collections::HashMap;
use xs_core::{Environment, Expr, Ident, Literal, Pattern, Span, TypeDefinition, Value, XsError};

#[derive(Default)]
pub struct Interpreter {
    type_definitions: HashMap<String, TypeDefinition>,
}

impl Interpreter {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn create_initial_env() -> Environment {
        let mut env = Environment::new();

        // Add builtin functions
        env = env.extend(
            Ident("+".to_string()),
            Value::BuiltinFunction {
                name: "+".to_string(),
                arity: 2,
                applied_args: vec![],
            },
        );
        env = env.extend(
            Ident("-".to_string()),
            Value::BuiltinFunction {
                name: "-".to_string(),
                arity: 2,
                applied_args: vec![],
            },
        );
        env = env.extend(
            Ident("*".to_string()),
            Value::BuiltinFunction {
                name: "*".to_string(),
                arity: 2,
                applied_args: vec![],
            },
        );
        env = env.extend(
            Ident("/".to_string()),
            Value::BuiltinFunction {
                name: "/".to_string(),
                arity: 2,
                applied_args: vec![],
            },
        );
        env = env.extend(
            Ident("%".to_string()),
            Value::BuiltinFunction {
                name: "%".to_string(),
                arity: 2,
                applied_args: vec![],
            },
        );
        env = env.extend(
            Ident("<".to_string()),
            Value::BuiltinFunction {
                name: "<".to_string(),
                arity: 2,
                applied_args: vec![],
            },
        );
        env = env.extend(
            Ident(">".to_string()),
            Value::BuiltinFunction {
                name: ">".to_string(),
                arity: 2,
                applied_args: vec![],
            },
        );
        env = env.extend(
            Ident("=".to_string()),
            Value::BuiltinFunction {
                name: "=".to_string(),
                arity: 2,
                applied_args: vec![],
            },
        );
        env = env.extend(
            Ident(">=".to_string()),
            Value::BuiltinFunction {
                name: ">=".to_string(),
                arity: 2,
                applied_args: vec![],
            },
        );
        env = env.extend(
            Ident("<=".to_string()),
            Value::BuiltinFunction {
                name: "<=".to_string(),
                arity: 2,
                applied_args: vec![],
            },
        );
        env = env.extend(
            Ident("cons".to_string()),
            Value::BuiltinFunction {
                name: "cons".to_string(),
                arity: 2,
                applied_args: vec![],
            },
        );
        env = env.extend(
            Ident("concat".to_string()),
            Value::BuiltinFunction {
                name: "concat".to_string(),
                arity: 2,
                applied_args: vec![],
            },
        );
        env = env.extend(
            Ident("str-concat".to_string()),
            Value::BuiltinFunction {
                name: "str-concat".to_string(),
                arity: 2,
                applied_args: vec![],
            },
        );
        env = env.extend(
            Ident("int-to-string".to_string()),
            Value::BuiltinFunction {
                name: "int-to-string".to_string(),
                arity: 1,
                applied_args: vec![],
            },
        );
        env = env.extend(
            Ident("string-to-int".to_string()),
            Value::BuiltinFunction {
                name: "string-to-int".to_string(),
                arity: 1,
                applied_args: vec![],
            },
        );
        env = env.extend(
            Ident("string-length".to_string()),
            Value::BuiltinFunction {
                name: "string-length".to_string(),
                arity: 1,
                applied_args: vec![],
            },
        );
        env = env.extend(
            Ident("str-eq".to_string()),
            Value::BuiltinFunction {
                name: "str-eq".to_string(),
                arity: 2,
                applied_args: vec![],
            },
        );
        env = env.extend(
            Ident("print".to_string()),
            Value::BuiltinFunction {
                name: "print".to_string(),
                arity: 1,
                applied_args: vec![],
            },
        );
        
        // New builtin functions
        env = env.extend(
            Ident("stringAt".to_string()),
            Value::BuiltinFunction {
                name: "stringAt".to_string(),
                arity: 2,
                applied_args: vec![],
            },
        );
        env = env.extend(
            Ident("charCode".to_string()),
            Value::BuiltinFunction {
                name: "charCode".to_string(),
                arity: 1,
                applied_args: vec![],
            },
        );
        env = env.extend(
            Ident("codeChar".to_string()),
            Value::BuiltinFunction {
                name: "codeChar".to_string(),
                arity: 1,
                applied_args: vec![],
            },
        );
        env = env.extend(
            Ident("stringSlice".to_string()),
            Value::BuiltinFunction {
                name: "stringSlice".to_string(),
                arity: 3,
                applied_args: vec![],
            },
        );
        env = env.extend(
            Ident("toString".to_string()),
            Value::BuiltinFunction {
                name: "toString".to_string(),
                arity: 1,
                applied_args: vec![],
            },
        );
        
        // lowerCamelCase aliases
        env = env.extend(
            Ident("stringConcat".to_string()),
            Value::BuiltinFunction {
                name: "stringConcat".to_string(),
                arity: 2,
                applied_args: vec![],
            },
        );
        env = env.extend(
            Ident("stringEq".to_string()),
            Value::BuiltinFunction {
                name: "stringEq".to_string(),
                arity: 2,
                applied_args: vec![],
            },
        );

        env
    }

    pub fn eval(&mut self, expr: &Expr, env: &Environment) -> Result<Value, XsError> {
        match expr {
            Expr::Literal(lit, _) => Ok(match lit {
                Literal::Int(n) => Value::Int(*n),
                Literal::Float(f) => Value::Float(f.0),
                Literal::Bool(b) => Value::Bool(*b),
                Literal::String(s) => Value::String(s.clone()),
            }),

            Expr::Ident(name, span) => env.lookup(name).cloned().ok_or_else(|| {
                XsError::RuntimeError(span.clone(), format!("Undefined variable: {name}"))
            }),

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

            Expr::Rec {
                name, params, body, ..
            } => {
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

            Expr::LetIn {
                name, value, body, ..
            } => {
                let val = self.eval(value, env)?;
                let new_env = env.extend(name.clone(), val);
                self.eval(body, &new_env)
            }

            Expr::Lambda { params, body, .. } => Ok(Value::Closure {
                params: params.iter().map(|(name, _)| name.clone()).collect(),
                body: (**body).clone(),
                env: env.clone(),
            }),

            Expr::If {
                cond,
                then_expr,
                else_expr,
                span,
            } => {
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
                let func_val = self.eval(func, env)?;

                match &func_val {
                    Value::Closure {
                        params,
                        body,
                        env: closure_env,
                    } => {
                        if args.len() > params.len() {
                            return Err(XsError::RuntimeError(
                                span.clone(),
                                format!(
                                    "Function expects {} arguments, got {}",
                                    params.len(),
                                    args.len()
                                ),
                            ));
                        }

                        if args.len() < params.len() {
                            // Partial application
                            let mut partial_env = closure_env.clone();
                            let mut remaining_params = params.clone();

                            for (i, arg) in args.iter().enumerate() {
                                let arg_val = self.eval(arg, env)?;
                                partial_env = partial_env.extend(params[i].clone(), arg_val);
                                remaining_params.remove(0);
                            }

                            Ok(Value::Closure {
                                params: remaining_params,
                                body: body.clone(),
                                env: partial_env,
                            })
                        } else {
                            // Full application
                            let mut new_env = closure_env.clone();
                            for (param, arg) in params.iter().zip(args.iter()) {
                                let arg_val = self.eval(arg, env)?;
                                new_env = new_env.extend(param.clone(), arg_val);
                            }

                            self.eval(body, &new_env)
                        }
                    }
                    Value::RecClosure {
                        name,
                        params,
                        body,
                        env: closure_env,
                    } => {
                        if args.len() > params.len() {
                            return Err(XsError::RuntimeError(
                                span.clone(),
                                format!(
                                    "Function expects {} arguments, got {}",
                                    params.len(),
                                    args.len()
                                ),
                            ));
                        }

                        if args.len() < params.len() {
                            // Partial application of recursive function
                            let mut partial_env = closure_env.clone();
                            partial_env = partial_env.extend(name.clone(), func_val.clone());

                            // Apply the given arguments
                            let mut remaining_params = params.clone();
                            for (i, arg) in args.iter().enumerate() {
                                let arg_val = self.eval(arg, env)?;
                                partial_env = partial_env.extend(params[i].clone(), arg_val);
                                remaining_params.remove(0);
                            }

                            // Create a new closure with remaining parameters
                            Ok(Value::Closure {
                                params: remaining_params,
                                body: body.clone(),
                                env: partial_env,
                            })
                        } else {
                            // Full application
                            let mut new_env = closure_env.clone();
                            new_env = new_env.extend(name.clone(), func_val.clone());

                            for (param, arg) in params.iter().zip(args.iter()) {
                                let arg_val = self.eval(arg, env)?;
                                new_env = new_env.extend(param.clone(), arg_val);
                            }

                            self.eval(body, &new_env)
                        }
                    }
                    Value::BuiltinFunction {
                        name,
                        arity,
                        applied_args,
                    } => {
                        let mut all_args = applied_args.clone();

                        // Evaluate and add new arguments
                        for arg in args {
                            all_args.push(self.eval(arg, env)?);
                        }

                        if all_args.len() < *arity {
                            // Partial application - return a new builtin with more args
                            Ok(Value::BuiltinFunction {
                                name: name.clone(),
                                arity: *arity,
                                applied_args: all_args,
                            })
                        } else if all_args.len() == *arity {
                            // Full application - execute the builtin
                            self.execute_builtin(name, &all_args, span)
                        } else {
                            Err(XsError::RuntimeError(
                                span.clone(),
                                format!(
                                    "{} expects {} arguments, got {}",
                                    name,
                                    arity,
                                    all_args.len()
                                ),
                            ))
                        }
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
                self.type_definitions
                    .insert(definition.name.clone(), definition.clone());
                // Type definitions don't have a runtime value, return a placeholder
                Ok(Value::Int(0)) // Using 0 as unit value
            }

            Expr::Module {
                name: _,
                exports: _,
                body,
                ..
            } => {
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

            Expr::QualifiedIdent {
                module_name,
                name,
                span,
            } => {
                // Look up builtin module functions
                let builtin_key = format!("{}.{}", module_name.0, name.0);
                
                // Map new namespace names to existing builtin functions
                let mapped_name = match builtin_key.as_str() {
                    // Int module
                    "Int.add" => "+",
                    "Int.sub" => "-",
                    "Int.mul" => "*",
                    "Int.div" => "/",
                    "Int.mod" => "%",
                    "Int.toString" => "int-to-string",
                    "Int.fromString" => "string-to-int",
                    "Int.lt" => "<",
                    "Int.gt" => ">",
                    "Int.lte" => "<=",
                    "Int.gte" => ">=",
                    "Int.eq" => "=",
                    
                    // String module
                    "String.concat" => "str-concat",
                    "String.length" => "string-length",
                    "String.toInt" => "string-to-int",
                    "String.fromInt" => "int-to-string",
                    "String.eq" => "str-eq",
                    
                    // List module
                    "List.cons" => "cons",
                    
                    // IO module
                    "IO.print" => "print",
                    
                    // Float module
                    "Float.add" => "+.",
                    
                    _ => {
                        return Err(XsError::RuntimeError(
                            span.clone(),
                            format!("Unknown qualified identifier: {builtin_key}"),
                        ))
                    }
                };
                
                // Look up the builtin function in the environment
                env.lookup(&Ident(mapped_name.to_string())).cloned().ok_or_else(|| {
                    XsError::RuntimeError(span.clone(), format!("Builtin function {mapped_name} not found"))
                })
            }

            Expr::Handler { .. } => {
                // TODO: Implement effect handlers
                Err(XsError::RuntimeError(
                    Span::new(0, 0),
                    "Effect handlers not yet implemented".to_string(),
                ))
            }

            Expr::WithHandler { .. } => {
                // TODO: Implement with-handler
                Err(XsError::RuntimeError(
                    Span::new(0, 0),
                    "with-handler not yet implemented".to_string(),
                ))
            }

            Expr::Perform { .. } => {
                // TODO: Implement effect performance
                Err(XsError::RuntimeError(
                    Span::new(0, 0),
                    "perform not yet implemented".to_string(),
                ))
            }

            Expr::Pipeline { expr, func, .. } => {
                // Evaluate the expression first
                let expr_value = self.eval(expr, env)?;
                
                // Evaluate the function
                let func_value = self.eval(func, env)?;
                
                // Apply the function to the expression value
                match func_value {
                    Value::Closure { params, body, env: closure_env } => {
                        if params.len() != 1 {
                            return Err(XsError::RuntimeError(
                                func.span().clone(),
                                format!("Pipeline function expects 1 argument, got {}", params.len()),
                            ));
                        }
                        let new_env = closure_env.extend(params[0].clone(), expr_value);
                        self.eval(&body, &new_env)
                    }
                    Value::BuiltinFunction { name, arity, mut applied_args } => {
                        applied_args.push(expr_value);
                        if applied_args.len() == arity {
                            self.execute_builtin(&name, &applied_args, func.span())
                        } else {
                            Ok(Value::BuiltinFunction {
                                name,
                                arity,
                                applied_args,
                            })
                        }
                    }
                    _ => Err(XsError::RuntimeError(
                        func.span().clone(),
                        "Pipeline requires a function".to_string(),
                    )),
                }
            }
        }
    }

    fn execute_builtin(
        &mut self,
        name: &str,
        args: &[Value],
        span: &xs_core::Span,
    ) -> Result<Value, XsError> {
        match name {
            "+" => match (&args[0], &args[1]) {
                (Value::Int(x), Value::Int(y)) => Ok(Value::Int(x + y)),
                _ => Err(XsError::RuntimeError(
                    span.clone(),
                    "+ requires integer arguments".to_string(),
                )),
            },
            "-" => match (&args[0], &args[1]) {
                (Value::Int(x), Value::Int(y)) => Ok(Value::Int(x - y)),
                _ => Err(XsError::RuntimeError(
                    span.clone(),
                    "- requires integer arguments".to_string(),
                )),
            },
            "*" => match (&args[0], &args[1]) {
                (Value::Int(x), Value::Int(y)) => Ok(Value::Int(x * y)),
                _ => Err(XsError::RuntimeError(
                    span.clone(),
                    "* requires integer arguments".to_string(),
                )),
            },
            "/" => match (&args[0], &args[1]) {
                (Value::Int(x), Value::Int(y)) => {
                    if *y == 0 {
                        Err(XsError::RuntimeError(
                            span.clone(),
                            "Division by zero".to_string(),
                        ))
                    } else {
                        Ok(Value::Int(x / y))
                    }
                }
                _ => Err(XsError::RuntimeError(
                    span.clone(),
                    "/ requires integer arguments".to_string(),
                )),
            },
            "%" => match (&args[0], &args[1]) {
                (Value::Int(x), Value::Int(y)) => {
                    if *y == 0 {
                        Err(XsError::RuntimeError(
                            span.clone(),
                            "Modulo by zero".to_string(),
                        ))
                    } else {
                        Ok(Value::Int(x % y))
                    }
                }
                _ => Err(XsError::RuntimeError(
                    span.clone(),
                    "% requires integer arguments".to_string(),
                )),
            },
            "<" => match (&args[0], &args[1]) {
                (Value::Int(x), Value::Int(y)) => Ok(Value::Bool(x < y)),
                _ => Err(XsError::RuntimeError(
                    span.clone(),
                    "< requires integer arguments".to_string(),
                )),
            },
            ">" => match (&args[0], &args[1]) {
                (Value::Int(x), Value::Int(y)) => Ok(Value::Bool(x > y)),
                _ => Err(XsError::RuntimeError(
                    span.clone(),
                    "> requires integer arguments".to_string(),
                )),
            },
            "=" => match (&args[0], &args[1]) {
                (Value::Int(x), Value::Int(y)) => Ok(Value::Bool(x == y)),
                _ => Err(XsError::RuntimeError(
                    span.clone(),
                    "= requires integer arguments".to_string(),
                )),
            },
            ">=" => match (&args[0], &args[1]) {
                (Value::Int(x), Value::Int(y)) => Ok(Value::Bool(x >= y)),
                _ => Err(XsError::RuntimeError(
                    span.clone(),
                    ">= requires integer arguments".to_string(),
                )),
            },
            "<=" => match (&args[0], &args[1]) {
                (Value::Int(x), Value::Int(y)) => Ok(Value::Bool(x <= y)),
                _ => Err(XsError::RuntimeError(
                    span.clone(),
                    "<= requires integer arguments".to_string(),
                )),
            },
            "cons" => match &args[1] {
                Value::List(tail) => {
                    let mut new_list = vec![args[0].clone()];
                    new_list.extend(tail.clone());
                    Ok(Value::List(new_list))
                }
                _ => Err(XsError::RuntimeError(
                    span.clone(),
                    "cons requires a list as second argument".to_string(),
                )),
            },
            "concat" => match (&args[0], &args[1]) {
                (Value::String(s1), Value::String(s2)) => Ok(Value::String(format!("{s1}{s2}"))),
                _ => Err(XsError::RuntimeError(
                    span.clone(),
                    "concat requires string arguments".to_string(),
                )),
            },
            "str-concat" => match (&args[0], &args[1]) {
                (Value::String(s1), Value::String(s2)) => Ok(Value::String(format!("{s1}{s2}"))),
                _ => Err(XsError::RuntimeError(
                    span.clone(),
                    "str-concat requires string arguments".to_string(),
                )),
            },
            "int-to-string" => match &args[0] {
                Value::Int(n) => Ok(Value::String(n.to_string())),
                _ => Err(XsError::RuntimeError(
                    span.clone(),
                    "int-to-string requires an integer argument".to_string(),
                )),
            },
            "string-to-int" => match &args[0] {
                Value::String(s) => match s.parse::<i64>() {
                    Ok(n) => Ok(Value::Int(n)),
                    Err(_) => Err(XsError::RuntimeError(
                        span.clone(),
                        format!("Cannot parse '{s}' as integer"),
                    )),
                },
                _ => Err(XsError::RuntimeError(
                    span.clone(),
                    "string-to-int requires a string argument".to_string(),
                )),
            },
            "string-length" => match &args[0] {
                Value::String(s) => Ok(Value::Int(s.len() as i64)),
                _ => Err(XsError::RuntimeError(
                    span.clone(),
                    "string-length requires a string argument".to_string(),
                )),
            },
            "str-eq" => match (&args[0], &args[1]) {
                (Value::String(s1), Value::String(s2)) => Ok(Value::Bool(s1 == s2)),
                _ => Err(XsError::RuntimeError(
                    span.clone(),
                    "str-eq requires two string arguments".to_string(),
                )),
            },
            "print" => {
                let value = &args[0];
                println!("{value}");
                Ok(value.clone())
            },
            "stringAt" => match (&args[0], &args[1]) {
                (Value::String(s), Value::Int(idx)) => {
                    let idx = *idx as usize;
                    if idx >= s.len() {
                        Err(XsError::RuntimeError(
                            span.clone(),
                            format!("String index {idx} out of bounds for string of length {}", s.len()),
                        ))
                    } else {
                        let ch = s.chars().nth(idx).unwrap();
                        Ok(Value::String(ch.to_string()))
                    }
                }
                _ => Err(XsError::RuntimeError(
                    span.clone(),
                    "stringAt requires a string and an integer argument".to_string(),
                )),
            },
            "charCode" => match &args[0] {
                Value::String(s) => {
                    if s.is_empty() {
                        Err(XsError::RuntimeError(
                            span.clone(),
                            "charCode requires a non-empty string".to_string(),
                        ))
                    } else {
                        let ch = s.chars().next().unwrap();
                        Ok(Value::Int(ch as u32 as i64))
                    }
                }
                _ => Err(XsError::RuntimeError(
                    span.clone(),
                    "charCode requires a string argument".to_string(),
                )),
            },
            "codeChar" => match &args[0] {
                Value::Int(code) => {
                    if *code < 0 || *code > 0x10FFFF {
                        Err(XsError::RuntimeError(
                            span.clone(),
                            format!("Invalid character code: {code}"),
                        ))
                    } else {
                        match char::from_u32(*code as u32) {
                            Some(ch) => Ok(Value::String(ch.to_string())),
                            None => Err(XsError::RuntimeError(
                                span.clone(),
                                format!("Invalid character code: {code}"),
                            )),
                        }
                    }
                }
                _ => Err(XsError::RuntimeError(
                    span.clone(),
                    "codeChar requires an integer argument".to_string(),
                )),
            },
            "stringSlice" => match (&args[0], &args[1], &args[2]) {
                (Value::String(s), Value::Int(start), Value::Int(end)) => {
                    let start = *start as usize;
                    let end = *end as usize;
                    let chars: Vec<char> = s.chars().collect();
                    
                    if start > chars.len() || end > chars.len() || start > end {
                        Err(XsError::RuntimeError(
                            span.clone(),
                            format!("Invalid slice bounds: start={start}, end={end}, length={}", chars.len()),
                        ))
                    } else {
                        let slice: String = chars[start..end].iter().collect();
                        Ok(Value::String(slice))
                    }
                }
                _ => Err(XsError::RuntimeError(
                    span.clone(),
                    "stringSlice requires a string and two integer arguments".to_string(),
                )),
            },
            "toString" => {
                let value = &args[0];
                Ok(Value::String(format!("{value}")))
            },
            "stringConcat" => match (&args[0], &args[1]) {
                (Value::String(s1), Value::String(s2)) => Ok(Value::String(format!("{s1}{s2}"))),
                _ => Err(XsError::RuntimeError(
                    span.clone(),
                    "stringConcat requires string arguments".to_string(),
                )),
            },
            "stringEq" => match (&args[0], &args[1]) {
                (Value::String(s1), Value::String(s2)) => Ok(Value::Bool(s1 == s2)),
                _ => Err(XsError::RuntimeError(
                    span.clone(),
                    "stringEq requires two string arguments".to_string(),
                )),
            },
            _ => Err(XsError::RuntimeError(
                span.clone(),
                format!("Unknown builtin function: {name}"),
            )),
        }
    }

    #[allow(clippy::only_used_in_recursion)]
    fn match_pattern(
        &self,
        pattern: &Pattern,
        value: &Value,
    ) -> Result<Option<Vec<(Ident, Value)>>, XsError> {
        match (pattern, value) {
            (Pattern::Wildcard(_), _) => Ok(Some(vec![])),

            (Pattern::Variable(name, _), _) => Ok(Some(vec![(name.clone(), value.clone())])),

            (Pattern::Literal(pat_lit, _), _) => {
                let matches = match (pat_lit, value) {
                    (Literal::Int(n1), Value::Int(n2)) => n1 == n2,
                    (Literal::Float(f1), Value::Float(f2)) => f1.0 == *f2,
                    (Literal::Bool(b1), Value::Bool(b2)) => b1 == b2,
                    (Literal::String(s1), Value::String(s2)) => s1 == s2,
                    _ => false,
                };
                Ok(if matches { Some(vec![]) } else { None })
            }

            (
                Pattern::Constructor {
                    name: pat_name,
                    patterns,
                    ..
                },
                Value::Constructor {
                    name: val_name,
                    values,
                },
            ) => {
                if pat_name != val_name || patterns.len() != values.len() {
                    return Ok(None);
                }

                let mut all_bindings = vec![];
                for (sub_pattern, sub_value) in patterns.iter().zip(values.iter()) {
                    if let Some(bindings) = self.match_pattern(sub_pattern, sub_value)? {
                        all_bindings.extend(bindings);
                    } else {
                        return Ok(None);
                    }
                }
                Ok(Some(all_bindings))
            }

            (Pattern::List { patterns, .. }, Value::List(values)) => {
                if patterns.is_empty() && values.is_empty() {
                    return Ok(Some(vec![]));
                }

                if patterns.len() == 2 {
                    // Check for cons pattern: [head, tail]
                    if let Pattern::Variable(tail_name, _) = &patterns[1] {
                        if !values.is_empty() {
                            // Match head with first element
                            if let Some(head_bindings) =
                                self.match_pattern(&patterns[0], &values[0])?
                            {
                                let mut all_bindings = head_bindings;
                                // Bind tail to rest of list
                                all_bindings
                                    .push((tail_name.clone(), Value::List(values[1..].to_vec())));
                                return Ok(Some(all_bindings));
                            }
                        }
                    }
                }

                // Exact list match
                if patterns.len() != values.len() {
                    return Ok(None);
                }

                let mut all_bindings = vec![];
                for (sub_pattern, sub_value) in patterns.iter().zip(values.iter()) {
                    if let Some(bindings) = self.match_pattern(sub_pattern, sub_value)? {
                        all_bindings.extend(bindings);
                    } else {
                        return Ok(None);
                    }
                }
                Ok(Some(all_bindings))
            }

            _ => Ok(None),
        }
    }
}

/// Helper function to evaluate an expression with a fresh interpreter and initial environment
pub fn eval(expr: &Expr) -> Result<Value, XsError> {
    let mut interpreter = Interpreter::new();
    let env = Interpreter::create_initial_env();
    interpreter.eval(expr, &env)
}

#[cfg(test)]
mod tests {
    use super::*;
    use xs_core::{Expr, Ident, Literal, Span};

    fn setup() -> (Interpreter, Environment) {
        let interp = Interpreter::new();
        let env = Interpreter::create_initial_env();
        (interp, env)
    }

    #[test]
    fn test_eval_literal() {
        let (mut interp, env) = setup();

        let expr = Expr::Literal(Literal::Int(42), Span::new(0, 2));
        let result = interp.eval(&expr, &env).unwrap();
        assert_eq!(result, Value::Int(42));

        let expr = Expr::Literal(Literal::Bool(true), Span::new(0, 4));
        let result = interp.eval(&expr, &env).unwrap();
        assert_eq!(result, Value::Bool(true));
    }

    #[test]
    fn test_eval_builtin_partial_application() {
        let (mut interp, env) = setup();

        // Test partial application of +
        let expr = Expr::Apply {
            func: Box::new(Expr::Ident(Ident("+".to_string()), Span::new(0, 1))),
            args: vec![Expr::Literal(Literal::Int(5), Span::new(2, 3))],
            span: Span::new(0, 4),
        };

        let result = interp.eval(&expr, &env).unwrap();
        match result {
            Value::BuiltinFunction {
                name,
                arity,
                applied_args,
            } => {
                assert_eq!(name, "+");
                assert_eq!(arity, 2);
                assert_eq!(applied_args.len(), 1);
                assert_eq!(applied_args[0], Value::Int(5));
            }
            _ => panic!("Expected BuiltinFunction"),
        }
    }

    #[test]
    fn test_eval_builtin_full_application() {
        let (mut interp, env) = setup();

        // Test full application of +
        let expr = Expr::Apply {
            func: Box::new(Expr::Ident(Ident("+".to_string()), Span::new(0, 1))),
            args: vec![
                Expr::Literal(Literal::Int(5), Span::new(2, 3)),
                Expr::Literal(Literal::Int(7), Span::new(4, 5)),
            ],
            span: Span::new(0, 6),
        };

        let result = interp.eval(&expr, &env).unwrap();
        assert_eq!(result, Value::Int(12));
    }

    #[test]
    fn test_eval_curried_builtin_application() {
        let (mut interp, env) = setup();

        // Test ((+ 5) 7)
        let add5 = Expr::Apply {
            func: Box::new(Expr::Ident(Ident("+".to_string()), Span::new(0, 1))),
            args: vec![Expr::Literal(Literal::Int(5), Span::new(2, 3))],
            span: Span::new(0, 4),
        };

        let expr = Expr::Apply {
            func: Box::new(add5),
            args: vec![Expr::Literal(Literal::Int(7), Span::new(5, 6))],
            span: Span::new(0, 7),
        };

        let result = interp.eval(&expr, &env).unwrap();
        assert_eq!(result, Value::Int(12));
    }
}
