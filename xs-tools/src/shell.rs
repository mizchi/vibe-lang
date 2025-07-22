//! Refactored shell library with reduced duplication

use anyhow::{Context, Result};
use colored::Colorize;
use std::collections::HashMap;
use std::path::PathBuf;
use xs_compiler::{TypeChecker, TypeEnv};
use xs_core::pretty_print::pretty_print;
use xs_core::Ident;
use xs_core::{Expr, Type, Value};
use xs_runtime::Interpreter;
use xs_workspace::{CodebaseManager, EditSession, ExpressionId};
use xs_workspace::unified_parser::{parse_unified_with_mode, SyntaxMode};

use crate::commands;

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
    #[allow(dead_code)]
    salsa_db: xs_workspace::database::XsDatabaseImpl,
    syntax_mode: SyntaxMode,
}

// Helper methods for common operations
impl ShellState {
    /// Get hash prefix for display (8 characters)
    fn hash_prefix(hash: &str) -> &str {
        if hash.len() >= 8 {
            &hash[..8]
        } else {
            hash
        }
    }

    /// Find expression history entry by hash or name
    fn find_expression(&self, name_or_hash: &str) -> Option<&ExpressionHistory> {
        // Try by name first
        if let Some(hash) = self.named_exprs.get(name_or_hash) {
            self.expr_history.iter().find(|h| &h.hash == hash)
        } else {
            // Try by hash prefix
            self.expr_history
                .iter()
                .rev()
                .find(|h| h.hash.starts_with(name_or_hash))
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
        self.named_exprs
            .iter()
            .find(|(_, h)| *h == hash)
            .map(|(n, _)| n.as_str())
    }

    /// Type check an expression with current environment
    fn type_check_with_env(&self, expr: &Expr) -> Result<Type> {
        let mut checker = TypeChecker::new();
        let mut type_env = TypeEnv::default();

        // Add current type environment
        for (name, ty) in &self.type_env {
            type_env.add_binding(name.clone(), xs_compiler::TypeScheme::mono(ty.clone()));
        }

        checker
            .check(expr, &mut type_env)
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
            salsa_db: xs_workspace::database::XsDatabaseImpl::new(),
            syntax_mode: SyntaxMode::Auto,
        })
    }

    pub fn evaluate_line(&mut self, line: &str) -> Result<String> {
        // Parse expression using unified parser with current mode
        let expr = parse_unified_with_mode(line, self.syntax_mode).context("Failed to parse expression")?;

        // Type check
        let ty = self
            .type_check_with_env(&expr)
            .context("Type inference failed")?;

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

        let _expr_id = ExpressionId(hash.clone());
        // TODO: Salsa integration
        // self.salsa_db
        //     .set_expression_source(expr_id.clone(), Arc::new(expr.clone()));

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

                let _val_expr_id = ExpressionId(val_hash.clone());
                // TODO: Salsa integration
                // self.salsa_db
                //     .set_expression_source(val_expr_id.clone(), Arc::new((**value).clone()));

                // Register name
                self.named_exprs.insert(name.0.clone(), val_hash);
                self.type_env.insert(name.0.clone(), ty.clone());
                self.runtime_env.insert(name.0.clone(), result.clone());

                // Add to session
                self.session
                    .add_definition(name.0.clone(), (**value).clone())?;

                Ok(format!(
                    "{} : {} = {}\n  [{}]",
                    name.0,
                    ty,
                    format_value(&result),
                    Self::hash_prefix(&hash)
                ))
            }
            _ => Ok(format!(
                "{} : {}\n  [{}]",
                format_value(&result),
                ty,
                Self::hash_prefix(&hash)
            )),
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
                results.push(format!("{} : {} [{}]", name, ty, Self::hash_prefix(hash)));
            }
        }

        if results.is_empty() {
            match pattern {
                Some(p) => format!("No definitions found matching '{p}'"),
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

        entries
            .iter()
            .map(|entry| {
                let named = self
                    .find_name_for_hash(&entry.hash)
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
        let expr = xs_core::parser::parse(expr_str).context("Failed to parse expression")?;
        match self.type_check_with_env(&expr) {
            Ok(ty) => Ok(ty.to_string()),
            Err(e) => Err(e),
        }
    }

    pub fn show_dependencies(&self, name: &str) -> String {
        // TODO: 実際の依存関係解析を実装
        format!("{name} has no dependencies tracked yet")
    }

    pub fn find_references(&self, name: &str) -> String {
        let mut references = Vec::new();

        if let Some(hash) = self.named_exprs.get(name) {
            references.push(format!(
                "Definition: {} [{}]",
                name,
                Self::hash_prefix(hash)
            ));
        }

        // TODO: 実際の参照解析を実装
        if references.is_empty() {
            format!("No references found for '{name}'")
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
                    Self::hash_prefix(hash)
                ));
            }
        }

        // 式として評価
        match xs_core::parser::parse(name_or_expr) {
            Ok(expr) => match self.type_check_with_env(&expr) {
                Ok(ty) => Ok(format!("{name_or_expr} : {ty}")),
                Err(e) => Ok(format!("Type error: {e}")),
            },
            Err(_) => anyhow::bail!("Invalid expression: {}", name_or_expr),
        }
    }

    pub fn find_definitions(&self, pattern: &str) -> String {
        let results: Vec<_> = self
            .named_exprs
            .iter()
            .filter(|(name, _)| name.contains(pattern))
            .map(|(name, hash)| format!("{} [{}]", name, Self::hash_prefix(hash)))
            .collect();

        if results.is_empty() {
            format!("No definitions found matching '{pattern}'")
        } else {
            results.join("\n")
        }
    }

    pub fn show_dependents(&self, name: &str) -> String {
        // TODO: 実際の被依存関係解析を実装
        format!("No dependents found for {name}")
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

    pub fn set_syntax_mode(&mut self, mode: SyntaxMode) {
        self.syntax_mode = mode;
    }

    pub fn get_syntax_mode(&self) -> SyntaxMode {
        self.syntax_mode
    }

    pub fn search_definitions(&self, query: &str) -> Result<Vec<String>> {
        
        // Parse query syntax
        let results = if query.starts_with("type:") {
            // Type search
            let type_pattern = query.trim_start_matches("type:").trim();
            self.search_by_type(type_pattern)?
        } else if query.starts_with("ast:") {
            // AST pattern search
            let ast_pattern = query.trim_start_matches("ast:").trim();
            self.search_by_ast(ast_pattern)?
        } else if query.starts_with("dependsOn:") {
            // Dependency search
            let target = query.trim_start_matches("dependsOn:").trim();
            self.search_depends_on(target)?
        } else {
            // Default: name search
            self.search_by_name(query)?
        };
        
        Ok(results)
    }
    
    fn search_by_type(&self, pattern: &str) -> Result<Vec<String>> {
        let mut results = Vec::new();
        
        for (name, hash) in &self.named_exprs {
            if let Some(entry) = self.expr_history.iter().find(|h| &h.hash == hash) {
                if self.type_matches_pattern(&entry.ty, pattern) {
                    results.push(format!(
                        "{} : {} [{}]",
                        name.green(),
                        entry.ty,
                        Self::hash_prefix(hash).cyan()
                    ));
                }
            }
        }
        
        Ok(results)
    }
    
    fn search_by_ast(&self, pattern: &str) -> Result<Vec<String>> {
        let mut results = Vec::new();
        
        for (name, hash) in &self.named_exprs {
            if let Some(entry) = self.expr_history.iter().find(|h| &h.hash == hash) {
                if self.expr_contains_pattern(&entry.expr, pattern) {
                    results.push(format!(
                        "{} : {} [{}]",
                        name.green(),
                        entry.ty,
                        Self::hash_prefix(hash).cyan()
                    ));
                }
            }
        }
        
        Ok(results)
    }
    
    fn search_depends_on(&self, _target: &str) -> Result<Vec<String>> {
        // Placeholder for dependency search
        Ok(vec!["Dependency search not yet implemented".to_string()])
    }
    
    fn search_by_name(&self, pattern: &str) -> Result<Vec<String>> {
        let mut results = Vec::new();
        
        for (name, hash) in &self.named_exprs {
            if name.contains(pattern) {
                if let Some(entry) = self.expr_history.iter().find(|h| &h.hash == hash) {
                    results.push(format!(
                        "{} : {} [{}]",
                        name.green(),
                        entry.ty,
                        Self::hash_prefix(hash).cyan()
                    ));
                }
            }
        }
        
        Ok(results)
    }
    
    fn type_matches_pattern(&self, ty: &Type, pattern: &str) -> bool {
        // Simple pattern matching for now
        match pattern {
            "Int -> Int" => {
                if let Type::Function(from, to) = ty {
                    matches!(**from, Type::Int) && matches!(**to, Type::Int)
                } else {
                    false
                }
            }
            "_ -> Int" => {
                if let Type::Function(_, to) = ty {
                    matches!(**to, Type::Int)
                } else {
                    false
                }
            }
            "Int -> _" => {
                if let Type::Function(from, _) = ty {
                    matches!(**from, Type::Int)
                } else {
                    false
                }
            }
            _ => format!("{ty:?}").contains(pattern),
        }
    }
    
    fn expr_contains_pattern(&self, expr: &Expr, pattern: &str) -> bool {
        match pattern {
            "match" => self.expr_contains_match(expr),
            "lambda" | "fn" => self.expr_contains_lambda(expr),
            "if" => self.expr_contains_if(expr),
            _ => false,
        }
    }
    
    fn expr_contains_match(&self, expr: &Expr) -> bool {
        match expr {
            Expr::Match { .. } => true,
            Expr::Lambda { body, .. } => self.expr_contains_match(body),
            Expr::Apply { func, args, .. } => {
                self.expr_contains_match(func) || 
                args.iter().any(|arg| self.expr_contains_match(arg))
            }
            Expr::Let { value, .. } => self.expr_contains_match(value),
            Expr::LetIn { value, body, .. } => {
                self.expr_contains_match(value) || self.expr_contains_match(body)
            }
            Expr::If { cond, then_expr, else_expr, .. } => {
                self.expr_contains_match(cond) || 
                self.expr_contains_match(then_expr) || 
                self.expr_contains_match(else_expr)
            }
            _ => false,
        }
    }
    
    fn expr_contains_lambda(&self, expr: &Expr) -> bool {
        match expr {
            Expr::Lambda { .. } => true,
            Expr::Apply { func, args, .. } => {
                self.expr_contains_lambda(func) || 
                args.iter().any(|arg| self.expr_contains_lambda(arg))
            }
            Expr::Let { value, .. } => self.expr_contains_lambda(value),
            Expr::LetIn { value, body, .. } => {
                self.expr_contains_lambda(value) || self.expr_contains_lambda(body)
            }
            Expr::If { cond, then_expr, else_expr, .. } => {
                self.expr_contains_lambda(cond) || 
                self.expr_contains_lambda(then_expr) || 
                self.expr_contains_lambda(else_expr)
            }
            Expr::Match { expr, cases, .. } => {
                self.expr_contains_lambda(expr) ||
                cases.iter().any(|(_, e)| self.expr_contains_lambda(e))
            }
            _ => false,
        }
    }
    
    fn expr_contains_if(&self, expr: &Expr) -> bool {
        match expr {
            Expr::If { .. } => true,
            Expr::Lambda { body, .. } => self.expr_contains_if(body),
            Expr::Apply { func, args, .. } => {
                self.expr_contains_if(func) || 
                args.iter().any(|arg| self.expr_contains_if(arg))
            }
            Expr::Let { value, .. } => self.expr_contains_if(value),
            Expr::LetIn { value, body, .. } => {
                self.expr_contains_if(value) || self.expr_contains_if(body)
            }
            Expr::Match { expr, cases, .. } => {
                self.expr_contains_if(expr) ||
                cases.iter().any(|(_, e)| self.expr_contains_if(e))
            }
            _ => false,
        }
    }
    
    pub fn execute_pipeline(&self, commands: &[String]) -> Result<String> {
        use xs_workspace::structured_data::{StructuredData, DefinitionData, DefinitionKind, DefinitionMetadata, format_structured_data};
        use xs_workspace::pipeline::parse_pipeline_operator;
        use chrono::Utc;
        
        if commands.is_empty() {
            return Err(anyhow::anyhow!("Empty pipeline"));
        }
        
        // Execute the first command to get initial data
        let first_cmd = &commands[0];
        let mut data = if first_cmd == "definitions" || first_cmd == "ls" {
            // Convert current definitions to structured data
            let mut defs = Vec::new();
            for (name, hash) in &self.named_exprs {
                if let Some(entry) = self.expr_history.iter().find(|h| &h.hash == hash) {
                    let kind = match &entry.ty {
                        Type::Function(_, _) => DefinitionKind::Function { arity: 1 }, // Simplified
                        _ => DefinitionKind::Value,
                    };
                    
                    let def = DefinitionData {
                        name: name.clone(),
                        path: xs_workspace::namespace::DefinitionPath::from_str(name).unwrap_or_else(|| {
                            xs_workspace::namespace::DefinitionPath::new(
                                xs_workspace::namespace::NamespacePath::root(),
                                name.clone()
                            )
                        }),
                        hash: xs_workspace::hash::DefinitionHash([0; 32]), // Simplified
                        type_signature: format!("{}", entry.ty),
                        kind,
                        dependencies: vec![],
                        metadata: DefinitionMetadata {
                            created_at: Utc::now(),
                            author: None,
                            documentation: None,
                            test_count: 0,
                        },
                    };
                    defs.push(def);
                }
            }
            StructuredData::Definitions(defs)
        } else if first_cmd.starts_with("search ") {
            // Execute search and convert to structured data
            let query = first_cmd.trim_start_matches("search ").trim();
            let results = self.search_definitions(query)?;
            
            // Convert search results to definitions
            let mut defs = Vec::new();
            for result_str in results {
                // Parse the result string (simplified)
                if let Some(name) = result_str.split(':').next() {
                    let name = name.trim();
                    if let Some(hash) = self.named_exprs.get(name) {
                        if let Some(entry) = self.expr_history.iter().find(|h| &h.hash == hash) {
                            let kind = match &entry.ty {
                                Type::Function(_, _) => DefinitionKind::Function { arity: 1 },
                                _ => DefinitionKind::Value,
                            };
                            
                            let def = DefinitionData {
                                name: name.to_string(),
                                path: xs_workspace::namespace::DefinitionPath::from_str(name).unwrap_or_else(|| {
                                    xs_workspace::namespace::DefinitionPath::new(
                                        xs_workspace::namespace::NamespacePath::root(),
                                        name.to_string()
                                    )
                                }),
                                hash: xs_workspace::hash::DefinitionHash([0; 32]),
                                type_signature: format!("{}", entry.ty),
                                kind,
                                dependencies: vec![],
                                metadata: DefinitionMetadata {
                                    created_at: Utc::now(),
                                    author: None,
                                    documentation: None,
                                    test_count: 0,
                                },
                            };
                            defs.push(def);
                        }
                    }
                }
            }
            StructuredData::Definitions(defs)
        } else {
            return Err(anyhow::anyhow!("First command must be 'definitions', 'ls', or 'search'"));
        };
        
        // Apply pipeline operators
        for cmd in &commands[1..] {
            let operator = parse_pipeline_operator(cmd)?;
            data = operator.apply(data)?;
        }
        
        // Format and return the result
        Ok(format_structured_data(&data))
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
        Value::BuiltinFunction {
            name,
            arity,
            applied_args,
        } => {
            format!("<builtin:{}/{} [{}]>", name, arity, applied_args.len())
        }
        Value::Float(f) => f.to_string(),
        Value::RecClosure { .. } => "<rec-closure>".to_string(),
        Value::Constructor { name, .. } => format!("<constructor:{name}>"),
    }
}

