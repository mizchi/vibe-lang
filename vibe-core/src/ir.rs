//! Intermediate Representation for XS language with Perceus memory management

use crate::{Literal, Type};

/// IR expressions with explicit memory management instructions
#[derive(Debug, Clone, PartialEq)]
pub enum IrExpr {
    /// Literal values
    Literal(Literal),

    /// Variable reference
    Var(String),

    /// Let binding
    Let {
        name: String,
        value: Box<IrExpr>,
        body: Box<IrExpr>,
    },

    /// Let-rec binding for recursive functions
    LetRec {
        name: String,
        value: Box<IrExpr>,
        body: Box<IrExpr>,
    },

    /// Lambda abstraction
    Lambda {
        params: Vec<String>,
        body: Box<IrExpr>,
    },

    /// Function application
    Apply {
        func: Box<IrExpr>,
        args: Vec<IrExpr>,
    },

    /// Conditional expression
    If {
        cond: Box<IrExpr>,
        then_expr: Box<IrExpr>,
        else_expr: Box<IrExpr>,
    },

    /// List construction
    List(Vec<IrExpr>),

    /// Cons operation
    Cons {
        head: Box<IrExpr>,
        tail: Box<IrExpr>,
    },

    /// Sequence of expressions
    Sequence(Vec<IrExpr>),

    // Memory management instructions
    /// Drop a reference (decrement reference count)
    Drop(String),

    /// Duplicate a reference (increment reference count)
    Dup(String),

    /// Check if a value can be reused (ref count == 1)
    ReuseCheck {
        var: String,
        reuse_expr: Box<IrExpr>,
        fallback_expr: Box<IrExpr>,
    },
}

/// Ownership information for variables
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ownership {
    /// Owned value (reference count = 1)
    Owned,
    /// Borrowed reference (doesn't affect reference count)
    Borrowed,
    /// Shared value (reference count > 1)
    Shared,
}

/// Variable usage information for Perceus analysis
#[derive(Debug, Clone)]
pub struct UsageInfo {
    pub name: String,
    pub use_count: usize,
    pub ownership: Ownership,
}

impl IrExpr {
    /// Count the number of uses of a variable in an expression
    pub fn count_uses(&self, var: &str) -> usize {
        match self {
            IrExpr::Var(name) => {
                if name == var {
                    1
                } else {
                    0
                }
            }
            IrExpr::Let { value, body, .. } => value.count_uses(var) + body.count_uses(var),
            IrExpr::LetRec { value, body, .. } => value.count_uses(var) + body.count_uses(var),
            IrExpr::Lambda { body, params, .. } => {
                if params.contains(&var.to_string()) {
                    0 // Variable is shadowed
                } else {
                    body.count_uses(var)
                }
            }
            IrExpr::Apply { func, args } => {
                func.count_uses(var) + args.iter().map(|a| a.count_uses(var)).sum::<usize>()
            }
            IrExpr::If {
                cond,
                then_expr,
                else_expr,
            } => cond.count_uses(var) + then_expr.count_uses(var) + else_expr.count_uses(var),
            IrExpr::List(exprs) => exprs.iter().map(|e| e.count_uses(var)).sum(),
            IrExpr::Cons { head, tail } => head.count_uses(var) + tail.count_uses(var),
            IrExpr::Sequence(exprs) => exprs.iter().map(|e| e.count_uses(var)).sum(),
            IrExpr::Drop(name) | IrExpr::Dup(name) => {
                if name == var {
                    1
                } else {
                    0
                }
            }
            IrExpr::ReuseCheck {
                var: v,
                reuse_expr,
                fallback_expr,
            } => {
                let base = if v == var { 1 } else { 0 };
                base + reuse_expr.count_uses(var) + fallback_expr.count_uses(var)
            }
            IrExpr::Literal(_) => 0,
        }
    }

