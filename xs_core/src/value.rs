use std::fmt;
use crate::Value;

impl fmt::Display for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Value::Int(n) => write!(f, "{}", n),
            Value::Float(v) => write!(f, "{}", v),
            Value::Bool(b) => write!(f, "{}", b),
            Value::String(s) => write!(f, "{:?}", s),
            Value::List(elems) => {
                write!(f, "(list")?;
                for elem in elems {
                    write!(f, " {}", elem)?;
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
                    write!(f, " {}", value)?;
                }
                write!(f, ")")
            }
        }
    }
}