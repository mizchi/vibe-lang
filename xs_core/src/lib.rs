use std::fmt;
use thiserror::Error;

mod types;
mod value;
pub mod ir;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Span {
    pub start: usize,
    pub end: usize,
}

impl Span {
    pub fn new(start: usize, end: usize) -> Self {
        Span { start, end }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Literal {
    Int(i64),
    Bool(bool),
    String(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ident(pub String);

impl fmt::Display for Ident {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Expr {
    Literal(Literal, Span),
    Ident(Ident, Span),
    List(Vec<Expr>, Span),
    Let {
        name: Ident,
        type_ann: Option<Type>,
        value: Box<Expr>,
        span: Span,
    },
    LetRec {
        name: Ident,
        type_ann: Option<Type>,
        value: Box<Expr>,
        span: Span,
    },
    Lambda {
        params: Vec<(Ident, Option<Type>)>,
        body: Box<Expr>,
        span: Span,
    },
    If {
        cond: Box<Expr>,
        then_expr: Box<Expr>,
        else_expr: Box<Expr>,
        span: Span,
    },
    Apply {
        func: Box<Expr>,
        args: Vec<Expr>,
        span: Span,
    },
}

impl Expr {
    pub fn span(&self) -> &Span {
        match self {
            Expr::Literal(_, span) => span,
            Expr::Ident(_, span) => span,
            Expr::List(_, span) => span,
            Expr::Let { span, .. } => span,
            Expr::LetRec { span, .. } => span,
            Expr::Lambda { span, .. } => span,
            Expr::If { span, .. } => span,
            Expr::Apply { span, .. } => span,
        }
    }
}

impl Default for Expr {
    fn default() -> Self {
        Expr::List(vec![], Span::new(0, 0))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Type {
    Int,
    Bool,
    String,
    List(Box<Type>),
    Function(Box<Type>, Box<Type>),
    Var(String),
}

impl fmt::Display for Type {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Type::Int => write!(f, "Int"),
            Type::Bool => write!(f, "Bool"),
            Type::String => write!(f, "String"),
            Type::List(t) => write!(f, "(List {})", t),
            Type::Function(from, to) => write!(f, "(-> {} {})", from, to),
            Type::Var(name) => write!(f, "{}", name),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Value {
    Int(i64),
    Bool(bool),
    String(String),
    List(Vec<Value>),
    Closure {
        params: Vec<Ident>,
        body: Expr,
        env: Environment,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Environment {
    bindings: Vec<(Ident, Value)>,
}

impl Environment {
    pub fn new() -> Self {
        Environment {
            bindings: Vec::new(),
        }
    }

    pub fn extend(&self, name: Ident, value: Value) -> Self {
        let mut new_env = self.clone();
        new_env.bindings.push((name, value));
        new_env
    }

    pub fn lookup(&self, name: &Ident) -> Option<&Value> {
        self.bindings
            .iter()
            .rev()
            .find(|(n, _)| n == name)
            .map(|(_, v)| v)
    }
}

#[derive(Error, Debug, Clone, PartialEq, Eq)]
pub enum XsError {
    #[error("Parse error at position {0}: {1}")]
    ParseError(usize, String),
    
    #[error("Type error at {0:?}: {1}")]
    TypeError(Span, String),
    
    #[error("Runtime error at {0:?}: {1}")]
    RuntimeError(Span, String),
    
    #[error("Undefined variable '{0}'")]
    UndefinedVariable(Ident),
    
    #[error("Type mismatch: expected {expected}, found {found}")]
    TypeMismatch { expected: Type, found: Type },
}