    /// Get all free variables in the expression
    pub fn free_vars(&self) -> Vec<String> {
        match self {
            IrExpr::Var(name) => vec![name.clone()],
            IrExpr::Let { name, value, body } => {
                let mut vars = value.free_vars();
                let body_vars = body.free_vars();
                for v in body_vars {
                    if v != *name {
                        vars.push(v);
                    }
                }
                vars
            }
            IrExpr::LetRec { name, value, body } => {
                let mut vars = vec![];
                for v in value.free_vars() {
                    if v != *name {
                        vars.push(v);
                    }
                }
                for v in body.free_vars() {
                    if v != *name {
                        vars.push(v);
                    }
                }
                vars
            }
            IrExpr::Lambda { params, body } => {
                let mut vars = vec![];
                for v in body.free_vars() {
                    if !params.contains(&v) {
                        vars.push(v);
                    }
                }
                vars
            }
            IrExpr::Apply { func, args } => {
                let mut vars = func.free_vars();
                for arg in args {
                    vars.extend(arg.free_vars());
                }
                vars
            }
            IrExpr::If {
                cond,
                then_expr,
                else_expr,
            } => {
                let mut vars = cond.free_vars();
                vars.extend(then_expr.free_vars());
                vars.extend(else_expr.free_vars());
                vars
            }
            IrExpr::List(exprs) => {
                let mut vars = vec![];
                for expr in exprs {
                    vars.extend(expr.free_vars());
                }
                vars
            }
            IrExpr::Cons { head, tail } => {
                let mut vars = head.free_vars();
                vars.extend(tail.free_vars());
                vars
            }
            IrExpr::Sequence(exprs) => {
                let mut vars = vec![];
                for expr in exprs {
                    vars.extend(expr.free_vars());
                }
                vars
            }
            IrExpr::Drop(name) | IrExpr::Dup(name) => vec![name.clone()],
            IrExpr::ReuseCheck {
                var,
                reuse_expr,
                fallback_expr,
            } => {
                let mut vars = vec![var.clone()];
                vars.extend(reuse_expr.free_vars());
                vars.extend(fallback_expr.free_vars());
                vars
            }
            IrExpr::Literal(_) => vec![],
        }
    }
}

/// Typed IR expression with type information
#[derive(Debug, Clone, PartialEq)]
pub enum TypedIrExpr {
    /// Literal value with type
    Literal { value: Literal, ty: Type },

    /// Variable reference with type
    Var { name: String, ty: Type },

    /// Let binding with types
    Let {
        name: String,
        value: Box<TypedIrExpr>,
        body: Box<TypedIrExpr>,
        ty: Type,
    },

    /// Recursive let binding with types
    LetRec {
        name: String,
        value: Box<TypedIrExpr>,
        body: Box<TypedIrExpr>,
        ty: Type,
    },

    /// Lambda abstraction with types
    Lambda {
        params: Vec<(String, Type)>,
        body: Box<TypedIrExpr>,
        ty: Type,
    },

    /// Function application with types
    Apply {
        func: Box<TypedIrExpr>,
        args: Vec<TypedIrExpr>,
        ty: Type,
    },

    /// If expression with types
    If {
        cond: Box<TypedIrExpr>,
        then_expr: Box<TypedIrExpr>,
        else_expr: Box<TypedIrExpr>,
        ty: Type,
    },

    /// List construction with types
    List {
        elements: Vec<TypedIrExpr>,
        elem_ty: Type,
        ty: Type,
    },

    /// Cons operation with types
    Cons {
        head: Box<TypedIrExpr>,
        tail: Box<TypedIrExpr>,
        ty: Type,
    },

    /// Match expression with types
    Match {
        expr: Box<TypedIrExpr>,
        cases: Vec<(TypedPattern, TypedIrExpr)>,
        ty: Type,
    },

    /// Constructor with types
    Constructor {
        name: String,
        args: Vec<TypedIrExpr>,
        ty: Type,
    },

    /// Sequence of expressions
    Sequence { exprs: Vec<TypedIrExpr>, ty: Type },

    // Memory management instructions
    /// Drop a reference (decrement reference count)
    Drop {
        name: String,
        value: Box<TypedIrExpr>,
    },

    /// Duplicate a reference (increment reference count)
    Dup {
        name: String,
        value: Box<TypedIrExpr>,
    },

    /// Check if a value can be reused (ref count == 1)
    ReuseCheck {
        var: String,
        reuse_expr: Box<TypedIrExpr>,
        fallback_expr: Box<TypedIrExpr>,
        ty: Type,
    },
}

/// Pattern for pattern matching in typed IR
#[derive(Debug, Clone, PartialEq)]
pub enum TypedPattern {
    /// Wildcard pattern
    Wildcard,
    /// Variable pattern
    Variable(String, Type),
    /// Literal pattern
    Literal(Literal),
    /// Constructor pattern
    Constructor {
        name: String,
        patterns: Vec<TypedPattern>,
        ty: Type,
    },
    /// List pattern
    List {
        patterns: Vec<TypedPattern>,
        elem_ty: Type,
    },
}

