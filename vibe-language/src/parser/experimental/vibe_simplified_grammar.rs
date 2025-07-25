use super::gll::{GLLGrammar, GLLRule, GLLSymbol};

/// Create a simplified Vibe language grammar for initial testing
pub fn create_simplified_vibe_grammar() -> GLLGrammar {
    let mut rules = Vec::new();
    
    // Program -> Statement Program | Statement
    rules.push(GLLRule {
        lhs: "Program".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Statement".to_string()),
            GLLSymbol::NonTerminal("Program".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "Program".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Statement".to_string())],
    });
    
    // Statement -> LetBinding | Expression
    rules.push(GLLRule {
        lhs: "Statement".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("LetBinding".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Statement".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Expression".to_string())],
    });
    
    // LetBinding -> let identifier = Expression
    rules.push(GLLRule {
        lhs: "LetBinding".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("let".to_string()),
            GLLSymbol::Terminal("identifier".to_string()),
            GLLSymbol::Terminal("=".to_string()),
            GLLSymbol::NonTerminal("Expression".to_string()),
        ],
    });
    
    // Expression -> Term + Expression | Term - Expression | Term
    rules.push(GLLRule {
        lhs: "Expression".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Term".to_string()),
            GLLSymbol::Terminal("+".to_string()),
            GLLSymbol::NonTerminal("Expression".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "Expression".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Term".to_string()),
            GLLSymbol::Terminal("-".to_string()),
            GLLSymbol::NonTerminal("Expression".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "Expression".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Term".to_string())],
    });
    
    // Term -> Factor * Term | Factor / Term | Factor
    rules.push(GLLRule {
        lhs: "Term".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Factor".to_string()),
            GLLSymbol::Terminal("*".to_string()),
            GLLSymbol::NonTerminal("Term".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "Term".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Factor".to_string()),
            GLLSymbol::Terminal("/".to_string()),
            GLLSymbol::NonTerminal("Term".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "Term".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Factor".to_string())],
    });
    
    // Factor -> Primary | ( Expression )
    rules.push(GLLRule {
        lhs: "Factor".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Primary".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Factor".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("(".to_string()),
            GLLSymbol::NonTerminal("Expression".to_string()),
            GLLSymbol::Terminal(")".to_string()),
        ],
    });
    
    // Primary -> identifier | number | true | false | FunctionCall
    rules.push(GLLRule {
        lhs: "Primary".to_string(),
        rhs: vec![GLLSymbol::Terminal("identifier".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Primary".to_string(),
        rhs: vec![GLLSymbol::Terminal("number".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Primary".to_string(),
        rhs: vec![GLLSymbol::Terminal("true".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Primary".to_string(),
        rhs: vec![GLLSymbol::Terminal("false".to_string())],
    });
    rules.push(GLLRule {
        lhs: "Primary".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("FunctionCall".to_string())],
    });
    
    // FunctionCall -> identifier Arguments
    rules.push(GLLRule {
        lhs: "FunctionCall".to_string(),
        rhs: vec![
            GLLSymbol::Terminal("identifier".to_string()),
            GLLSymbol::NonTerminal("Arguments".to_string()),
        ],
    });
    
    // Arguments -> Primary Arguments | Primary
    rules.push(GLLRule {
        lhs: "Arguments".to_string(),
        rhs: vec![
            GLLSymbol::NonTerminal("Primary".to_string()),
            GLLSymbol::NonTerminal("Arguments".to_string()),
        ],
    });
    rules.push(GLLRule {
        lhs: "Arguments".to_string(),
        rhs: vec![GLLSymbol::NonTerminal("Primary".to_string())],
    });
    
    GLLGrammar::new(rules, "Program".to_string())
}

/// A simpler vibe parser for testing
pub struct SimplifiedVibeParser {
    gll_parser: super::gll::GLLParser,
}

impl SimplifiedVibeParser {
    pub fn new() -> Self {
        let grammar = create_simplified_vibe_grammar();
        Self {
            gll_parser: super::gll::GLLParser::new(grammar),
        }
    }
    
    pub fn parse(&mut self, tokens: Vec<String>) -> Result<Vec<usize>, String> {
        self.gll_parser.parse(tokens)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_simple_arithmetic() {
        let mut parser = SimplifiedVibeParser::new();
        
        // Test: 1 + 2
        let input = vec![
            "number".to_string(),
            "+".to_string(),
            "number".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
    
    #[test]
    fn test_let_binding() {
        let mut parser = SimplifiedVibeParser::new();
        
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
    fn test_function_call() {
        let mut parser = SimplifiedVibeParser::new();
        
        // Test: f x y
        let input = vec![
            "identifier".to_string(),
            "identifier".to_string(),
            "identifier".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
    
    #[test]
    fn test_nested_expression() {
        let mut parser = SimplifiedVibeParser::new();
        
        // Test: (1 + 2) * 3
        let input = vec![
            "(".to_string(),
            "number".to_string(),
            "+".to_string(),
            "number".to_string(),
            ")".to_string(),
            "*".to_string(),
            "number".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
    
    #[test] 
    fn test_multiple_statements() {
        let mut parser = SimplifiedVibeParser::new();
        
        // Test: let x = 1 let y = 2
        let input = vec![
            "let".to_string(),
            "identifier".to_string(),
            "=".to_string(),
            "number".to_string(),
            "let".to_string(),
            "identifier".to_string(),
            "=".to_string(),
            "number".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok());
    }
}