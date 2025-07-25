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
    
    // Expr -> MatchExpr | IfExpr | LetInExpr | FnExpr | AppExpr
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
    
    // AtomExpr -> Ident | Literal | ( Expr ) | { RecordFields } | [ ListElements ]
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
}