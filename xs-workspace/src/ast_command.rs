//! AST Command System
//! 
//! Provides structured commands for modifying XS code through AST transformations.
//! This enables AI and tools to make precise, type-safe code modifications.

use xs_core::{Expr, Ident, Type, Pattern};
use crate::namespace::{NamespacePath, DefinitionPath};

/// A command that transforms the AST
#[derive(Debug, Clone)]
pub enum AstCommand {
    /// Insert a new expression at a specific location
    Insert {
        target: AstPath,
        position: InsertPosition,
        expr: Expr,
    },
    
    /// Replace an expression at a specific location
    Replace {
        target: AstPath,
        new_expr: Expr,
    },
    
    /// Delete an expression at a specific location
    Delete {
        target: AstPath,
    },
    
    /// Rename an identifier throughout a scope
    Rename {
        scope: AstPath,
        old_name: String,
        new_name: String,
    },
    
    /// Extract an expression into a new definition
    Extract {
        target: AstPath,
        definition_name: String,
        namespace: NamespacePath,
    },
    
    /// Inline a definition at all usage sites
    Inline {
        definition: DefinitionPath,
    },
    
    /// Move an expression to a different location
    Move {
        source: AstPath,
        destination: AstPath,
        position: InsertPosition,
    },
    
    /// Wrap an expression with another expression
    Wrap {
        target: AstPath,
        wrapper: ExprWrapper,
    },
    
    /// Unwrap an expression (remove wrapping)
    Unwrap {
        target: AstPath,
    },
    
    /// Add a type annotation
    AddTypeAnnotation {
        target: AstPath,
        type_annotation: Type,
    },
    
    /// Remove a type annotation
    RemoveTypeAnnotation {
        target: AstPath,
    },
    
    /// Transform a pattern match
    TransformMatch {
        target: AstPath,
        transformation: MatchTransformation,
    },
    
    /// Refactor a sequence of lets into let-in
    RefactorToLetIn {
        target: AstPath,
        let_count: usize,
    },
    
    /// Convert between different function syntaxes
    ConvertFunction {
        target: AstPath,
        style: FunctionStyle,
    },
}

/// Path to a specific node in the AST
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct AstPath {
    /// Path segments from root to target
    segments: Vec<PathSegment>,
}

impl AstPath {
    pub fn root() -> Self {
        Self { segments: vec![] }
    }
    
    pub fn push(&mut self, segment: PathSegment) {
        self.segments.push(segment);
    }
    
    pub fn pop(&mut self) -> Option<PathSegment> {
        self.segments.pop()
    }
    
    pub fn child(mut self, segment: PathSegment) -> Self {
        self.push(segment);
        self
    }
}

/// A segment in an AST path
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum PathSegment {
    /// Named definition
    Definition(String),
    
    /// Function body
    FunctionBody,
    
    /// Lambda body
    LambdaBody,
    
    /// Let binding value
    LetValue,
    
    /// Let-in body
    LetInBody,
    
    /// If condition
    IfCondition,
    
    /// If then branch
    IfThen,
    
    /// If else branch
    IfElse,
    
    /// Apply function
    ApplyFunction,
    
    /// Apply argument at index
    ApplyArgument(usize),
    
    /// Match expression
    MatchExpr,
    
    /// Match case at index
    MatchCase(usize),
    
    /// Match case pattern
    MatchCasePattern,
    
    /// Match case body
    MatchCaseBody,
    
    /// List element at index
    ListElement(usize),
    
    /// Record field
    RecordField(String),
    
    /// Module body expression at index
    ModuleBodyExpr(usize),
}

/// Position for inserting expressions
#[derive(Debug, Clone)]
pub enum InsertPosition {
    Before,
    After,
    AtStart,
    AtEnd,
    AtIndex(usize),
}

/// Wrapper types for expressions
#[derive(Debug, Clone)]
pub enum ExprWrapper {
    /// Wrap in a let binding
    Let {
        name: String,
        type_ann: Option<Type>,
    },
    
    /// Wrap in a lambda
    Lambda {
        params: Vec<(String, Option<Type>)>,
    },
    
