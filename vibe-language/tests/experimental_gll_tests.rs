use vibe_language::parser::experimental::gll::{GLLParser, GLLGrammar, GLLRule, GLLSymbol};
use vibe_language::parser::experimental::{ParseEffect, Constraint};

fn create_simple_grammar() -> GLLGrammar {
    // S -> a S b | c
    let rules = vec![
        GLLRule {
            lhs: "S".to_string(),
            rhs: vec![
                GLLSymbol::Terminal("a".to_string()),
                GLLSymbol::NonTerminal("S".to_string()),
                GLLSymbol::Terminal("b".to_string()),
            ],
        },
        GLLRule {
            lhs: "S".to_string(),
            rhs: vec![GLLSymbol::Terminal("c".to_string())],
        },
    ];
    
    GLLGrammar::new(rules, "S".to_string())
}

#[test]
fn test_gll_simple_grammar() {
    let grammar = create_simple_grammar();
    let mut parser = GLLParser::new(grammar);
    
    // Test valid input: a c b
    let input = vec!["a".to_string(), "c".to_string(), "b".to_string()];
    let result = parser.parse(input);
    
    assert!(result.is_ok());
    let roots = result.unwrap();
    assert!(!roots.is_empty());
}

#[test]
fn test_gll_invalid_input() {
    let grammar = create_simple_grammar();
    let mut parser = GLLParser::new(grammar);
    
    // Test invalid input: a b c
    let input = vec!["a".to_string(), "b".to_string(), "c".to_string()];
    let result = parser.parse(input);
    
    assert!(result.is_err());
}

#[test]
fn test_gll_morpheus_verification() {
    let grammar = create_simple_grammar();
    let mut parser = GLLParser::new(grammar);
    
    let input = vec!["a".to_string(), "c".to_string(), "b".to_string()];
    let _ = parser.parse(input);
    
    let state = parser.get_state();
    
    // Check that effects were tracked
    assert!(!state.effects.is_empty());
    assert!(state.effects.iter().any(|e| matches!(e, ParseEffect::SemanticAction(_))));
    
    // Check that constraints were generated
    assert!(!state.constraints.is_empty());
    assert!(state.constraints.iter().any(|c| matches!(c, Constraint::Termination { .. })));
}

fn create_left_recursive_grammar() -> GLLGrammar {
    // A -> A a | b
    let rules = vec![
        GLLRule {
            lhs: "A".to_string(),
            rhs: vec![
                GLLSymbol::NonTerminal("A".to_string()),
                GLLSymbol::Terminal("a".to_string()),
            ],
        },
        GLLRule {
            lhs: "A".to_string(),
            rhs: vec![GLLSymbol::Terminal("b".to_string())],
        },
    ];
    
    GLLGrammar::new(rules, "A".to_string())
}

#[test]
fn test_gll_left_recursion() {
    let grammar = create_left_recursive_grammar();
    let mut parser = GLLParser::new(grammar);
    
    // Test input: b a a a
    let input = vec!["b".to_string(), "a".to_string(), "a".to_string(), "a".to_string()];
    let result = parser.parse(input);
    
    assert!(result.is_ok());
    let roots = result.unwrap();
    assert!(!roots.is_empty());
}

fn create_ambiguous_grammar() -> GLLGrammar {
    // E -> E + E | E * E | n
    let rules = vec![
        GLLRule {
            lhs: "E".to_string(),
            rhs: vec![
                GLLSymbol::NonTerminal("E".to_string()),
                GLLSymbol::Terminal("+".to_string()),
                GLLSymbol::NonTerminal("E".to_string()),
            ],
        },
        GLLRule {
            lhs: "E".to_string(),
            rhs: vec![
                GLLSymbol::NonTerminal("E".to_string()),
                GLLSymbol::Terminal("*".to_string()),
                GLLSymbol::NonTerminal("E".to_string()),
            ],
        },
        GLLRule {
            lhs: "E".to_string(),
            rhs: vec![GLLSymbol::Terminal("n".to_string())],
        },
    ];
    
    GLLGrammar::new(rules, "E".to_string())
}

#[test]
fn test_gll_ambiguous_grammar() {
    let grammar = create_ambiguous_grammar();
    let mut parser = GLLParser::new(grammar);
    
    // n + n * n can be parsed as (n + n) * n or n + (n * n)
    let input = vec!["n".to_string(), "+".to_string(), "n".to_string(), "*".to_string(), "n".to_string()];
    let result = parser.parse(input);
    
    assert!(result.is_ok());
    let sppf = parser.get_sppf();
    assert!(sppf.is_ambiguous());
}

fn create_epsilon_grammar() -> GLLGrammar {
    // S -> A B
    // A -> a | ε
    // B -> b | ε
    let rules = vec![
        GLLRule {
            lhs: "S".to_string(),
            rhs: vec![
                GLLSymbol::NonTerminal("A".to_string()),
                GLLSymbol::NonTerminal("B".to_string()),
            ],
        },
        GLLRule {
            lhs: "A".to_string(),
            rhs: vec![GLLSymbol::Terminal("a".to_string())],
        },
        GLLRule {
            lhs: "A".to_string(),
            rhs: vec![GLLSymbol::Epsilon],
        },
        GLLRule {
            lhs: "B".to_string(),
            rhs: vec![GLLSymbol::Terminal("b".to_string())],
        },
        GLLRule {
            lhs: "B".to_string(),
            rhs: vec![GLLSymbol::Epsilon],
        },
    ];
    
    GLLGrammar::new(rules, "S".to_string())
}

#[test]
fn test_gll_epsilon_productions() {
    let grammar = create_epsilon_grammar();
    
    // Test different valid inputs
    let test_cases = vec![
        vec!["a".to_string(), "b".to_string()],
        vec!["a".to_string()],
        vec!["b".to_string()],
        vec![],
    ];
    
    for input in test_cases {
        let mut parser = GLLParser::new(grammar.clone());
        let result = parser.parse(input.clone());
        assert!(result.is_ok(), "Failed to parse {:?}", input);
    }
}

#[test]
fn test_gll_complex_ambiguity() {
    // Create a grammar with multiple ambiguities
    // S -> S S | a
    let rules = vec![
        GLLRule {
            lhs: "S".to_string(),
            rhs: vec![
                GLLSymbol::NonTerminal("S".to_string()),
                GLLSymbol::NonTerminal("S".to_string()),
            ],
        },
        GLLRule {
            lhs: "S".to_string(),
            rhs: vec![GLLSymbol::Terminal("a".to_string())],
        },
    ];
    
    let grammar = GLLGrammar::new(rules, "S".to_string());
    let mut parser = GLLParser::new(grammar);
    
    // Input "a a a" can be parsed in many ways
    let input = vec!["a".to_string(), "a".to_string(), "a".to_string()];
    let result = parser.parse(input);
    
    assert!(result.is_ok());
    let sppf = parser.get_sppf();
    assert!(sppf.is_ambiguous());
    
    // Should have multiple parse trees
    let tree_count = sppf.count_trees();
    assert!(tree_count > 1, "Expected multiple parse trees, got {}", tree_count);
}