impl TypedIrExpr {
    /// Get the type of this typed IR expression
    pub fn get_type(&self) -> &Type {
        match self {
            TypedIrExpr::Literal { ty, .. } => ty,
            TypedIrExpr::Var { ty, .. } => ty,
            TypedIrExpr::Let { ty, .. } => ty,
            TypedIrExpr::LetRec { ty, .. } => ty,
            TypedIrExpr::Lambda { ty, .. } => ty,
            TypedIrExpr::Apply { ty, .. } => ty,
            TypedIrExpr::If { ty, .. } => ty,
            TypedIrExpr::List { ty, .. } => ty,
            TypedIrExpr::Cons { ty, .. } => ty,
            TypedIrExpr::Match { ty, .. } => ty,
            TypedIrExpr::Constructor { ty, .. } => ty,
            TypedIrExpr::Sequence { ty, .. } => ty,
            TypedIrExpr::Drop { value, .. } => value.get_type(),
            TypedIrExpr::Dup { value, .. } => value.get_type(),
            TypedIrExpr::ReuseCheck { ty, .. } => ty,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ordered_float::OrderedFloat;

    #[test]
    fn test_count_uses() {
        let expr = IrExpr::Let {
            name: "x".to_string(),
            value: Box::new(IrExpr::Literal(Literal::Int(42))),
            body: Box::new(IrExpr::Apply {
                func: Box::new(IrExpr::Var("f".to_string())),
                args: vec![IrExpr::Var("x".to_string()), IrExpr::Var("x".to_string())],
            }),
        };

        assert_eq!(expr.count_uses("x"), 2);
        assert_eq!(expr.count_uses("f"), 1);
        assert_eq!(expr.count_uses("y"), 0);
    }

    #[test]
    fn test_count_uses_shadowing() {
        let expr = IrExpr::Lambda {
            params: vec!["x".to_string()],
            body: Box::new(IrExpr::Var("x".to_string())),
        };

        // x is shadowed inside lambda, so outer x has 0 uses
        assert_eq!(expr.count_uses("x"), 0);
    }

    #[test]
    fn test_count_uses_if() {
        let expr = IrExpr::If {
            cond: Box::new(IrExpr::Var("x".to_string())),
            then_expr: Box::new(IrExpr::Var("x".to_string())),
            else_expr: Box::new(IrExpr::Var("y".to_string())),
        };

        assert_eq!(expr.count_uses("x"), 2);
        assert_eq!(expr.count_uses("y"), 1);
    }

    #[test]
    fn test_count_uses_list() {
        let expr = IrExpr::List(vec![
            IrExpr::Var("x".to_string()),
            IrExpr::Var("x".to_string()),
            IrExpr::Var("y".to_string()),
        ]);

        assert_eq!(expr.count_uses("x"), 2);
        assert_eq!(expr.count_uses("y"), 1);
    }

    #[test]
    fn test_count_uses_cons() {
        let expr = IrExpr::Cons {
            head: Box::new(IrExpr::Var("x".to_string())),
            tail: Box::new(IrExpr::Var("xs".to_string())),
        };

        assert_eq!(expr.count_uses("x"), 1);
        assert_eq!(expr.count_uses("xs"), 1);
    }

    #[test]
    fn test_count_uses_sequence() {
        let expr = IrExpr::Sequence(vec![
            IrExpr::Var("x".to_string()),
            IrExpr::Var("x".to_string()),
            IrExpr::Var("y".to_string()),
        ]);

        assert_eq!(expr.count_uses("x"), 2);
        assert_eq!(expr.count_uses("y"), 1);
    }

    #[test]
    fn test_count_uses_memory_ops() {
        let expr1 = IrExpr::Drop("x".to_string());
        assert_eq!(expr1.count_uses("x"), 1);

        let expr2 = IrExpr::Dup("y".to_string());
        assert_eq!(expr2.count_uses("y"), 1);
        assert_eq!(expr2.count_uses("x"), 0);
    }

    #[test]
    fn test_count_uses_reuse_check() {
        let expr = IrExpr::ReuseCheck {
            var: "x".to_string(),
            reuse_expr: Box::new(IrExpr::Var("x".to_string())),
            fallback_expr: Box::new(IrExpr::Var("y".to_string())),
        };

        assert_eq!(expr.count_uses("x"), 2); // 1 for var + 1 in reuse_expr
        assert_eq!(expr.count_uses("y"), 1);
    }

    #[test]
    fn test_count_uses_let_rec() {
        let expr = IrExpr::LetRec {
            name: "f".to_string(),
            value: Box::new(IrExpr::Lambda {
                params: vec!["x".to_string()],
                body: Box::new(IrExpr::Apply {
                    func: Box::new(IrExpr::Var("f".to_string())),
                    args: vec![IrExpr::Var("x".to_string())],
                }),
            }),
            body: Box::new(IrExpr::Var("f".to_string())),
        };

        assert_eq!(expr.count_uses("f"), 2); // 1 in value + 1 in body
    }

    #[test]
    fn test_free_vars() {
        let expr = IrExpr::Lambda {
            params: vec!["x".to_string()],
            body: Box::new(IrExpr::Apply {
                func: Box::new(IrExpr::Var("f".to_string())),
                args: vec![IrExpr::Var("x".to_string())],
            }),
        };

        let free = expr.free_vars();
        assert_eq!(free, vec!["f"]);
    }

    #[test]
    fn test_free_vars_let() {
        let expr = IrExpr::Let {
            name: "x".to_string(),
            value: Box::new(IrExpr::Var("y".to_string())),
            body: Box::new(IrExpr::Apply {
                func: Box::new(IrExpr::Var("f".to_string())),
                args: vec![IrExpr::Var("x".to_string())],
            }),
        };

        let free = expr.free_vars();
        assert!(free.contains(&"y".to_string()));
        assert!(free.contains(&"f".to_string()));
        assert!(!free.contains(&"x".to_string())); // x is bound
    }

    #[test]
    fn test_free_vars_let_rec() {
        let expr = IrExpr::LetRec {
            name: "f".to_string(),
            value: Box::new(IrExpr::Lambda {
                params: vec!["x".to_string()],
                body: Box::new(IrExpr::Apply {
                    func: Box::new(IrExpr::Var("f".to_string())),
                    args: vec![IrExpr::Var("x".to_string()), IrExpr::Var("g".to_string())],
                }),
            }),
            body: Box::new(IrExpr::Var("f".to_string())),
        };

        let free = expr.free_vars();
        assert!(free.contains(&"g".to_string()));
        assert!(!free.contains(&"f".to_string())); // f is bound
        assert!(!free.contains(&"x".to_string())); // x is bound
    }

    #[test]
    fn test_free_vars_if() {
        let expr = IrExpr::If {
            cond: Box::new(IrExpr::Var("x".to_string())),
            then_expr: Box::new(IrExpr::Var("y".to_string())),
            else_expr: Box::new(IrExpr::Var("z".to_string())),
        };

        let free = expr.free_vars();
        assert!(free.contains(&"x".to_string()));
        assert!(free.contains(&"y".to_string()));
        assert!(free.contains(&"z".to_string()));
    }

    #[test]
    fn test_free_vars_literal() {
        let expr = IrExpr::Literal(Literal::Int(42));
        let free = expr.free_vars();
        assert!(free.is_empty());
    }

    #[test]
    fn test_ownership_types() {
        let owned = Ownership::Owned;
        let borrowed = Ownership::Borrowed;
        let shared = Ownership::Shared;

        assert_eq!(owned, Ownership::Owned);
        assert_ne!(owned, borrowed);
        assert_ne!(borrowed, shared);
    }

    #[test]
    fn test_usage_info() {
        let info = UsageInfo {
            name: "x".to_string(),
            use_count: 2,
            ownership: Ownership::Shared,
        };

        assert_eq!(info.name, "x");
        assert_eq!(info.use_count, 2);
        assert_eq!(info.ownership, Ownership::Shared);
    }

    #[test]
    fn test_typed_ir_get_type() {
        let expr = TypedIrExpr::Literal {
            value: Literal::Int(42),
            ty: Type::Int,
        };
        assert_eq!(expr.get_type(), &Type::Int);

        let expr = TypedIrExpr::Var {
            name: "x".to_string(),
            ty: Type::Bool,
        };
        assert_eq!(expr.get_type(), &Type::Bool);

        let expr = TypedIrExpr::Lambda {
            params: vec![("x".to_string(), Type::Int)],
            body: Box::new(TypedIrExpr::Var {
                name: "x".to_string(),
                ty: Type::Int,
            }),
            ty: Type::Function(Box::new(Type::Int), Box::new(Type::Int)),
        };
        assert_eq!(
            expr.get_type(),
            &Type::Function(Box::new(Type::Int), Box::new(Type::Int))
        );
    }

    #[test]
    fn test_typed_ir_let() {
        let expr = TypedIrExpr::Let {
            name: "x".to_string(),
            value: Box::new(TypedIrExpr::Literal {
                value: Literal::Int(42),
                ty: Type::Int,
            }),
            body: Box::new(TypedIrExpr::Var {
                name: "x".to_string(),
                ty: Type::Int,
            }),
            ty: Type::Int,
        };
        assert_eq!(expr.get_type(), &Type::Int);
    }

    #[test]
    fn test_typed_ir_if() {
        let expr = TypedIrExpr::If {
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
        assert_eq!(expr.get_type(), &Type::Int);
    }

    #[test]
    fn test_typed_ir_list() {
        let expr = TypedIrExpr::List {
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
        assert_eq!(expr.get_type(), &Type::List(Box::new(Type::Int)));
    }

    #[test]
    fn test_typed_ir_constructor() {
        let expr = TypedIrExpr::Constructor {
            name: "Some".to_string(),
            args: vec![TypedIrExpr::Literal {
                value: Literal::Int(42),
                ty: Type::Int,
            }],
            ty: Type::UserDefined {
                name: "Option".to_string(),
                type_params: vec![Type::Int],
            },
        };
        assert_eq!(
            expr.get_type(),
            &Type::UserDefined {
                name: "Option".to_string(),
                type_params: vec![Type::Int],
            }
        );
    }

    #[test]
    fn test_typed_ir_memory_ops() {
        let inner = TypedIrExpr::Literal {
            value: Literal::Int(42),
            ty: Type::Int,
        };

        let drop_expr = TypedIrExpr::Drop {
            name: "x".to_string(),
            value: Box::new(inner.clone()),
        };
        assert_eq!(drop_expr.get_type(), &Type::Int);

        let dup_expr = TypedIrExpr::Dup {
            name: "x".to_string(),
            value: Box::new(inner),
        };
        assert_eq!(dup_expr.get_type(), &Type::Int);
    }

    #[test]
    fn test_typed_pattern() {
        let wildcard = TypedPattern::Wildcard;
        assert_eq!(wildcard, TypedPattern::Wildcard);

        let var_pat = TypedPattern::Variable("x".to_string(), Type::Int);
        match &var_pat {
            TypedPattern::Variable(name, ty) => {
                assert_eq!(name, "x");
                assert_eq!(ty, &Type::Int);
            }
            _ => panic!("Expected Variable pattern"),
        }

        let lit_pat = TypedPattern::Literal(Literal::Bool(true));
        match &lit_pat {
            TypedPattern::Literal(lit) => {
                assert_eq!(lit, &Literal::Bool(true));
            }
            _ => panic!("Expected Literal pattern"),
        }
    }

    #[test]
    fn test_typed_pattern_constructor() {
        let pat = TypedPattern::Constructor {
            name: "Some".to_string(),
            patterns: vec![TypedPattern::Variable("x".to_string(), Type::Int)],
            ty: Type::UserDefined {
                name: "Option".to_string(),
                type_params: vec![Type::Int],
            },
        };

        match &pat {
            TypedPattern::Constructor { name, patterns, ty } => {
                assert_eq!(name, "Some");
                assert_eq!(patterns.len(), 1);
                assert_eq!(
                    ty,
                    &Type::UserDefined {
                        name: "Option".to_string(),
                        type_params: vec![Type::Int],
                    }
                );
            }
            _ => panic!("Expected Constructor pattern"),
        }
    }

    #[test]
    fn test_typed_pattern_list() {
        let pat = TypedPattern::List {
            patterns: vec![
                TypedPattern::Literal(Literal::Int(1)),
                TypedPattern::Variable("xs".to_string(), Type::List(Box::new(Type::Int))),
            ],
            elem_ty: Type::Int,
        };

        match &pat {
            TypedPattern::List { patterns, elem_ty } => {
                assert_eq!(patterns.len(), 2);
                assert_eq!(elem_ty, &Type::Int);
            }
            _ => panic!("Expected List pattern"),
        }
    }

    #[test]
    fn test_typed_ir_match() {
        let expr = TypedIrExpr::Match {
            expr: Box::new(TypedIrExpr::Var {
                name: "x".to_string(),
                ty: Type::UserDefined {
                    name: "Option".to_string(),
                    type_params: vec![Type::Int],
                },
            }),
            cases: vec![
                (
                    TypedPattern::Constructor {
                        name: "Some".to_string(),
                        patterns: vec![TypedPattern::Variable("v".to_string(), Type::Int)],
                        ty: Type::UserDefined {
                            name: "Option".to_string(),
                            type_params: vec![Type::Int],
                        },
                    },
                    TypedIrExpr::Var {
                        name: "v".to_string(),
                        ty: Type::Int,
                    },
                ),
                (
                    TypedPattern::Constructor {
                        name: "None".to_string(),
                        patterns: vec![],
                        ty: Type::UserDefined {
                            name: "Option".to_string(),
                            type_params: vec![Type::Int],
                        },
                    },
                    TypedIrExpr::Literal {
                        value: Literal::Int(0),
                        ty: Type::Int,
                    },
                ),
            ],
            ty: Type::Int,
        };

        assert_eq!(expr.get_type(), &Type::Int);
    }

    #[test]
    fn test_typed_ir_sequence() {
        let expr = TypedIrExpr::Sequence {
            exprs: vec![
                TypedIrExpr::Literal {
                    value: Literal::String("hello".to_string()),
                    ty: Type::String,
                },
                TypedIrExpr::Literal {
                    value: Literal::Int(42),
                    ty: Type::Int,
                },
            ],
            ty: Type::Int,
        };
        assert_eq!(expr.get_type(), &Type::Int);
    }

    #[test]
    fn test_typed_ir_reuse_check() {
        let expr = TypedIrExpr::ReuseCheck {
            var: "x".to_string(),
            reuse_expr: Box::new(TypedIrExpr::Literal {
                value: Literal::Int(1),
                ty: Type::Int,
            }),
            fallback_expr: Box::new(TypedIrExpr::Literal {
                value: Literal::Int(2),
                ty: Type::Int,
            }),
            ty: Type::Int,
        };
        assert_eq!(expr.get_type(), &Type::Int);
    }

    #[test]
    fn test_typed_ir_apply() {
        let expr = TypedIrExpr::Apply {
            func: Box::new(TypedIrExpr::Var {
                name: "add".to_string(),
                ty: Type::Function(
                    Box::new(Type::Int),
                    Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int))),
                ),
            }),
            args: vec![
                TypedIrExpr::Literal {
                    value: Literal::Int(1),
                    ty: Type::Int,
                },
                TypedIrExpr::Literal {
                    value: Literal::Int(2),
                    ty: Type::Int,
                },
            ],
            ty: Type::Int,
        };
        assert_eq!(expr.get_type(), &Type::Int);
    }

    #[test]
    fn test_typed_ir_cons() {
        let expr = TypedIrExpr::Cons {
            head: Box::new(TypedIrExpr::Literal {
                value: Literal::Int(1),
                ty: Type::Int,
            }),
            tail: Box::new(TypedIrExpr::List {
                elements: vec![],
                elem_ty: Type::Int,
                ty: Type::List(Box::new(Type::Int)),
            }),
            ty: Type::List(Box::new(Type::Int)),
        };
        assert_eq!(expr.get_type(), &Type::List(Box::new(Type::Int)));
    }

    #[test]
    fn test_typed_ir_let_rec() {
        let expr = TypedIrExpr::LetRec {
            name: "fact".to_string(),
            value: Box::new(TypedIrExpr::Lambda {
                params: vec![("n".to_string(), Type::Int)],
                body: Box::new(TypedIrExpr::Literal {
                    value: Literal::Int(1),
                    ty: Type::Int,
                }),
                ty: Type::Function(Box::new(Type::Int), Box::new(Type::Int)),
            }),
            body: Box::new(TypedIrExpr::Var {
                name: "fact".to_string(),
                ty: Type::Function(Box::new(Type::Int), Box::new(Type::Int)),
            }),
            ty: Type::Function(Box::new(Type::Int), Box::new(Type::Int)),
        };
        assert_eq!(
            expr.get_type(),
            &Type::Function(Box::new(Type::Int), Box::new(Type::Int))
        );
    }

    #[test]
    fn test_literal_types() {
        let int_lit = Literal::Int(42);
        let float_lit = Literal::Float(OrderedFloat(3.14159));
        let bool_lit = Literal::Bool(true);
        let string_lit = Literal::String("hello".to_string());

        // Test Debug trait
        assert!(format!("{int_lit:?}").contains("Int"));
        assert!(format!("{float_lit:?}").contains("Float"));
        assert!(format!("{bool_lit:?}").contains("Bool"));
        assert!(format!("{string_lit:?}").contains("String"));
    }
}