    /// Wrap in parentheses (for precedence)
    Parentheses,
    
    /// Wrap in a list
    List,
    
    /// Wrap in an if expression
    If {
        condition: Expr,
        else_branch: Expr,
    },
}

/// Transformations for match expressions
#[derive(Debug, Clone)]
pub enum MatchTransformation {
    /// Add a new case
    AddCase {
        pattern: Pattern,
        body: Expr,
        position: InsertPosition,
    },
    
    /// Remove a case
    RemoveCase {
        index: usize,
    },
    
    /// Reorder cases
    ReorderCases {
        new_order: Vec<usize>,
    },
    
    /// Merge similar cases
    MergeCases {
        indices: Vec<usize>,
    },
    
    /// Split a case with OR patterns
    SplitCase {
        index: usize,
    },
}

/// Function definition styles
#[derive(Debug, Clone)]
pub enum FunctionStyle {
    /// Regular function: (fn (x y) body)
    Regular,
    
    /// Curried function: (fn (x) (fn (y) body))
    Curried,
    
    /// Named recursive: (rec name (x y) body)
    Recursive { name: String },
}

/// Result of applying an AST command
#[derive(Debug)]
pub struct CommandResult {
    /// The transformed expression
    pub expr: Expr,
    
    /// Expressions that were extracted (for Extract command)
    pub extracted: Vec<(String, Expr)>,
    
    /// Locations that were affected
    pub affected_paths: Vec<AstPath>,
}

/// AST transformer that applies commands
pub struct AstTransformer;

impl AstTransformer {
    /// Apply a command to an expression
    pub fn apply_command(expr: &Expr, command: &AstCommand) -> Result<CommandResult, TransformError> {
        let mut transformer = AstTransformer;
        transformer.transform(expr, command)
    }
    
    fn transform(&mut self, expr: &Expr, command: &AstCommand) -> Result<CommandResult, TransformError> {
        match command {
            AstCommand::Replace { target, new_expr } => {
                self.replace_at_path(expr, target, new_expr)
            }
            
            AstCommand::Rename { scope, old_name, new_name } => {
                self.rename_in_scope(expr, scope, old_name, new_name)
            }
            
            AstCommand::Wrap { target, wrapper } => {
                self.wrap_at_path(expr, target, wrapper)
            }
            
            // TODO: Implement other commands
            _ => Err(TransformError::NotImplemented(format!("{:?}", command))),
        }
    }
    
    fn replace_at_path(&mut self, expr: &Expr, path: &AstPath, new_expr: &Expr) -> Result<CommandResult, TransformError> {
        if path.segments.is_empty() {
            // Replacing root expression
            Ok(CommandResult {
                expr: new_expr.clone(),
                extracted: vec![],
                affected_paths: vec![path.clone()],
            })
        } else {
            // Navigate to target and replace
            let transformed = self.transform_at_path(expr, path, |_| new_expr.clone())?;
            Ok(CommandResult {
                expr: transformed,
                extracted: vec![],
                affected_paths: vec![path.clone()],
            })
        }
    }
    
    fn rename_in_scope(&mut self, expr: &Expr, scope: &AstPath, old_name: &str, new_name: &str) -> Result<CommandResult, TransformError> {
        let scope_expr = self.navigate_to_path(expr, scope)?;
        let renamed = self.rename_ident_in_expr(scope_expr, old_name, new_name);
        
        if scope.segments.is_empty() {
            Ok(CommandResult {
                expr: renamed,
                extracted: vec![],
                affected_paths: vec![scope.clone()],
            })
        } else {
            let transformed = self.transform_at_path(expr, scope, |_| renamed)?;
            Ok(CommandResult {
                expr: transformed,
                extracted: vec![],
                affected_paths: vec![scope.clone()],
            })
        }
    }
    
