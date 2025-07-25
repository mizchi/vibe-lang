use crate::Value;
use std::fmt;

impl fmt::Display for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Value::Int(n) => write!(f, "{n}"),
            Value::Float(v) => write!(f, "{v}"),
            Value::Bool(b) => write!(f, "{b}"),
            Value::String(s) => write!(f, "{s:?}"),
            Value::List(elems) => {
                write!(f, "(list")?;
                for elem in elems {
                    write!(f, " {elem}")?;
                }
                write!(f, ")")
            }
            Value::Closure { params, .. } => {
                write!(f, "<closure:{}>", params.len())
            }
            Value::RecClosure { name, params, .. } => {
                write!(f, "<rec-closure:{}:{}>", name.0, params.len())
            }
            Value::Constructor { name, values } => {
                write!(f, "({}", name.0)?;
                for value in values {
                    write!(f, " {value}")?;
                }
                write!(f, ")")
            }
            Value::BuiltinFunction {
                name,
                arity,
                applied_args,
            } => {
                if applied_args.is_empty() {
                    write!(f, "<builtin:{name}:{arity}>")
                } else {
                    write!(f, "<builtin:{name}:{arity}/{}>", applied_args.len())
                }
            }
            Value::UseStatement { path, items } => {
                write!(f, "<use {}", path.join("/"))?;
                if let Some(items) = items {
                    write!(f, " (")?;
                    for (i, item) in items.iter().enumerate() {
                        if i > 0 {
                            write!(f, ", ")?;
                        }
                        write!(f, "{}", item.0)?;
                    }
                    write!(f, ")")?;
                }
                write!(f, ">")
            }
            Value::Record { fields } => {
                write!(f, "{{")?;
                for (i, (name, value)) in fields.iter().enumerate() {
                    if i > 0 {
                        write!(f, ", ")?;
                    }
                    write!(f, "{}: {}", name, value)?;
                }
                write!(f, "}}")
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Environment, Expr, Ident};

    #[test]
    fn test_value_display_int() {
        let val = Value::Int(42);
        assert_eq!(format!("{val}"), "42");

        let val = Value::Int(-17);
        assert_eq!(format!("{val}"), "-17");
    }

    #[test]
    fn test_value_display_float() {
        let val = Value::Float(3.14159);
        assert_eq!(format!("{val}"), "3.14159");

        let val = Value::Float(-2.5);
        assert_eq!(format!("{val}"), "-2.5");
    }

    #[test]
    fn test_value_display_bool() {
        let val = Value::Bool(true);
        assert_eq!(format!("{val}"), "true");

        let val = Value::Bool(false);
        assert_eq!(format!("{val}"), "false");
    }

    #[test]
    fn test_value_display_string() {
        let val = Value::String("hello".to_string());
        assert_eq!(format!("{val}"), "\"hello\"");

        let val = Value::String("with \"quotes\"".to_string());
        assert_eq!(format!("{val}"), "\"with \\\"quotes\\\"\"");

        let val = Value::String("".to_string());
        assert_eq!(format!("{val}"), "\"\"");
    }

    #[test]
    fn test_value_display_list_empty() {
        let val = Value::List(vec![]);
        assert_eq!(format!("{val}"), "(list)");
    }

    #[test]
    fn test_value_display_list_single() {
        let val = Value::List(vec![Value::Int(1)]);
        assert_eq!(format!("{val}"), "(list 1)");
    }

    #[test]
    fn test_value_display_list_multiple() {
        let val = Value::List(vec![Value::Int(1), Value::Int(2), Value::Int(3)]);
        assert_eq!(format!("{val}"), "(list 1 2 3)");
    }

    #[test]
    fn test_value_display_list_mixed() {
        let val = Value::List(vec![
            Value::Int(1),
            Value::Bool(true),
            Value::String("test".to_string()),
        ]);
        assert_eq!(format!("{val}"), "(list 1 true \"test\")");
    }

    #[test]
    fn test_value_display_list_nested() {
        let inner = Value::List(vec![Value::Int(2), Value::Int(3)]);
        let val = Value::List(vec![Value::Int(1), inner]);
        assert_eq!(format!("{val}"), "(list 1 (list 2 3))");
    }

    #[test]
    fn test_value_display_closure() {
        let val = Value::Closure {
            params: vec![Ident("x".to_string())],
            body: Expr::default(),
            env: Environment::new(),
        };
        assert_eq!(format!("{val}"), "<closure:1>");

        let val = Value::Closure {
            params: vec![Ident("x".to_string()), Ident("y".to_string())],
            body: Expr::default(),
            env: Environment::new(),
        };
        assert_eq!(format!("{val}"), "<closure:2>");

        let val = Value::Closure {
            params: vec![],
            body: Expr::default(),
            env: Environment::new(),
        };
        assert_eq!(format!("{val}"), "<closure:0>");
    }

    #[test]
    fn test_value_display_rec_closure() {
        let val = Value::RecClosure {
            name: Ident("factorial".to_string()),
            params: vec![Ident("n".to_string())],
            body: Expr::default(),
            env: Environment::new(),
        };
        assert_eq!(format!("{val}"), "<rec-closure:factorial:1>");

        let val = Value::RecClosure {
            name: Ident("fib".to_string()),
            params: vec![Ident("a".to_string()), Ident("b".to_string())],
            body: Expr::default(),
            env: Environment::new(),
        };
        assert_eq!(format!("{val}"), "<rec-closure:fib:2>");
    }

    #[test]
    fn test_value_display_constructor_empty() {
        let val = Value::Constructor {
            name: Ident("None".to_string()),
            values: vec![],
        };
        assert_eq!(format!("{val}"), "(None)");
    }

    #[test]
    fn test_value_display_constructor_with_values() {
        let val = Value::Constructor {
            name: Ident("Some".to_string()),
            values: vec![Value::Int(42)],
        };
        assert_eq!(format!("{val}"), "(Some 42)");

        let val = Value::Constructor {
            name: Ident("Point".to_string()),
            values: vec![Value::Int(10), Value::Int(20)],
        };
        assert_eq!(format!("{val}"), "(Point 10 20)");
    }

    #[test]
    fn test_value_display_constructor_nested() {
        let inner = Value::Constructor {
            name: Ident("Some".to_string()),
            values: vec![Value::Int(5)],
        };
        let val = Value::Constructor {
            name: Ident("Box".to_string()),
            values: vec![inner],
        };
        assert_eq!(format!("{val}"), "(Box (Some 5))");
    }

    #[test]
    fn test_value_equality() {
        // Test integer equality
        assert_eq!(Value::Int(42), Value::Int(42));
        assert_ne!(Value::Int(42), Value::Int(43));

        // Test float equality
        assert_eq!(Value::Float(3.14159), Value::Float(3.14159));
        assert_ne!(Value::Float(3.14159), Value::Float(2.71828));

        // Test bool equality
        assert_eq!(Value::Bool(true), Value::Bool(true));
        assert_ne!(Value::Bool(true), Value::Bool(false));

        // Test string equality
        assert_eq!(
            Value::String("hello".to_string()),
            Value::String("hello".to_string())
        );
        assert_ne!(
            Value::String("hello".to_string()),
            Value::String("world".to_string())
        );

        // Test list equality
        assert_eq!(
            Value::List(vec![Value::Int(1), Value::Int(2)]),
            Value::List(vec![Value::Int(1), Value::Int(2)])
        );
        assert_ne!(
            Value::List(vec![Value::Int(1), Value::Int(2)]),
            Value::List(vec![Value::Int(2), Value::Int(1)])
        );

        // Test constructor equality
        assert_eq!(
            Value::Constructor {
                name: Ident("Some".to_string()),
                values: vec![Value::Int(5)],
            },
            Value::Constructor {
                name: Ident("Some".to_string()),
                values: vec![Value::Int(5)],
            }
        );
        assert_ne!(
            Value::Constructor {
                name: Ident("Some".to_string()),
                values: vec![Value::Int(5)],
            },
            Value::Constructor {
                name: Ident("None".to_string()),
                values: vec![],
            }
        );
    }

    #[test]
    fn test_value_clone() {
        // Test that values can be cloned
        let val = Value::Int(42);
        let cloned = val.clone();
        assert_eq!(val, cloned);

        let val = Value::List(vec![Value::Int(1), Value::Int(2)]);
        let cloned = val.clone();
        assert_eq!(val, cloned);

        let val = Value::Constructor {
            name: Ident("Some".to_string()),
            values: vec![Value::Int(42)],
        };
        let cloned = val.clone();
        assert_eq!(val, cloned);
    }
}
