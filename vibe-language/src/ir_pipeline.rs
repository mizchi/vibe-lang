//! IR transformation pipeline for Vibe Language
//! 
//! This module defines the transformation pipeline from surface syntax
//! to optimized IR, ensuring semantic equivalence at each stage.

use crate::normalized_ast::{NormalizedExpr, NormalizedDef};
use crate::ir::{TypedIrExpr};
use crate::{Type, Effect};
use std::collections::HashMap;

/// The IR pipeline that transforms code through multiple stages
pub struct IRPipeline {
    /// Type environment for type inference
    type_env: HashMap<String, Type>,
    /// Effect environment
    effect_env: HashMap<String, Vec<Effect>>,
}

impl IRPipeline {
    pub fn new() -> Self {
        Self {
            type_env: HashMap::new(),
            effect_env: HashMap::new(),
        }
    }
    
    /// Transform normalized AST to typed IR
    pub fn normalize_to_typed(&mut self, expr: &NormalizedExpr) -> Result<TypedIrExpr, String> {
        match expr {
            NormalizedExpr::Literal(lit) => {
                let ty = infer_literal_type(lit);
                Ok(TypedIrExpr::Literal {
                    value: lit.clone(),
                    ty,
                })
            }
            
            NormalizedExpr::Var(name) => {
                let ty = self.type_env.get(name)
                    .cloned()
                    .ok_or_else(|| format!("Undefined variable: {}", name))?;
                Ok(TypedIrExpr::Var {
                    name: name.clone(),
                    ty,
                })
            }
            
            NormalizedExpr::Lambda { param, body } => {
                // For now, assume parameter type (would be inferred in real implementation)
                let param_ty = Type::TypeVar("a".to_string());
                self.type_env.insert(param.clone(), param_ty.clone());
                
                let body_ir = self.normalize_to_typed(body)?;
                let body_ty = body_ir.get_type().clone();
                
                Ok(TypedIrExpr::Lambda {
                    params: vec![(param.clone(), param_ty.clone())],
                    body: Box::new(body_ir),
                    ty: Type::Function(Box::new(param_ty), Box::new(body_ty)),
                })
            }
            
            NormalizedExpr::Apply { func, arg } => {
                let func_ir = self.normalize_to_typed(func)?;
                let arg_ir = self.normalize_to_typed(arg)?;
                
                // Extract return type from function type
                let ret_ty = match func_ir.get_type() {
                    Type::Function(_, ret) => (**ret).clone(),
                    _ => return Err("Applied non-function".to_string()),
                };
                
                Ok(TypedIrExpr::Apply {
                    func: Box::new(func_ir),
                    args: vec![arg_ir],
                    ty: ret_ty,
                })
            }
            
            NormalizedExpr::Let { name, value, body } => {
                let value_ir = self.normalize_to_typed(value)?;
                let value_ty = value_ir.get_type().clone();
                
                self.type_env.insert(name.clone(), value_ty);
                let body_ir = self.normalize_to_typed(body)?;
                let body_ty = body_ir.get_type().clone();
                
                Ok(TypedIrExpr::Let {
                    name: name.clone(),
                    value: Box::new(value_ir),
                    body: Box::new(body_ir),
                    ty: body_ty,
                })
            }
            
            NormalizedExpr::List(elements) => {
                if elements.is_empty() {
                    // Empty list, polymorphic type
                    Ok(TypedIrExpr::List {
                        elements: vec![],
                        elem_ty: Type::TypeVar("a".to_string()),
                        ty: Type::List(Box::new(Type::TypeVar("a".to_string()))),
                    })
                } else {
                    let typed_elements: Result<Vec<_>, _> = elements.iter()
                        .map(|e| self.normalize_to_typed(e))
                        .collect();
                    let typed_elements = typed_elements?;
                    
                    // Get element type from first element
                    let elem_ty = typed_elements[0].get_type().clone();
                    
                    Ok(TypedIrExpr::List {
                        elements: typed_elements,
                        elem_ty: elem_ty.clone(),
                        ty: Type::List(Box::new(elem_ty)),
                    })
                }
            }
            
            // TODO: Implement other cases
            _ => Err("Not implemented yet".to_string()),
        }
    }
}

