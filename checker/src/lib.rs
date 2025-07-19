use ordered_float::OrderedFloat;
use std::collections::{HashMap, HashSet};
use xs_core::{Expr, Ident, Literal, Pattern, Span, Type, TypeDefinition, XsError};

#[derive(Debug, Clone, PartialEq)]
pub struct TypeScheme {
    pub vars: Vec<String>,
    pub typ: Type,
}

impl TypeScheme {
    pub fn mono(typ: Type) -> Self {
        TypeScheme {
            vars: Vec::new(),
            typ,
        }
    }
}

pub struct TypeEnv {
    bindings: Vec<HashMap<String, TypeScheme>>,
    type_definitions: HashMap<String, TypeDefinition>,
}

impl Default for TypeEnv {
    fn default() -> Self {
        let mut env = TypeEnv {
            bindings: vec![HashMap::new()],
            type_definitions: HashMap::new(),
        };
        
        // Built-in functions
        env.add_builtin("+", Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int)))
        ));
        env.add_builtin("-", Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int)))
        ));
        env.add_builtin("*", Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int)))
        ));
        env.add_builtin("/", Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int)))
        ));
        env.add_builtin("%", Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int)))
        ));
        env.add_builtin("<", Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Bool)))
        ));
        env.add_builtin(">", Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Bool)))
        ));
        env.add_builtin("=", Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Bool)))
        ));
        env.add_builtin("cons", Type::Function(
            Box::new(Type::Var("a".to_string())),
            Box::new(Type::Function(
                Box::new(Type::List(Box::new(Type::Var("a".to_string())))),
                Box::new(Type::List(Box::new(Type::Var("a".to_string()))))
            ))
        ));
        env.add_builtin("concat", Type::Function(
            Box::new(Type::String),
            Box::new(Type::Function(Box::new(Type::String), Box::new(Type::String)))
        ));
        
        env
    }
}

impl TypeEnv {
    pub fn new() -> Self {
        Self::default()
    }

    fn add_builtin(&mut self, name: &str, typ: Type) {
        let free_vars = typ.free_vars();
        self.bindings.last_mut().unwrap().insert(
            name.to_string(),
            TypeScheme {
                vars: free_vars.into_iter().collect(),
                typ,
            }
        );
    }

    pub fn push_scope(&mut self) {
        self.bindings.push(HashMap::new());
    }

    pub fn pop_scope(&mut self) {
        self.bindings.pop();
    }

    pub fn extend(&mut self, name: String, scheme: TypeScheme) {
        self.bindings.last_mut().unwrap().insert(name, scheme);
    }

    pub fn lookup(&self, name: &str) -> Option<&TypeScheme> {
        for scope in self.bindings.iter().rev() {
            if let Some(scheme) = scope.get(name) {
                return Some(scheme);
            }
        }
        None
    }

    pub fn free_vars(&self) -> HashSet<String> {
        let mut vars = HashSet::new();
        for scope in &self.bindings {
            for scheme in scope.values() {
                let scheme_free_vars = scheme.typ.free_vars();
                let bound_vars: HashSet<String> = scheme.vars.iter().cloned().collect();
                for var in scheme_free_vars.difference(&bound_vars) {
                    vars.insert(var.clone());
                }
            }
        }
        vars
    }
    
    pub fn add_type_definition(&mut self, def: TypeDefinition) {
        self.type_definitions.insert(def.name.clone(), def);
    }
    
    pub fn get_type_definition(&self, name: &str) -> Option<&TypeDefinition> {
        self.type_definitions.get(name)
    }
    
    pub fn get_constructor_type(&self, constructor_name: &str) -> Option<(String, Vec<Type>, Type)> {
        for (type_name, def) in &self.type_definitions {
            for constructor in &def.constructors {
                if constructor.name == constructor_name {
                    // Build the constructor type
                    let result_type = Type::UserDefined {
                        name: type_name.clone(),
                        type_params: def.type_params.iter()
                            .map(|p| Type::Var(p.clone()))
                            .collect(),
                    };
                    
                    return Some((
                        type_name.clone(),
                        constructor.fields.clone(),
                        result_type,
                    ));
                }
            }
        }
        None
    }
}


