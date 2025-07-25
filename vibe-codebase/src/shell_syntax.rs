//! Shell Syntax to S-Expression Conversion
//!
//! Converts shell-style syntax (including pipelines) to XS S-expressions,
//! allowing unified AST handling for both traditional XS code and shell commands.

use vibe_language::{Expr, Ident, Literal, Span};

/// Shell expression that can be converted to S-expression
#[derive(Debug, Clone)]
pub enum ShellExpr {
    /// Simple command: `ls`, `definitions`
    Command(String, Vec<String>),

    /// Pipeline: `cmd1 | cmd2 | cmd3`
    Pipeline(Vec<ShellExpr>),

    /// Function call: `search type:Int`
    FunctionCall(String, Vec<ShellArg>),

    /// Variable reference: `$var`
    Variable(String),

    /// Literal value
    Literal(ShellLiteral),
}

/// Shell argument
#[derive(Debug, Clone)]
pub enum ShellArg {
    /// Positional argument
    Positional(String),

    /// Named argument: `key:value`
    Named(String, String),

    /// Flag: `--flag`
    Flag(String),
}

/// Shell literal
#[derive(Debug, Clone)]
pub enum ShellLiteral {
    String(String),
    Int(i64),
    Bool(bool),
}

/// Parse shell syntax into ShellExpr
pub fn parse_shell_syntax(input: &str) -> Result<ShellExpr, String> {
    let input = input.trim();

    // Check for pipeline
    if input.contains('|') {
        let parts: Vec<&str> = input.split('|').map(|s| s.trim()).collect();
        if parts.len() > 1 {
            let mut pipeline = Vec::new();
            for part in parts {
                pipeline.push(parse_single_command(part)?);
            }
            return Ok(ShellExpr::Pipeline(pipeline));
        }
    }

    // Single command
    parse_single_command(input)
}

/// Parse a single command
fn parse_single_command(input: &str) -> Result<ShellExpr, String> {
    let parts: Vec<&str> = input.split_whitespace().collect();
    if parts.is_empty() {
        return Err("Empty command".to_string());
    }

    let cmd = parts[0];
    let args = &parts[1..];

    // Check for special commands that need custom parsing
    match cmd {
        "search" => parse_search_command(args),
        "filter" => parse_filter_command(args),
        "select" => parse_select_command(args),
        "sort" => parse_sort_command(args),
        "take" => parse_take_command(args),
        "group" => parse_group_command(args),
        _ => {
            // For function calls with arguments, use FunctionCall variant
            if !args.is_empty() {
                let mut parsed_args = Vec::new();
                for arg in args {
                    // Try to parse as number
                    if let Ok(n) = arg.parse::<i64>() {
                        parsed_args.push(ShellArg::Positional(n.to_string()));
                    } else if let Ok(f) = arg.parse::<f64>() {
                        parsed_args.push(ShellArg::Positional(f.to_string()));
                    } else if *arg == "true" || *arg == "false" {
                        parsed_args.push(ShellArg::Positional(arg.to_string()));
                    } else {
                        // Check if it's a named argument (key:value)
                        if arg.contains(':') && !arg.starts_with(':') {
                            let parts: Vec<&str> = arg.splitn(2, ':').collect();
                            if parts.len() == 2 {
                                parsed_args.push(ShellArg::Named(
                                    parts[0].to_string(),
                                    parts[1].to_string(),
                                ));
                            } else {
                                parsed_args.push(ShellArg::Positional(arg.to_string()));
                            }
                        } else {
                            parsed_args.push(ShellArg::Positional(arg.to_string()));
                        }
                    }
                }
                Ok(ShellExpr::FunctionCall(cmd.to_string(), parsed_args))
            } else {
                // Just a command/identifier
                Ok(ShellExpr::Command(cmd.to_string(), vec![]))
            }
        }
    }
}

/// Parse search command: `search type:Int`
fn parse_search_command(args: &[&str]) -> Result<ShellExpr, String> {
    if args.is_empty() {
        return Err("search requires a query".to_string());
    }

    let mut parsed_args = Vec::new();
    for arg in args {
        if arg.contains(':') {
            let parts: Vec<&str> = arg.splitn(2, ':').collect();
            if parts.len() == 2 {
                parsed_args.push(ShellArg::Named(parts[0].to_string(), parts[1].to_string()));
            } else {
                parsed_args.push(ShellArg::Positional(arg.to_string()));
            }
        } else {
            parsed_args.push(ShellArg::Positional(arg.to_string()));
        }
    }

    Ok(ShellExpr::FunctionCall("search".to_string(), parsed_args))
}

