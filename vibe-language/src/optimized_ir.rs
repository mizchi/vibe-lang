//! Optimized IR - Low-level IR with optimizations applied
//! 
//! This module defines the optimized intermediate representation
//! that includes memory management (Perceus), inlining, and other
//! optimizations while maintaining semantic correctness.

use crate::Type;
use crate::content_hash::ContentHash;
use crate::ir::{Ownership};
use serde::{Serialize, Deserialize};

/// Optimized IR expression with explicit memory management
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum OptimizedIR {
    /// Literal value
    Literal {
        value: Literal,
        ty: Type,
    },
    
    /// Variable reference
    Var {
        name: String,
        ty: Type,
        ownership: Ownership,
    },
    
    /// Let binding with ownership transfer
    Let {
        name: String,
        value: Box<OptimizedIR>,
        body: Box<OptimizedIR>,
        ty: Type,
        /// Whether the binding transfers ownership
        moves: bool,
    },
    
    /// Function application
    Apply {
        func: Box<OptimizedIR>,
        args: Vec<OptimizedIR>,
        ty: Type,
        /// Tail call optimization hint
        is_tail_call: bool,
    },
    
    /// Lambda with captured variables
    Lambda {
        params: Vec<(String, Type, Ownership)>,
        body: Box<OptimizedIR>,
        ty: Type,
        /// Variables captured from outer scope
        captures: Vec<CaptureInfo>,
    },
    
    /// Pattern matching (optimized to jump table when possible)
    Match {
        expr: Box<OptimizedIR>,
        cases: Vec<(Pattern, OptimizedIR)>,
        ty: Type,
        /// Hint for jump table optimization
        is_exhaustive: bool,
    },
    
    /// Primitive operation (for builtins)
    PrimOp {
        op: PrimitiveOp,
        args: Vec<OptimizedIR>,
        ty: Type,
    },
    
    /// Memory management operations
    Drop {
        var: String,
        continuation: Box<OptimizedIR>,
    },
    
    Dup {
        var: String,
        continuation: Box<OptimizedIR>,
    },
    
    /// Reuse check for in-place updates
    ReuseCheck {
        var: String,
        reuse_branch: Box<OptimizedIR>,
        fresh_branch: Box<OptimizedIR>,
        ty: Type,
    },
    
    /// Effect operation (after monomorphization)
    EffectOp {
        effect: String,
        operation: String,
        args: Vec<OptimizedIR>,
        continuation: ContinuationRef,
        ty: Type,
    },
    
    /// Resume continuation
    Resume {
        continuation: ContinuationRef,
        value: Box<OptimizedIR>,
        ty: Type,
    },
}

/// Simplified literal for optimized IR
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum Literal {
    Int(i64),
    Float(f64),
    Bool(bool),
    String(String),
    Unit,
}

/// Pattern for optimized matching
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum Pattern {
    Wildcard,
    Literal(Literal),
    Constructor(String, Vec<Pattern>),
    /// Optimized: integer range for switch
    IntRange(i64, i64),
}

/// Information about captured variables
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CaptureInfo {
    pub name: String,
    pub ty: Type,
    pub ownership: Ownership,
    /// Whether this capture can be optimized away
    pub can_inline: bool,
}

/// Primitive operations for optimization
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum PrimitiveOp {
    // Arithmetic
    Add, Sub, Mul, Div, Mod,
    // Comparison
    Eq, Ne, Lt, Le, Gt, Ge,
    // Boolean
    And, Or, Not,
    // List operations
    Cons, Head, Tail, IsEmpty,
    // Memory
    Alloc, Free,
    // String
    Concat, Length,
    // I/O (side effects tracked separately)
    Print, Read,
}

/// Reference to a continuation
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ContinuationRef {
    /// Unique identifier for the continuation
    pub id: String,
    /// Type of the value the continuation expects
    pub arg_type: Type,
}

/// Optimization pass result
pub struct OptimizationResult {
    pub ir: OptimizedIR,
    pub stats: OptimizationStats,
}

/// Statistics about optimizations performed
#[derive(Debug, Default)]
pub struct OptimizationStats {
    pub inlined_functions: usize,
    pub eliminated_allocations: usize,
    pub reused_allocations: usize,
    pub tail_calls_optimized: usize,
    pub constants_folded: usize,
    pub dead_code_eliminated: usize,
}

/// Optimizer that transforms TypedIR to OptimizedIR
pub struct Optimizer {
    /// Inline threshold (max size of function to inline)
    inline_threshold: usize,
    /// Enable Perceus reference counting
    enable_perceus: bool,
    /// Enable tail call optimization
    enable_tco: bool,
}

impl Optimizer {
    pub fn new() -> Self {
        Self {
            inline_threshold: 20,
            enable_perceus: true,
            enable_tco: true,
        }
    }
    