#[derive(Debug, Clone)]
pub struct Constraint {
    pub left: Type,
    pub right: Type,
    pub span: Span,
}

#[derive(Default)]
pub struct TypeChecker {
    next_var: usize,
    constraints: Vec<Constraint>,
}


impl TypeChecker {
    pub fn new() -> Self {
        Self::default()
    }

    fn fresh_var(&mut self) -> Type {
        let var = Type::Var(format!("t{}", self.next_var));
        self.next_var += 1;
        var
    }

    pub fn check(&mut self, expr: &Expr, env: &mut TypeEnv) -> Result<Type, XsError> {
        let typ = self.infer(expr, env)?;
        let subst = self.solve_constraints()?;
        Ok(typ.apply_subst(&subst))
    }

    fn infer(&mut self, expr: &Expr, env: &mut TypeEnv) -> Result<Type, XsError> {
        match expr {
            Expr::Literal(lit, _) => Ok(match lit {
                Literal::Int(_) => Type::Int,
                Literal::Float(_) => Type::Float,
                Literal::Bool(_) => Type::Bool,
                Literal::String(_) => Type::String,
            }),
            
            Expr::Ident(Ident(name), _span) => {
                // Check for built-in functions first
                let builtin_type = match name.as_str() {
                    "+" | "-" | "*" | "/" => Some(Type::Function(
                        Box::new(Type::Int),
                        Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int)))
                    )),
                    "<" | ">" | "<=" | ">=" | "=" => Some(Type::Function(
                        Box::new(Type::Int),
                        Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Bool)))
                    )),
                    "cons" => {
                        let a = self.fresh_var();
                        Some(Type::Function(
                            Box::new(a.clone()),
                            Box::new(Type::Function(
                                Box::new(Type::List(Box::new(a.clone()))),
                                Box::new(Type::List(Box::new(a)))
                            ))
                        ))
                    },
                    "list" => {
                        // list is variadic, but we'll handle it specially in Apply
                        let a = self.fresh_var();
                        Some(Type::List(Box::new(a)))
                    },
                    _ => None,
                };
                
                match builtin_type {
                    Some(typ) => Ok(typ),
                    None => match env.lookup(name) {
                        Some(scheme) => Ok(self.instantiate(scheme)),
                        None => Err(XsError::UndefinedVariable(Ident(name.clone()))),
                    }
                }
            }
            
            Expr::List(elems, _) => {
                if elems.is_empty() {
                    Ok(Type::List(Box::new(self.fresh_var())))
                } else {
                    let elem_type = self.infer(&elems[0], env)?;
                    for elem in &elems[1..] {
                        let t = self.infer(elem, env)?;
                        self.constraints.push(Constraint {
                            left: elem_type.clone(),
                            right: t,
                            span: elem.span().clone(),
                        });
                    }
                    Ok(Type::List(Box::new(elem_type)))
                }
            }
            
            Expr::Let { name, type_ann, value, span } => {
                let value_type = self.infer(value, env)?;
                
                if let Some(ann_type) = type_ann {
                    self.constraints.push(Constraint {
                        left: value_type.clone(),
                        right: ann_type.clone(),
                        span: span.clone(),
                    });
                }
                
                let scheme = self.generalize(&value_type, env);
                env.extend(name.0.clone(), scheme);
                
                Ok(value_type)
            }
            
            Expr::LetRec { name, type_ann, value, span } => {
                // For recursive bindings, we need to add the name to the environment
                // before inferring the value type
                let rec_type = type_ann.clone().unwrap_or_else(|| self.fresh_var());
                env.extend(name.0.clone(), TypeScheme::mono(rec_type.clone()));
                
                let value_type = self.infer(value, env)?;
                
                self.constraints.push(Constraint {
                    left: value_type.clone(),
                    right: rec_type.clone(),
                    span: span.clone(),
                });
                
                // For let-rec, we return the value_type which contains the actual inferred type
                let scheme = self.generalize(&value_type, env);
                env.extend(name.0.clone(), scheme);
                
                Ok(value_type)
            }
            
            Expr::Rec { name, params, return_type, body, span } => {
                // For rec, we add the function name to the environment first
                let mut param_types = Vec::new();
                for (_, type_ann) in params {
                    let param_type = type_ann.clone().unwrap_or_else(|| self.fresh_var());
                    param_types.push(param_type);
                }
                
                let inferred_return_type = return_type.clone().unwrap_or_else(|| self.fresh_var());
                
                // Build the function type
                let mut func_type = inferred_return_type.clone();
                for param_type in param_types.iter().rev() {
                    func_type = Type::Function(Box::new(param_type.clone()), Box::new(func_type));
                }
                
                // Add function to environment before checking body
                env.push_scope();
                env.extend(name.0.clone(), TypeScheme::mono(func_type.clone()));
                
                // Add parameters to environment
                for ((param, _type_ann), param_type) in params.iter().zip(param_types.iter()) {
                    env.extend(param.0.clone(), TypeScheme::mono(param_type.clone()));
                }
                
                // Type check body
                let body_type = self.infer(body, env)?;
                env.pop_scope();
                
                // Constrain body type to match return type
                self.constraints.push(Constraint {
                    left: body_type,
                    right: inferred_return_type,
                    span: span.clone(),
                });
                
                Ok(func_type)
            }
            
            Expr::Lambda { params, body, .. } => {
                env.push_scope();
                
                let mut param_types = Vec::new();
                for (param, type_ann) in params {
                    let param_type = type_ann.clone().unwrap_or_else(|| self.fresh_var());
                    param_types.push(param_type.clone());
                    env.extend(param.0.clone(), TypeScheme::mono(param_type));
                }
                
                let body_type = self.infer(body, env)?;
                env.pop_scope();
                
                let mut result_type = body_type;
                for param_type in param_types.into_iter().rev() {
                    result_type = Type::Function(Box::new(param_type), Box::new(result_type));
                }
                
                Ok(result_type)
            }
            
            Expr::If { cond, then_expr, else_expr, span } => {
                let cond_type = self.infer(cond, env)?;
                self.constraints.push(Constraint {
                    left: cond_type,
                    right: Type::Bool,
                    span: cond.span().clone(),
                });
                
                let then_type = self.infer(then_expr, env)?;
                let else_type = self.infer(else_expr, env)?;
                
                self.constraints.push(Constraint {
                    left: then_type.clone(),
                    right: else_type,
                    span: span.clone(),
                });
                
                Ok(then_type)
            }
            
            Expr::Apply { func, args, span } => {
                let func_type = self.infer(func, env)?;
                
                let mut current_type = func_type;
                let result_type = self.fresh_var();
                
                for (i, arg) in args.iter().enumerate() {
                    let arg_type = self.infer(arg, env)?;
                    
                    if i == args.len() - 1 {
                        self.constraints.push(Constraint {
                            left: current_type.clone(),
                            right: Type::Function(Box::new(arg_type.clone()), Box::new(result_type.clone())),
                            span: span.clone(),
                        });
                    } else {
                        let next_type = self.fresh_var();
                        self.constraints.push(Constraint {
                            left: current_type.clone(),
                            right: Type::Function(Box::new(arg_type.clone()), Box::new(next_type.clone())),
                            span: span.clone(),
                        });
                        current_type = next_type;
                    }
                }
                
                Ok(result_type)
            }
            
            Expr::Match { expr, cases, span } => {
                let expr_type = self.infer(expr, env)?;
                
                if cases.is_empty() {
                    return Err(XsError::TypeError(span.clone(), "Match expression must have at least one case".to_string()));
                }
                
                // All branches must have the same type
                let result_type = self.fresh_var();
                
                for (pattern, case_expr) in cases {
                    // Create a new scope for pattern variables
                    env.push_scope();
                    
                    // Infer pattern type and bind variables
                    self.check_pattern(pattern, &expr_type, env)?;
                    
                    // Infer case expression type
                    let case_type = self.infer(case_expr, env)?;
                    
                    // Pop pattern scope
                    env.pop_scope();
                    
                    // Constrain all branches to have the same type
                    self.constraints.push(Constraint {
                        left: case_type,
                        right: result_type.clone(),
                        span: case_expr.span().clone(),
                    });
                }
                
                Ok(result_type)
            }
            
            Expr::Constructor { name, args, span } => {
                // Look up the constructor in the type environment
                if let Some((type_name, field_types, result_type)) = env.get_constructor_type(&name.0) {
                    // Check that we have the right number of arguments
                    if args.len() != field_types.len() {
                        return Err(XsError::TypeError(
                            span.clone(),
                            format!("Constructor {} expects {} arguments, got {}", 
                                    name.0, field_types.len(), args.len())
                        ));
                    }
                    
                    // Instantiate type variables if needed
                    let type_def = env.get_type_definition(&type_name).unwrap();
                    let mut type_subst = HashMap::new();
                    let mut instantiated_field_types = Vec::new();
                    
                    // Create fresh type variables for type parameters
                    for param in &type_def.type_params {
                        type_subst.insert(param.clone(), self.fresh_var());
                    }
                    
                    // Apply substitution to field types
                    for field_type in &field_types {
                        instantiated_field_types.push(field_type.apply_subst(&type_subst));
                    }
                    
                    // Type check arguments against field types
                    for (arg, expected_type) in args.iter().zip(instantiated_field_types.iter()) {
                        let arg_type = self.infer(arg, env)?;
                        self.constraints.push(Constraint {
                            left: arg_type,
                            right: expected_type.clone(),
                            span: arg.span().clone(),
                        });
                    }
                    
                    // Return the instantiated result type
                    Ok(result_type.apply_subst(&type_subst))
                } else {
                    // If no type definition found, create a placeholder type
                    let constructor_type = Type::UserDefined {
                        name: name.0.clone(),
                        type_params: vec![],
                    };
                    
                    // Type check arguments
                    for arg in args {
                        self.infer(arg, env)?;
                    }
                    
                    Ok(constructor_type)
                }
            }
            
            Expr::TypeDef { definition, .. } => {
                // Add the type definition to the environment
                env.add_type_definition(definition.clone());
                
                // Type definitions don't have a runtime value, return unit type
                Ok(Type::Int) // Using Int as a placeholder for unit type
            }
            
            Expr::Module { name: _, exports: _, body, .. } => {
                // For now, just type check the body expressions
                // TODO: Implement proper module type checking with export validation
                let mut result_type = Type::Int; // unit type
                for expr in body {
                    result_type = self.infer(expr, env)?;
                }
                Ok(result_type)
            }
            
            Expr::Import { .. } => {
                // Import statements don't have a runtime value
                // TODO: Implement proper import handling
                Ok(Type::Int) // unit type
            }
            
            Expr::QualifiedIdent { module_name: _, name: _, span } => {
                // TODO: Implement proper module member lookup
                Err(XsError::TypeError(
                    span.clone(),
                    "Module member lookup not yet implemented".to_string(),
                ))
            }
        }
    }

    fn instantiate(&mut self, scheme: &TypeScheme) -> Type {
        let mut subst = HashMap::new();
        for var in &scheme.vars {
            subst.insert(var.clone(), self.fresh_var());
        }
        scheme.typ.apply_subst(&subst)
    }

    fn generalize(&self, typ: &Type, env: &TypeEnv) -> TypeScheme {
        let env_vars = env.free_vars();
        let type_vars = typ.free_vars();
        let gen_vars: Vec<String> = type_vars.difference(&env_vars).cloned().collect();
        
        TypeScheme {
            vars: gen_vars,
            typ: typ.clone(),
        }
    }

    fn solve_constraints(&mut self) -> Result<HashMap<String, Type>, XsError> {
        let mut subst = HashMap::new();
        
        while let Some(constraint) = self.constraints.pop() {
            let left = constraint.left.apply_subst(&subst);
            let right = constraint.right.apply_subst(&subst);
            
            match self.unify(&left, &right) {
                Ok(new_subst) => {
                    subst = self.compose_subst(&new_subst, &subst);
                }
                Err(_) => {
                    return Err(XsError::TypeMismatch {
                        expected: left,
                        found: right,
                    });
                }
            }
        }
        
        Ok(subst)
    }

    fn unify(&self, t1: &Type, t2: &Type) -> Result<HashMap<String, Type>, XsError> {
        match (t1, t2) {
            (Type::Int, Type::Int) | (Type::Float, Type::Float) | (Type::Bool, Type::Bool) | (Type::String, Type::String) => {
                Ok(HashMap::new())
            }
            (Type::List(a), Type::List(b)) => self.unify(a, b),
            (Type::Function(a1, r1), Type::Function(a2, r2)) => {
                let subst = self.unify(a1, a2)?;
                let r1_subst = r1.apply_subst(&subst);
                let r2_subst = r2.apply_subst(&subst);
                let subst2 = self.unify(&r1_subst, &r2_subst)?;
                Ok(self.compose_subst(&subst2, &subst))
            }
            (Type::Var(v), t) | (t, Type::Var(v)) => {
                if t == &Type::Var(v.clone()) {
                    Ok(HashMap::new())
                } else if t.free_vars().contains(v) {
                    Err(XsError::TypeError(Span::new(0, 0), "Infinite type".to_string()))
                } else {
                    let mut subst = HashMap::new();
                    subst.insert(v.clone(), t.clone());
                    Ok(subst)
                }
            }
            _ => Err(XsError::TypeMismatch {
                expected: t1.clone(),
                found: t2.clone(),
            }),
        }
    }

    fn compose_subst(&self, s1: &HashMap<String, Type>, s2: &HashMap<String, Type>) -> HashMap<String, Type> {
        let mut result = s2.clone();
        for (k, v) in s1 {
            result.insert(k.clone(), v.apply_subst(s2));
        }
        result
    }
    
    fn check_pattern(&mut self, pattern: &Pattern, expected_type: &Type, env: &mut TypeEnv) -> Result<(), XsError> {
        match pattern {
            Pattern::Wildcard(_) => Ok(()),
            
            Pattern::Literal(lit, span) => {
                let lit_type = match lit {
                    Literal::Int(_) => Type::Int,
                    Literal::Float(OrderedFloat(_)) => Type::Float,
                    Literal::Bool(_) => Type::Bool,
                    Literal::String(_) => Type::String,
                };
                self.constraints.push(Constraint {
                    left: lit_type,
                    right: expected_type.clone(),
                    span: span.clone(),
                });
                Ok(())
            }
            
            Pattern::Variable(name, _) => {
                // Bind the variable to the expected type
                env.extend(name.0.clone(), TypeScheme::mono(expected_type.clone()));
                Ok(())
            }
            
            Pattern::Constructor { name, patterns, span: _ } => {
                // For now, we assume constructors have the same type as their data type
                // This will be refined when we implement proper ADT support
                match expected_type {
                    Type::UserDefined { name: type_name, .. } => {
                        if name.0 != *type_name {
                            // For now, we'll be lenient and allow any constructor
                            // This will be fixed when we have proper ADT definitions
                        }
                        
                        // Type check nested patterns
                        // For now, we'll use fresh type variables for each pattern
                        for pattern in patterns {
                            let pattern_type = self.fresh_var();
                            self.check_pattern(pattern, &pattern_type, env)?;
                        }
                        
                        Ok(())
                    }
                    _ => {
                        // For now, allow constructor patterns to match any type
                        // This will be fixed when we have proper ADT support
                        for pattern in patterns {
                            let pattern_type = self.fresh_var();
                            self.check_pattern(pattern, &pattern_type, env)?;
                        }
                        Ok(())
                    }
                }
            }
            
            Pattern::List { patterns, span } => {
                match expected_type {
                    Type::List(elem_type) => {
                        if patterns.len() == 2 {
                            // Check for cons pattern: [head, tail]
                            // where tail should bind to the rest of the list
                            self.check_pattern(&patterns[0], elem_type, env)?;
                            // The second element should be a list of the same type
                            self.check_pattern(&patterns[1], expected_type, env)?;
                        } else {
                            // All elements must have the same type
                            for pattern in patterns {
                                self.check_pattern(pattern, elem_type, env)?;
                            }
                        }
                        Ok(())
                    }
                    Type::Var(_) => {
                        // If the expected type is a variable, constrain it to be a list
                        let elem_type = self.fresh_var();
                        self.constraints.push(Constraint {
                            left: expected_type.clone(),
                            right: Type::List(Box::new(elem_type.clone())),
                            span: span.clone(),
                        });
                        
                        if patterns.len() == 2 {
                            // Check for cons pattern
                            self.check_pattern(&patterns[0], &elem_type, env)?;
                            self.check_pattern(&patterns[1], expected_type, env)?;
                        } else {
                            // Check patterns against element type
                            for pattern in patterns {
                                self.check_pattern(pattern, &elem_type, env)?;
                            }
                        }
                        Ok(())
                    }
                    _ => Err(XsError::TypeError(span.clone(), "Expected list type in list pattern".to_string())),
                }
            }
        }
    }
}

