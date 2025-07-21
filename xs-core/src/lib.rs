use ordered_float::OrderedFloat;
use serde::{Deserialize, Serialize};
use std::fmt;
use thiserror::Error;

pub mod builtin_effects;
pub mod builtin_modules;
pub mod builtins;
pub mod curry;
pub mod effects;
pub mod error_context;
pub mod ir;
pub mod metadata;
pub mod parser;
pub mod pretty_print;
mod types;
mod value;

// Re-export builtins for convenience
pub use builtins::{BuiltinFunction, BuiltinRegistry};
// Re-export effects
pub use builtin_effects::BuiltinEffects;
pub use effects::{Effect, EffectRow, EffectSet, EffectVar};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Span {
    pub start: usize,
    pub end: usize,
}

impl Span {
    pub fn new(start: usize, end: usize) -> Self {
        Span { start, end }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Literal {
    Int(i64),
    Float(OrderedFloat<f64>),
    Bool(bool),
    String(String),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Ident(pub String);

impl fmt::Display for Ident {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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
    LetIn {
        name: Ident,
        type_ann: Option<Type>,
        value: Box<Expr>,
        body: Box<Expr>,
        span: Span,
    },
    Rec {
        name: Ident,
        params: Vec<(Ident, Option<Type>)>,
        return_type: Option<Type>,
        body: Box<Expr>,
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
    Match {
        expr: Box<Expr>,
        cases: Vec<(Pattern, Expr)>,
        span: Span,
    },
    Constructor {
        name: Ident,
        args: Vec<Expr>,
        span: Span,
    },
    TypeDef {
        definition: TypeDefinition,
        span: Span,
    },
    Module {
        name: Ident,
        exports: Vec<Ident>,
        body: Vec<Expr>,
        span: Span,
    },
    Import {
        module_name: Ident,
        items: Option<Vec<Ident>>, // None means import all with prefix
        as_name: Option<Ident>,    // For "import Foo as F"
        span: Span,
    },
    QualifiedIdent {
        module_name: Ident,
        name: Ident,
        span: Span,
    },
    Handler {
        cases: Vec<(Ident, Vec<Pattern>, Ident, Expr)>, // (effect_name, patterns, continuation, body)
        body: Box<Expr>,
        span: Span,
    },
    WithHandler {
        handler: Box<Expr>,
        body: Box<Expr>,
        span: Span,
    },
    Perform {
        effect: Ident,
        args: Vec<Expr>,
        span: Span,
    },
    Pipeline {
        expr: Box<Expr>,
        func: Box<Expr>,
        span: Span,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Pattern {
    Wildcard(Span),
    Literal(Literal, Span),
    Variable(Ident, Span),
    Constructor {
        name: Ident,
        patterns: Vec<Pattern>,
        span: Span,
    },
    List {
        patterns: Vec<Pattern>,
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
            Expr::LetIn { span, .. } => span,
            Expr::Rec { span, .. } => span,
            Expr::Lambda { span, .. } => span,
            Expr::If { span, .. } => span,
            Expr::Apply { span, .. } => span,
            Expr::Match { span, .. } => span,
            Expr::Constructor { span, .. } => span,
            Expr::TypeDef { span, .. } => span,
            Expr::Module { span, .. } => span,
            Expr::Import { span, .. } => span,
            Expr::QualifiedIdent { span, .. } => span,
            Expr::Handler { span, .. } => span,
            Expr::WithHandler { span, .. } => span,
            Expr::Perform { span, .. } => span,
            Expr::Pipeline { span, .. } => span,
        }
    }
}

impl Default for Expr {
    fn default() -> Self {
        Expr::List(vec![], Span::new(0, 0))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Type {
    Int,
    Float,
    Bool,
    String,
    List(Box<Type>),
    Function(Box<Type>, Box<Type>),
    FunctionWithEffect {
        from: Box<Type>,
        to: Box<Type>,
        effects: EffectRow,
    },
    Var(String),
    UserDefined {
        name: String,
        type_params: Vec<Type>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TypeDefinition {
    pub name: String,
    pub type_params: Vec<String>,
    pub constructors: Vec<Constructor>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Constructor {
    pub name: String,
    pub fields: Vec<Type>,
}

impl fmt::Display for Type {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Type::Int => write!(f, "Int"),
            Type::Float => write!(f, "Float"),
            Type::Bool => write!(f, "Bool"),
            Type::String => write!(f, "String"),
            Type::List(t) => write!(f, "(List {t})"),
            Type::Function(from, to) => write!(f, "(-> {from} {to})"),
            Type::FunctionWithEffect { from, to, effects } => {
                if effects.is_pure() {
                    write!(f, "(-> {from} {to})")
                } else {
                    write!(f, "(-> {from} {to} ! {effects})")
                }
            }
            Type::Var(name) => write!(f, "{name}"),
            Type::UserDefined { name, type_params } => {
                if type_params.is_empty() {
                    write!(f, "{name}")
                } else {
                    write!(f, "({name}")?;
                    for param in type_params {
                        write!(f, " {param}")?;
                    }
                    write!(f, ")")
                }
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Int(i64),
    Float(f64),
    Bool(bool),
    String(String),
    List(Vec<Value>),
    Closure {
        params: Vec<Ident>,
        body: Expr,
        env: Environment,
    },
    RecClosure {
        name: Ident,
        params: Vec<Ident>,
        body: Expr,
        env: Environment,
    },
    Constructor {
        name: Ident,
        values: Vec<Value>,
    },
    BuiltinFunction {
        name: String,
        arity: usize,
        applied_args: Vec<Value>,
    },
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Environment {
    bindings: Vec<(Ident, Value)>,
}

impl Environment {
    pub fn new() -> Self {
        Self::default()
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

    pub fn contains(&self, name: &Ident) -> bool {
        self.bindings.iter().any(|(n, _)| n == name)
    }

    pub fn len(&self) -> usize {
        self.bindings.len()
    }

    pub fn is_empty(&self) -> bool {
        self.bindings.is_empty()
    }

    pub fn debug_bindings(&self) -> Vec<String> {
        self.bindings
            .iter()
            .map(|(name, _)| name.0.clone())
            .collect()
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

    #[error("Type mismatch: expected {}, found {}", expected, found)]
    TypeMismatch {
        expected: Box<Type>,
        found: Box<Type>,
    },
}

impl XsError {
    /// Convert to rich error context for AI-friendly error reporting
    pub fn to_error_context(&self, source: Option<&str>) -> error_context::ErrorContext {
        use error_context::{ErrorBuilder, ErrorCategory};

        match self {
            XsError::ParseError(pos, msg) => {
                let mut builder = ErrorBuilder::new(ErrorCategory::Syntax, msg.clone());
                if let Some(src) = source {
                    builder = builder.with_snippet(src, Span::new(*pos, *pos + 1));
                }
                builder.build()
            }
            XsError::TypeError(span, msg) => {
                let mut builder = ErrorBuilder::new(ErrorCategory::Type, msg.clone());
                if let Some(src) = source {
                    builder = builder.with_snippet(src, span.clone());
                }
                builder.build()
            }
            XsError::RuntimeError(span, msg) => {
                let mut builder = ErrorBuilder::new(ErrorCategory::Runtime, msg.clone());
                if let Some(src) = source {
                    builder = builder.with_snippet(src, span.clone());
                }
                builder.build()
            }
            XsError::UndefinedVariable(ident) => ErrorBuilder::undefined_variable(&ident.0).build(),
            XsError::TypeMismatch { expected, found } => {
                ErrorBuilder::type_mismatch((**expected).clone(), (**found).clone()).build()
            }
        }
    }
}

// Module structure for XS language
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Module {
    pub name: String,
    pub imports: Vec<(String, Option<String>)>, // (module_name, alias)
    pub exports: Vec<Ident>,
    pub definitions: Vec<Expr>,
    pub type_definitions: Vec<TypeDefinition>,
}
