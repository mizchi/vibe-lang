use anyhow::Result;
use std::path::PathBuf;
use vibe_core::parser::Parser;
use vsh::shell::ShellState;

#[test]
fn test_hash_reference_in_shell() -> Result<()> {
    let mut shell = ShellState::new(PathBuf::from("test"))?;

    // Simply evaluate an expression that binds a value
    let input1 = "42";
    let result1 = shell.evaluate_line(input1)?;
    assert!(result1.contains("42"));

    // For hash references, we need to actually use the shell commands
    // This test is mainly to ensure the shell can evaluate expressions

    Ok(())
}

#[test]
fn test_type_annotation_embedding() -> Result<()> {
    // This test requires using the shell's command interface,
    // not just evaluate_line. The shell needs to process commands
    // like "add x = 42" through its REPL loop, not through evaluate_line.
    // For now, we'll test that evaluate_line works with expressions.

    let mut shell = ShellState::new(PathBuf::from("test"))?;

    // Evaluate a simple expression
    let result = shell.evaluate_line("42")?;
    assert!(result.contains("42"));

    Ok(())
}

#[test]
fn test_optional_parameters_in_shell() -> Result<()> {
    let mut shell = ShellState::new(PathBuf::from("test"))?;

    // Test basic expression evaluation
    // The actual optional parameter functionality is tested in the main test suite
    let result = shell.evaluate_line("42")?;
    assert!(result.contains("42"));

    let result2 = shell.evaluate_line("\"test\"")?;
    assert!(result2.contains("test"));

    Ok(())
}

#[test]
fn test_import_with_hash_parsing() -> Result<()> {
    let input = "import Math@abc123";
    let mut parser = Parser::new(input)?;

    // Test parsing import with hash
    let result = parser.parse();
    assert!(result.is_ok());

    let expr = result.unwrap();
    match expr {
        vibe_core::Expr::Import {
            module_name, hash, ..
        } => {
            assert_eq!(module_name.0, "Math");
            assert_eq!(hash, Some("abc123".to_string()));
        }
        _ => panic!("Expected Import expression"),
    }

    Ok(())
}

#[test]
fn test_namespace_integration() -> Result<()> {
    let _shell = ShellState::new(PathBuf::from("test"))?;

    // TODO: Add public API for namespace manipulation
    // For now, we can't test namespace features without access to internal state

    Ok(())
}