fn builtin_env() -> TypeEnv {
    let mut env = TypeEnv::new();
    
    // Arithmetic operators
    let int_binop_type = Type::Function(
        Box::new(Type::Int),
        Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int)))
    );
    env.extend("+".to_string(), TypeScheme::mono(int_binop_type.clone()));
    env.extend("-".to_string(), TypeScheme::mono(int_binop_type.clone()));
    env.extend("*".to_string(), TypeScheme::mono(int_binop_type.clone()));
    env.extend("/".to_string(), TypeScheme::mono(int_binop_type.clone()));
    
    // Comparison operators
    let int_cmp_type = Type::Function(
        Box::new(Type::Int),
        Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Bool)))
    );
    env.extend("=".to_string(), TypeScheme::mono(int_cmp_type.clone()));
    env.extend("<".to_string(), TypeScheme::mono(int_cmp_type.clone()));
    env.extend(">".to_string(), TypeScheme::mono(int_cmp_type.clone()));
    env.extend("<=".to_string(), TypeScheme::mono(int_cmp_type.clone()));
    env.extend(">=".to_string(), TypeScheme::mono(int_cmp_type.clone()));
    
    // List operations
    let cons_type = TypeScheme {
        vars: vec!["a".to_string()],
        typ: Type::Function(
            Box::new(Type::Var("a".to_string())),
            Box::new(Type::Function(
                Box::new(Type::List(Box::new(Type::Var("a".to_string())))),
                Box::new(Type::List(Box::new(Type::Var("a".to_string()))))
            ))
        ),
    };
    env.extend("cons".to_string(), cons_type);
    
    env
}

