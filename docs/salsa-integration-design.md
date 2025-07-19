# Salsa Framework Integration Design for XS Language

## 1. Salsa Framework Overview

### What is Salsa?
Salsa is a Rust framework for incremental computation, designed to efficiently track dependencies between computations and recompute only what's necessary when inputs change. It's used extensively in rust-analyzer for providing fast IDE features.

### Core Concepts
- **Query System**: Programs are defined as a set of queries (functions K -> V)
- **Dependency Tracking**: Automatically tracks which inputs each query accesses
- **Memoization**: Caches results and intelligently determines when to reuse them
- **Red-Green Algorithm**: Determines which computations need re-execution

### Key Benefits for XS Language
- Incremental type checking: Only recheck affected code when changes occur
- Fast IDE support: Provide real-time feedback as users type
- Memory efficiency: Cache intermediate results across compilations
- Designed for AI: Fast static analysis results align with XS language goals

## 2. Integration Architecture

### Database Structure
```rust
// xs_salsa/src/db.rs
#[salsa::db]
pub trait XsDb: salsa::Database {
    // Input queries
    #[salsa::input]
    fn source_file(&self, path: PathBuf) -> Arc<String>;
    
    #[salsa::input]
    fn file_modification_time(&self, path: PathBuf) -> SystemTime;
}

#[salsa::db]
pub struct XsDatabase {
    storage: salsa::Storage<Self>,
}

impl salsa::Database for XsDatabase {}

impl XsDb for XsDatabase {}
```

### Salsa Structs for XS Language

#### Input Structs
```rust
// xs_salsa/src/inputs.rs
#[salsa::input]
pub struct SourceFile {
    pub path: PathBuf,
    pub contents: String,
}

#[salsa::input]
pub struct Module {
    pub name: String,
    pub files: Vec<SourceFile>,
}
```

#### Tracked Structs (Intermediate Values)
```rust
// xs_salsa/src/ir.rs
#[salsa::tracked]
pub struct ParsedFile {
    #[return_ref]
    pub ast: Expr,
    #[return_ref]
    pub parse_errors: Vec<ParseError>,
}

#[salsa::tracked]
pub struct TypedExpr {
    pub expr: Expr,
    pub ty: Type,
    #[return_ref]
    pub type_errors: Vec<TypeError>,
}

#[salsa::tracked]
pub struct TypeEnvironment {
    #[return_ref]
    pub bindings: HashMap<String, TypeScheme>,
    pub parent: Option<TypeEnvironment>,
}
```

#### Interned Structs (Small, Frequently Compared Values)
```rust
// xs_salsa/src/interned.rs
#[salsa::interned]
pub struct InternedType {
    pub data: Type,
}

#[salsa::interned]
pub struct InternedIdent {
    pub name: String,
}
```

### Tracked Functions

#### Parser Integration
```rust
// xs_salsa/src/parser_queries.rs
#[salsa::tracked]
pub fn parse_file(db: &dyn XsDb, file: SourceFile) -> ParsedFile {
    let contents = file.contents(db);
    match parser::parse(&contents) {
        Ok(ast) => ParsedFile::new(db, ast, vec![]),
        Err(e) => ParsedFile::new(db, Expr::default(), vec![e.into()]),
    }
}

#[salsa::tracked]
pub fn all_exprs(db: &dyn XsDb, parsed: ParsedFile) -> Vec<Expr> {
    let ast = parsed.ast(db);
    collect_all_exprs(ast)
}
```