    /// Optimize a typed IR expression
    pub fn optimize(&self, typed_ir: &crate::ir::TypedIrExpr) -> OptimizationResult {
        let mut stats = OptimizationStats::default();
        
        // Phase 1: Convert to OptimizedIR
        let mut ir = self.convert_to_optimized(typed_ir);
        
        // Phase 2: Inline small functions
        if self.inline_threshold > 0 {
            ir = self.inline_functions(ir, &mut stats);
        }
        
        // Phase 3: Insert reference counting
        if self.enable_perceus {
            ir = self.insert_ref_counting(ir, &mut stats);
        }
        
        // Phase 4: Optimize tail calls
        if self.enable_tco {
            ir = self.optimize_tail_calls(ir, &mut stats);
        }
        
        // Phase 5: Constant folding
        ir = self.fold_constants(ir, &mut stats);
        
        // Phase 6: Dead code elimination
        ir = self.eliminate_dead_code(ir, &mut stats);
        
        OptimizationResult { ir, stats }
    }
    
    /// Convert TypedIR to OptimizedIR (simplified)
    fn convert_to_optimized(&self, typed_ir: &crate::ir::TypedIrExpr) -> OptimizedIR {
        use crate::ir::TypedIrExpr;
        
        match typed_ir {
            TypedIrExpr::Literal { value, ty } => {
                OptimizedIR::Literal {
                    value: convert_literal(value),
                    ty: ty.clone(),
                }
            }
            
            TypedIrExpr::Var { name, ty } => {
                OptimizedIR::Var {
                    name: name.clone(),
                    ty: ty.clone(),
                    ownership: Ownership::Borrowed, // Conservative default
                }
            }
            
            TypedIrExpr::Apply { func, args, ty } => {
                OptimizedIR::Apply {
                    func: Box::new(self.convert_to_optimized(func)),
                    args: args.iter().map(|a| self.convert_to_optimized(a)).collect(),
                    ty: ty.clone(),
                    is_tail_call: false, // Will be determined in TCO phase
                }
            }
            
            // ... other cases ...
            _ => todo!("Complete conversion implementation"),
        }
    }
    
    /// Inline small functions
    fn inline_functions(&self, ir: OptimizedIR, stats: &mut OptimizationStats) -> OptimizedIR {
        // Simplified: would traverse and inline based on size heuristics
        ir
    }
    
    /// Insert reference counting operations
    fn insert_ref_counting(&self, ir: OptimizedIR, stats: &mut OptimizationStats) -> OptimizedIR {
        // Simplified: would analyze usage and insert Drop/Dup operations
        ir
    }
    
    /// Optimize tail calls
    fn optimize_tail_calls(&self, ir: OptimizedIR, stats: &mut OptimizationStats) -> OptimizedIR {
        // Simplified: would identify and mark tail calls
        ir
    }
    
    /// Fold constant expressions
    fn fold_constants(&self, ir: OptimizedIR, stats: &mut OptimizationStats) -> OptimizedIR {
        match ir {
            OptimizedIR::PrimOp { op: PrimitiveOp::Add, args, ty } => {
                if let [OptimizedIR::Literal { value: Literal::Int(a), .. },
                        OptimizedIR::Literal { value: Literal::Int(b), .. }] = &args[..] {
                    stats.constants_folded += 1;
                    OptimizedIR::Literal {
                        value: Literal::Int(a + b),
                        ty,
                    }
                } else {
                    OptimizedIR::PrimOp { op: PrimitiveOp::Add, args, ty }
                }
            }
            // ... other cases ...
            _ => ir,
        }
    }
    
    /// Eliminate dead code
    fn eliminate_dead_code(&self, ir: OptimizedIR, stats: &mut OptimizationStats) -> OptimizedIR {
        // Simplified: would remove unreachable code
        ir
    }
}

/// Convert from crate::Literal to optimized Literal
fn convert_literal(lit: &crate::Literal) -> Literal {
    match lit {
        crate::Literal::Int(n) => Literal::Int(*n),
        crate::Literal::Float(f) => Literal::Float(f.into_inner()),
        crate::Literal::Bool(b) => Literal::Bool(*b),
        crate::Literal::String(s) => Literal::String(s.clone()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_constant_folding() {
        let optimizer = Optimizer::new();
        let mut stats = OptimizationStats::default();
        
        // Create an addition of two constants
        let ir = OptimizedIR::PrimOp {
            op: PrimitiveOp::Add,
            args: vec![
                OptimizedIR::Literal {
                    value: Literal::Int(2),
                    ty: Type::Int,
                },
                OptimizedIR::Literal {
                    value: Literal::Int(3),
                    ty: Type::Int,
                },
            ],
            ty: Type::Int,
        };
        
        let optimized = optimizer.fold_constants(ir, &mut stats);
        
        match optimized {
            OptimizedIR::Literal { value: Literal::Int(5), .. } => {
                assert_eq!(stats.constants_folded, 1);
            }
            _ => panic!("Expected constant folding to produce Literal(5)"),
        }
    }
}