use super::gll::{GLLGrammar, GLLRule, GLLSymbol};

/// Create the unified Vibe language grammar based on the new consistent syntax
pub fn create_unified_vibe_grammar() -> GLLGrammar {
    let mut rules = Vec::new();
    
    // ========== Program Structure ==========
    
    // Program -> TopLevelDef Program | TopLevelDef
    rules.push(GLLRule {
        lhs: "Program".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("TopLevelDef".to_string()),
            GLLSymbol::NonTerminal("Program".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "Program".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("TopLevelDef".to_string())],
    });
    
    // TopLevelDef -> LetBinding | TypeDef | ModuleDef | ImportDef | TypeClassDef | InstanceDef | EffectDef | Expr
    rules.push(GLLRule {
        lhs: "TopLevelDef".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("LetBinding".to_string())],
    });
    rules.push(GLLRule {
        lhs: "TopLevelDef".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("TypeDef".to_string())],
    });
    rules.push(GLLRule {
        lhs: "TopLevelDef".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("ModuleDef".to_string())],
    });
    rules.push(GLLRule {
        lhs: "TopLevelDef".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("ImportDef".to_string())],
    });
    rules.push(GLLRule {
        lhs: "TopLevelDef".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("TypeClassDef".to_string())],
    });
    rules.push(GLLRule {
        lhs: "TopLevelDef".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("InstanceDef".to_string())],
    });
    rules.push(GLLRule {
        lhs: "TopLevelDef".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("EffectDef".to_string())],
    });
    rules.push(GLLRule {
        lhs: "TopLevelDef".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Expr".to_string())],
    });
    
    // ========== Let Bindings (Unified) ==========
    
    // LetBinding -> let Pattern Parameters = Expr LetBindingTail
    rules.push(GLLRule {
        lhs: "LetBinding".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("let".to_string()),
            GLLSymbol::NonTerminal("Pattern".to_string()),
            GLLSymbol::NonTerminal("Parameters".to_string()),
            GLLSymbol::Terminal("=".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
            GLLSymbol::NonTerminal("LetBindingTail".to_string()),
        ],
    });
    
    // LetBinding -> let Pattern Parameters TypeAnnotation = Expr LetBindingTail
    rules.push(GLLRule {
        lhs: "LetBinding".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("let".to_string()),
            GLLSymbol::NonTerminal("Pattern".to_string()),
            GLLSymbol::NonTerminal("Parameters".to_string()),
            GLLSymbol::NonTerminal("TypeAnnotation".to_string()),
            GLLSymbol::Terminal("=".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
            GLLSymbol::NonTerminal("LetBindingTail".to_string()),
        ],
    });
    
    // LetBindingTail -> and Pattern Parameters = Expr LetBindingTail | ε
    rules.push(GLLRule {
        lhs: "LetBindingTail".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("and".to_string()),
            GLLSymbol::NonTerminal("Pattern".to_string()),
            GLLSymbol::NonTerminal("Parameters".to_string()),
            GLLSymbol::Terminal("=".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
            GLLSymbol::NonTerminal("LetBindingTail".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "LetBindingTail".to_string(),
        rhs: vec![GLLSymbol::Epsilon],
    });
    
    // Parameters -> Parameter Parameters | ε
    rules.push(GLLRule {
        lhs: "Parameters".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Parameter".to_string()),
            GLLSymbol::NonTerminal("Parameters".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "Parameters".to_string(),
        rhs: vec![GLLSymbol::Epsilon],
    });
    
    // Parameter -> identifier | ( Pattern : Type )
    rules.push(GLLRule {
        lhs: "Parameter".to_string(),
        rhs: vec![GLLSymbol::Terminal("identifier".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Parameter".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("(".to_string()),
            GLLSymbol::NonTerminal("Pattern".to_string()),
            GLLSymbol::Terminal(":".to_string()),
            GLLSymbol::NonTerminal("Type".to_string()),
            GLLSymbol::Terminal(")".to_string()),
        ],
    });
    
    // TypeAnnotation -> -> Type
    rules.push(GLLRule {
        lhs: "TypeAnnotation".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("->".to_string()),
            GLLSymbol::NonTerminal("Type".to_string()),
        ],
    });
    
    // ========== Expressions ==========
    
    // Expr -> LetExpr | IfExpr | CaseExpr | DoExpr | LambdaExpr | BinaryExpr
    rules.push(GLLRule {
        lhs: "Expr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("LetExpr".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Expr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("IfExpr".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Expr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("CaseExpr".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Expr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("DoExpr".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Expr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("LambdaExpr".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Expr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("BinaryExpr".to_string())],
    });
    
    // LetExpr -> LetBinding in Expr
    rules.push(GLLRule {
        lhs: "LetExpr".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("LetBinding".to_string()),
            GLLSymbol::Terminal("in".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
        ],
    });
    
    // IfExpr -> if Expr Block else Block
    rules.push(GLLRule {
        lhs: "IfExpr".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("if".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
            GLLSymbol::NonTerminal("Block".to_string()),
            GLLSymbol::Terminal("else".to_string()),
            GLLSymbol::NonTerminal("Block".to_string()),
        ],
    });
    
    // CaseExpr -> match Expr { CaseBranches }
    rules.push(GLLRule {
        lhs: "CaseExpr".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("match".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
            GLLSymbol::Terminal("{".to_string()),
            GLLSymbol::NonTerminal("CaseBranches".to_string()),
            GLLSymbol::Terminal("}".to_string()),
        ],
    });
    
    // CaseBranches -> Pattern CaseGuard -> Expr CaseBranches | Pattern CaseGuard -> Expr
    rules.push(GLLRule {
        lhs: "CaseBranches".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Pattern".to_string()),
            GLLSymbol::NonTerminal("CaseGuard".to_string()),
            GLLSymbol::Terminal("->".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
            GLLSymbol::NonTerminal("CaseBranches".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "CaseBranches".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Pattern".to_string()),
            GLLSymbol::NonTerminal("CaseGuard".to_string()),
            GLLSymbol::Terminal("->".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
        ],
    });
    
    // CaseGuard -> when Expr | ε
    rules.push(GLLRule {
        lhs: "CaseGuard".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("when".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "CaseGuard".to_string(),
        rhs: vec![GLLSymbol::Epsilon],
    });
    
    // DoExpr -> do Block
    rules.push(GLLRule {
        lhs: "DoExpr".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("do".to_string()),
            GLLSymbol::NonTerminal("Block".to_string()),
        ],
    });
    
    // LambdaExpr -> \ Parameters -> Expr | fn Parameters -> Expr | fn Parameters Block
    rules.push(GLLRule {
        lhs: "LambdaExpr".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("\\".to_string()),
            GLLSymbol::NonTerminal("Parameters".to_string()),
            GLLSymbol::Terminal("->".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "LambdaExpr".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("fn".to_string()),
            GLLSymbol::NonTerminal("Parameters".to_string()),
            GLLSymbol::Terminal("->".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "LambdaExpr".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("fn".to_string()),
            GLLSymbol::NonTerminal("Parameters".to_string()),
            GLLSymbol::NonTerminal("Block".to_string()),
        ],
    });
    
    // ========== Binary Expressions (with precedence) ==========
    
    // BinaryExpr -> PipelineExpr
    rules.push(GLLRule {
        lhs: "BinaryExpr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("PipelineExpr".to_string())],
    });
    
    // PipelineExpr -> PipelineExpr |> ApplyExpr | ApplyExpr
    rules.push(GLLRule {
        lhs: "PipelineExpr".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("PipelineExpr".to_string()),
            GLLSymbol::Terminal("|>".to_string()),
            GLLSymbol::NonTerminal("ApplyExpr".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "PipelineExpr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("ApplyExpr".to_string())],
    });
    
    // ApplyExpr -> OrExpr $ ApplyExpr | OrExpr
    rules.push(GLLRule {
        lhs: "ApplyExpr".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("OrExpr".to_string()),
            GLLSymbol::Terminal("$".to_string()),
            GLLSymbol::NonTerminal("ApplyExpr".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "ApplyExpr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("OrExpr".to_string())],
    });
    
    // OrExpr -> OrExpr || AndExpr | AndExpr
    rules.push(GLLRule {
        lhs: "OrExpr".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("OrExpr".to_string()),
            GLLSymbol::Terminal("||".to_string()),
            GLLSymbol::NonTerminal("AndExpr".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "OrExpr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("AndExpr".to_string())],
    });
    
    // AndExpr -> AndExpr && CompareExpr | CompareExpr
    rules.push(GLLRule {
        lhs: "AndExpr".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("AndExpr".to_string()),
            GLLSymbol::Terminal("&&".to_string()),
            GLLSymbol::NonTerminal("CompareExpr".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "AndExpr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("CompareExpr".to_string())],
    });
    
    // CompareExpr -> ConsExpr CompareOp ConsExpr | ConsExpr
    rules.push(GLLRule {
        lhs: "CompareExpr".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("ConsExpr".to_string()),
            GLLSymbol::NonTerminal("CompareOp".to_string()),
            GLLSymbol::NonTerminal("ConsExpr".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "CompareExpr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("ConsExpr".to_string())],
    });
    
    // CompareOp -> == | != | < | > | <= | >=
    rules.push(GLLRule {
        lhs: "CompareOp".to_string(),
        rhs: vec![GLLSymbol::Terminal("==".to_string())],
    });
    rules.push(GLLRule {
        lhs: "CompareOp".to_string(),
        rhs: vec![GLLSymbol::Terminal("!=".to_string())],
    });
    rules.push(GLLRule {
        lhs: "CompareOp".to_string(),
        rhs: vec![GLLSymbol::Terminal("<".to_string())],
    });
    rules.push(GLLRule {
        lhs: "CompareOp".to_string(),
        rhs: vec![GLLSymbol::Terminal(">".to_string())],
    });
    rules.push(GLLRule {
        lhs: "CompareOp".to_string(),
        rhs: vec![GLLSymbol::Terminal("<=".to_string())],
    });
    rules.push(GLLRule {
        lhs: "CompareOp".to_string(),
        rhs: vec![GLLSymbol::Terminal(">=".to_string())],
    });
    
    // ConsExpr -> ConcatExpr :: ConsExpr | ConcatExpr
    rules.push(GLLRule {
        lhs: "ConsExpr".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("ConcatExpr".to_string()),
            GLLSymbol::Terminal("::".to_string()),
            GLLSymbol::NonTerminal("ConsExpr".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "ConsExpr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("ConcatExpr".to_string())],
    });
    
    // ConcatExpr -> AddExpr ++ ConcatExpr | AddExpr
    rules.push(GLLRule {
        lhs: "ConcatExpr".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("AddExpr".to_string()),
            GLLSymbol::Terminal("++".to_string()),
            GLLSymbol::NonTerminal("ConcatExpr".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "ConcatExpr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("AddExpr".to_string())],
    });
    
    // AddExpr -> AddExpr + MulExpr | AddExpr - MulExpr | MulExpr
    rules.push(GLLRule {
        lhs: "AddExpr".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("AddExpr".to_string()),
            GLLSymbol::Terminal("+".to_string()),
            GLLSymbol::NonTerminal("MulExpr".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "AddExpr".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("AddExpr".to_string()),
            GLLSymbol::Terminal("-".to_string()),
            GLLSymbol::NonTerminal("MulExpr".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "AddExpr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("MulExpr".to_string())],
    });
    
    // MulExpr -> MulExpr * PowExpr | MulExpr / PowExpr | MulExpr mod PowExpr | PowExpr
    rules.push(GLLRule {
        lhs: "MulExpr".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("MulExpr".to_string()),
            GLLSymbol::Terminal("*".to_string()),
            GLLSymbol::NonTerminal("PowExpr".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "MulExpr".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("MulExpr".to_string()),
            GLLSymbol::Terminal("/".to_string()),
            GLLSymbol::NonTerminal("PowExpr".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "MulExpr".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("MulExpr".to_string()),
            GLLSymbol::Terminal("mod".to_string()),
            GLLSymbol::NonTerminal("PowExpr".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "MulExpr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("PowExpr".to_string())],
    });
    
    // PowExpr -> AppExpr ^ PowExpr | AppExpr
    rules.push(GLLRule {
        lhs: "PowExpr".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("AppExpr".to_string()),
            GLLSymbol::Terminal("^".to_string()),
            GLLSymbol::NonTerminal("PowExpr".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "PowExpr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("AppExpr".to_string())],
    });
    
    // AppExpr -> AppExpr PostfixExpr | PostfixExpr
    rules.push(GLLRule {
        lhs: "AppExpr".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("AppExpr".to_string()),
            GLLSymbol::NonTerminal("PostfixExpr".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "AppExpr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("PostfixExpr".to_string())],
    });
    
    // PostfixExpr -> PostfixExpr . identifier | PostfixExpr ? | PrimaryExpr
    rules.push(GLLRule {
        lhs: "PostfixExpr".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("PostfixExpr".to_string()),
            GLLSymbol::Terminal(".".to_string()),
            GLLSymbol::Terminal("identifier".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "PostfixExpr".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("PostfixExpr".to_string()),
            GLLSymbol::Terminal("?".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "PostfixExpr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("PrimaryExpr".to_string())],
    });
    
    // PrimaryExpr -> Literal | identifier | Constructor | ( Expr ) | [ ListElements ] | { RecordFields } | Block
    rules.push(GLLRule {
        lhs: "PrimaryExpr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Literal".to_string())],
    });
    rules.push(GLLRule {
        lhs: "PrimaryExpr".to_string(),
        rhs: vec![GLLSymbol::Terminal("identifier".to_string())],
    });
    rules.push(GLLRule {
        lhs: "PrimaryExpr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Constructor".to_string())],
    });
    rules.push(GLLRule {
        lhs: "PrimaryExpr".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("(".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
            GLLSymbol::Terminal(")".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "PrimaryExpr".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("[".to_string()),
            GLLSymbol::NonTerminal("ListElements".to_string()),
            GLLSymbol::Terminal("]".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "PrimaryExpr".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("{".to_string()),
            GLLSymbol::NonTerminal("RecordFields".to_string()),
            GLLSymbol::Terminal("}".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "PrimaryExpr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Block".to_string())],
    });
    
    // Block -> { BlockStatements }
    rules.push(GLLRule {
        lhs: "Block".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("{".to_string()),
            GLLSymbol::NonTerminal("BlockStatements".to_string()),
            GLLSymbol::Terminal("}".to_string()),
        ],
    });
    
    // BlockStatements -> Statement BlockStatements | Expr | Statement
    rules.push(GLLRule {
        lhs: "BlockStatements".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Statement".to_string()),
            GLLSymbol::NonTerminal("BlockStatements".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "BlockStatements".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Expr".to_string())],
    });
    // Allow a single statement without following expression
    rules.push(GLLRule {
        lhs: "BlockStatements".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Statement".to_string())],
    });
    
    // Statement -> LetBinding | Pattern <- Expr
    rules.push(GLLRule {
        lhs: "Statement".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("LetBinding".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Statement".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Pattern".to_string()),
            GLLSymbol::Terminal("<-".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
        ],
    });
    
    // ========== Patterns ==========
    
    // Pattern -> identifier | Constructor Patterns | Literal | _ | [ ListPattern ] | ( Pattern ) | Pattern :: Pattern
    rules.push(GLLRule {
        lhs: "Pattern".to_string(),
        rhs: vec![GLLSymbol::Terminal("identifier".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Pattern".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Constructor".to_string()),
            GLLSymbol::NonTerminal("Patterns".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "Pattern".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Literal".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Pattern".to_string(),
        rhs: vec![GLLSymbol::Terminal("_".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Pattern".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("[".to_string()),
            GLLSymbol::NonTerminal("ListPattern".to_string()),
            GLLSymbol::Terminal("]".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "Pattern".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("(".to_string()),
            GLLSymbol::NonTerminal("Pattern".to_string()),
            GLLSymbol::Terminal(")".to_string()),
        ],
    });
    // Add cons pattern directly to Pattern
    rules.push(GLLRule {
        lhs: "Pattern".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Pattern".to_string()),
            GLLSymbol::Terminal("::".to_string()),
            GLLSymbol::NonTerminal("Pattern".to_string()),
        ],
    });
    
    // ListPattern -> Pattern :: Pattern | PatternList | ε
    rules.push(GLLRule {
        lhs: "ListPattern".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Pattern".to_string()),
            GLLSymbol::Terminal("::".to_string()),
            GLLSymbol::NonTerminal("Pattern".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "ListPattern".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("PatternList".to_string())],
    });
    rules.push(GLLRule {
        lhs: "ListPattern".to_string(),
        rhs: vec![GLLSymbol::Epsilon],
    });
    
    // ========== Type System ==========
    
    // Type -> TypeAtom | TypeAtom -> Type
    rules.push(GLLRule {
        lhs: "Type".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("TypeAtom".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Type".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("TypeAtom".to_string()),
            GLLSymbol::Terminal("->".to_string()),
            GLLSymbol::NonTerminal("Type".to_string()),
        ],
    });
    
    // TypeAtom -> type_identifier | type_identifier TypeArgs | ( Type ) | { RecordType }
    rules.push(GLLRule {
        lhs: "TypeAtom".to_string(),
        rhs: vec![GLLSymbol::Terminal("type_identifier".to_string())],
    });
    rules.push(GLLRule {
        lhs: "TypeAtom".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("type_identifier".to_string()),
            GLLSymbol::NonTerminal("TypeArgs".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "TypeAtom".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("(".to_string()),
            GLLSymbol::NonTerminal("Type".to_string()),
            GLLSymbol::Terminal(")".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "TypeAtom".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("{".to_string()),
            GLLSymbol::NonTerminal("RecordType".to_string()),
            GLLSymbol::Terminal("}".to_string()),
        ],
    });
    
    // TypeDef -> type type_identifier TypeParams = TypeBody
    rules.push(GLLRule {
        lhs: "TypeDef".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("type".to_string()),
            GLLSymbol::Terminal("type_identifier".to_string()),
            GLLSymbol::NonTerminal("TypeParams".to_string()),
            GLLSymbol::Terminal("=".to_string()),
            GLLSymbol::NonTerminal("TypeBody".to_string()),
        ],
    });
    
    // TypeBody -> Type | TypeConstructors
    rules.push(GLLRule {
        lhs: "TypeBody".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Type".to_string())],
    });
    rules.push(GLLRule {
        lhs: "TypeBody".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("TypeConstructors".to_string())],
    });
    
    // TypeConstructors -> | Constructor TypeArgs TypeConstructors | | Constructor TypeArgs
    rules.push(GLLRule {
        lhs: "TypeConstructors".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("|".to_string()),
            GLLSymbol::NonTerminal("Constructor".to_string()),
            GLLSymbol::NonTerminal("TypeArgs".to_string()),
            GLLSymbol::NonTerminal("TypeConstructors".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "TypeConstructors".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("|".to_string()),
            GLLSymbol::NonTerminal("Constructor".to_string()),
            GLLSymbol::NonTerminal("TypeArgs".to_string()),
        ],
    });
    
    // ========== Module System ==========
    
    // ModuleDef -> module ModulePath exposing ( ExportList ) where ModuleBody
    rules.push(GLLRule {
        lhs: "ModuleDef".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("module".to_string()),
            GLLSymbol::NonTerminal("ModulePath".to_string()),
            GLLSymbol::Terminal("exposing".to_string()),
            GLLSymbol::Terminal("(".to_string()),
            GLLSymbol::NonTerminal("ExportList".to_string()),
            GLLSymbol::Terminal(")".to_string()),
            GLLSymbol::Terminal("where".to_string()),
            GLLSymbol::NonTerminal("ModuleBody".to_string()),
        ],
    });
    
    // ImportDef -> import ModulePath ImportTail
    rules.push(GLLRule {
        lhs: "ImportDef".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("import".to_string()),
            GLLSymbol::NonTerminal("ModulePath".to_string()),
            GLLSymbol::NonTerminal("ImportTail".to_string()),
        ],
    });
    
    // ImportTail -> as identifier | ( ImportList ) | exposing ( ImportList ) | ε
    rules.push(GLLRule {
        lhs: "ImportTail".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("as".to_string()),
            GLLSymbol::Terminal("identifier".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "ImportTail".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("(".to_string()),
            GLLSymbol::NonTerminal("ImportList".to_string()),
            GLLSymbol::Terminal(")".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "ImportTail".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("exposing".to_string()),
            GLLSymbol::Terminal("(".to_string()),
            GLLSymbol::NonTerminal("ImportList".to_string()),
            GLLSymbol::Terminal(")".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "ImportTail".to_string(),
        rhs: vec![GLLSymbol::Epsilon],
    });
    
    // ========== Type Classes ==========
    
    // TypeClassDef -> type class type_identifier identifier where TypeClassBody
    rules.push(GLLRule {
        lhs: "TypeClassDef".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("type".to_string()),
            GLLSymbol::Terminal("class".to_string()),
            GLLSymbol::Terminal("type_identifier".to_string()),
            GLLSymbol::Terminal("identifier".to_string()),
            GLLSymbol::Terminal("where".to_string()),
            GLLSymbol::NonTerminal("TypeClassBody".to_string()),
        ],
    });
    
    // InstanceDef -> instance type_identifier Type where InstanceBody
    rules.push(GLLRule {
        lhs: "InstanceDef".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("instance".to_string()),
            GLLSymbol::Terminal("type_identifier".to_string()),
            GLLSymbol::NonTerminal("Type".to_string()),
            GLLSymbol::Terminal("where".to_string()),
            GLLSymbol::NonTerminal("InstanceBody".to_string()),
        ],
    });
    
    // ========== Effects (simplified) ==========
    
    // EffectDef -> effect type_identifier TypeParams where EffectBody
    rules.push(GLLRule {
        lhs: "EffectDef".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("effect".to_string()),
            GLLSymbol::Terminal("type_identifier".to_string()),
            GLLSymbol::NonTerminal("TypeParams".to_string()),
            GLLSymbol::Terminal("where".to_string()),
            GLLSymbol::NonTerminal("EffectBody".to_string()),
        ],
    });
    
    // ========== Common Rules ==========
    
    // Literal -> number | string | true | false
    rules.push(GLLRule {
        lhs: "Literal".to_string(),
        rhs: vec![GLLSymbol::Terminal("number".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Literal".to_string(),
        rhs: vec![GLLSymbol::Terminal("string".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Literal".to_string(),
        rhs: vec![GLLSymbol::Terminal("true".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Literal".to_string(),
        rhs: vec![GLLSymbol::Terminal("false".to_string())],
    });
    
    // Constructor -> type_identifier
    rules.push(GLLRule {
        lhs: "Constructor".to_string(),
        rhs: vec![GLLSymbol::Terminal("type_identifier".to_string())],
    });
    
    // ========== Helper Rules ==========
    
    // TypeParams -> identifier TypeParams | ε
    rules.push(GLLRule {
        lhs: "TypeParams".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("identifier".to_string()),
            GLLSymbol::NonTerminal("TypeParams".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "TypeParams".to_string(),
        rhs: vec![GLLSymbol::Epsilon],
    });
    
    // TypeArgs -> Type TypeArgs | Type | ε
    rules.push(GLLRule {
        lhs: "TypeArgs".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Type".to_string()),
            GLLSymbol::NonTerminal("TypeArgs".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "TypeArgs".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Type".to_string())],
    });
    rules.push(GLLRule {
        lhs: "TypeArgs".to_string(),
        rhs: vec![GLLSymbol::Epsilon],
    });
    
    // Patterns -> Pattern Patterns | ε
    rules.push(GLLRule {
        lhs: "Patterns".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Pattern".to_string()),
            GLLSymbol::NonTerminal("Patterns".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "Patterns".to_string(),
        rhs: vec![GLLSymbol::Epsilon],
    });
    
    // PatternList -> Pattern , PatternList | Pattern | ε
    rules.push(GLLRule {
        lhs: "PatternList".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Pattern".to_string()),
            GLLSymbol::Terminal(",".to_string()),
            GLLSymbol::NonTerminal("PatternList".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "PatternList".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Pattern".to_string())],
    });
    rules.push(GLLRule {
        lhs: "PatternList".to_string(),
        rhs: vec![GLLSymbol::Epsilon],
    });
    
    // ListElements -> Expr , ListElements | Expr | ε
    rules.push(GLLRule {
        lhs: "ListElements".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Expr".to_string()),
            GLLSymbol::Terminal(",".to_string()),
            GLLSymbol::NonTerminal("ListElements".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "ListElements".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Expr".to_string())],
    });
    rules.push(GLLRule {
        lhs: "ListElements".to_string(),
        rhs: vec![GLLSymbol::Epsilon],
    });
    
    // RecordFields -> RecordField , RecordFields | RecordField | ε
    rules.push(GLLRule {
        lhs: "RecordFields".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("RecordField".to_string()),
            GLLSymbol::Terminal(",".to_string()),
            GLLSymbol::NonTerminal("RecordFields".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "RecordFields".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("RecordField".to_string())],
    });
    rules.push(GLLRule {
        lhs: "RecordFields".to_string(),
        rhs: vec![GLLSymbol::Epsilon],
    });
    
    // RecordField -> identifier : Expr
    rules.push(GLLRule {
        lhs: "RecordField".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("identifier".to_string()),
            GLLSymbol::Terminal(":".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
        ],
    });
    
    // RecordType -> RecordTypeField , RecordType | RecordTypeField | ε
    rules.push(GLLRule {
        lhs: "RecordType".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("RecordTypeField".to_string()),
            GLLSymbol::Terminal(",".to_string()),
            GLLSymbol::NonTerminal("RecordType".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "RecordType".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("RecordTypeField".to_string())],
    });
    rules.push(GLLRule {
        lhs: "RecordType".to_string(),
        rhs: vec![GLLSymbol::Epsilon],
    });
    
    // RecordTypeField -> identifier : Type
    rules.push(GLLRule {
        lhs: "RecordTypeField".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("identifier".to_string()),
            GLLSymbol::Terminal(":".to_string()),
            GLLSymbol::NonTerminal("Type".to_string()),
        ],
    });
    
    // ModulePath -> type_identifier . ModulePath | type_identifier
    rules.push(GLLRule {
        lhs: "ModulePath".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("type_identifier".to_string()),
            GLLSymbol::Terminal(".".to_string()),
            GLLSymbol::NonTerminal("ModulePath".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "ModulePath".to_string(),
        rhs: vec![GLLSymbol::Terminal("type_identifier".to_string())],
    });
    
    // ExportList -> ImportList
    rules.push(GLLRule {
        lhs: "ExportList".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("ImportList".to_string())],
    });
    
    // ImportList -> identifier , ImportList | identifier | ( .. ) | ..
    rules.push(GLLRule {
        lhs: "ImportList".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("identifier".to_string()),
            GLLSymbol::Terminal(",".to_string()),
            GLLSymbol::NonTerminal("ImportList".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "ImportList".to_string(),
        rhs: vec![GLLSymbol::Terminal("identifier".to_string())],
    });
    rules.push(GLLRule {
        lhs: "ImportList".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("(".to_string()),
            GLLSymbol::Terminal("..".to_string()),
            GLLSymbol::Terminal(")".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "ImportList".to_string(),
        rhs: vec![GLLSymbol::Terminal("..".to_string())],
    });
    
    // ModuleBody -> TopLevelDef ModuleBody | TopLevelDef | ε
    rules.push(GLLRule {
        lhs: "ModuleBody".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("TopLevelDef".to_string()),
            GLLSymbol::NonTerminal("ModuleBody".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "ModuleBody".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("TopLevelDef".to_string())],
    });
    rules.push(GLLRule {
        lhs: "ModuleBody".to_string(),
        rhs: vec![GLLSymbol::Epsilon],
    });
    
    // TypeClassBody -> TypeSignature TypeClassBody | TypeSignature | ε
    rules.push(GLLRule {
        lhs: "TypeClassBody".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("TypeSignature".to_string()),
            GLLSymbol::NonTerminal("TypeClassBody".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "TypeClassBody".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("TypeSignature".to_string())],
    });
    rules.push(GLLRule {
        lhs: "TypeClassBody".to_string(),
        rhs: vec![GLLSymbol::Epsilon],
    });
    
    // TypeSignature -> identifier : Type
    rules.push(GLLRule {
        lhs: "TypeSignature".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("identifier".to_string()),
            GLLSymbol::Terminal(":".to_string()),
            GLLSymbol::NonTerminal("Type".to_string()),
        ],
    });
    
    // InstanceBody -> LetBinding InstanceBody | LetBinding | ε
    rules.push(GLLRule {
        lhs: "InstanceBody".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("LetBinding".to_string()),
            GLLSymbol::NonTerminal("InstanceBody".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "InstanceBody".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("LetBinding".to_string())],
    });
    rules.push(GLLRule {
        lhs: "InstanceBody".to_string(),
        rhs: vec![GLLSymbol::Epsilon],
    });
    
    // EffectBody -> TypeSignature EffectBody | TypeSignature | ε
    rules.push(GLLRule {
        lhs: "EffectBody".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("TypeSignature".to_string()),
            GLLSymbol::NonTerminal("EffectBody".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "EffectBody".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("TypeSignature".to_string())],
    });
    rules.push(GLLRule {
        lhs: "EffectBody".to_string(),
        rhs: vec![GLLSymbol::Epsilon],
    });
    
    GLLGrammar::new(rules, "Program".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::experimental::gll::GLLParser;
    
    #[test]
    fn test_unified_let_binding() {
        let grammar = create_unified_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test: let x = 42
        let input = vec![
            "let".to_string(),
            "identifier".to_string(),
            "=".to_string(),
            "number".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
    
    #[test]
    fn test_unified_function_definition() {
        let grammar = create_unified_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test: let add x y = x + y
        let input = vec![
            "let".to_string(),
            "identifier".to_string(),
            "identifier".to_string(),
            "identifier".to_string(),
            "=".to_string(),
            "identifier".to_string(),
            "+".to_string(),
            "identifier".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
    
    #[test]
    fn test_unified_case_expression() {
        let grammar = create_unified_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test: case x of | [] -> 0
        let input = vec![
            "case".to_string(),
            "identifier".to_string(),
            "of".to_string(),
            "|".to_string(),
            "[".to_string(),
            "]".to_string(),
            "->".to_string(),
            "number".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
    
    #[test]
    fn test_unified_if_then_else() {
        let grammar = create_unified_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test: if x then y else z
        let input = vec![
            "if".to_string(),
            "identifier".to_string(),
            "then".to_string(),
            "identifier".to_string(),
            "else".to_string(),
            "identifier".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
    
    #[test]
    fn test_unified_pipeline() {
        let grammar = create_unified_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test: x |> f |> g
        let input = vec![
            "identifier".to_string(),
            "|>".to_string(),
            "identifier".to_string(),
            "|>".to_string(),
            "identifier".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
    
    #[test]
    fn test_unified_lambda() {
        let grammar = create_unified_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test: \x y -> x + y
        let input = vec![
            "\\".to_string(),
            "identifier".to_string(),
            "identifier".to_string(),
            "->".to_string(),
            "identifier".to_string(),
            "+".to_string(),
            "identifier".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
    
    #[test]
    fn test_unified_mutual_recursion() {
        let grammar = create_unified_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test: let f x = g x and g x = f x
        let input = vec![
            "let".to_string(),
            "identifier".to_string(),
            "identifier".to_string(),
            "=".to_string(),
            "identifier".to_string(),
            "identifier".to_string(),
            "and".to_string(),
            "identifier".to_string(),
            "identifier".to_string(),
            "=".to_string(),
            "identifier".to_string(),
            "identifier".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
    
    #[test]
    fn test_unified_block_expression() {
        let grammar = create_unified_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test simpler case first: { 1 + 2 }
        let input = vec![
            "{".to_string(),
            "number".to_string(),
            "+".to_string(),
            "number".to_string(),
            "}".to_string(),
        ];
        
        let result = parser.parse_with_errors(input.clone());
        match result {
            Ok(_) => {
                println!("Simple block expression parsed successfully");
            },
            Err(e) => {
                eprintln!("Parse error in simple block expression:");
                eprintln!("{}", e.to_ai_json());
                panic!("Parse failed");
            }
        }
        
        // Now test with let binding - try wrapping in let-in expression
        // Test: { let x = 10 in x + 1 }
        let input2 = vec![
            "{".to_string(),
            "let".to_string(),
            "identifier".to_string(),
            "=".to_string(),
            "number".to_string(),
            "in".to_string(),
            "identifier".to_string(),
            "+".to_string(),
            "number".to_string(),
            "}".to_string(),
        ];
        
        let result2 = parser.parse_with_errors(input2);
        match result2 {
            Ok(_) => {},
            Err(e) => {
                eprintln!("Parse error in test_unified_block_expression with let-in:");
                eprintln!("{}", e.to_ai_json());
                panic!("Parse failed with let-in");
            }
        }
    }
    
    #[test]
    fn test_unified_record_literal() {
        let grammar = create_unified_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test: { name: "Alice", age: 30 }
        let input = vec![
            "{".to_string(),
            "identifier".to_string(),
            ":".to_string(),
            "string".to_string(),
            ",".to_string(),
            "identifier".to_string(),
            ":".to_string(),
            "number".to_string(),
            "}".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
    
    #[test]
    fn test_unified_type_definition() {
        let grammar = create_unified_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test: type Option a = | None | Some a
        let input = vec![
            "type".to_string(),
            "type_identifier".to_string(),
            "identifier".to_string(),
            "=".to_string(),
            "|".to_string(),
            "type_identifier".to_string(),
            "|".to_string(),
            "type_identifier".to_string(),
            "identifier".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
    
    #[test]
    fn test_unified_do_expression() {
        let grammar = create_unified_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // First test simpler do expression: do { identifier }
        let simple_input = vec![
            "do".to_string(),
            "{".to_string(),
            "identifier".to_string(),
            "}".to_string(),
        ];
        
        let result = parser.parse_with_errors(simple_input);
        match result {
            Ok(_) => {
                println!("Simple do expression parsed successfully");
            },
            Err(e) => {
                eprintln!("Parse error in simple do expression:");
                eprintln!("{}", e.to_ai_json());
                panic!("Simple do expression failed");
            }
        }
        
        // Test with bind: do { x <- readInt }
        let bind_input = vec![
            "do".to_string(),
            "{".to_string(),
            "identifier".to_string(),
            "<-".to_string(),
            "identifier".to_string(),
            "}".to_string(),
        ];
        
        let result2 = parser.parse_with_errors(bind_input);
        match result2 {
            Ok(_) => {
                println!("Do expression with bind parsed successfully");
            },
            Err(e) => {
                eprintln!("Parse error in do expression with bind:");
                eprintln!("{}", e.to_ai_json());
                // Don't panic, continue to next test
            }
        }
        
        // Original test: do { x <- readInt return x + 1 }
        // Note: 'return' is being treated as identifier here
        let input = vec![
            "do".to_string(),
            "{".to_string(),
            "identifier".to_string(),
            "<-".to_string(),
            "identifier".to_string(),
            "identifier".to_string(),
            "identifier".to_string(),
            "+".to_string(),
            "number".to_string(),
            "}".to_string(),
        ];
        
        let result3 = parser.parse_with_errors(input);
        match result3 {
            Ok(_) => {},
            Err(e) => {
                eprintln!("Parse error in full do expression:");
                eprintln!("{}", e.to_ai_json());
                panic!("Full do expression failed");
            }
        }
    }
    
    #[test]
    fn test_unified_field_access() {
        let grammar = create_unified_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test: person.name
        let input = vec![
            "identifier".to_string(),
            ".".to_string(),
            "identifier".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
    
    #[test]
    fn test_unified_function_type() {
        let grammar = create_unified_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test: let f (x: Int) (y: Int) -> Int = x + y
        let input = vec![
            "let".to_string(),
            "identifier".to_string(),
            "(".to_string(),
            "identifier".to_string(),
            ":".to_string(),
            "type_identifier".to_string(),
            ")".to_string(),
            "(".to_string(),
            "identifier".to_string(),
            ":".to_string(),
            "type_identifier".to_string(),
            ")".to_string(),
            "->".to_string(),
            "type_identifier".to_string(),
            "=".to_string(),
            "identifier".to_string(),
            "+".to_string(),
            "identifier".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
    
    #[test]
    fn test_unified_list_pattern() {
        let grammar = create_unified_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // First test simple identifier
        let simple_input = vec![
            "identifier".to_string(),
        ];
        
        let result = parser.parse_with_errors(simple_input);
        match result {
            Ok(_) => {
                println!("Simple identifier parsed successfully");
            },
            Err(e) => {
                eprintln!("Parse error in simple identifier:");
                eprintln!("{}", e.to_ai_json());
                // Continue testing
            }
        }
        
        // Test simple case expression: case x of | y -> z
        let simple_case = vec![
            "case".to_string(),
            "identifier".to_string(),
            "of".to_string(),
            "|".to_string(),
            "identifier".to_string(),
            "->".to_string(),
            "identifier".to_string(),
        ];
        
        let result2 = parser.parse_with_errors(simple_case);
        match result2 {
            Ok(_) => {
                println!("Simple case expression parsed successfully");
            },
            Err(e) => {
                eprintln!("Parse error in simple case expression:");
                eprintln!("{}", e.to_ai_json());
                // Continue testing
            }
        }
        
        // Original test: case xs of | h :: t -> h
        let input = vec![
            "case".to_string(),
            "identifier".to_string(),
            "of".to_string(),
            "|".to_string(),
            "identifier".to_string(),
            "::".to_string(),
            "identifier".to_string(),
            "->".to_string(),
            "identifier".to_string(),
        ];
        
        let result3 = parser.parse_with_errors(input);
        match result3 {
            Ok(_) => {},
            Err(e) => {
                eprintln!("Parse error in list pattern:");
                eprintln!("{}", e.to_ai_json());
                panic!("List pattern parse failed");
            }
        }
    }
    
    #[test]
    fn test_unified_module_definition() {
        let grammar = create_unified_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test: module Data.List exposing (map, filter) where let map f xs = xs
        let input = vec![
            "module".to_string(),
            "type_identifier".to_string(),
            ".".to_string(),
            "type_identifier".to_string(),
            "exposing".to_string(),
            "(".to_string(),
            "identifier".to_string(),
            ",".to_string(),
            "identifier".to_string(),
            ")".to_string(),
            "where".to_string(),
            "let".to_string(),
            "identifier".to_string(),
            "identifier".to_string(),
            "identifier".to_string(),
            "=".to_string(),
            "identifier".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
    
    #[test]
    fn test_unified_complex_expression() {
        let grammar = create_unified_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test: [1, 2, 3] |> map (\x -> x * 2) |> filter (\x -> x > 2)
        let input = vec![
            "[".to_string(),
            "number".to_string(),
            ",".to_string(),
            "number".to_string(),
            ",".to_string(),
            "number".to_string(),
            "]".to_string(),
            "|>".to_string(),
            "identifier".to_string(),
            "(".to_string(),
            "\\".to_string(),
            "identifier".to_string(),
            "->".to_string(),
            "identifier".to_string(),
            "*".to_string(),
            "number".to_string(),
            ")".to_string(),
            "|>".to_string(),
            "identifier".to_string(),
            "(".to_string(),
            "\\".to_string(),
            "identifier".to_string(),
            "->".to_string(),
            "identifier".to_string(),
            ">".to_string(),
            "number".to_string(),
            ")".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
}