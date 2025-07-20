//! Tests for module system type checking

use checker::type_check;
use parser::parse;

#[test]
fn test_simple_module() {
    let source = r#"
        (module Math
            (export add)
            (let add (fn (x y) (+ x y))))
    "#;
    
    let expr = parse(source).unwrap();
    let result = type_check(&expr);
    
    // Should type check successfully
    assert!(result.is_ok());
}

#[test]
fn test_module_export_validation() {
    // Test exporting undefined identifier
    let source = r#"
        (module Math
            (export add sub)
            (let add (fn (x y) (+ x y))))
    "#;
    
    let expr = parse(source).unwrap();
    let result = type_check(&expr);
    
    // Should fail because 'sub' is not defined
    assert!(result.is_err());
    let err = result.unwrap_err();
    assert!(err.to_string().contains("Cannot export undefined identifier: sub"));
}

#[test]
fn test_module_import() {
    // First create a Math module
    let math_module_source = r#"
        (module Math
            (export add PI)
            (let add (fn (x y) (+ x y)))
            (let PI 3.14159))
    "#;
    
    let math_expr = parse(math_module_source).unwrap();
    
    // Type check the module (this would need proper integration)
    let _ = type_check(&math_expr).unwrap();
    
    // Now test importing from it - for now we test the structure
    let import_expr = parse("(import (Math add))").unwrap();
    assert!(matches!(import_expr, xs_core::Expr::Import { .. }));
}

#[test]
fn test_qualified_identifier() {
    let source = "(Math.add 5 10)";
    let expr = parse(source).unwrap();
    
    // The parser creates nested Apply expressions for (Math.add 5 10)
    match expr {
        xs_core::Expr::Apply { func: outer_func, args: outer_args, .. } => {
            // (Math.add 5) 10
            assert_eq!(outer_args.len(), 1); // Just 10
            
            match outer_func.as_ref() {
                xs_core::Expr::Apply { func: inner_func, args: inner_args, .. } => {
                    // Math.add 5
                    assert_eq!(inner_args.len(), 1); // Just 5
                    
                    match inner_func.as_ref() {
                        xs_core::Expr::QualifiedIdent { module_name, name, .. } => {
                            assert_eq!(module_name.0, "Math");
                            assert_eq!(name.0, "add");
                        }
                        _ => panic!("Expected QualifiedIdent"),
                    }
                }
                _ => panic!("Expected nested Apply"),
            }
        }
        _ => panic!("Expected Apply"),
    }
}

#[test]
fn test_module_with_types() {
    let source = r#"
        (module DataStructures
            (export Stack push pop)
            (type Stack 
                (Empty)
                (Node value rest))
            (let push (fn (stack value) 
                (Node value stack)))
            (let pop (fn (stack)
                (match stack
                    ((Empty) (Empty))
                    ((Node value rest) rest)))))
    "#;
    
    let expr = parse(source).unwrap();
    let result = type_check(&expr);
    
    // Should type check successfully
    match result {
        Ok(_) => {},
        Err(e) => panic!("Type check failed: {}", e),
    }
}

#[test]
fn test_import_with_alias() {
    let source = "(import Math as M)";
    let expr = parse(source).unwrap();
    
    match expr {
        xs_core::Expr::Import { module_name, items, as_name, .. } => {
            assert_eq!(module_name.0, "Math");
            assert!(items.is_none());
            assert_eq!(as_name.as_ref().unwrap().0, "M");
        }
        _ => panic!("Expected Import"),
    }
}

#[test]
fn test_module_creates_scope() {
    // For now, just test the module part
    let module_source = r#"
        (module Test
            (export public_fn)
            (let private_var 42)
            (let public_fn (fn () private_var)))
    "#;
    
    let expr = parse(module_source).unwrap();
    let result = type_check(&expr);
    assert!(result.is_ok());
}