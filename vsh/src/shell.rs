//! Refactored shell library with reduced duplication

use anyhow::{Context, Result};
use colored::Colorize;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use vibe_compiler::{TypeChecker, TypeEnv};
use vibe_core::pretty_print::pretty_print;
use vibe_core::type_annotator::embed_type_annotations;
use vibe_core::Ident;
use vibe_core::{DoStatement, Expr, Type, Value};
use vibe_runtime::Interpreter;
use vibe_workspace::code_repository::CodeRepository;
use vibe_workspace::hash::DefinitionHash;
use vibe_workspace::namespace::{
    DefinitionContent, DefinitionPath, NamespaceCommand, NamespacePath, NamespaceStore,
};
use vibe_workspace::unified_parser::{parse_unified_with_mode, SyntaxMode};
use vibe_workspace::{CodebaseManager, EditSession, ExpressionId};

use crate::commands;
use crate::search_patterns::{expr_contains_pattern, parse_type_pattern, AstPattern};

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
    current_namespace: String,
    session: EditSession,
    #[allow(dead_code)]
    temp_definitions: HashMap<String, (Expr, Type)>,
    type_env: HashMap<String, Type>,
    runtime_env: HashMap<String, Value>,
    expr_history: Vec<ExpressionHistory>,
    pub(crate) named_exprs: HashMap<String, String>, // name -> hash
    #[allow(dead_code)]
    salsa_db: vibe_workspace::database::XsDatabaseImpl,
    syntax_mode: SyntaxMode,
    code_repository: Option<CodeRepository>,
    namespace_store: NamespaceStore,
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
                "{} = {}\n  : {} (inferred)\n  [{}]",
                name,
                pretty_print(&entry.expr),
                entry.ty,
                hash_prefix
            )
        } else {
            format!(
                "{}\n  : {} (inferred)\n  [{}]",
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
            type_env.add_binding(name.clone(), vibe_compiler::TypeScheme::mono(ty.clone()));
        }

        checker
            .check(expr, &mut type_env)
            .map_err(|e| anyhow::anyhow!("{}", e))
    }

    /// Resolve hash references in an expression
    fn resolve_hash_refs(&self, expr: &Expr) -> Result<Expr> {
        match expr {
            Expr::HashRef { hash, span: _ } => {
                // Try to find the expression by hash
                if let Some(entry) = self.find_expression(hash) {
                    Ok(entry.expr.clone())
                } else {
                    Err(anyhow::anyhow!("Hash reference #{} not found", hash))
                }
            }
            // Recursively process other expression types
            Expr::Apply { func, args, span } => {
                let resolved_func = self.resolve_hash_refs(func)?;
                let resolved_args: Result<Vec<_>> =
                    args.iter().map(|arg| self.resolve_hash_refs(arg)).collect();
                Ok(Expr::Apply {
                    func: Box::new(resolved_func),
                    args: resolved_args?,
                    span: span.clone(),
                })
            }
            Expr::Lambda { params, body, span } => {
                let resolved_body = self.resolve_hash_refs(body)?;
                Ok(Expr::Lambda {
                    params: params.clone(),
                    body: Box::new(resolved_body),
                    span: span.clone(),
                })
            }
            Expr::Let {
                name,
                type_ann,
                value,
                span,
            } => {
                let resolved_value = self.resolve_hash_refs(value)?;
                Ok(Expr::Let {
                    name: name.clone(),
                    type_ann: type_ann.clone(),
                    value: Box::new(resolved_value),
                    span: span.clone(),
                })
            }
            Expr::LetIn {
                name,
                type_ann,
                value,
                body,
                span,
            } => {
                let resolved_value = self.resolve_hash_refs(value)?;
                let resolved_body = self.resolve_hash_refs(body)?;
                Ok(Expr::LetIn {
                    name: name.clone(),
                    type_ann: type_ann.clone(),
                    value: Box::new(resolved_value),
                    body: Box::new(resolved_body),
                    span: span.clone(),
                })
            }
            Expr::If {
                cond,
                then_expr,
                else_expr,
                span,
            } => {
                let resolved_cond = self.resolve_hash_refs(cond)?;
                let resolved_then = self.resolve_hash_refs(then_expr)?;
                let resolved_else = self.resolve_hash_refs(else_expr)?;
                Ok(Expr::If {
                    cond: Box::new(resolved_cond),
                    then_expr: Box::new(resolved_then),
                    else_expr: Box::new(resolved_else),
                    span: span.clone(),
                })
            }
            Expr::List(exprs, span) => {
                let resolved: Result<Vec<_>> =
                    exprs.iter().map(|e| self.resolve_hash_refs(e)).collect();
                Ok(Expr::List(resolved?, span.clone()))
            }
            // For other expression types, return as-is
            // TODO: Add more cases as needed
            _ => Ok(expr.clone()),
        }
    }
}

