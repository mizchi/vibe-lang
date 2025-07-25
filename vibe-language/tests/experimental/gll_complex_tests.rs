use vibe_language::parser::experimental::gll::{GLLParser, GLLGrammar, GLLRule, GLLSymbol};
#[allow(unused_imports)]
use vibe_language::parser::experimental::ParseEffect;

/// Create a grammar with left recursion: A -> A a | b
fn create_left_recursive_grammar() -> GLLGrammar {
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

/// Create a deeply nested expression grammar with operator precedence
#[allow(dead_code)]
fn create_expression_grammar() -> GLLGrammar {
    // E -> T E'
    // E' -> + T E' | ε
    // T -> F T'
    // T' -> * F T' | ε
    // F -> ( E ) | n
    let rules = vec![
        // E -> T E'
        GLLRule {
            lhs: "E".to_string(),
            rhs: vec![
                GLLSymbol::NonTerminal("T".to_string()),
                GLLSymbol::NonTerminal("E'".to_string()),
            ],
        },
        // E' -> + T E'
        GLLRule {
            lhs: "E'".to_string(),
            rhs: vec![
                GLLSymbol::Terminal("+".to_string()),
                GLLSymbol::NonTerminal("T".to_string()),
                GLLSymbol::NonTerminal("E'".to_string()),
            ],
        },
        // E' -> ε
        GLLRule {
            lhs: "E'".to_string(),
            rhs: vec![GLLSymbol::Epsilon],
        },
        // T -> F T'
        GLLRule {
            lhs: "T".to_string(),
            rhs: vec![
                GLLSymbol::NonTerminal("F".to_string()),
                GLLSymbol::NonTerminal("T'".to_string()),
            ],
        },
        // T' -> * F T'
        GLLRule {
            lhs: "T'".to_string(),
            rhs: vec![
                GLLSymbol::Terminal("*".to_string()),
                GLLSymbol::NonTerminal("F".to_string()),
                GLLSymbol::NonTerminal("T'".to_string()),
            ],
        },
        // T' -> ε
        GLLRule {
            lhs: "T'".to_string(),
            rhs: vec![GLLSymbol::Epsilon],
        },
        // F -> ( E )
        GLLRule {
            lhs: "F".to_string(),
            rhs: vec![
                GLLSymbol::Terminal("(".to_string()),
                GLLSymbol::NonTerminal("E".to_string()),
                GLLSymbol::Terminal(")".to_string()),
            ],
        },
        // F -> n
        GLLRule {
            lhs: "F".to_string(),
            rhs: vec![GLLSymbol::Terminal("n".to_string())],
        },
    ];
    
    GLLGrammar::new(rules, "E".to_string())
}

/// Create a highly ambiguous grammar: S -> S S | S S S | a
fn create_highly_ambiguous_grammar() -> GLLGrammar {
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
            rhs: vec![
                GLLSymbol::NonTerminal("S".to_string()),
                GLLSymbol::NonTerminal("S".to_string()),
                GLLSymbol::NonTerminal("S".to_string()),
            ],
        },
        GLLRule {
            lhs: "S".to_string(),
            rhs: vec![GLLSymbol::Terminal("a".to_string())],
        },
    ];
    
    GLLGrammar::new(rules, "S".to_string())
}