    fn wrap_at_path(&mut self, expr: &Expr, path: &AstPath, wrapper: &ExprWrapper) -> Result<CommandResult, TransformError> {
        let target_expr = self.navigate_to_path(expr, path)?;
        let wrapped = self.wrap_expr(target_expr, wrapper);
        
        if path.segments.is_empty() {
            Ok(CommandResult {
                expr: wrapped,
                extracted: vec![],
                affected_paths: vec![path.clone()],
            })
        } else {
            let transformed = self.transform_at_path(expr, path, |_| wrapped)?;
            Ok(CommandResult {
                expr: transformed,
                extracted: vec![],
                affected_paths: vec![path.clone()],
            })
        }
    }
    
    fn navigate_to_path<'a>(&self, expr: &'a Expr, path: &AstPath) -> Result<&'a Expr, TransformError> {
        let mut current = expr;
        
        for segment in &path.segments {
            current = self.navigate_segment(current, segment)?;
        }
        
        Ok(current)
    }
    
    fn navigate_segment<'a>(&self, expr: &'a Expr, segment: &PathSegment) -> Result<&'a Expr, TransformError> {
        match (expr, segment) {
            (Expr::Lambda { body, .. }, PathSegment::LambdaBody) => Ok(body),
            (Expr::Let { value, .. }, PathSegment::LetValue) => Ok(value),
            (Expr::LetIn { body, .. }, PathSegment::LetInBody) => Ok(body),
            (Expr::If { cond, .. }, PathSegment::IfCondition) => Ok(cond),
            (Expr::If { then_expr, .. }, PathSegment::IfThen) => Ok(then_expr),
            (Expr::If { else_expr, .. }, PathSegment::IfElse) => Ok(else_expr),
            (Expr::Apply { func, .. }, PathSegment::ApplyFunction) => Ok(func),
            (Expr::Apply { args, .. }, PathSegment::ApplyArgument(i)) => {
                args.get(*i).ok_or_else(|| TransformError::InvalidPath("Argument index out of bounds".to_string()))
            }
            (Expr::List(items, _), PathSegment::ListElement(i)) => {
                items.get(*i).ok_or_else(|| TransformError::InvalidPath("List index out of bounds".to_string()))
            }
            _ => Err(TransformError::InvalidPath(format!("Cannot navigate {:?} in {:?}", segment, expr))),
        }
    }
    
    fn transform_at_path(&mut self, expr: &Expr, path: &AstPath, f: impl FnOnce(&Expr) -> Expr) -> Result<Expr, TransformError> {
        if path.segments.is_empty() {
            Ok(f(expr))
        } else {
            // Clone and modify the expression tree
            self.transform_recursive(expr, &path.segments, 0, f)
        }
    }
    
    fn transform_recursive(&mut self, expr: &Expr, segments: &[PathSegment], index: usize, f: impl FnOnce(&Expr) -> Expr) -> Result<Expr, TransformError> {
        if index >= segments.len() {
            Ok(f(expr))
        } else {
            let segment = &segments[index];
            match (expr, segment) {
                (Expr::Lambda { params, body, span }, PathSegment::LambdaBody) => {
                    let new_body = Box::new(self.transform_recursive(body, segments, index + 1, f)?);
                    Ok(Expr::Lambda {
                        params: params.clone(),
                        body: new_body,
                        span: span.clone(),
                    })
                }
                (Expr::Let { name, type_ann, value, span }, PathSegment::LetValue) => {
                    let new_value = Box::new(self.transform_recursive(value, segments, index + 1, f)?);
                    Ok(Expr::Let {
                        name: name.clone(),
                        type_ann: type_ann.clone(),
                        value: new_value,
                        span: span.clone(),
                    })
                }
                // TODO: Handle other cases
                _ => Err(TransformError::InvalidPath(format!("Cannot transform {:?} in {:?}", segment, expr))),
            }
        }
    }
    
    fn rename_ident_in_expr(&self, expr: &Expr, old_name: &str, new_name: &str) -> Expr {
        match expr {
            Expr::Ident(ident, span) if ident.0 == old_name => {
                Expr::Ident(Ident(new_name.to_string()), span.clone())
            }
            Expr::Lambda { params, body, span } => {
                // Don't rename if it's shadowed by a parameter
                let shadowed = params.iter().any(|(p, _)| p.0 == old_name);
                if shadowed {
                    expr.clone()
                } else {
                    Expr::Lambda {
                        params: params.clone(),
                        body: Box::new(self.rename_ident_in_expr(body, old_name, new_name)),
                        span: span.clone(),
                    }
                }
            }
            Expr::Apply { func, args, span } => {
                Expr::Apply {
                    func: Box::new(self.rename_ident_in_expr(func, old_name, new_name)),
                    args: args.iter().map(|arg| self.rename_ident_in_expr(arg, old_name, new_name)).collect(),
                    span: span.clone(),
                }
            }
            // TODO: Handle other cases
            _ => expr.clone(),
        }
    }
    
    fn wrap_expr(&self, expr: &Expr, wrapper: &ExprWrapper) -> Expr {
        let span = expr.span().clone();
        match wrapper {
            ExprWrapper::Let { name, type_ann } => {
                Expr::Let {
                    name: Ident(name.clone()),
                    type_ann: type_ann.clone(),
                    value: Box::new(expr.clone()),
                    span,
                }
            }
            ExprWrapper::Lambda { params } => {
                Expr::Lambda {
                    params: params.iter().map(|(n, t)| (Ident(n.clone()), t.clone())).collect(),
                    body: Box::new(expr.clone()),
                    span,
                }
            }
            ExprWrapper::List => {
                Expr::List(vec![expr.clone()], span)
            }
            // TODO: Handle other wrappers
            _ => expr.clone(),
        }
    }
}

