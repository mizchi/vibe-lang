//! Integration tests for Koka-style effect system

use vibe_language::parser::parse;
use vibe_language::ast_normalizer::AstNormalizer;
use vibe_language::koka_effects::{EffectType, EffectRow};
use vibe_language::effect_normalizer::EffectNormalizer;

#[test]
fn test_simple_perform_normalization() {
    let source = r#"
        perform IO.print "Hello, World!"
    "#;
    
    let expr = parse(source).expect("Failed to parse");
    let mut normalizer = AstNormalizer::new();
    let normalized = normalizer.normalize_expr(&expr);
    
    // Verify it's normalized to a Perform expression
    match normalized {
        vibe_language::normalized_ast::NormalizedExpr::Perform { effect, operation, args } => {
            assert_eq!(effect, "IO");
            assert_eq!(operation, "perform");
            assert_eq!(args.len(), 1);
        }
        _ => panic!("Expected Perform expression"),
    }
}

#[test]
fn test_with_handler_normalization() {
    let source = r#"
        with stateHandler {
            perform State.get
        }
    "#;
    
    let expr = parse(source).expect("Failed to parse");
    let mut normalizer = AstNormalizer::new();
    let normalized = normalizer.normalize_expr(&expr);
    
    // Verify it's normalized to a Handle expression
    match normalized {
        vibe_language::normalized_ast::NormalizedExpr::Handle { expr, handlers } => {
            // The body should contain a perform expression
            match expr.as_ref() {
                vibe_language::normalized_ast::NormalizedExpr::Perform { effect, operation, .. } => {
                    assert_eq!(effect, "State");
                    assert_eq!(operation, "perform");
                }
                _ => panic!("Expected Perform expression in handle body"),
            }
        }
        _ => panic!("Expected Handle expression"),
    }
}

#[test]
fn test_do_notation_normalization() {
    let source = r#"
        do {
            x <- foo;
            y <- bar;
            x + y
        }
    "#;
    
    let expr = parse(source).expect("Failed to parse");
    let mut normalizer = AstNormalizer::new();
    let normalized = normalizer.normalize_expr(&expr);
    
    // Do notation should be desugared to nested let bindings
    match normalized {
        vibe_language::normalized_ast::NormalizedExpr::Let { name, value, body } => {
            // First binding: x <- foo
            assert!(name.starts_with("do_bind"));
            
            // Should have nested structure for the rest
            match body.as_ref() {
                vibe_language::normalized_ast::NormalizedExpr::Let { .. } => {
                    // Good, we have nested let bindings
                }
                _ => panic!("Expected nested Let expression"),
            }
        }
        _ => panic!("Expected Let expression from do notation"),
    }
}

#[test]
fn test_effect_inference() {
    let source = r#"
        perform IO.print "Hello"
    "#;
    
    let expr = parse(source).expect("Failed to parse");
    let mut normalizer = AstNormalizer::new();
    let normalized = normalizer.normalize_expr(&expr);
    
    // Infer effects
    let effect_normalizer = EffectNormalizer::new();
    let effects = effect_normalizer.infer_effects(&normalized);
    
    // Should infer IO effect
    assert!(effects.contains("IO"));
}

#[test]
fn test_handle_with_multiple_cases() {
    let source = r#"
        handle {
            perform State.get
        } {
            State.get () k -> k 42
        }
    "#;
    
    let expr = parse(source).expect("Failed to parse");
    let mut normalizer = AstNormalizer::new();
    let normalized = normalizer.normalize_expr(&expr);
    
    match normalized {
        vibe_language::normalized_ast::NormalizedExpr::Handle { handlers, .. } => {
            assert_eq!(handlers.len(), 1);
            assert_eq!(handlers[0].effect, "State");
            assert_eq!(handlers[0].operation, "get");
        }
        _ => panic!("Expected Handle expression"),
    }
}

#[test]
fn test_effect_row_operations() {
    // Test effect row creation and operations
    let io_effect = EffectType::Named("IO".to_string());
    let state_effect = EffectType::Named("State".to_string());
    
    let row1 = EffectRow::single(io_effect.clone());
    let row2 = EffectRow::single(state_effect.clone());
    
    // Test union
    let combined = row1.union(&row2);
    assert_eq!(combined.effects.len(), 2);
    assert!(combined.effects.contains(&io_effect));
    assert!(combined.effects.contains(&state_effect));
    
    // Test polymorphic rows
    let poly_row = EffectRow::polymorphic("e".to_string());
    assert!(poly_row.row_var.is_some());
}

#[test]
fn test_nested_handlers() {
    let source = r#"
        handle {
            handle {
                perform IO.print "inner"
            } {
                IO.print msg k -> k ()
            }
        } {
            State.get () k -> k 0
        }
    "#;
    
    let expr = parse(source).expect("Failed to parse");
    let mut normalizer = AstNormalizer::new();
    let normalized = normalizer.normalize_expr(&expr);
    
    // Should have nested Handle expressions
    match normalized {
        vibe_language::normalized_ast::NormalizedExpr::Handle { expr, handlers } => {
            // Outer handler for State
            assert!(handlers.iter().any(|h| h.effect == "State"));
            
            // Inner expression should also be a Handle
            match expr.as_ref() {
                vibe_language::normalized_ast::NormalizedExpr::Handle { handlers: inner_handlers, .. } => {
                    // Inner handler for IO
                    assert!(inner_handlers.iter().any(|h| h.effect == "IO"));
                }
                _ => panic!("Expected nested Handle expression"),
            }
        }
        _ => panic!("Expected Handle expression"),
    }
}