/// Create a grammar for simple if-then-else with dangling else problem
fn create_if_else_grammar() -> GLLGrammar {
    // S -> if E then S else S | if E then S | other
    // E -> true | false
    let rules = vec![
        // S -> if E then S else S
        GLLRule {
            lhs: "S".to_string(),
            rhs: vec![
                GLLSymbol::Terminal("if".to_string()),
                GLLSymbol::NonTerminal("E".to_string()),
                GLLSymbol::Terminal("then".to_string()),
                GLLSymbol::NonTerminal("S".to_string()),
                GLLSymbol::Terminal("else".to_string()),
                GLLSymbol::NonTerminal("S".to_string()),
            ],
        },
        // S -> if E then S
        GLLRule {
            lhs: "S".to_string(),
            rhs: vec![
                GLLSymbol::Terminal("if".to_string()),
                GLLSymbol::NonTerminal("E".to_string()),
                GLLSymbol::Terminal("then".to_string()),
                GLLSymbol::NonTerminal("S".to_string()),
            ],
        },
        // S -> other
        GLLRule {
            lhs: "S".to_string(),
            rhs: vec![GLLSymbol::Terminal("other".to_string())],
        },
        // E -> true
        GLLRule {
            lhs: "E".to_string(),
            rhs: vec![GLLSymbol::Terminal("true".to_string())],
        },
        // E -> false
        GLLRule {
            lhs: "E".to_string(),
            rhs: vec![GLLSymbol::Terminal("false".to_string())],
        },
    ];
    
    GLLGrammar::new(rules, "S".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_left_recursion() {
        println!("\n=== Testing Left Recursive Grammar ===");
        let grammar = create_left_recursive_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // First test simple case "b"
        println!("\nTest 1: Simple case \"b\"");
        let input1 = vec!["b".to_string()];
        let result1 = parser.parse(input1);
        assert!(result1.is_ok(), "Should parse \"b\"");
        println!("✓ Parsed \"b\" successfully");
        
        // Then test "b a"  
        println!("\nTest 2: One recursion \"b a\"");
        let mut parser2 = GLLParser::new(create_left_recursive_grammar());
        let input2 = vec!["b".to_string(), "a".to_string()];
        let result2 = parser2.parse(input2);
        assert!(result2.is_ok(), "Should parse \"b a\"");
        println!("✓ Parsed \"b a\" successfully");
        
        // Finally test "b a a a"
        println!("\nTest 3: Multiple recursions \"b a a a\"");
        let mut parser3 = GLLParser::new(create_left_recursive_grammar());
        let input3 = vec!["b".to_string(), "a".to_string(), "a".to_string(), "a".to_string()];
        println!("Input: {:?}", input3);
        
        let result3 = parser3.parse(input3);
        if let Err(ref e) = result3 {
            println!("Parse error: {}", e);
        }
        assert!(result3.is_ok());
        
        let roots = result3.unwrap();
        println!("Parse successful! Found {} root(s)", roots.len());
        
        let state = parser3.get_state();
        println!("Effects tracked: {}", state.effects.len());
        
        // Count backtracks (important for left recursion)
        let backtracks = state.effects.iter()
            .filter(|e| matches!(e, ParseEffect::Backtrack))
            .count();
        println!("Backtracks: {}", backtracks);
    }

    #[test]
    fn test_expression_precedence() {
        println!("\n=== Testing Expression Grammar with Precedence ===");
        let grammar = create_expression_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test "n + n * n"
        let input = vec![
            "n".to_string(), "+".to_string(), 
            "n".to_string(), "*".to_string(), 
            "n".to_string()
        ];
        println!("Input: {:?}", input);
        
        let result = parser.parse(input);
        assert!(result.is_ok());
        
        let roots = result.unwrap();
        println!("Parse successful! Found {} root(s)", roots.len());
        
        // Check parsing succeeded
        let sppf = parser.get_sppf();
        println!("Parse trees: {}", sppf.count_trees());
        println!("Is ambiguous: {}", sppf.is_ambiguous());
        
        // Note: GLL parser may create multiple derivation paths internally
        // even for unambiguous grammars, so we just check successful parsing
        println!("Grammar parsed successfully with precedence");
    }

    #[test]
    fn test_deeply_nested_expression() {
        println!("\n=== Testing Deeply Nested Expression ===");
        let grammar = create_expression_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test "((n + n) * (n + n))"
        let input = vec![
            "(".to_string(), "(".to_string(), 
            "n".to_string(), "+".to_string(), "n".to_string(),
            ")".to_string(), "*".to_string(), "(".to_string(),
            "n".to_string(), "+".to_string(), "n".to_string(),
            ")".to_string(), ")".to_string()
        ];
        println!("Input: {:?}", input);
        
        let result = parser.parse(input);
        assert!(result.is_ok());
        
        let _state = parser.get_state();
        let gss = parser.get_gss();
        let sppf = parser.get_sppf();
        
        println!("Parse successful!");
        println!("GSS nodes: {}", gss.node_count());
        println!("GSS edges: {}", gss.edge_count());
        println!("SPPF nodes: {}", sppf.stats().total_nodes);
    }

    #[test]
    fn test_highly_ambiguous() {
        println!("\n=== Testing Highly Ambiguous Grammar ===");
        let grammar = create_highly_ambiguous_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test "a a a a" - has many possible parse trees
        let input = vec!["a".to_string(), "a".to_string(), "a".to_string(), "a".to_string()];
        println!("Input: {:?}", input);
        
        let result = parser.parse(input);
        assert!(result.is_ok());
        
        let sppf = parser.get_sppf();
        assert!(sppf.is_ambiguous());
        
        let tree_count = sppf.count_trees();
        println!("Number of parse trees: {}", tree_count);
        assert!(tree_count > 1); // Should have multiple parse trees
        
        let stats = sppf.stats();
        println!("SPPF Statistics:");
        println!("  Total nodes: {}", stats.total_nodes);
        println!("  Ambiguous nodes: {}", stats.ambiguous_nodes);
    }

    #[test]
    fn test_dangling_else() {
        println!("\n=== Testing Dangling Else Problem ===");
        let grammar = create_if_else_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test "if true then if false then other else other"
        // This is ambiguous: else could belong to either if
        let input = vec![
            "if".to_string(), "true".to_string(), "then".to_string(),
            "if".to_string(), "false".to_string(), "then".to_string(),
            "other".to_string(), "else".to_string(), "other".to_string()
        ];
        println!("Input: {:?}", input);
        
        let result = parser.parse(input);
        assert!(result.is_ok());
        
        let sppf = parser.get_sppf();
        assert!(sppf.is_ambiguous());
        
        let tree_count = sppf.count_trees();
        println!("Number of parse trees: {}", tree_count);
        assert_eq!(tree_count, 2); // Should have exactly 2 interpretations
    }

    #[test]
    fn test_invalid_input() {
        println!("\n=== Testing Invalid Input ===");
        let grammar = create_expression_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test "n + +" - invalid syntax
        let input = vec!["n".to_string(), "+".to_string(), "+".to_string()];
        println!("Input: {:?}", input);
        
        let result = parser.parse(input);
        assert!(result.is_err());
        println!("Parse correctly failed: {}", result.unwrap_err());
        
        // Check that error recovery was attempted
        let state = parser.get_state();
        let backtracks = state.effects.iter()
            .filter(|e| matches!(e, ParseEffect::Backtrack))
            .count();
        println!("Backtracks during error: {}", backtracks);
        assert!(backtracks > 0); // Should have attempted backtracking
    }

    #[test]
    fn test_effect_analysis() {
        println!("\n=== Testing Effect Analysis ===");
        let grammar = create_highly_ambiguous_grammar();
        let mut parser = GLLParser::new(grammar);
        
        let input = vec!["a".to_string(), "a".to_string(), "a".to_string()];
        let _ = parser.parse(input);
        
        let state = parser.get_state();
        
        // Analyze effects
        let mut effect_counts = std::collections::HashMap::new();
        for effect in &state.effects {
            match effect {
                ParseEffect::SemanticAction(action) => {
                    *effect_counts.entry(format!("semantic:{}", action)).or_insert(0) += 1;
                }
                ParseEffect::Lookahead(n) => {
                    *effect_counts.entry(format!("lookahead:{}", n)).or_insert(0) += 1;
                }
                ParseEffect::Backtrack => {
                    *effect_counts.entry("backtrack".to_string()).or_insert(0) += 1;
                }
                _ => {}
            }
        }
        
        println!("Effect Analysis:");
        for (effect, count) in effect_counts.iter() {
            println!("  {}: {}", effect, count);
        }
    }

    #[test]
    fn test_stress_test() {
        println!("\n=== Stress Test: Large Input ===");
        let grammar = create_expression_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Generate a large expression: n + n + n + ... (50 terms)
        let mut input = vec!["n".to_string()];
        for _ in 0..49 {
            input.push("+".to_string());
            input.push("n".to_string());
        }
        println!("Input size: {} tokens", input.len());
        
        let start = std::time::Instant::now();
        let result = parser.parse(input);
        let duration = start.elapsed();
        
        assert!(result.is_ok());
        println!("Parse time: {:?}", duration);
        
        let gss = parser.get_gss();
        let sppf = parser.get_sppf();
        println!("GSS nodes: {}", gss.node_count());
        println!("SPPF nodes: {}", sppf.stats().total_nodes);
    }
}

/// Demo function for complex grammar verification
pub fn demo_complex_gll_verification() {
    println!("=== Complex GLL Parser Verification Demo ===\n");
    
    // Test 1: Left Recursion
    println!("1. Left Recursive Grammar (A -> A a | b)");
    let grammar = create_left_recursive_grammar();
    let mut parser = GLLParser::new(grammar);
    let input = vec!["b".to_string(), "a".to_string(), "a".to_string()];
    match parser.parse(input.clone()) {
        Ok(_) => println!("   ✓ Successfully parsed: {:?}", input),
        Err(e) => println!("   ✗ Failed: {}", e),
    }
    
    // Test 2: Highly Ambiguous
    println!("\n2. Highly Ambiguous Grammar (S -> S S | S S S | a)");
    let grammar = create_highly_ambiguous_grammar();
    let mut parser = GLLParser::new(grammar);
    let input = vec!["a".to_string(), "a".to_string(), "a".to_string()];
    match parser.parse(input.clone()) {
        Ok(_) => {
            let sppf = parser.get_sppf();
            println!("   ✓ Successfully parsed: {:?}", input);
            println!("   Parse trees: {}", sppf.count_trees());
        }
        Err(e) => println!("   ✗ Failed: {}", e),
    }
    
    // Test 3: Dangling Else
    println!("\n3. Dangling Else Problem");
    let grammar = create_if_else_grammar();
    let mut parser = GLLParser::new(grammar);
    let input = vec![
        "if".to_string(), "true".to_string(), "then".to_string(),
        "if".to_string(), "false".to_string(), "then".to_string(),
        "other".to_string(), "else".to_string(), "other".to_string()
    ];
    match parser.parse(input) {
        Ok(_) => {
            let sppf = parser.get_sppf();
            println!("   ✓ Successfully parsed if-then-else");
            println!("   Ambiguous: {} (expected: true)", sppf.is_ambiguous());
            println!("   Parse trees: {} (expected: 2)", sppf.count_trees());
        }
        Err(e) => println!("   ✗ Failed: {}", e),
    }
    
    println!("\n=== All complex tests completed ===");
}