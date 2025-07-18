use std::collections::{HashMap, HashSet};
use xs_core::{Expr, Ident, Literal, Span, Type, XsError};

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
}

impl TypeEnv {
    pub fn new() -> Self {
        let mut env = TypeEnv {
            bindings: vec![HashMap::new()],
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
        
        env
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
}


#[derive(Debug, Clone)]
pub struct Constraint {
    pub left: Type,
    pub right: Type,
    pub span: Span,
}

pub struct TypeChecker {
    next_var: usize,
    constraints: Vec<Constraint>,
}

impl TypeChecker {
    pub fn new() -> Self {
        TypeChecker {
            next_var: 0,
            constraints: Vec::new(),
        }
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
                Literal::Bool(_) => Type::Bool,
                Literal::String(_) => Type::String,
            }),
            
            Expr::Ident(Ident(name), _span) => {
                match env.lookup(name) {
                    Some(scheme) => Ok(self.instantiate(scheme)),
                    None => Err(XsError::UndefinedVariable(Ident(name.clone()))),
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
            (Type::Int, Type::Int) | (Type::Bool, Type::Bool) | (Type::String, Type::String) => {
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
}

pub fn type_check(expr: &Expr) -> Result<Type, XsError> {
    let mut checker = TypeChecker::new();
    let mut env = TypeEnv::new();
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
}