pub fn type_check(expr: &Expr) -> Result<Type, XsError> {
    let mut checker = TypeChecker::new();
    let mut env = builtin_env();
    checker.check(expr, &mut env)
}

#[cfg(test)]
mod tests {
    use super::*;
    use parser::parse;

    #[test]
    fn test_literal_types() {
        assert_eq!(type_check(&parse("42").unwrap()).unwrap(), Type::Int);
        assert_eq!(type_check(&parse("true").unwrap()).unwrap(), Type::Bool);
        assert_eq!(type_check(&parse(r#""hello""#).unwrap()).unwrap(), Type::String);
    }

    #[test]
    fn test_list_types() {
        let typ = type_check(&parse("(list 1 2 3)").unwrap()).unwrap();
        match typ {
            Type::List(elem) => assert_eq!(*elem, Type::Int),
            _ => panic!("Expected List type"),
        }

        let typ = type_check(&parse("(list)").unwrap()).unwrap();
        match typ {
            Type::List(_) => {}, // Empty list can be any type
            _ => panic!("Expected List type"),
        }
    }

    #[test]
    fn test_let_binding() {
        let typ = type_check(&parse("(let x 42)").unwrap()).unwrap();
        assert_eq!(typ, Type::Int);

        let typ = type_check(&parse("(let x : Int 42)").unwrap()).unwrap();
        assert_eq!(typ, Type::Int);
    }

    #[test]
    fn test_let_type_mismatch() {
        let result = type_check(&parse("(let x : Bool 42)").unwrap());
        assert!(matches!(result, Err(XsError::TypeMismatch { .. })));
    }

    #[test]
    fn test_rec_types() {
        // Basic recursive function
        let typ = type_check(&parse("(rec factorial (n : Int) : Int (if (= n 0) 1 (* n (factorial (- n 1)))))").unwrap()).unwrap();
        match &typ {
            Type::Function(from, to) => {
                // Should be Int -> Int
                assert!(matches!(from.as_ref(), Type::Int));
                assert!(matches!(to.as_ref(), Type::Int));
            },
            _ => panic!("Expected function type for factorial, got {typ:?}"),
        }

        // With type annotations
        let typ = type_check(&parse("(rec add (x : Int y : Int) : Int (+ x y))").unwrap()).unwrap();
        match &typ {
            Type::Function(from, to) => {
                match (from.as_ref(), to.as_ref()) {
                    (Type::Int, Type::Function(from2, to2)) => {
                        assert!(matches!(from2.as_ref(), Type::Int));
                        assert!(matches!(to2.as_ref(), Type::Int));
                    },
                    _ => panic!("Expected Int -> Int -> Int for add"),
                }
            },
            _ => panic!("Expected function type for add"),
        }
    }

    #[test]
    fn test_lambda_types() {
        let typ = type_check(&parse("(lambda (x) x)").unwrap()).unwrap();
        match typ {
            Type::Function(_, _) => {},
            _ => panic!("Expected Function type"),
        }

        let typ = type_check(&parse("(lambda (x : Int) x)").unwrap()).unwrap();
        match typ {
            Type::Function(from, to) => {
                assert_eq!(*from, Type::Int);
                assert_eq!(*to, Type::Int);
            },
            _ => panic!("Expected Function type"),
        }
    }

    #[test]
    fn test_if_expression() {
        let typ = type_check(&parse("(if true 1 2)").unwrap()).unwrap();
        assert_eq!(typ, Type::Int);

        let result = type_check(&parse("(if 1 2 3)").unwrap());
        assert!(matches!(result, Err(XsError::TypeMismatch { .. })));

        let result = type_check(&parse("(if true 1 false)").unwrap());
        assert!(matches!(result, Err(XsError::TypeMismatch { .. })));
    }

    #[test]
    fn test_builtin_functions() {
        let typ = type_check(&parse("(+ 1 2)").unwrap()).unwrap();
        assert_eq!(typ, Type::Int);

        let typ = type_check(&parse("(< 1 2)").unwrap()).unwrap();
        assert_eq!(typ, Type::Bool);
    }

    #[test]
    fn test_function_application() {
        let typ = type_check(&parse("((lambda (x : Int) (+ x 1)) 5)").unwrap()).unwrap();
        assert_eq!(typ, Type::Int);
    }

    #[test]
    fn test_let_polymorphism() {
        // Identity function should work with different types
        let program = r#"
            (let id (lambda (x) x))
        "#;
        let typ = type_check(&parse(program).unwrap()).unwrap();
        match typ {
            Type::Function(_, _) => {},
            _ => panic!("Expected Function type"),
        }
    }

    #[test]
    fn test_undefined_variable() {
        let result = type_check(&parse("x").unwrap());
        assert!(matches!(result, Err(XsError::UndefinedVariable(_))));
    }

    #[test]
    fn test_nested_let() {
        let program = "(let x 1 (let y 2 (+ x y)))";
        let result = parse(program);
        assert!(result.is_err()); // This syntax is not supported yet
    }

    #[test]
    fn test_let_rec() {
        // Simple recursive function
        let program = "(let-rec fact : (-> Int Int) (lambda (n : Int) (if (= n 0) 1 (* n (fact (- n 1))))))";
        let typ = type_check(&parse(program).unwrap()).unwrap();
        match typ {
            Type::Function(from, to) => {
                assert_eq!(*from, Type::Int);
                assert_eq!(*to, Type::Int);
            },
            _ => panic!("Expected Function type"),
        }
    }

    #[test]
    #[ignore] // TODO: Fix type inference for let-rec without type annotation
    fn test_let_rec_no_annotation() {
        // Recursive function without type annotation
        let program = "(let-rec fact (lambda (n) (if (= n 0) 1 (* n (fact (- n 1))))))";
        let typ = type_check(&parse(program).unwrap()).unwrap();
        match typ {
            Type::Function(from, to) => {
                assert_eq!(*from, Type::Int);
                assert_eq!(*to, Type::Int);
            },
            _ => panic!("Expected Function type"),
        }
    }

    #[test]
    fn test_higher_order_function() {
        let program = "(lambda (f : (-> Int Int)) (lambda (x : Int) (f x)))";
        let typ = type_check(&parse(program).unwrap()).unwrap();
        match typ {
            Type::Function(from, to) => {
                match from.as_ref() {
                    Type::Function(a, b) => {
                        assert_eq!(**a, Type::Int);
                        assert_eq!(**b, Type::Int);
                    },
                    _ => panic!("Expected function type as parameter"),
                }
                match to.as_ref() {
                    Type::Function(a, b) => {
                        assert_eq!(**a, Type::Int);
                        assert_eq!(**b, Type::Int);
                    },
                    _ => panic!("Expected function type as result"),
                }
            },
            _ => panic!("Expected Function type"),
        }
    }
    
    #[test]
    fn test_match_expression() {
        let program = "(match 1 (0 \"zero\") (1 \"one\") (_ \"other\"))";
        let typ = type_check(&parse(program).unwrap()).unwrap();
        assert_eq!(typ, Type::String);
    }
    
    #[test]
    fn test_match_with_variables() {
        let program = "(match (list 1 2 3) ((list x y z) (+ x z)))";
        let typ = type_check(&parse(program).unwrap()).unwrap();
        assert_eq!(typ, Type::Int);
    }
    
    #[test]
    fn test_constructor() {
        let program = "(Some 42)";
        let typ = type_check(&parse(program).unwrap()).unwrap();
        match typ {
            Type::UserDefined { name, .. } => assert_eq!(name, "Some"),
            _ => panic!("Expected UserDefined type"),
        }
    }
    
    #[test]
    fn test_type_definition() {
        let program = r#"
            (type Option 
                (Some value)
                (None))
        "#;
        let result = type_check(&parse(program).unwrap());
        assert!(result.is_ok()); // Type definitions themselves just return unit
    }
    
    #[test]
    fn test_adt_constructor() {
        // First define the type
        let def_program = "(type Option (Some value) (None))";
        let mut checker = TypeChecker::new();
        let mut env = builtin_env();
        checker.check(&parse(def_program).unwrap(), &mut env).unwrap();
        
        // Then use the constructor
        let use_program = "(Some 42)";
        let typ = checker.check(&parse(use_program).unwrap(), &mut env).unwrap();
        match typ {
            Type::UserDefined { name, .. } => assert_eq!(name, "Option"),
            _ => panic!("Expected UserDefined type, got {typ:?}"),
        }
    }
    
    #[test]
    fn test_adt_pattern_match() {
        // First define the type
        let def_program = "(type Option (Some value) (None))";
        let mut checker = TypeChecker::new();
        let mut env = builtin_env();
        checker.check(&parse(def_program).unwrap(), &mut env).unwrap();
        
        // Then use it in a match
        let match_program = r#"
            (match (Some 42)
                ((Some x) x)
                ((None) 0))
        "#;
        let typ = checker.check(&parse(match_program).unwrap(), &mut env).unwrap();
        assert_eq!(typ, Type::Int);
    }
}
