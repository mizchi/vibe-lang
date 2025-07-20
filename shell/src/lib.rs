use anyhow::{Context, Result};
use checker::{TypeChecker, TypeEnv};
use codebase::{CodebaseManager, EditAction, EditSession};
use colored::*;
use interpreter::Interpreter;
use rustyline::error::ReadlineError;
use rustyline::Editor;
use std::collections::HashMap;
use std::path::PathBuf;
use xs_core::{Environment, Ident};
use xs_core::{Expr, Type, Value};

#[derive(Debug)]
struct ExpressionHistory {
    hash: String,
    expr: Expr,
    ty: Type,
    value: Value,
    timestamp: std::time::SystemTime,
}

pub struct ShellState {
    codebase: CodebaseManager,
    current_branch: String,
    session: EditSession,
    temp_definitions: HashMap<String, (Expr, Type)>,
    type_env: HashMap<String, Type>,
    runtime_env: HashMap<String, Value>,
    // すべての評価式をハッシュで管理
    expr_history: Vec<ExpressionHistory>,
    // ハッシュ→名前のマッピング（名前付けされたもののみ）
    named_exprs: HashMap<String, String>, // name -> hash
}

impl ShellState {
    pub fn new(storage_path: PathBuf) -> Result<Self> {
        let mut codebase = CodebaseManager::new(storage_path)?;
        let main_branch = codebase.create_branch("main".to_string())?;
        let session = EditSession::new(main_branch.hash.clone());

        Ok(Self {
            codebase,
            current_branch: "main".to_string(),
            session,
            temp_definitions: HashMap::new(),
            type_env: HashMap::new(),
            runtime_env: HashMap::new(),
            expr_history: Vec::new(),
            named_exprs: HashMap::new(),
        })
    }

    pub fn evaluate_line(&mut self, line: &str) -> Result<String> {
        // Parse expression
        let expr = parser::parse(line).context("Failed to parse expression")?;

        // Type check
        let mut checker = TypeChecker::new();
        let mut type_env = TypeEnv::default();

        // Add current type environment
        for (name, ty) in &self.type_env {
            type_env.extend(name.clone(), checker::TypeScheme::mono(ty.clone()));
        }

        let ty = checker
            .check(&expr, &mut type_env)
            .context("Type inference failed")?;

        // Interpret
        let mut interpreter = Interpreter::new();
        let mut env = Interpreter::create_initial_env();

        // Add current runtime environment
        for (name, val) in &self.runtime_env {
            env = env.extend(Ident(name.clone()), val.clone());
        }

        let result = interpreter.eval(&expr, &env).context("Evaluation failed")?;

        // すべての式を自動的にコードベースに保存
        let hash = self.codebase.hash_expr(&expr);
        self.expr_history.push(ExpressionHistory {
            hash: hash.clone(),
            expr: expr.clone(),
            ty: ty.clone(),
            value: result.clone(),
            timestamp: std::time::SystemTime::now(),
        });

        // Handle special forms
        match &expr {
            Expr::Let { name, value, .. } => {
                // let式の場合は名前を自動的に登録
                let val_hash = self.codebase.hash_expr(value);
                self.named_exprs.insert(name.0.clone(), val_hash);
                self.type_env.insert(name.0.clone(), ty.clone());
                self.runtime_env.insert(name.0.clone(), result.clone());
                let hash_prefix = if hash.len() >= 8 { &hash[..8] } else { &hash };
                Ok(format!(
                    "{} : {} = {}\n  [{}]",
                    name.0,
                    ty,
                    format_value(&result),
                    hash_prefix
                ))
            }
            _ => {
                let hash_prefix = if hash.len() >= 8 { &hash[..8] } else { &hash };
                Ok(format!(
                    "{} : {}\n  [{}]",
                    format_value(&result),
                    ty,
                    hash_prefix
                ))
            }
        }
    }

