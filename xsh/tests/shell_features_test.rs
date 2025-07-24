use xsh::shell::{ShellState, ExpressionId};
use xs_core::parser::Parser;
use xs_core::Span;
use anyhow::Result;

#[test]
fn test_hash_reference_in_shell() -> Result<()> {
    let mut shell = ShellState::new();
    
    // First, define a value
    let input1 = "(let x 42)";
    let result1 = shell.evaluate_line(input1)?;
    assert!(result1.contains("42"));
    
    // Get the hash of the expression
    let hash = shell.expr_history.last()
        .map(|h| &h.hash)
        .ok_or_else(|| anyhow::anyhow!("No expression history"))?;
    
    // Reference it by hash (first 8 chars)
    let hash_ref = format!("#{}", &hash[..8]);
    let result2 = shell.evaluate_line(&hash_ref)?;
    assert!(result2.contains("42"));
    
    Ok(())
}

#[test]
fn test_type_annotation_embedding() -> Result<()> {
    let mut shell = ShellState::new();
    
    // Define a value without type annotation
    let input = "(let x 42)";
    let result = shell.evaluate_line(input)?;
    assert!(result.contains("42"));
    
    // View the definition - it should now have a type annotation
    let view_result = shell.view_definition("x")?;
    assert!(view_result.contains(": Int"));
    
    Ok(())
}

#[test]
fn test_optional_parameters_in_shell() -> Result<()> {
    let mut shell = ShellState::new();
    
    // Define a function with optional parameters using S-expression syntax
    let input = r#"
    (let process (fn key flag 
      (match flag 
        [None key]
        [(Some s) (+ key (strLength s))])))
    "#;
    
    shell.evaluate_line(input)?;
    
    // Call with None
    let result1 = shell.evaluate_line("(process 42 None)")?;
    assert!(result1.contains("42"));
    
    // Call with Some
    let result2 = shell.evaluate_line("(process 42 (Some \"test\"))")?;
    assert!(result2.contains("46")); // 42 + 4
    
    Ok(())
}

#[test]
fn test_import_with_hash_parsing() -> Result<()> {
    let parser = Parser::new();
    
    // Test parsing import with hash
    let input = "import Math@abc123";
    let result = parser.parse(input);
    assert!(result.is_ok());
    
    let expr = result.unwrap();
    match expr {
        xs_core::Expr::Import { module_name, hash, .. } => {
            assert_eq!(module_name.0, "Math");
            assert_eq!(hash, Some("abc123".to_string()));
        }
        _ => panic!("Expected Import expression"),
    }
    
    Ok(())
}

#[test]
fn test_namespace_integration() -> Result<()> {
    let mut shell = ShellState::new();
    
    // Change namespace
    shell.current_namespace = "Math.Utils".to_string();
    
    // Define a function in the namespace
    let input = "(let fibonacci (rec fib n (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))";
    shell.evaluate_line(input)?;
    
    // Access with full path
    shell.current_namespace = "main".to_string();
    let result = shell.evaluate_line("(Math.Utils.fibonacci 10)")?;
    assert!(result.contains("55"));
    
    Ok(())
}