pub fn run_repl() -> Result<()> {
    use colored::*;
    use commands::{print_ucm_help, Command};
    use rustyline::error::ReadlineError;
    use rustyline::Editor;

    let mut rl = Editor::<()>::new()?;
    let storage_path = PathBuf::from(".xs-codebase");
    let mut state = ShellState::new(storage_path)?;

    println!("{}", "XS Language Shell - Unified S-expression & Shell Syntax".bold().cyan());
    println!("Type 'help' for available commands");
    println!("Default mode: Auto-detect syntax. Use :mode to check, :sexpr/:shell/:auto/:mixed to switch.\n");

    loop {
        let readline = rl.readline("xs> ");
        match readline {
            Ok(line) => {
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }

                rl.add_history_entry(line);

                // Check for special commands first
                if line.starts_with(':') {
                    // Handle mode switching commands
                    match line {
                        ":sexpr" => {
                            state.set_syntax_mode(SyntaxMode::SExprOnly);
                            println!("Switched to S-expression only mode");
                            continue;
                        }
                        ":shell" => {
                            state.set_syntax_mode(SyntaxMode::ShellOnly);
                            println!("Switched to shell syntax only mode");
                            continue;
                        }
                        ":auto" => {
                            state.set_syntax_mode(SyntaxMode::Auto);
                            println!("Switched to auto-detect mode");
                            continue;
                        }
                        ":mixed" => {
                            state.set_syntax_mode(SyntaxMode::Mixed);
                            println!("Switched to mixed syntax mode");
                            continue;
                        }
                        ":mode" => {
                            println!("Current syntax mode: {:?}", state.get_syntax_mode());
                            continue;
                        }
                        _ => {}
                    }
                }

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
                                    Ok(result) => println!("{result}"),
                                    Err(e) => println!("{}: {}", "Error".red(), e),
                                }
                            }

                            Command::History(limit) => {
                                println!("{}", state.show_history(limit));
                            }

                            Command::Ls(pattern) => {
                                println!("{}", state.list_definitions(pattern.as_deref()));
                            }

                            Command::Eval(expr) => match state.evaluate_line(&expr) {
                                Ok(result) => println!("{result}"),
                                Err(e) => println!("{}: {}", "Error".red(), e),
                            },

                            Command::Search(query) => {
                                match state.search_definitions(&query) {
                                    Ok(results) => {
                                        if results.is_empty() {
                                            println!("No definitions found matching the query");
                                        } else {
                                            println!("Found {} definitions:", results.len());
                                            for result in results {
                                                println!("{result}");
                                            }
                                        }
                                    }
                                    Err(e) => println!("{}: {}", "Error".red(), e),
                                }
                            }
                            
                            Command::Pipeline(commands) => {
                                match state.execute_pipeline(&commands) {
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
                        // コマンドではない場合は式として評価（統一パーサーを使用）
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