// Main implementation methods
impl ShellState {
    pub fn new(storage_path: PathBuf) -> Result<Self> {
        let mut codebase = CodebaseManager::new(storage_path.clone())?;
        let main_branch = codebase.create_branch("main".to_string())?;
        let session = EditSession::new(main_branch.hash.clone());

        // Initialize code repository (SQLite database)
        let db_path = storage_path.join("code_repository.db");
        let code_repository = match CodeRepository::new(&db_path) {
            Ok(mut repo) => {
                // Start a new session
                if let Err(e) = repo.start_session() {
                    eprintln!("Warning: Failed to start repository session: {}", e);
                }
                Some(repo)
            }
            Err(e) => {
                eprintln!("Warning: Failed to initialize code repository: {}", e);
                None
            }
        };

        let mut shell_state = Self {
            codebase,
            current_branch: "main".to_string(),
            current_namespace: "scratch".to_string(),
            session,
            temp_definitions: HashMap::new(),
            type_env: HashMap::new(),
            runtime_env: HashMap::new(),
            expr_history: Vec::new(),
            named_exprs: HashMap::new(),
            salsa_db: vibe_workspace::database::XsDatabaseImpl::new(),
            syntax_mode: SyntaxMode::Auto,
            code_repository,
            namespace_store: NamespaceStore::new(),
        };

        // Auto-load index.vin if it exists
        let index_path = PathBuf::from("index.vin");
        if index_path.exists() {
            println!("{}", "Loading index.vin...".cyan());
            if let Err(e) = shell_state.load_vbin(&index_path) {
                eprintln!("{}: Failed to load index.vin: {}", "Warning".yellow(), e);
            } else {
                println!("{}", "index.vin loaded successfully".green());
            }
        }

        Ok(shell_state)
    }

