//! Refactored shell library with reduced duplication

use anyhow::{Context, Result};
use checker::{TypeChecker, TypeEnv};
use codebase::{CodebaseManager, EditSession};
use interpreter::Interpreter;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use xs_core::Ident;
use xs_core::{Expr, Type, Value};
use xs_core::pretty_print::pretty_print;
use xs_salsa::{XsDatabase, ExpressionId, SourcePrograms};

mod commands;

pub mod api;

#[derive(Debug)]
struct ExpressionHistory {
    hash: String,
    expr: Expr,
    ty: Type,
    value: Value,
    #[allow(dead_code)]
    timestamp: std::time::SystemTime,
}

pub struct ShellState {
    codebase: CodebaseManager,
    #[allow(dead_code)]
    current_branch: String,
    session: EditSession,
    #[allow(dead_code)]
    temp_definitions: HashMap<String, (Expr, Type)>,
    type_env: HashMap<String, Type>,
    runtime_env: HashMap<String, Value>,
    expr_history: Vec<ExpressionHistory>,
    pub(crate) named_exprs: HashMap<String, String>, // name -> hash
    salsa_db: XsDatabase,
}

// Helper methods for common operations
impl ShellState {
    /// Get hash prefix for display (8 characters)
    fn hash_prefix(hash: &str) -> &str {
        if hash.len() >= 8 { &hash[..8] } else { hash }
    }
    
    /// Find expression history entry by hash or name
    fn find_expression(&self, name_or_hash: &str) -> Option<&ExpressionHistory> {
        // Try by name first
        if let Some(hash) = self.named_exprs.get(name_or_hash) {
            self.expr_history.iter().find(|h| &h.hash == hash)
        } else {
            // Try by hash prefix
            self.expr_history.iter().rev().find(|h| h.hash.starts_with(name_or_hash))
        }
    }
    
    /// Format expression info for display
    fn format_expression_info(&self, entry: &ExpressionHistory, name: Option<&str>) -> String {
        let hash_prefix = Self::hash_prefix(&entry.hash);
        if let Some(name) = name {
            format!(
                "{} = {}\n  : {}\n  [{}]",
                name,
                pretty_print(&entry.expr),
                entry.ty,
                hash_prefix
            )
        } else {
            format!(
                "{}\n  : {}\n  [{}]",
                pretty_print(&entry.expr),
                entry.ty,
                hash_prefix
            )
        }
    }
    
    /// Find name for a given hash
    fn find_name_for_hash(&self, hash: &str) -> Option<&str> {
        self.named_exprs.iter()
            .find(|(_, h)| *h == hash)
            .map(|(n, _)| n.as_str())
    }
    
    /// Type check an expression with current environment
    fn type_check_with_env(&self, expr: &Expr) -> Result<Type> {
        let mut checker = TypeChecker::new();
        let mut type_env = TypeEnv::default();
        
        // Add current type environment
        for (name, ty) in &self.type_env {
            type_env.extend(name.clone(), checker::TypeScheme::mono(ty.clone()));
        }
        
        checker.check(expr, &mut type_env)
            .map_err(|e| anyhow::anyhow!("Type error: {}", e))
    }
}