/// Parse filter command: `filter field value` or `filter field = value`
fn parse_filter_command(args: &[&str]) -> Result<ShellExpr, String> {
    if args.len() < 2 {
        return Err("filter requires field and value".to_string());
    }

    let field = args[0].to_string();

    // Handle different filter operators
    if args.len() >= 3 && (args[1] == "=" || args[1] == "==" || args[1] == "contains") {
        let op = args[1];
        let value = args[2..].join(" ");
        Ok(ShellExpr::FunctionCall(
            "filter".to_string(),
            vec![
                ShellArg::Positional(field),
                ShellArg::Named("op".to_string(), op.to_string()),
                ShellArg::Positional(value),
            ],
        ))
    } else {
        // Default to equality
        let value = args[1..].join(" ");
        Ok(ShellExpr::FunctionCall(
            "filter".to_string(),
            vec![ShellArg::Positional(field), ShellArg::Positional(value)],
        ))
    }
}

/// Parse select command: `select field1 field2 ...`
fn parse_select_command(args: &[&str]) -> Result<ShellExpr, String> {
    if args.is_empty() {
        return Err("select requires at least one field".to_string());
    }

    let fields: Vec<ShellArg> = args
        .iter()
        .map(|&s| ShellArg::Positional(s.to_string()))
        .collect();

    Ok(ShellExpr::FunctionCall("select".to_string(), fields))
}

/// Parse sort command: `sort field [desc]`
fn parse_sort_command(args: &[&str]) -> Result<ShellExpr, String> {
    if args.is_empty() {
        return Err("sort requires a field".to_string());
    }

    let mut parsed_args = vec![ShellArg::Positional(args[0].to_string())];

    if args.len() > 1 && (args[1] == "desc" || args[1] == "reverse") {
        parsed_args.push(ShellArg::Flag("desc".to_string()));
    }

    Ok(ShellExpr::FunctionCall("sort".to_string(), parsed_args))
}

/// Parse take command: `take n`
fn parse_take_command(args: &[&str]) -> Result<ShellExpr, String> {
    if args.is_empty() {
        return Err("take requires a count".to_string());
    }

    Ok(ShellExpr::FunctionCall(
        "take".to_string(),
        vec![ShellArg::Positional(args[0].to_string())],
    ))
}

/// Parse group command: `group by field`
fn parse_group_command(args: &[&str]) -> Result<ShellExpr, String> {
    if args.len() < 2 || args[0] != "by" {
        return Err("group requires 'by' and a field".to_string());
    }

    Ok(ShellExpr::FunctionCall(
        "groupBy".to_string(),
        vec![ShellArg::Positional(args[1].to_string())],
    ))
}

/// Convert ShellExpr to XS AST (S-expression)
pub fn shell_to_sexpr(shell_expr: &ShellExpr) -> Expr {
    match shell_expr {
        ShellExpr::Command(cmd, args) => {
            // Convert to function call: (cmd arg1 arg2 ...)
            let mut expr_args = vec![Expr::Ident(Ident(cmd.clone()), Span::new(0, 0))];

            for arg in args {
                expr_args.push(Expr::Literal(Literal::String(arg.clone()), Span::new(0, 0)));
            }

            if expr_args.len() == 1 {
                // Just the command itself
                expr_args[0].clone()
            } else {
                // Function application
                let func = expr_args[0].clone();
                let args = expr_args[1..].to_vec();
                Expr::Apply {
                    func: Box::new(func),
                    args,
                    span: Span::new(0, 0),
                }
            }
        }

        ShellExpr::Pipeline(commands) => {
            // Convert to nested pipe calls: (pipe cmd1 (pipe cmd2 cmd3))
            if commands.is_empty() {
                return Expr::List(vec![], Span::new(0, 0));
            }

            let mut result = shell_to_sexpr(&commands[0]);

            for cmd in &commands[1..] {
                result = Expr::Apply {
                    func: Box::new(Expr::Ident(Ident("pipe".to_string()), Span::new(0, 0))),
                    args: vec![result, shell_to_sexpr(cmd)],
                    span: Span::new(0, 0),
                };
            }

            result
        }

        ShellExpr::FunctionCall(name, args) => {
            // Convert to function call with proper argument handling
            let mut expr_args = Vec::new();

            // Handle positional arguments first
            for arg in args {
                match arg {
                    ShellArg::Positional(val) => {
                        // Try to parse as number or boolean
                        if let Ok(n) = val.parse::<i64>() {
                            expr_args.push(Expr::Literal(Literal::Int(n), Span::new(0, 0)));
                        } else if let Ok(f) = val.parse::<f64>() {
                            expr_args
                                .push(Expr::Literal(Literal::Float(f.into()), Span::new(0, 0)));
                        } else if val == "true" {
                            expr_args.push(Expr::Literal(Literal::Bool(true), Span::new(0, 0)));
                        } else if val == "false" {
                            expr_args.push(Expr::Literal(Literal::Bool(false), Span::new(0, 0)));
                        } else {
                            // Check if it's an identifier (starts with lowercase letter)
                            if val.chars().next().map_or(false, |c| c.is_lowercase()) {
                                expr_args.push(Expr::Ident(Ident(val.clone()), Span::new(0, 0)));
                            } else {
                                expr_args.push(Expr::Literal(
                                    Literal::String(val.clone()),
                                    Span::new(0, 0),
                                ));
                            }
                        }
                    }
                    ShellArg::Named(key, val) => {
                        // Convert named arguments to a simple string representation
                        expr_args.push(Expr::Literal(
                            Literal::String(format!("{key}:{val}")),
                            Span::new(0, 0),
                        ));
                    }
                    ShellArg::Flag(flag) => {
                        // Convert to symbol
                        expr_args.push(Expr::Ident(Ident(format!(":{flag}")), Span::new(0, 0)));
                    }
                }
            }

            if expr_args.is_empty() {
                Expr::Ident(Ident(name.clone()), Span::new(0, 0))
            } else {
                Expr::Apply {
                    func: Box::new(Expr::Ident(Ident(name.clone()), Span::new(0, 0))),
                    args: expr_args,
                    span: Span::new(0, 0),
                }
            }
        }

        ShellExpr::Variable(name) => {
            // Variable reference
            Expr::Ident(Ident(name.clone()), Span::new(0, 0))
        }

        ShellExpr::Literal(lit) => {
            // Convert literal
            match lit {
                ShellLiteral::String(s) => {
                    Expr::Literal(Literal::String(s.clone()), Span::new(0, 0))
                }
                ShellLiteral::Int(n) => Expr::Literal(Literal::Int(*n), Span::new(0, 0)),
                ShellLiteral::Bool(b) => Expr::Literal(Literal::Bool(*b), Span::new(0, 0)),
            }
        }
    }
}