    pub fn evaluate_line(&mut self, line: &str) -> Result<String> {
        // Parse expression using unified parser with current mode
        let mut expr = parse_unified_with_mode(line, self.syntax_mode)
            .map_err(|e| anyhow::anyhow!("Parse error: {}", e))?;

        // Resolve hash references before any other processing
        expr = self.resolve_hash_refs(&expr)?;

        // Check if expression contains holes and fill them interactively
        if self.has_holes(&expr) {
            use crate::hole_completion::HoleCompleter;
            let completer = HoleCompleter::new(
                self.type_env.clone(),
                vibe_core::Environment::from_iter(
                    self.runtime_env
                        .iter()
                        .map(|(k, v)| (Ident(k.clone()), v.clone())),
                ),
            );
            expr = completer.fill_holes_interactive(&expr)?;
        }

        // Semantic analysis
        let _block_attributes = {
            use vibe_compiler::semantic_analysis::SemanticAnalyzer;
            let mut analyzer = SemanticAnalyzer::new();
            analyzer
                .analyze(&expr)
                .map_err(|e| anyhow::anyhow!("Semantic analysis error: {}", e))?
        };

        // TODO: Store block attributes in the codebase or repository when persistence is needed

        // Type check
        let ty = self
            .type_check_with_env(&expr)
            .map_err(|e| anyhow::anyhow!("Type error: {}", e))?;

        // Interpret
        let mut interpreter = Interpreter::new();
        let mut env = Interpreter::create_initial_env();

        // Add current runtime environment
        for (name, val) in &self.runtime_env {
            env = env.extend(Ident(name.clone()), val.clone());
        }

        let result = interpreter.eval(&expr, &env).context("Evaluation failed")?;

        // Handle use statements
        if let Value::UseStatement { path, items } = &result {
            // Update both runtime and type environments based on the use statement
            let runtime_functions = match path
                .iter()
                .map(|s| s.as_str())
                .collect::<Vec<_>>()
                .as_slice()
            {
                ["lib"] => interpreter.get_lib_runtime_functions(),
                ["lib", "String"] => interpreter.get_string_runtime_functions(),
                ["lib", "List"] => interpreter.get_list_runtime_functions(),
                ["lib", "Int"] => interpreter.get_int_runtime_functions(),
                _ => HashMap::new(),
            };

            // Get type information for the imported functions
            use vibe_core::lib_modules::get_module_functions;
            let type_functions = get_module_functions(path).unwrap_or_default();

            if let Some(items) = items {
                // Import only specific items
                for item in items {
                    if let Some(func_value) = runtime_functions.get(&item.0) {
                        self.runtime_env.insert(item.0.clone(), func_value.clone());
                    }
                    if let Some(func_type) = type_functions.get(&item.0) {
                        self.type_env.insert(item.0.clone(), func_type.clone());
                    }
                }
            } else {
                // Import all functions
                for (name, value) in runtime_functions {
                    self.runtime_env.insert(name, value);
                }
                for (name, typ) in type_functions {
                    self.type_env.insert(name, typ);
                }
            }
        }

        // Save to history and Salsa DB
        let hash = self.codebase.hash_expr(&expr);
        let hash_obj = vibe_workspace::Hash::from_hex(&hash)?;

        self.expr_history.push(ExpressionHistory {
            hash: hash.clone(),
            expr: expr.clone(),
            ty: ty.clone(),
            value: result.clone(),
            timestamp: std::time::SystemTime::now(),
        });

        // Auto-save to code repository
        // Extract dependencies before mutable borrow
        let dependencies = self.extract_dependencies(&expr);

        if let Some(repo) = &mut self.code_repository {
            // Create a Term for storage
            let term = vibe_workspace::Term {
                hash: hash_obj.clone(),
                name: None, // Will be set for let expressions
                expr: expr.clone(),
                ty: ty.clone(),
                dependencies: dependencies.clone(),
            };

            // Store in repository
            if let Err(e) = repo.store_term(&term, &dependencies) {
                eprintln!("Warning: Failed to store in repository: {}", e);
            }

            // Record evaluation
            let result_str = format_value(&result);
            if let Err(e) = repo.record_evaluation(line, Some(&hash_obj), &result_str) {
                eprintln!("Warning: Failed to record evaluation: {}", e);
            }
        }

        let _expr_id = ExpressionId(hash.clone());
        // TODO: Salsa integration
        // self.salsa_db
        //     .set_expression_source(expr_id.clone(), Arc::new(expr.clone()));

        // Handle special forms
        match &expr {
            Expr::Let {
                name,
                value,
                type_ann,
                ..
            } => {
                // Embed type annotation if not present
                let annotated_value = if type_ann.is_none() {
                    // The value itself might be a lambda or function that needs type annotation
                    Box::new(embed_type_annotations(value, &ty))
                } else {
                    value.clone()
                };

                // Create the annotated let expression
                let annotated_expr = Expr::Let {
                    name: name.clone(),
                    type_ann: if type_ann.is_none() {
                        Some(ty.clone())
                    } else {
                        type_ann.clone()
                    },
                    value: annotated_value.clone(),
                    span: expr.span().clone(),
                };

                // Save the complete annotated let expression
                let expr_hash = self.codebase.hash_expr(&annotated_expr);
                let expr_hash_obj = vibe_workspace::Hash::from_hex(&expr_hash)?;

                self.expr_history.push(ExpressionHistory {
                    hash: expr_hash.clone(),
                    expr: annotated_expr.clone(),
                    ty: ty.clone(),
                    value: result.clone(),
                    timestamp: std::time::SystemTime::now(),
                });

                // Store named definition in repository
                // Extract dependencies before mutable borrow
                let dependencies = self.extract_dependencies(&annotated_expr);

                if let Some(repo) = &mut self.code_repository {
                    let named_term = vibe_workspace::Term {
                        hash: expr_hash_obj.clone(),
                        name: Some(name.0.clone()),
                        expr: annotated_expr.clone(),
                        ty: ty.clone(),
                        dependencies: dependencies.clone(),
                    };

                    if let Err(e) = repo.store_term(&named_term, &dependencies) {
                        eprintln!("Warning: Failed to store named term: {}", e);
                    }
                }

                let _val_expr_id = ExpressionId(expr_hash.clone());
                // TODO: Salsa integration
                // self.salsa_db
                //     .set_expression_source(val_expr_id.clone(), Arc::new((**value).clone()));

                // Check if already defined
                let is_redefinition = self.type_env.contains_key(&name.0);
                let old_hash = if is_redefinition {
                    self.named_exprs.get(&name.0).cloned()
                } else {
                    None
                };

                // Register name with namespace prefix
                let qualified_name =
                    if self.current_namespace.is_empty() || self.current_namespace == "main" {
                        name.0.clone()
                    } else {
                        format!("{}.{}", self.current_namespace, name.0)
                    };
                self.named_exprs
                    .insert(qualified_name.clone(), expr_hash.clone());
                self.type_env.insert(qualified_name.clone(), ty.clone());
                self.runtime_env
                    .insert(qualified_name.clone(), result.clone());

                // Also register without namespace for convenience in current namespace
                self.named_exprs.insert(name.0.clone(), expr_hash.clone());
                self.type_env.insert(name.0.clone(), ty.clone());
                self.runtime_env.insert(name.0.clone(), result.clone());

                // Add to session
                self.session
                    .add_definition(name.0.clone(), (**value).clone())?;

                // Add to namespace store with annotated expression
                let current_ns = NamespacePath::from_str(&self.current_namespace);
                let def_path = DefinitionPath::new(current_ns, name.0.clone());
                let content = DefinitionContent::Value((*annotated_value).clone());

                // Convert workspace hash dependencies to namespace hash dependencies
                let _ns_dependencies: HashSet<DefinitionHash> = dependencies
                    .iter()
                    .filter_map(|h| {
                        // Convert workspace Hash to hex and then to DefinitionHash
                        let hex = h.to_hex();
                        if let Ok(bytes) = hex::decode(&hex) {
                            if bytes.len() == 32 {
                                let mut arr = [0u8; 32];
                                arr.copy_from_slice(&bytes);
                                Some(DefinitionHash(arr))
                            } else {
                                None
                            }
                        } else {
                            None
                        }
                    })
                    .collect();

                let command = NamespaceCommand::AddDefinition {
                    path: def_path,
                    content,
                    type_signature: ty.clone(),
                    metadata: Default::default(),
                };

                if let Err(e) = self.namespace_store.execute_command(command) {
                    eprintln!("Warning: Failed to add to namespace store: {}", e);
                }

                let mut response = format!(
                    "{} : {} = {}\n  [{}]",
                    name.0,
                    ty,
                    format_value(&result),
                    Self::hash_prefix(&hash)
                );

                if is_redefinition {
                    if let Some(old_hash) = old_hash {
                        if old_hash != expr_hash {
                            response.push_str(&format!(
                                "\n  {} (previous definition: [{}])",
                                "Updated existing definition".yellow(),
                                Self::hash_prefix(&old_hash)
                            ));
                        } else {
                            response.push_str(&format!(
                                "\n  {}",
                                "Definition unchanged (same implementation)".cyan()
                            ));
                        }
                    }
                }

                Ok(response)
            }
            Expr::Rec {
                name,
                params,
                return_type,
                body,
                span,
            } => {
                // Embed return type annotation if not present
                let annotated_expr = if return_type.is_none() {
                    Expr::Rec {
                        name: name.clone(),
                        params: params.clone(),
                        return_type: Some(ty.clone()),
                        body: body.clone(),
                        span: span.clone(),
                    }
                } else {
                    expr.clone()
                };
                // Register recursive function with namespace prefix
                let qualified_name =
                    if self.current_namespace.is_empty() || self.current_namespace == "main" {
                        name.0.clone()
                    } else {
                        format!("{}.{}", self.current_namespace, name.0)
                    };
                self.named_exprs
                    .insert(qualified_name.clone(), hash.clone());
                self.type_env.insert(qualified_name.clone(), ty.clone());
                self.runtime_env
                    .insert(qualified_name.clone(), result.clone());

                // Also register without namespace for convenience in current namespace
                self.type_env.insert(name.0.clone(), ty.clone());
                self.runtime_env.insert(name.0.clone(), result.clone());

                // Save the complete annotated rec expression
                let expr_hash = self.codebase.hash_expr(&annotated_expr);
                let expr_hash_obj = vibe_workspace::Hash::from_hex(&expr_hash)?;

                self.expr_history.push(ExpressionHistory {
                    hash: expr_hash.clone(),
                    expr: annotated_expr.clone(),
                    ty: ty.clone(),
                    value: result.clone(),
                    timestamp: std::time::SystemTime::now(),
                });

                // Store named definition in repository
                let dependencies = self.extract_dependencies(&annotated_expr);

                if let Some(repo) = &mut self.code_repository {
                    let named_term = vibe_workspace::Term {
                        hash: expr_hash_obj.clone(),
                        name: Some(name.0.clone()),
                        expr: annotated_expr.clone(),
                        ty: ty.clone(),
                        dependencies: dependencies.clone(),
                    };

                    if let Err(e) = repo.store_term(&named_term, &dependencies) {
                        eprintln!("Warning: Failed to store named term: {}", e);
                    }
                }

                // Add to session with type annotation
                self.session
                    .add_definition(name.0.clone(), annotated_expr.clone())?;

                // Also add to namespace store
                let current_ns = NamespacePath::from_str(&self.current_namespace);
                let def_path = DefinitionPath::new(current_ns, name.0.clone());
                let _ns_dependencies: HashSet<DefinitionHash> = dependencies
                    .iter()
                    .filter_map(|h| {
                        let hex = h.to_hex();
                        if let Ok(bytes) = hex::decode(&hex) {
                            if bytes.len() == 32 {
                                let mut arr = [0u8; 32];
                                arr.copy_from_slice(&bytes);
                                Some(DefinitionHash(arr))
                            } else {
                                None
                            }
                        } else {
                            None
                        }
                    })
                    .collect();

                let content = DefinitionContent::Function {
                    params: params.iter().map(|(p, _)| p.0.clone()).collect(),
                    body: (**body).clone(),
                };

                let command = NamespaceCommand::AddDefinition {
                    path: def_path,
                    content,
                    type_signature: ty.clone(),
                    metadata: Default::default(),
                };

                if let Err(e) = self.namespace_store.execute_command(command) {
                    eprintln!("Warning: Failed to add to namespace store: {}", e);
                }

                Ok(format!(
                    "{} : {}\n  [{}]",
                    format_value(&result),
                    ty,
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

    pub fn load_vbin(&mut self, path: &PathBuf) -> Result<()> {
        use vibe_workspace::vbin::VBinStorage;

        let mut storage = VBinStorage::new(path.to_string_lossy().to_string());
        let loaded_codebase = storage
            .load_full()
            .map_err(|e| anyhow::anyhow!("Failed to load vbin: {}", e))?;

        // Add all terms to the current environment
        for (name, hash) in loaded_codebase.names() {
            if let Some(term) = loaded_codebase.get_term(&hash) {
                // Add to type environment
                self.type_env.insert(name.clone(), term.ty.clone());

                // Evaluate and add to runtime environment
                let mut interpreter = Interpreter::new();
                let mut env = Interpreter::create_initial_env();

                // Add current runtime environment for evaluation
                for (existing_name, val) in &self.runtime_env {
                    env = env.extend(Ident(existing_name.clone()), val.clone());
                }

                match interpreter.eval(&term.expr, &env) {
                    Ok(value) => {
                        self.runtime_env.insert(name.clone(), value.clone());

                        // Add to history
                        let entry = ExpressionHistory {
                            hash: hash.to_hex(),
                            expr: term.expr.clone(),
                            ty: term.ty.clone(),
                            value,
                            timestamp: std::time::SystemTime::now(),
                        };
                        self.expr_history.push(entry);
                        self.named_exprs.insert(name, hash.to_hex());
                    }
                    Err(e) => {
                        eprintln!("Warning: Failed to evaluate {}: {}", name, e);
                    }
                }
            }
        }

        Ok(())
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
        let expr = vibe_core::parser::parse(expr_str).context("Failed to parse expression")?;
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
        match vibe_core::parser::parse(name_or_expr) {
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
        match parse_type_pattern(pattern) {
            Ok(matcher) => matcher(ty),
            Err(_) => format!("{ty:?}").contains(pattern), // Fallback to simple string matching
        }
    }

    fn expr_contains_pattern(&self, expr: &Expr, pattern: &str) -> bool {
        if let Some(ast_pattern) = AstPattern::from_str(pattern) {
            expr_contains_pattern(expr, &ast_pattern)
        } else {
            false
        }
    }

    pub fn execute_pipeline(&self, commands: &[String]) -> Result<String> {
        use chrono::Utc;
        use vibe_workspace::pipeline::parse_pipeline_operator;
        use vibe_workspace::structured_data::{
            format_structured_data, DefinitionData, DefinitionKind, DefinitionMetadata,
            StructuredData,
        };

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
                        path: vibe_workspace::namespace::DefinitionPath::from_str(name)
                            .unwrap_or_else(|| {
                                vibe_workspace::namespace::DefinitionPath::new(
                                    vibe_workspace::namespace::NamespacePath::root(),
                                    name.clone(),
                                )
                            }),
                        hash: vibe_workspace::hash::DefinitionHash([0; 32]), // Simplified
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
                                path: vibe_workspace::namespace::DefinitionPath::from_str(name)
                                    .unwrap_or_else(|| {
                                        vibe_workspace::namespace::DefinitionPath::new(
                                            vibe_workspace::namespace::NamespacePath::root(),
                                            name.to_string(),
                                        )
                                    }),
                                hash: vibe_workspace::hash::DefinitionHash([0; 32]),
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
            return Err(anyhow::anyhow!(
                "First command must be 'definitions', 'ls', or 'search'"
            ));
        };

        // Apply pipeline operators
        for cmd in &commands[1..] {
            let operator = parse_pipeline_operator(cmd)?;
            data = operator.apply(data)?;
        }

        // Format and return the result
        Ok(format_structured_data(&data))
    }

    /// Check if an expression contains holes
    fn has_holes(&self, expr: &Expr) -> bool {
        match expr {
            Expr::Hole { .. } => true,
            Expr::Block { exprs, .. } => exprs.iter().any(|e| self.has_holes(e)),
            Expr::Apply { func, args, .. } => {
                self.has_holes(func) || args.iter().any(|a| self.has_holes(a))
            }
            Expr::If {
                cond,
                then_expr,
                else_expr,
                ..
            } => self.has_holes(cond) || self.has_holes(then_expr) || self.has_holes(else_expr),
            Expr::Let { value, .. } => self.has_holes(value),
            Expr::LetIn { value, body, .. } => self.has_holes(value) || self.has_holes(body),
            Expr::Lambda { body, .. } => self.has_holes(body),
            Expr::Match {
                expr: match_expr,
                cases,
                ..
            } => self.has_holes(match_expr) || cases.iter().any(|(_, e)| self.has_holes(e)),
            Expr::Pipeline {
                expr: lhs, func, ..
            } => self.has_holes(lhs) || self.has_holes(func),
            Expr::Do { statements, .. } => statements.iter().any(|stmt| match stmt {
                DoStatement::Bind { expr, .. } => self.has_holes(expr),
                DoStatement::Expression(expr) => self.has_holes(expr),
            }),
            Expr::RecordLiteral { fields, .. } => fields.iter().any(|(_, e)| self.has_holes(e)),
            Expr::RecordAccess { record, .. } => self.has_holes(record),
            Expr::RecordUpdate {
                record, updates, ..
            } => self.has_holes(record) || updates.iter().any(|(_, e)| self.has_holes(e)),
            Expr::List(elements, _) => elements.iter().any(|e| self.has_holes(e)),
            Expr::LetRec { value, .. } => self.has_holes(value),
            Expr::LetRecIn { value, body, .. } => self.has_holes(value) || self.has_holes(body),
            Expr::HandleExpr {
                expr,
                handlers,
                return_handler,
                ..
            } => {
                self.has_holes(expr)
                    || handlers.iter().any(|h| self.has_holes(&h.body))
                    || return_handler
                        .as_ref()
                        .map_or(false, |(_, body)| self.has_holes(body))
            }
            Expr::Rec { body, .. } => self.has_holes(body),
            _ => false,
        }
    }

    /// Extract dependencies from an expression
    fn extract_dependencies(&self, expr: &Expr) -> std::collections::HashSet<vibe_workspace::Hash> {
        use std::collections::HashSet;
        let mut deps = HashSet::new();
        self.extract_deps_recursive(expr, &mut deps);
        deps
    }

    fn extract_deps_recursive(
        &self,
        expr: &Expr,
        deps: &mut std::collections::HashSet<vibe_workspace::Hash>,
    ) {
        match expr {
            Expr::Ident(name, _) => {
                // Check if this identifier refers to a named expression
                if let Some(hash_str) = self.named_exprs.get(&name.0) {
                    if let Ok(hash) = vibe_workspace::Hash::from_hex(hash_str) {
                        deps.insert(hash);
                    }
                }
            }
            Expr::Apply { func, args, .. } => {
                self.extract_deps_recursive(func, deps);
                for arg in args {
                    self.extract_deps_recursive(arg, deps);
                }
            }
            Expr::Lambda { body, .. } => {
                self.extract_deps_recursive(body, deps);
            }
            Expr::Let { value, .. } => {
                self.extract_deps_recursive(value, deps);
            }
            Expr::LetIn { value, body, .. } => {
                self.extract_deps_recursive(value, deps);
                self.extract_deps_recursive(body, deps);
            }
            Expr::If {
                cond,
                then_expr,
                else_expr,
                ..
            } => {
                self.extract_deps_recursive(cond, deps);
                self.extract_deps_recursive(then_expr, deps);
                self.extract_deps_recursive(else_expr, deps);
            }
            Expr::Match { expr, cases, .. } => {
                self.extract_deps_recursive(expr, deps);
                for (_, case_expr) in cases {
                    self.extract_deps_recursive(case_expr, deps);
                }
            }
            Expr::List(elements, _) => {
                for elem in elements {
                    self.extract_deps_recursive(elem, deps);
                }
            }
            Expr::LetRec { value, .. } => {
                self.extract_deps_recursive(value, deps);
            }
            Expr::Rec { body, .. } => {
                self.extract_deps_recursive(body, deps);
            }
            _ => {}
        }
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
        Value::Constructor { name, .. } => format!("<constructor:{}>", name.0),
        Value::UseStatement { .. } => "<use>".to_string(),
        Value::Record { fields } => {
            let field_strs: Vec<String> = fields
                .iter()
                .map(|(name, value)| format!("{}: {}", name, format_value(value)))
                .collect();
            format!("{{{}}}", field_strs.join(", "))
        }
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

    println!(
        "{}",
        "Vibe Language Shell - Unified S-expression & Shell Syntax"
            .bold()
            .cyan()
    );
    println!("Type 'help' for available commands");
    println!("Default mode: Auto-detect syntax. Use :mode to check, :sexpr/:shell/:auto/:mixed to switch.\n");

    loop {
        let prompt = format!("{}> ", state.current_namespace.cyan());
        let readline = rl.readline(&prompt);
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

                            Command::Search(query) => match state.search_definitions(&query) {
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
                            },

                            Command::Pipeline(commands) => {
                                match state.execute_pipeline(&commands) {
                                    Ok(result) => println!("{result}"),
                                    Err(e) => println!("{}: {}", "Error".red(), e),
                                }
                            }

                            Command::Stats => {
                                if let Some(repo) = &mut state.code_repository {
                                    match repo.get_access_stats() {
                                        Ok(stats) => {
                                            println!("{}", "Repository Statistics:".bold());
                                            println!();
                                            println!("{}", "Most accessed definitions:".cyan());
                                            for (name, count) in stats {
                                                println!("  {} - {} accesses", name, count);
                                            }
                                        }
                                        Err(e) => println!("{}: {}", "Error".red(), e),
                                    }
                                } else {
                                    println!("{}: Code repository not available", "Error".red());
                                }
                            }

                            Command::DeadCode => {
                                if let Some(repo) = &mut state.code_repository {
                                    // Get all root namespaces currently in use
                                    let mut namespaces = std::collections::HashSet::new();
                                    for (name, _) in &state.named_exprs {
                                        if let Some(ns) = name.split('.').next() {
                                            namespaces.insert(ns.to_string());
                                        }
                                    }
                                    let root_namespaces: Vec<String> =
                                        namespaces.into_iter().collect();

                                    match repo.analyze_reachability(&root_namespaces) {
                                        Ok(analysis) => {
                                            println!("{}", "Dead Code Analysis:".bold());
                                            println!();
                                            if analysis.dead_code.is_empty() {
                                                println!("No dead code found!");
                                            } else {
                                                println!(
                                                    "Found {} unreachable definitions:",
                                                    analysis.dead_code.len()
                                                );

                                                // Look up names for dead code
                                                for hash in &analysis.dead_code {
                                                    if let Ok(results) = repo.search_by_name("") {
                                                        for (h, name, _) in results {
                                                            if &h == hash {
                                                                println!(
                                                                    "  {} [{}]",
                                                                    name,
                                                                    hash.to_hex()
                                                                );
                                                                break;
                                                            }
                                                        }
                                                    }
                                                }

                                                println!();
                                                println!("Use 'remove-dead-code' to clean up (not implemented yet)");
                                            }
                                        }
                                        Err(e) => println!("{}: {}", "Error".red(), e),
                                    }
                                } else {
                                    println!("{}: Code repository not available", "Error".red());
                                }
                            }

                            Command::Reachable(namespaces) => {
                                if let Some(repo) = &mut state.code_repository {
                                    match repo.analyze_reachability(&namespaces) {
                                        Ok(analysis) => {
                                            println!("{}", "Reachability Analysis:".bold());
                                            println!();
                                            println!("From namespaces: {}", namespaces.join(", "));
                                            println!(
                                                "Reachable definitions: {}",
                                                analysis.reachable.len()
                                            );
                                            println!(
                                                "Unreachable definitions: {}",
                                                analysis.dead_code.len()
                                            );
                                            println!();

                                            // Show top referenced definitions
                                            let mut refs: Vec<_> =
                                                analysis.reference_count.into_iter().collect();
                                            refs.sort_by_key(|(_, count)| {
                                                std::cmp::Reverse(*count)
                                            });

                                            println!("{}", "Most referenced definitions:".cyan());
                                            for (hash, count) in refs.iter().take(10) {
                                                // Try to find name
                                                if let Ok(results) = repo.search_by_name("") {
                                                    for (h, name, _) in results {
                                                        if &h == hash {
                                                            println!(
                                                                "  {} - {} references",
                                                                name, count
                                                            );
                                                            break;
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        Err(e) => println!("{}: {}", "Error".red(), e),
                                    }
                                } else {
                                    println!("{}: Code repository not available", "Error".red());
                                }
                            }

                            Command::Namespace(None) => {
                                println!("Current namespace: {}", state.current_namespace.cyan());
                            }

                            Command::Namespace(Some(name)) => {
                                state.current_namespace = name.clone();
                                println!("Changed to namespace: {}", name.cyan());
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
                println!("\n{}", "Goodbye!".green());
                break;
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
