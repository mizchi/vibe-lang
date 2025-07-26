use super::gll::{GLLGrammar, GLLRule, GLLSymbol};

/// Create the Vibe language grammar for GLL parsing
pub fn create_vibe_grammar() -> GLLGrammar {
    let mut rules = Vec::new();
    
    // Program -> TopLevel Program | ε
    rules.push(GLLRule {
        lhs: "Program".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("TopLevel".to_string()),
            GLLSymbol::NonTerminal("Program".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "Program".to_string(),
        rhs: vec![GLLSymbol::Epsilon],
    });
    
    // TopLevel -> LetDef | TypeDef | ModuleDef | ImportDef | Expr
    rules.push(GLLRule {
        lhs: "TopLevel".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("LetDef".to_string())],
    });
    rules.push(GLLRule {
        lhs: "TopLevel".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("TypeDef".to_string())],
    });
    rules.push(GLLRule {
        lhs: "TopLevel".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("ModuleDef".to_string())],
    });
    rules.push(GLLRule {
        lhs: "TopLevel".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("ImportDef".to_string())],
    });
    rules.push(GLLRule {
        lhs: "TopLevel".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Expr".to_string())],
    });
    
    // LetDef -> let Ident = Expr
    rules.push(GLLRule {
        lhs: "LetDef".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("let".to_string()),
            GLLSymbol::NonTerminal("Ident".to_string()),
            GLLSymbol::Terminal("=".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
        ],
    });
    
    // LetDef -> let Ident : Type = Expr  (with type annotation)
    rules.push(GLLRule {
        lhs: "LetDef".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("let".to_string()),
            GLLSymbol::NonTerminal("Ident".to_string()),
            GLLSymbol::Terminal(":".to_string()),
            GLLSymbol::NonTerminal("Type".to_string()),
            GLLSymbol::Terminal("=".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
        ],
    });
    
    // RecDef -> rec Ident Params = Expr
    rules.push(GLLRule {
        lhs: "RecDef".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("rec".to_string()),
            GLLSymbol::NonTerminal("Ident".to_string()),
            GLLSymbol::NonTerminal("Params".to_string()),
            GLLSymbol::Terminal("=".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
        ],
    });
    
    // ImportDef -> import ModulePath
    rules.push(GLLRule {
        lhs: "ImportDef".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("import".to_string()),
            GLLSymbol::NonTerminal("ModulePath".to_string()),
        ],
    });
    
    // ImportDef -> import ModulePath as Ident
    rules.push(GLLRule {
        lhs: "ImportDef".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("import".to_string()),
            GLLSymbol::NonTerminal("ModulePath".to_string()),
            GLLSymbol::Terminal("as".to_string()),
            GLLSymbol::NonTerminal("Ident".to_string()),
        ],
    });
    
    // TypeDef -> type TypeName TypeParams = TypeConstructors
    rules.push(GLLRule {
        lhs: "TypeDef".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("type".to_string()),
            GLLSymbol::NonTerminal("TypeName".to_string()),
            GLLSymbol::NonTerminal("TypeParams".to_string()),
            GLLSymbol::Terminal("=".to_string()),
            GLLSymbol::NonTerminal("TypeConstructors".to_string()),
        ],
    });
    
    // TypeConstructors -> | Constructor TypeConstructors'
    rules.push(GLLRule {
        lhs: "TypeConstructors".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("|".to_string()),
            GLLSymbol::NonTerminal("Constructor".to_string()),
            GLLSymbol::NonTerminal("TypeConstructors'".to_string()),
        ],
    });
    
    // TypeConstructors' -> | Constructor TypeConstructors' | ε
    rules.push(GLLRule {
        lhs: "TypeConstructors'".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("|".to_string()),
            GLLSymbol::NonTerminal("Constructor".to_string()),
            GLLSymbol::NonTerminal("TypeConstructors'".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "TypeConstructors'".to_string(),
        rhs: vec![GLLSymbol::Epsilon],
    });
    
    // Constructor -> TypeName Type*
    rules.push(GLLRule {
        lhs: "Constructor".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("TypeName".to_string()),
            GLLSymbol::NonTerminal("Types".to_string()),
        ],
    });
    
    // Constructor -> TypeName
    rules.push(GLLRule {
        lhs: "Constructor".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("TypeName".to_string())],
    });
    
    // Types -> Type Types | ε
    rules.push(GLLRule {
        lhs: "Types".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Type".to_string()),
            GLLSymbol::NonTerminal("Types".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "Types".to_string(),
        rhs: vec![GLLSymbol::Epsilon],
    });
    
    // Expr -> MatchExpr | IfExpr | LetInExpr | FnExpr | WithExpr | DoExpr | HandleExpr | AppExpr
    rules.push(GLLRule {
        lhs: "Expr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("MatchExpr".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Expr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("IfExpr".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Expr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("LetInExpr".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Expr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("FnExpr".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Expr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("WithExpr".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Expr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("DoExpr".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Expr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("HandleExpr".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Expr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("AppExpr".to_string())],
    });
    
    // MatchExpr -> match Expr { MatchCases }
    rules.push(GLLRule {
        lhs: "MatchExpr".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("match".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
            GLLSymbol::Terminal("{".to_string()),
            GLLSymbol::NonTerminal("MatchCases".to_string()),
            GLLSymbol::Terminal("}".to_string()),
        ],
    });
    
    // MatchCases -> MatchCase MatchCases | MatchCase
    rules.push(GLLRule {
        lhs: "MatchCases".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("MatchCase".to_string()),
            GLLSymbol::NonTerminal("MatchCases".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "MatchCases".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("MatchCase".to_string())],
    });
    
    // MatchCase -> Pattern -> Expr
    rules.push(GLLRule {
        lhs: "MatchCase".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Pattern".to_string()),
            GLLSymbol::Terminal("->".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
        ],
    });
    
    // Pattern -> Ident | Literal | [] | [Pattern, ...] | Pattern :: Pattern | _
    rules.push(GLLRule {
        lhs: "Pattern".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Ident".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Pattern".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Literal".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Pattern".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("[".to_string()),
            GLLSymbol::Terminal("]".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "Pattern".to_string(),
        rhs: vec![GLLSymbol::Terminal("_".to_string())],
    });
    
    // Pattern -> Pattern :: Pattern (cons pattern)
    rules.push(GLLRule {
        lhs: "Pattern".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Pattern".to_string()),
            GLLSymbol::Terminal("::".to_string()),
            GLLSymbol::NonTerminal("Pattern".to_string()),
        ],
    });
    
    // IfExpr -> if Expr { Expr } else { Expr }
    rules.push(GLLRule {
        lhs: "IfExpr".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("if".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
            GLLSymbol::Terminal("{".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
            GLLSymbol::Terminal("}".to_string()),
            GLLSymbol::Terminal("else".to_string()),
            GLLSymbol::Terminal("{".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
            GLLSymbol::Terminal("}".to_string()),
        ],
    });
    
    // LetInExpr -> let Ident = Expr in Expr
    rules.push(GLLRule {
        lhs: "LetInExpr".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("let".to_string()),
            GLLSymbol::NonTerminal("Ident".to_string()),
            GLLSymbol::Terminal("=".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
            GLLSymbol::Terminal("in".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
        ],
    });
    
    // FnExpr -> fn Params -> Expr
    rules.push(GLLRule {
        lhs: "FnExpr".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("fn".to_string()),
            GLLSymbol::NonTerminal("Params".to_string()),
            GLLSymbol::Terminal("->".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
        ],
    });
    
    // WithExpr -> with Handler { Expr }
    rules.push(GLLRule {
        lhs: "WithExpr".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("with".to_string()),
            GLLSymbol::NonTerminal("Handler".to_string()),
            GLLSymbol::Terminal("{".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
            GLLSymbol::Terminal("}".to_string()),
        ],
    });
    
    // DoExpr -> do { DoStatements }
    rules.push(GLLRule {
        lhs: "DoExpr".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("do".to_string()),
            GLLSymbol::Terminal("{".to_string()),
            GLLSymbol::NonTerminal("DoStatements".to_string()),
            GLLSymbol::Terminal("}".to_string()),
        ],
    });
    
    // DoStatements -> DoStatement ; DoStatements | DoStatement
    rules.push(GLLRule {
        lhs: "DoStatements".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("DoStatement".to_string()),
            GLLSymbol::Terminal(";".to_string()),
            GLLSymbol::NonTerminal("DoStatements".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "DoStatements".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("DoStatement".to_string())],
    });
    
    // DoStatement -> Ident <- Expr | Expr
    rules.push(GLLRule {
        lhs: "DoStatement".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Ident".to_string()),
            GLLSymbol::Terminal("<-".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "DoStatement".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Expr".to_string())],
    });
    
    // HandleExpr -> handle { Expr } { HandlerCases }
    rules.push(GLLRule {
        lhs: "HandleExpr".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("handle".to_string()),
            GLLSymbol::Terminal("{".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
            GLLSymbol::Terminal("}".to_string()),
            GLLSymbol::Terminal("{".to_string()),
            GLLSymbol::NonTerminal("HandlerCases".to_string()),
            GLLSymbol::Terminal("}".to_string()),
        ],
    });
    
    // HandleExpr -> handle { Expr } { }  (empty handlers for testing)
    rules.push(GLLRule {
        lhs: "HandleExpr".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("handle".to_string()),
            GLLSymbol::Terminal("{".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
            GLLSymbol::Terminal("}".to_string()),
            GLLSymbol::Terminal("{".to_string()),
            GLLSymbol::Terminal("}".to_string()),
        ],
    });
    
    // HandlerCases -> HandlerCase HandlerCases | HandlerCase
    rules.push(GLLRule {
        lhs: "HandlerCases".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("HandlerCase".to_string()),
            GLLSymbol::NonTerminal("HandlerCases".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "HandlerCases".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("HandlerCase".to_string())],
    });
    
    // HandlerCase -> EffectOp HandlerParams -> Expr
    rules.push(GLLRule {
        lhs: "HandlerCase".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("EffectOp".to_string()),
            GLLSymbol::NonTerminal("HandlerParams".to_string()),
            GLLSymbol::Terminal("->".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
        ],
    });
    
    // HandlerParams -> Ident HandlerParams | Ident | ε
    rules.push(GLLRule {
        lhs: "HandlerParams".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Ident".to_string()),
            GLLSymbol::NonTerminal("HandlerParams".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "HandlerParams".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Ident".to_string())],
    });
    rules.push(GLLRule {
        lhs: "HandlerParams".to_string(),
        rhs: vec![GLLSymbol::Epsilon],
    });
    
    // EffectOp -> Ident . Ident
    rules.push(GLLRule {
        lhs: "EffectOp".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Ident".to_string()),
            GLLSymbol::Terminal(".".to_string()),
            GLLSymbol::NonTerminal("Ident".to_string()),
        ],
    });
    // EffectOp -> TypeName . Ident (for type names like IO)
    rules.push(GLLRule {
        lhs: "EffectOp".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("TypeName".to_string()),
            GLLSymbol::Terminal(".".to_string()),
            GLLSymbol::NonTerminal("Ident".to_string()),
        ],
    });
    
    // Handler -> Ident | { HandlerFields }
    rules.push(GLLRule {
        lhs: "Handler".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Ident".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Handler".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("{".to_string()),
            GLLSymbol::NonTerminal("HandlerFields".to_string()),
            GLLSymbol::Terminal("}".to_string()),
        ],
    });
    
    // HandlerFields -> HandlerField , HandlerFields | HandlerField | ε
    rules.push(GLLRule {
        lhs: "HandlerFields".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("HandlerField".to_string()),
            GLLSymbol::Terminal(",".to_string()),
            GLLSymbol::NonTerminal("HandlerFields".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "HandlerFields".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("HandlerField".to_string())],
    });
    rules.push(GLLRule {
        lhs: "HandlerFields".to_string(),
        rhs: vec![GLLSymbol::Epsilon],
    });
    
    // HandlerField -> EffectOp : Expr
    rules.push(GLLRule {
        lhs: "HandlerField".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("EffectOp".to_string()),
            GLLSymbol::Terminal(":".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
        ],
    });
    
    // Params -> Ident Params | Ident | ε
    rules.push(GLLRule {
        lhs: "Params".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Ident".to_string()),
            GLLSymbol::NonTerminal("Params".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "Params".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Ident".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Params".to_string(),
        rhs: vec![GLLSymbol::Epsilon],
    });
    
    // AppExpr -> InfixExpr
    rules.push(GLLRule {
        lhs: "AppExpr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("InfixExpr".to_string())],
    });
    
    // InfixExpr -> InfixExpr $ InfixExpr (right associative)
    rules.push(GLLRule {
        lhs: "InfixExpr".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("InfixExpr".to_string()),
            GLLSymbol::Terminal("$".to_string()),
            GLLSymbol::NonTerminal("InfixExpr".to_string()),
        ],
    });
    
    // InfixExpr -> InfixExpr + PrimaryExpr | InfixExpr - PrimaryExpr | ...
    rules.push(GLLRule {
        lhs: "InfixExpr".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("InfixExpr".to_string()),
            GLLSymbol::Terminal("+".to_string()),
            GLLSymbol::NonTerminal("PrimaryExpr".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "InfixExpr".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("InfixExpr".to_string()),
            GLLSymbol::Terminal("-".to_string()),
            GLLSymbol::NonTerminal("PrimaryExpr".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "InfixExpr".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("InfixExpr".to_string()),
            GLLSymbol::Terminal("*".to_string()),
            GLLSymbol::NonTerminal("PrimaryExpr".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "InfixExpr".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("InfixExpr".to_string()),
            GLLSymbol::Terminal("/".to_string()),
            GLLSymbol::NonTerminal("PrimaryExpr".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "InfixExpr".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("InfixExpr".to_string()),
            GLLSymbol::Terminal("==".to_string()),
            GLLSymbol::NonTerminal("PrimaryExpr".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "InfixExpr".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("InfixExpr".to_string()),
            GLLSymbol::Terminal("<".to_string()),
            GLLSymbol::NonTerminal("PrimaryExpr".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "InfixExpr".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("InfixExpr".to_string()),
            GLLSymbol::Terminal(">".to_string()),
            GLLSymbol::NonTerminal("PrimaryExpr".to_string()),
        ],
    });
    
    // InfixExpr -> PrimaryExpr
    rules.push(GLLRule {
        lhs: "InfixExpr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("PrimaryExpr".to_string())],
    });
    
    // PrimaryExpr -> FunctionCall | AtomExpr
    rules.push(GLLRule {
        lhs: "PrimaryExpr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("FunctionCall".to_string())],
    });
    rules.push(GLLRule {
        lhs: "PrimaryExpr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("AtomExpr".to_string())],
    });
    
    // FunctionCall -> AtomExpr AtomExpr+
    rules.push(GLLRule {
        lhs: "FunctionCall".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("AtomExpr".to_string()),
            GLLSymbol::NonTerminal("AtomExprs".to_string()),
        ],
    });
    
    // AtomExprs -> AtomExpr AtomExprs | AtomExpr
    rules.push(GLLRule {
        lhs: "AtomExprs".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("AtomExpr".to_string()),
            GLLSymbol::NonTerminal("AtomExprs".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "AtomExprs".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("AtomExpr".to_string())],
    });
    
    // AtomExpr -> Ident | Literal | ( Expr ) | { RecordFields } | [ ListElements ] | PerformExpr
    rules.push(GLLRule {
        lhs: "AtomExpr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Ident".to_string())],
    });
    rules.push(GLLRule {
        lhs: "AtomExpr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Literal".to_string())],
    });
    rules.push(GLLRule {
        lhs: "AtomExpr".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("(".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
            GLLSymbol::Terminal(")".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "AtomExpr".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("{".to_string()),
            GLLSymbol::NonTerminal("RecordFields".to_string()),
            GLLSymbol::Terminal("}".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "AtomExpr".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("[".to_string()),
            GLLSymbol::NonTerminal("ListElements".to_string()),
            GLLSymbol::Terminal("]".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "AtomExpr".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("[".to_string()),
            GLLSymbol::Terminal("]".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "AtomExpr".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("PerformExpr".to_string())],
    });
    
    // PerformExpr -> perform EffectOp AtomExprs
    rules.push(GLLRule {
        lhs: "PerformExpr".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("perform".to_string()),
            GLLSymbol::NonTerminal("EffectOp".to_string()),
            GLLSymbol::NonTerminal("AtomExprs".to_string()),
        ],
    });
    
    // PerformExpr -> perform EffectOp  (no args)
    rules.push(GLLRule {
        lhs: "PerformExpr".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("perform".to_string()),
            GLLSymbol::NonTerminal("EffectOp".to_string()),
        ],
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
    
    // RecordField -> Ident : Expr
    rules.push(GLLRule {
        lhs: "RecordField".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Ident".to_string()),
            GLLSymbol::Terminal(":".to_string()),
            GLLSymbol::NonTerminal("Expr".to_string()),
        ],
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
    
    // Type -> TypeName | Type -> Type | ( Type )
    rules.push(GLLRule {
        lhs: "Type".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("TypeName".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Type".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Type".to_string()),
            GLLSymbol::Terminal("->".to_string()),
            GLLSymbol::NonTerminal("Type".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "Type".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("(".to_string()),
            GLLSymbol::NonTerminal("Type".to_string()),
            GLLSymbol::Terminal(")".to_string()),
        ],
    });
    
    // TypeParams -> TypeParam TypeParams | ε
    rules.push(GLLRule {
        lhs: "TypeParams".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("TypeParam".to_string()),
            GLLSymbol::NonTerminal("TypeParams".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "TypeParams".to_string(),
        rhs: vec![GLLSymbol::Epsilon],
    });
    
    // TypeParam -> identifier (lowercase)
    rules.push(GLLRule {
        lhs: "TypeParam".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Ident".to_string())],
    });
    
    // ModulePath -> Ident . ModulePath | Ident
    rules.push(GLLRule {
        lhs: "ModulePath".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Ident".to_string()),
            GLLSymbol::Terminal(".".to_string()),
            GLLSymbol::NonTerminal("ModulePath".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "ModulePath".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Ident".to_string())],
    });
    
    // ModuleDef -> module Ident { ModuleBody }
    rules.push(GLLRule {
        lhs: "ModuleDef".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("module".to_string()),
            GLLSymbol::NonTerminal("Ident".to_string()),
            GLLSymbol::Terminal("{".to_string()),
            GLLSymbol::NonTerminal("ModuleBody".to_string()),
            GLLSymbol::Terminal("}".to_string()),
        ],
    });
    
    // ModuleBody -> export ExportList TopLevel* | TopLevel*
    rules.push(GLLRule {
        lhs: "ModuleBody".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("export".to_string()),
            GLLSymbol::NonTerminal("ExportList".to_string()),
            GLLSymbol::NonTerminal("TopLevels".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "ModuleBody".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("TopLevels".to_string())],
    });
    
    // TopLevels -> TopLevel TopLevels | ε
    rules.push(GLLRule {
        lhs: "TopLevels".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("TopLevel".to_string()),
            GLLSymbol::NonTerminal("TopLevels".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "TopLevels".to_string(),
        rhs: vec![GLLSymbol::Epsilon],
    });
    
    // ExportList -> Ident , ExportList | Ident
    rules.push(GLLRule {
        lhs: "ExportList".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Ident".to_string()),
            GLLSymbol::Terminal(",".to_string()),
            GLLSymbol::NonTerminal("ExportList".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "ExportList".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Ident".to_string())],
    });
    
    // Terminal symbols (simplified - these would be handled by lexer)
    // Ident -> identifier
    rules.push(GLLRule {
        lhs: "Ident".to_string(),
        rhs: vec![GLLSymbol::Terminal("identifier".to_string())],
    });
    
    // TypeName -> type_identifier
    rules.push(GLLRule {
        lhs: "TypeName".to_string(),
        rhs: vec![GLLSymbol::Terminal("type_identifier".to_string())],
    });
    
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
    
    GLLGrammar::new(rules, "Program".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::experimental::gll::GLLParser;
    
    #[test]
    fn test_simple_let_binding() {
        let grammar = create_vibe_grammar();
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
    fn test_function_definition() {
        let grammar = create_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test: let add = fn x y -> x + y
        let input = vec![
            "let".to_string(),
            "identifier".to_string(),
            "=".to_string(),
            "fn".to_string(),
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
    fn test_match_expression() {
        let grammar = create_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test: match x { [] -> 0 }
        let input = vec![
            "match".to_string(),
            "identifier".to_string(),
            "{".to_string(),
            "[".to_string(),
            "]".to_string(),
            "->".to_string(),
            "number".to_string(),
            "}".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
    
    #[test]
    fn test_type_definition() {
        let grammar = create_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test: type Option a = | None | Some a
        let input = vec![
            "type".to_string(),
            "type_identifier".to_string(),
            "identifier".to_string(), // type parameter 'a'
            "=".to_string(),
            "|".to_string(),
            "type_identifier".to_string(), // None
            "|".to_string(),
            "type_identifier".to_string(), // Some
            "identifier".to_string(), // a
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
    
    #[test]
    fn test_dollar_operator() {
        let grammar = create_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test: print $ 1 + 2
        let input = vec![
            "identifier".to_string(), // print
            "$".to_string(),
            "number".to_string(), // 1
            "+".to_string(),
            "number".to_string(), // 2
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
    
    #[test]
    fn test_let_in_expression() {
        let grammar = create_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test: let x = 10 in x + 5
        let input = vec![
            "let".to_string(),
            "identifier".to_string(), // x
            "=".to_string(),
            "number".to_string(), // 10
            "in".to_string(),
            "identifier".to_string(), // x
            "+".to_string(),
            "number".to_string(), // 5
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
    
    #[test]
    fn test_with_handler_expression() {
        let grammar = create_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test: with stateHandler { perform State.get }
        let input = vec![
            "with".to_string(),
            "identifier".to_string(), // stateHandler
            "{".to_string(),
            "perform".to_string(),
            "identifier".to_string(), // State
            ".".to_string(),
            "identifier".to_string(), // get
            "}".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
    
    #[test]
    fn test_with_inline_handler() {
        let grammar = create_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test: with { State.get: fn x k -> k 0 } { perform State.get }
        let input = vec![
            "with".to_string(),
            "{".to_string(),
            "identifier".to_string(), // State
            ".".to_string(),
            "identifier".to_string(), // get
            ":".to_string(),
            "fn".to_string(),
            "identifier".to_string(), // x
            "identifier".to_string(), // k
            "->".to_string(),
            "identifier".to_string(), // k
            "number".to_string(), // 0
            "}".to_string(),
            "{".to_string(),
            "perform".to_string(),
            "identifier".to_string(), // State
            ".".to_string(),
            "identifier".to_string(), // get
            "}".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
    
    #[test]
    fn test_do_notation() {
        let grammar = create_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test: do { x <- perform State.get ; perform State.put (x + 1) }
        let input = vec![
            "do".to_string(),
            "{".to_string(),
            "identifier".to_string(), // x
            "<-".to_string(),
            "perform".to_string(),
            "identifier".to_string(), // State
            ".".to_string(),
            "identifier".to_string(), // get
            "perform".to_string(),
            "identifier".to_string(), // State
            ".".to_string(),
            "identifier".to_string(), // put
            "(".to_string(),
            "identifier".to_string(), // x
            "+".to_string(),
            "number".to_string(), // 1
            ")".to_string(),
            "}".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
    
    #[test]
    fn test_handle_expression() {
        let grammar = create_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test: handle { number } { IO.print msg k -> k () }
        let input = vec![
            "handle".to_string(),
            "{".to_string(),
            "number".to_string(), // 42
            "}".to_string(),
            "{".to_string(),
            "identifier".to_string(), // IO
            ".".to_string(),
            "identifier".to_string(), // print
            "identifier".to_string(), // msg
            "identifier".to_string(), // k
            "->".to_string(),
            "identifier".to_string(), // k
            "(".to_string(),
            ")".to_string(),
            "}".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
    
    #[test]
    fn test_perform_expression() {
        let grammar = create_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test: perform IO.print
        let input = vec![
            "perform".to_string(),
            "identifier".to_string(), // IO
            ".".to_string(),
            "identifier".to_string(), // print
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
    
    #[test]
    fn test_simple_handle() {
        let grammar = create_vibe_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test: handle { number } { IO.print -> number }
        let input = vec![
            "handle".to_string(),
            "{".to_string(),
            "number".to_string(), // 42
            "}".to_string(),
            "{".to_string(),
            "identifier".to_string(), // IO
            ".".to_string(),
            "identifier".to_string(), // print
            "->".to_string(),
            "number".to_string(), // 1
            "}".to_string(),
        ];
        
        let result = parser.parse(input);
        if !result.is_ok() {
            println!("Parse failed: {:?}", result);
        }
        assert!(result.is_ok());
    }
}