/// Infer the type of a literal
fn infer_literal_type(lit: &crate::Literal) -> Type {
    match lit {
        crate::Literal::Int(_) => Type::Int,
        crate::Literal::Float(_) => Type::Float,
        crate::Literal::Bool(_) => Type::Bool,
        crate::Literal::String(_) => Type::String,
    }
}

/// Semantic equivalence checker for normalized expressions
pub fn semantically_equivalent(expr1: &NormalizedExpr, expr2: &NormalizedExpr) -> bool {
    match (expr1, expr2) {
        (NormalizedExpr::Literal(l1), NormalizedExpr::Literal(l2)) => l1 == l2,
        
        (NormalizedExpr::Var(v1), NormalizedExpr::Var(v2)) => v1 == v2,
        
        (NormalizedExpr::Lambda { param: p1, body: b1 }, 
         NormalizedExpr::Lambda { param: p2, body: b2 }) => {
            // Alpha equivalence: parameters can have different names
            if p1 == p2 {
                semantically_equivalent(b1, b2)
            } else {
                // Would need alpha conversion here
                false // Simplified for now
            }
        }
        
        (NormalizedExpr::Apply { func: f1, arg: a1 },
         NormalizedExpr::Apply { func: f2, arg: a2 }) => {
            semantically_equivalent(f1, f2) && semantically_equivalent(a1, a2)
        }
        
        (NormalizedExpr::List(l1), NormalizedExpr::List(l2)) => {
            l1.len() == l2.len() && 
            l1.iter().zip(l2.iter()).all(|(e1, e2)| semantically_equivalent(e1, e2))
        }
        
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Literal;
    
    #[test]
    fn test_literal_normalization() {
        let mut pipeline = IRPipeline::new();
        let expr = NormalizedExpr::Literal(Literal::Int(42));
        
        let typed = pipeline.normalize_to_typed(&expr).unwrap();
        match typed {
            TypedIrExpr::Literal { value: Literal::Int(42), ty: Type::Int } => {},
            _ => panic!("Expected Int literal"),
        }
    }
    
    #[test]
    fn test_semantic_equivalence() {
        // Same literals are equivalent
        let expr1 = NormalizedExpr::Literal(Literal::Int(42));
        let expr2 = NormalizedExpr::Literal(Literal::Int(42));
        assert!(semantically_equivalent(&expr1, &expr2));
        
        // Different literals are not equivalent
        let expr3 = NormalizedExpr::Literal(Literal::Int(43));
        assert!(!semantically_equivalent(&expr1, &expr3));
        
        // Same function applications are equivalent
        let app1 = NormalizedExpr::Apply {
            func: Box::new(NormalizedExpr::Var("f".to_string())),
            arg: Box::new(NormalizedExpr::Var("x".to_string())),
        };
        let app2 = NormalizedExpr::Apply {
            func: Box::new(NormalizedExpr::Var("f".to_string())),
            arg: Box::new(NormalizedExpr::Var("x".to_string())),
        };
        assert!(semantically_equivalent(&app1, &app2));
    }
    
    #[test]
    fn test_different_syntax_same_semantics() {
        // These would be generated from different surface syntax but normalized to same form
        // e.g., "f $ g x" and "f (g x)" both normalize to Apply(f, Apply(g, x))
        let expr1 = NormalizedExpr::Apply {
            func: Box::new(NormalizedExpr::Var("f".to_string())),
            arg: Box::new(NormalizedExpr::Apply {
                func: Box::new(NormalizedExpr::Var("g".to_string())),
                arg: Box::new(NormalizedExpr::Var("x".to_string())),
            }),
        };
        
        let expr2 = NormalizedExpr::Apply {
            func: Box::new(NormalizedExpr::Var("f".to_string())),
            arg: Box::new(NormalizedExpr::Apply {
                func: Box::new(NormalizedExpr::Var("g".to_string())),
                arg: Box::new(NormalizedExpr::Var("x".to_string())),
            }),
        };
        
        assert!(semantically_equivalent(&expr1, &expr2));
    }
}