// Main implementation methods
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
            salsa_db: XsDatabase::new(),
        })
    }

    pub fn evaluate_line(&mut self, line: &str) -> Result<String> {
        // Parse expression
        let expr = parser::parse(line).context("Failed to parse expression")?;

        // Type check
        let ty = self.type_check_with_env(&expr).context("Type inference failed")?;

        // Interpret
        let mut interpreter = Interpreter::new();
        let mut env = Interpreter::create_initial_env();

        // Add current runtime environment
        for (name, val) in &self.runtime_env {
            env = env.extend(Ident(name.clone()), val.clone());
        }

        let result = interpreter.eval(&expr, &env).context("Evaluation failed")?;

        // Save to history and Salsa DB
        let hash = self.codebase.hash_expr(&expr);
        self.expr_history.push(ExpressionHistory {
            hash: hash.clone(),
            expr: expr.clone(),
            ty: ty.clone(),
            value: result.clone(),
            timestamp: std::time::SystemTime::now(),
        });
        
        let expr_id = ExpressionId(hash.clone());
        self.salsa_db.set_expression_source(expr_id.clone(), Arc::new(expr.clone()));

        // Handle special forms
        match &expr {
            Expr::Let { name, value, .. } => {
                // Save value expression too
                let val_hash = self.codebase.hash_expr(value);
                self.expr_history.push(ExpressionHistory {
                    hash: val_hash.clone(),
                    expr: (**value).clone(),
                    ty: ty.clone(),
                    value: result.clone(),
                    timestamp: std::time::SystemTime::now(),
                });
                
                let val_expr_id = ExpressionId(val_hash.clone());
                self.salsa_db.set_expression_source(val_expr_id.clone(), Arc::new((**value).clone()));
                
                // Register name
                self.named_exprs.insert(name.0.clone(), val_hash);
                self.type_env.insert(name.0.clone(), ty.clone());
                self.runtime_env.insert(name.0.clone(), result.clone());
                
                // Add to session
                self.session.add_definition(name.0.clone(), (**value).clone())?;
                
                Ok(format!(
                    "{} : {} = {}\n  [{}]",
                    name.0,
                    ty,
                    format_value(&result),
                    Self::hash_prefix(&hash)
                ))
            }
            _ => {
                Ok(format!(
                    "{} : {}\n  [{}]",
                    format_value(&result),
                    ty,
                    Self::hash_prefix(&hash)
                ))
            }
        }
    }

    pub fn view_definition(&self, name_or_hash: &str) -> Result<String> {
        if let Some(entry) = self.find_expression(name_or_hash) {
            let name = self.find_name_for_hash(&entry.hash);
            Ok(self.format_expression_info(entry, name))
        } else {
            anyhow::bail!("Definition '{}' not found", name_or_hash)
        }
    }

    pub fn list_definitions(&self, pattern: Option<&str>) -> String {
        let mut results = Vec::new();

        for (name, hash) in &self.named_exprs {
            if let Some(pattern) = pattern {
                if !name.contains(pattern) {
                    continue;
                }
            }

            if let Some(entry) = self.expr_history.iter().find(|h| &h.hash == hash) {
                results.push(format!(
                    "{} : {} [{}]",
                    name,
                    entry.ty,
                    Self::hash_prefix(hash)
                ));
            } else if let Some(ty) = self.type_env.get(name) {
                results.push(format!(
                    "{} : {} [{}]",
                    name,
                    ty,
                    Self::hash_prefix(hash)
                ));
            }
        }

        if results.is_empty() {
            match pattern {
                Some(p) => format!("No definitions found matching '{}'", p),
                None => "No definitions in codebase".to_string(),
            }
        } else {
            results.join("\n")
        }
    }

    pub fn show_history(&self, limit: Option<usize>) -> String {
        if self.expr_history.is_empty() {
            return "No expressions evaluated yet".to_string();
        }

        let entries: Vec<_> = if let Some(limit) = limit {
            self.expr_history.iter().rev().take(limit).collect()
        } else {
            self.expr_history.iter().rev().collect()
        };

        entries.iter()
            .map(|entry| {
                let named = self.find_name_for_hash(&entry.hash)
                    .map(|n| format!(" ({n})"))
                    .unwrap_or_default();
                
                format!(
                    "[{}] {} : {}{}",
                    Self::hash_prefix(&entry.hash),
                    format_value(&entry.value),
                    entry.ty,
                    named
                )
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    pub fn update_codebase(&mut self) -> Result<String> {
        // TODO: セッションの編集をコミット
        Ok("Update functionality not yet implemented".to_string())
    }
    
    pub fn type_of_expr(&mut self, expr_str: &str) -> Result<String> {
        let expr = parser::parse(expr_str).context("Failed to parse expression")?;
        match self.type_check_with_env(&expr) {
            Ok(ty) => Ok(ty.to_string()),
            Err(e) => Err(e)
        }
    }
    
    pub fn show_dependencies(&self, name: &str) -> String {
        // TODO: 実際の依存関係解析を実装
        format!("{} has no dependencies tracked yet", name)
    }
    
    pub fn find_references(&self, name: &str) -> String {
        let mut references = Vec::new();
        
        if let Some(hash) = self.named_exprs.get(name) {
            references.push(format!("Definition: {} [{}]", name, Self::hash_prefix(hash)));
        }
        
        // TODO: 実際の参照解析を実装
        if references.is_empty() {
            format!("No references found for '{}'", name)
        } else {
            format!("References to '{}':\n{}", name, references.join("\n"))
        }
    }
    
    pub fn show_hover_info(&mut self, name_or_expr: &str) -> Result<String> {
        // 名前の場合
        if let Some(hash) = self.named_exprs.get(name_or_expr) {
            if let Some(entry) = self.expr_history.iter().find(|h| &h.hash == hash) {
                return Ok(format!(
                    "{} : {}\n= {}\n[{}]",
                    name_or_expr,
                    entry.ty,
                    format_value(&entry.value),
                    Self::hash_prefix(&hash)
                ));
            }
        }
        
        // 式として評価
        match parser::parse(name_or_expr) {
            Ok(expr) => {
                match self.type_check_with_env(&expr) {
                    Ok(ty) => Ok(format!("{} : {}", name_or_expr, ty)),
                    Err(e) => Ok(format!("Type error: {}", e))
                }
            }
            Err(_) => anyhow::bail!("Invalid expression: {}", name_or_expr)
        }
    }
    
    pub fn find_definitions(&self, pattern: &str) -> String {
        let results: Vec<_> = self.named_exprs
            .iter()
            .filter(|(name, _)| name.contains(pattern))
            .map(|(name, hash)| {
                format!("{} [{}]", name, Self::hash_prefix(hash))
            })
            .collect();
            
        if results.is_empty() {
            format!("No definitions found matching '{}'", pattern)
        } else {
            results.join("\n")
        }
    }
    
    pub fn show_dependents(&self, name: &str) -> String {
        // TODO: 実際の被依存関係解析を実装
        format!("No dependents found for {}", name)
    }
    
    pub fn show_definition(&self, name: &str) -> Result<String> {
        if let Some(hash) = self.named_exprs.get(name) {
            if let Some(entry) = self.expr_history.iter().find(|h| &h.hash == hash) {
                return Ok(format!(
                    "Definition of '{}':\n  Location: [{}]\n  Expression: {}\n  Type: {}",
                    name,
                    Self::hash_prefix(hash),
                    pretty_print(&entry.expr),
                    entry.ty
                ));
            }
        }
        anyhow::bail!("Definition '{}' not found", name)
    }
}

fn format_value(val: &Value) -> String {
    match val {
        Value::Int(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        Value::String(s) => format!("\"{s}\""),
        Value::List(vals) => {
            let items: Vec<_> = vals.iter().map(format_value).collect();
            format!("(list {})", items.join(" "))
        }
        Value::Closure { .. } => "<closure>".to_string(),
        Value::BuiltinFunction { name, arity, applied_args } => {
            format!("<builtin:{}/{} [{}]>", name, arity, applied_args.len())
        }
        Value::Float(f) => f.to_string(),
        Value::RecClosure { .. } => "<rec-closure>".to_string(),
        Value::Constructor { name, .. } => format!("<constructor:{name}>"),
    }
}

pub fn run_repl() -> Result<()> {
    use colored::*;
    use rustyline::error::ReadlineError;
    use rustyline::Editor;
    use commands::{Command, print_ucm_help};
    
    let mut rl = Editor::<()>::new()?;
    let storage_path = PathBuf::from(".xs-codebase");
    let mut state = ShellState::new(storage_path)?;

    println!("{}", "XS Language Shell (UCM-style)".bold().cyan());
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

                // コマンドをパース
                match Command::parse(line) {
                    Ok(cmd) => {
                        match cmd {
                            Command::Help => print_ucm_help(),
                            Command::Exit => break,
                            Command::Clear => {
                                print!("\x1B[2J\x1B[1;1H"); // ANSIエスケープコードでクリア
                            }
                            
                            Command::Add(def) => {
                                let expr = def.as_deref().unwrap_or("");
                                match state.evaluate_line(expr) {
                                    Ok(result) => println!("{}", result.green()),
                                    Err(e) => println!("{}: {}", "Error".red(), e),
                                }
                            }
                            
                            Command::View(name_or_hash) => {
                                match state.view_definition(&name_or_hash) {
                                    Ok(result) => println!("{}", result),
                                    Err(e) => println!("{}: {}", "Error".red(), e),
                                }
                            }
                            
                            Command::History(limit) => {
                                println!("{}", state.show_history(limit));
                            }
                            
                            Command::Ls(pattern) => {
                                println!("{}", state.list_definitions(pattern.as_deref()));
                            }
                            
                            Command::Eval(expr) => {
                                match state.evaluate_line(&expr) {
                                    Ok(result) => println!("{result}"),
                                    Err(e) => println!("{}: {}", "Error".red(), e),
                                }
                            }
                            
                            _ => {
                                println!("{}: Command not yet implemented", "Note".yellow());
                            }
                        }
                    }
                    Err(_) => {
                        // コマンドではない場合は式として評価
                        match state.evaluate_line(line) {
                            Ok(result) => println!("{result}"),
                            Err(e) => println!("{}: {}", "Error".red(), e),
                        }
                    }
                }
            }
            Err(ReadlineError::Interrupted) => {
                println!("\n{}", "Use 'exit' to quit".yellow());
            }
            Err(ReadlineError::Eof) => {
                println!("\n{}", "Goodbye!".green());
                break;
            }
            Err(err) => {
                println!("{}: {:?}", "Error".red(), err);
                break;
            }
        }
    }

    Ok(())
}