#### Type Checker Integration
```rust
// xs_salsa/src/type_check_queries.rs
#[salsa::tracked]
pub fn infer_expr_type(
    db: &dyn XsDb,
    expr: Expr,
    env: TypeEnvironment,
) -> TypedExpr {
    // Reuse existing type inference logic
    let mut checker = TypeChecker::new();
    match checker.infer(&expr, &env.to_type_env(db)) {
        Ok(ty) => TypedExpr::new(db, expr, ty, vec![]),
        Err(e) => TypedExpr::new(db, expr, Type::Error, vec![e]),
    }
}

#[salsa::tracked]
pub fn check_file(db: &dyn XsDb, file: SourceFile) -> Vec<TypeError> {
    let parsed = parse_file(db, file);
    if !parsed.parse_errors(db).is_empty() {
        return vec![];
    }
    
    let ast = parsed.ast(db);
    let env = create_initial_env(db);
    let typed = infer_expr_type(db, ast.clone(), env);
    typed.type_errors(db).clone()
}

#[salsa::tracked(specify)]
pub fn type_at_position(
    db: &dyn XsDb,
    file: SourceFile,
    position: usize,
) -> Option<Type> {
    let parsed = parse_file(db, file);
    let ast = parsed.ast(db);
    
    // Find expression at position
    if let Some(expr) = find_expr_at_position(ast, position) {
        let env = create_initial_env(db);
        let typed = infer_expr_type(db, expr, env);
        Some(typed.ty(db))
    } else {
        None
    }
}
```

#### Interpreter Integration
```rust
// xs_salsa/src/interpreter_queries.rs
#[salsa::tracked]
pub fn eval_expr(
    db: &dyn XsDb,
    expr: Expr,
    env: EvalEnvironment,
) -> Result<Value, RuntimeError> {
    // Check types first
    let type_env = env.to_type_env(db);
    let typed = infer_expr_type(db, expr.clone(), type_env);
    
    if !typed.type_errors(db).is_empty() {
        return Err(RuntimeError::TypeError);
    }
    
    // Evaluate using existing interpreter
    interpreter::eval(&expr, &env.to_eval_env())
}
```

### Durability and Optimization
```rust
// Mark standard library and dependencies as durable
#[salsa::tracked]
pub fn stdlib_types(db: &dyn XsDb) -> TypeEnvironment {
    db.set_lru_capacity(0); // Never evict
    create_stdlib_env(db)
}

// Use durability for caching
impl XsDatabase {
    pub fn mark_file_durable(&mut self, path: PathBuf) {
        // Mark files in dependencies as durable
        self.set_durability(Durability::HIGH);
    }
}
```

## 3. Integration with Existing XS Components

### Modified CLI Structure
```rust
// cli/src/main.rs
use xs_salsa::{XsDatabase, XsDb};

fn main() {
    let mut db = XsDatabase::default();
    
    match args.command {
        Command::Parse { file } => {
            let source = load_file(&file);
            let source_file = SourceFile::new(&db, file, source);
            let parsed = parse_file(&db, source_file);
            println!("{:#?}", parsed.ast(&db));
        }
        Command::Check { file } => {
            let source = load_file(&file);
            let source_file = SourceFile::new(&db, file, source);
            let errors = check_file(&db, source_file);
            for error in errors {
                println!("{}", error);
            }
        }
        Command::Run { file } => {
            let source = load_file(&file);
            let source_file = SourceFile::new(&db, file, source);
            let parsed = parse_file(&db, source_file);
            let result = eval_expr(&db, parsed.ast(&db), initial_env());
            println!("{:?}", result);
        }
    }
}
```

### Watch Mode for Incremental Compilation
```rust
// cli/src/watch.rs
use notify::{Watcher, RecursiveMode, Result};

pub fn watch_mode(db: &mut XsDatabase, files: Vec<PathBuf>) {
    let (tx, rx) = channel();
    let mut watcher = notify::watcher(tx, Duration::from_millis(100)).unwrap();
    
    for file in &files {
        watcher.watch(file, RecursiveMode::NonRecursive).unwrap();
    }
    
    loop {
        match rx.recv() {
            Ok(DebouncedEvent::Write(path)) => {
                // Update only the changed file
                let new_contents = fs::read_to_string(&path).unwrap();
                let source_file = db.source_file(path.clone());
                source_file.set_contents(db, new_contents);
                
                // Salsa automatically knows what to recompute
                let errors = check_file(db, source_file);
                println!("Rechecked {}: {} errors", path.display(), errors.len());
            }
            _ => {}
        }
    }
}
```

## 4. AI-Focused Features