/// Errors that can occur during AST transformation
#[derive(Debug, thiserror::Error)]
pub enum TransformError {
    #[error("Invalid path: {0}")]
    InvalidPath(String),
    
    #[error("Target not found")]
    TargetNotFound,
    
    #[error("Invalid transformation: {0}")]
    InvalidTransformation(String),
    
    #[error("Not implemented: {0}")]
    NotImplemented(String),
}

#[cfg(test)]
mod tests {
    use super::*;
    use xs_core::{Literal, Span};
    
    #[test]
    fn test_replace_root() {
        let expr = Expr::Literal(Literal::Int(42), Span::new(0, 2));
        let new_expr = Expr::Literal(Literal::Int(100), Span::new(0, 3));
        
        let command = AstCommand::Replace {
            target: AstPath::root(),
            new_expr: new_expr.clone(),
        };
        
        let result = AstTransformer::apply_command(&expr, &command).unwrap();
        assert_eq!(result.expr, new_expr);
    }
    
    #[test]
    fn test_rename_ident() {
        let expr = Expr::Apply {
            func: Box::new(Expr::Ident(Ident("add".to_string()), Span::new(0, 3))),
            args: vec![
                Expr::Ident(Ident("x".to_string()), Span::new(4, 5)),
                Expr::Ident(Ident("y".to_string()), Span::new(6, 7)),
            ],
            span: Span::new(0, 8),
        };
        
        let command = AstCommand::Rename {
            scope: AstPath::root(),
            old_name: "x".to_string(),
            new_name: "z".to_string(),
        };
        
        let result = AstTransformer::apply_command(&expr, &command).unwrap();
        
        // Check that x was renamed to z
        if let Expr::Apply { args, .. } = &result.expr {
            if let Expr::Ident(ident, _) = &args[0] {
                assert_eq!(ident.0, "z");
            } else {
                panic!("Expected identifier");
            }
        } else {
            panic!("Expected apply expression");
        }
    }
    
    #[test]
    fn test_wrap_in_let() {
        let expr = Expr::Literal(Literal::Int(42), Span::new(0, 2));
        
        let command = AstCommand::Wrap {
            target: AstPath::root(),
            wrapper: ExprWrapper::Let {
                name: "x".to_string(),
                type_ann: Some(Type::Int),
            },
        };
        
        let result = AstTransformer::apply_command(&expr, &command).unwrap();
        
        // Check that expression was wrapped in let
        if let Expr::Let { name, value, type_ann, .. } = &result.expr {
            assert_eq!(name.0, "x");
            assert_eq!(type_ann, &Some(Type::Int));
            assert_eq!(**value, expr);
        } else {
            panic!("Expected let expression");
        }
    }
}