    pub fn name_expression(&mut self, hash_prefix: &str, name: &str) -> Result<String> {
        // ハッシュプレフィックスから完全なハッシュを検索
        let full_hash = self
            .expr_history
            .iter()
            .rev()
            .find(|h| h.hash.starts_with(hash_prefix))
            .ok_or_else(|| {
                anyhow::anyhow!("No expression found with hash prefix {}", hash_prefix)
            })?;

        let expr = full_hash.expr.clone();
        let ty = full_hash.ty.clone();
        let value = full_hash.value.clone();
        let hash = full_hash.hash.clone();

        // 名前を登録
        self.named_exprs.insert(name.to_string(), hash.clone());
        self.type_env.insert(name.to_string(), ty.clone());
        self.runtime_env.insert(name.to_string(), value.clone());

        // セッションに追加
        self.session.add_definition(name.to_string(), expr)?;

        let hash_prefix = if hash.len() >= 8 { &hash[..8] } else { &hash };
        Ok(format!(
            "Named {} : {} = {} [{}]",
            name,
            ty,
            format_value(&value),
            hash_prefix
        ))
    }

    pub fn update_codebase(&mut self) -> Result<String> {
        let edits: Vec<_> = self
            .session
            .edits
            .iter()
            .map(|e| match e {
                EditAction::AddDefinition { name, .. } => format!("+ {}", name),
                EditAction::UpdateDefinition { name, .. } => format!("~ {}", name),
                EditAction::DeleteDefinition { name } => format!("- {}", name),
            })
            .collect();

        if edits.is_empty() {
            return Ok("No changes to update".to_string());
        }

        let patch = self.codebase.create_patch_from_session(&self.session)?;
        self.codebase.apply_patch(&self.current_branch, &patch)?;

        // Get updated branch hash
        let branch = self.codebase.get_branch(&self.current_branch)?;

        // Clear session after update
        self.session = EditSession::new(branch.hash.clone());

        Ok(format!(
            "Updated {} definitions:\n{}",
            edits.len(),
            edits.join("\n")
        ))
    }

    pub fn show_history(&self, limit: Option<usize>) -> String {
        if self.expr_history.is_empty() {
            return "No expressions evaluated yet".to_string();
        }

        let history_iter = self.expr_history.iter().rev();
        let limited_iter: Box<dyn Iterator<Item = &ExpressionHistory>> = if let Some(limit) = limit
        {
            Box::new(history_iter.take(limit))
        } else {
            Box::new(history_iter)
        };

        let mut output = Vec::new();
        for (_i, entry) in limited_iter.enumerate() {
            let named = self
                .named_exprs
                .iter()
                .find(|(_, h)| **h == entry.hash)
                .map(|(n, _)| format!(" ({})", n))
                .unwrap_or_default();

            let hash_prefix = if entry.hash.len() >= 8 {
                &entry.hash[..8]
            } else {
                &entry.hash
            };

            output.push(format!(
                "[{}] {} : {}{}",
                hash_prefix,
                format_value(&entry.value),
                entry.ty,
                named
            ));
        }
        output.join("\n")
    }

    pub fn show_named(&self) -> String {
        if self.named_exprs.is_empty() {
            return "No named expressions".to_string();
        }

        let mut output = Vec::new();
        for (name, hash) in &self.named_exprs {
            if let Some(entry) = self.expr_history.iter().find(|h| h.hash == *hash) {
                let hash_prefix = if hash.len() >= 8 { &hash[..8] } else { hash };
                output.push(format!(
                    "{} : {} = {} [{}]",
                    name,
                    entry.ty,
                    format_value(&entry.value),
                    hash_prefix
                ));
            }
        }
        output.join("\n")
    }

    pub fn show_edits(&self) -> String {
        if self.session.edits.is_empty() {
            return "No pending edits".to_string();
        }

        let edits: Vec<_> = self
            .session
            .edits
            .iter()
            .map(|e| match e {
                EditAction::AddDefinition { name, .. } => format!("+ {}", name),
                EditAction::UpdateDefinition { name, .. } => format!("~ {}", name),
                EditAction::DeleteDefinition { name } => format!("- {}", name),
            })
            .collect();

        format!("Pending edits:\n{}", edits.join("\n"))
    }
}