### Structured Query API
```rust
// xs_salsa/src/ai_queries.rs
#[salsa::tracked]
pub fn ast_hash(db: &dyn XsDb, file: SourceFile) -> String {
    let parsed = parse_file(db, file);
    let ast = parsed.ast(db);
    calculate_content_hash(ast)
}

#[salsa::tracked]
pub fn find_all_functions(db: &dyn XsDb, module: Module) -> Vec<FunctionInfo> {
    module.files(db)
        .iter()
        .flat_map(|file| {
            let parsed = parse_file(db, *file);
            extract_functions(parsed.ast(db))
        })
        .collect()
}

#[salsa::tracked]
pub fn dependency_graph(db: &dyn XsDb, module: Module) -> DependencyGraph {
    // Build dependency graph using incremental computation
    let mut graph = DependencyGraph::new();
    
    for file in module.files(db) {
        let deps = analyze_dependencies(db, file);
        graph.add_file(file.path(db), deps);
    }
    
    graph
}
```

### Fast Static Analysis Results
```rust
// xs_salsa/src/analysis.rs
#[derive(Debug, Clone)]
pub struct AnalysisResult {
    pub types: HashMap<Span, Type>,
    pub scopes: HashMap<Span, Vec<String>>,
    pub errors: Vec<XsError>,
}

#[salsa::tracked]
pub fn analyze_file(db: &dyn XsDb, file: SourceFile) -> AnalysisResult {
    let parsed = parse_file(db, file);
    let mut result = AnalysisResult::default();
    
    // Collect all type information incrementally
    collect_types(db, parsed.ast(db), &mut result);
    collect_scopes(db, parsed.ast(db), &mut result);
    
    result
}
```

## 5. Implementation Plan

### Phase 1: Core Infrastructure (2-3 days)
1. Create xs_salsa crate
2. Define database trait and implementation
3. Create input structs for source files
4. Implement basic parse_file query

### Phase 2: Type Checker Integration (3-4 days)
1. Convert type checker to use Salsa queries
2. Implement incremental type environment
3. Add type inference queries
4. Test incremental recompilation

### Phase 3: Interpreter Integration (2 days)
1. Create evaluation queries
2. Cache intermediate values
3. Test incremental evaluation

### Phase 4: CLI and Watch Mode (2 days)
1. Update CLI to use Salsa database
2. Implement file watching
3. Add incremental compilation mode
4. Performance benchmarking

### Phase 5: AI Features (3-4 days)
1. Implement AST hashing queries
2. Create structured analysis queries
3. Build dependency graph queries
4. Add fast query API for AI tools

## 6. Benefits and Trade-offs

### Benefits
- **Performance**: Only recompute changed parts
- **Memory Efficiency**: Automatic caching with LRU eviction
- **Parallelism**: Salsa supports parallel query execution
- **Debugging**: Built-in cycle detection and debugging support
- **AI-Ready**: Fast incremental analysis for AI tools

### Trade-offs
- **Complexity**: Additional abstraction layer
- **Memory Usage**: Caches can grow large
- **Learning Curve**: Team needs to understand Salsa concepts
- **Refactoring**: Significant changes to existing code structure

## 7. Example Usage

```rust
// Create database
let mut db = XsDatabase::default();

// Load file
let file = SourceFile::new(&db, "main.xs", source_code);

// Type check (first time computes everything)
let errors = check_file(&db, file);

// Modify file (only recomputes affected parts)
file.set_contents(&mut db, new_source_code);
let errors = check_file(&db, file); // Much faster!

// Query specific information
let type_at_pos = type_at_position(&db, file, 42);
let ast_hash = ast_hash(&db, file);
```

## 8. Migration Strategy

1. Start with new xs_salsa crate alongside existing code
2. Gradually migrate functionality to Salsa queries
3. Maintain compatibility with existing CLI
4. Add new incremental features
5. Eventually deprecate old non-incremental code

This design provides a solid foundation for integrating Salsa into the XS language compiler, enabling efficient incremental computation while maintaining the AI-focused design goals.