/// Convert XS AST back to shell syntax (for display)
pub fn sexpr_to_shell_syntax(expr: &Expr) -> Option<String> {
    match expr {
        Expr::Ident(Ident(name), _) => Some(name.clone()),

        Expr::Apply { func, args, .. } => {
            if let Expr::Ident(Ident(name), _) = &**func {
                if name == "pipe" && args.len() == 2 {
                    // Handle pipeline
                    let left = sexpr_to_shell_syntax(&args[0])?;
                    let right = sexpr_to_shell_syntax(&args[1])?;
                    Some(format!("{left} | {right}"))
                } else {
                    // Regular function call
                    let mut parts = vec![name.clone()];
                    for arg in args {
                        if let Some(s) = expr_to_shell_arg(arg) {
                            parts.push(s);
                        }
                    }
                    Some(parts.join(" "))
                }
            } else {
                None
            }
        }

        Expr::Literal(lit, _) => match lit {
            Literal::String(s) => Some(s.clone()),
            Literal::Int(n) => Some(n.to_string()),
            Literal::Bool(b) => Some(b.to_string()),
            _ => None,
        },

        _ => None,
    }
}

/// Convert expression to shell argument
fn expr_to_shell_arg(expr: &Expr) -> Option<String> {
    match expr {
        Expr::Literal(Literal::String(s), _) => Some(s.clone()),
        Expr::Literal(Literal::Int(n), _) => Some(n.to_string()),
        Expr::Literal(Literal::Bool(b), _) => Some(b.to_string()),
        Expr::Ident(Ident(name), _) if name.starts_with(':') => Some(format!("--{}", &name[1..])),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_simple_command() {
        let shell = parse_shell_syntax("ls").unwrap();
        match shell {
            ShellExpr::Command(cmd, args) => {
                assert_eq!(cmd, "ls");
                assert!(args.is_empty());
            }
            _ => panic!("Expected Command"),
        }
    }

    #[test]
    fn test_parse_pipeline() {
        let shell = parse_shell_syntax("ls | filter kind function | sort name").unwrap();
        match shell {
            ShellExpr::Pipeline(cmds) => {
                assert_eq!(cmds.len(), 3);
            }
            _ => panic!("Expected Pipeline"),
        }
    }

    #[test]
    fn test_shell_to_sexpr_pipeline() {
        let shell = parse_shell_syntax("ls | take 5").unwrap();
        let sexpr = shell_to_sexpr(&shell);

        // Should produce: (pipe ls (take 5))
        match sexpr {
            Expr::Apply { func, args, .. } => {
                if let Expr::Ident(Ident(name), _) = func.as_ref() {
                    assert_eq!(name, "pipe");
                    assert_eq!(args.len(), 2);
                }
            }
            _ => panic!("Expected Apply"),
        }
    }

    #[test]
    fn test_search_command() {
        let shell = parse_shell_syntax("search type:Int").unwrap();
        match shell {
            ShellExpr::FunctionCall(name, args) => {
                assert_eq!(name, "search");
                assert_eq!(args.len(), 1);
                match &args[0] {
                    ShellArg::Named(k, v) => {
                        assert_eq!(k, "type");
                        assert_eq!(v, "Int");
                    }
                    _ => panic!("Expected Named argument"),
                }
            }
            _ => panic!("Expected FunctionCall"),
        }
    }
}