fn format_value(val: &Value) -> String {
    match val {
        Value::Int(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        Value::String(s) => format!("\"{}\"", s),
        Value::List(vals) => {
            let items: Vec<_> = vals.iter().map(format_value).collect();
            format!("(list {})", items.join(" "))
        }
        Value::Closure { .. } => "<closure>".to_string(),
        Value::BuiltinFunction {
            name,
            arity,
            applied_args,
        } => {
            format!("<builtin:{}/{} [{}]>", name, arity, applied_args.len())
        }
        Value::Float(f) => f.to_string(),
        Value::RecClosure { .. } => "<rec-closure>".to_string(),
        Value::Constructor { name, .. } => format!("<constructor:{}>", name),
    }
}

pub fn run_repl() -> Result<()> {
    let mut rl = Editor::<()>::new()?;
    let storage_path = PathBuf::from(".xs-codebase");
    let mut state = ShellState::new(storage_path)?;

    println!("{}", "XS Language Shell".bold().cyan());
    println!("Type 'help' for available commands\n");

    loop {
        let readline = rl.readline("xs> ");
        match readline {
            Ok(line) => {
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }

                rl.add_history_entry(line);

                // Handle commands
                let parts: Vec<&str> = line.split_whitespace().collect();
                match parts.get(0) {
                    Some(&"help") => print_help(),
                    Some(&"exit") | Some(&"quit") => break,
                    Some(&"history") => {
                        let limit = parts.get(1).and_then(|s| s.parse::<usize>().ok());
                        println!("{}", state.show_history(limit));
                    }
                    Some(&"ls") => {
                        let named = state.show_named();
                        if !named.is_empty() {
                            println!("{}", named);
                        } else {
                            println!("No named expressions");
                        }
                    }
                    Some(&"edits") => println!("{}", state.show_edits()),
                    Some(&"name") => {
                        if parts.len() >= 3 {
                            let hash_prefix = parts[1];
                            let name = parts[2];
                            match state.name_expression(hash_prefix, name) {
                                Ok(msg) => println!("{}", msg.green()),
                                Err(e) => println!("{}: {}", "Error".red(), e),
                            }
                        } else {
                            println!("Usage: name <hash-prefix> <name>");
                        }
                    }
                    Some(&"update") => match state.update_codebase() {
                        Ok(msg) => println!("{}", msg.green()),
                        Err(e) => println!("{}: {}", "Error".red(), e),
                    },
                    _ => {
                        // Evaluate as expression
                        match state.evaluate_line(line) {
                            Ok(result) => println!("{}", result),
                            Err(e) => println!("{}: {}", "Error".red(), e),
                        }
                    }
                }
            }
            Err(ReadlineError::Interrupted) => {
                println!("CTRL-C");
                break;
            }
            Err(ReadlineError::Eof) => {
                println!("CTRL-D");
                break;
            }
            Err(err) => {
                println!("Error: {:?}", err);
                break;
            }
        }
    }

    Ok(())
}

fn print_help() {
    println!("{}", "Available commands:".bold());
    println!("  help          - Show this help message");
    println!("  exit/quit     - Exit the shell");
    println!("  history [n]   - Show last n expressions (all if n omitted)");
    println!("  ls            - Show named expressions");
    println!("  edits         - Show pending edits");
    println!("  name <h> <n>  - Name expression with hash prefix h as n");
    println!("  update        - Commit pending changes to codebase");
    println!();
    println!("{}", "Examples:".bold());
    println!("  42                   # Evaluates to 42 : Int [12345678]");
    println!("  (+ 1 2)              # Evaluates to 3 : Int [87654321]");
    println!("  name 8765 sum        # Names the expression as 'sum'");
    println!("  (let f (fn (x) (* x 2)))");
    println!("  (f 21)               # Uses named function");
    println!("  update               # Commits all named expressions");
}
