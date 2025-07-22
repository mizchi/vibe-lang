//! XS Tools - CLI and Shell for XS language
//!
//! This crate combines the command-line interface and interactive shell
//! for the XS language.

use colored::Colorize;

// CLI modules
pub mod cli;
pub mod component_commands;

// Shell modules
pub mod api;
pub mod commands;
pub mod shell;
pub mod permission_cli;

// Re-export important types
pub use cli::{run_cli, Args, Command};
pub use shell::{run_repl, ShellState};

/// Print error message in red
pub fn print_error(msg: &str) {
    eprintln!("{}", msg.red());
}

/// Print success message in green
pub fn print_success(msg: &str) {
    println!("{}", msg.green());
}

/// Print warning message in yellow
pub fn print_warning(msg: &str) {
    println!("{}", msg.yellow());
}

/// Print info message in blue
pub fn print_info(msg: &str) {
    println!("{}", msg.blue());
}

/// Format hash for display (show first 8 characters)
pub fn format_hash(hash: &str) -> String {
    if hash.len() > 8 {
        format!("[{}]", &hash[..8])
    } else {
        format!("[{hash}]")
    }
}

/// Print expression with syntax highlighting
pub fn print_expr(expr: &str) {
    // Simple syntax highlighting
    let highlighted = expr
        .replace("let", &"let".bright_blue().to_string())
        .replace("rec", &"rec".bright_blue().to_string())
        .replace("fn", &"fn".bright_blue().to_string())
        .replace("if", &"if".bright_blue().to_string())
        .replace("then", &"then".bright_blue().to_string())
        .replace("else", &"else".bright_blue().to_string())
        .replace("match", &"match".bright_blue().to_string())
        .replace("type", &"type".bright_blue().to_string())
        .replace("module", &"module".bright_blue().to_string())
        .replace("import", &"import".bright_blue().to_string())
        .replace("true", &"true".bright_green().to_string())
        .replace("false", &"false".bright_red().to_string());

    println!("{highlighted}");
}

/// Print type with syntax highlighting
pub fn print_type(ty: &str) {
    let highlighted = ty
        .replace("Int", &"Int".bright_cyan().to_string())
        .replace("Bool", &"Bool".bright_cyan().to_string())
        .replace("String", &"String".bright_cyan().to_string())
        .replace("List", &"List".bright_cyan().to_string())
        .replace("->", &"->".bright_magenta().to_string());

    println!("{highlighted}");
}
