pub mod parser;
pub mod gll;
pub mod error;
pub mod error_helpers;
pub mod expression_combiner;
pub mod vibe_grammar;
pub mod vibe_parser;
pub mod vibe_simplified_grammar;
pub mod unified_vibe_grammar;
pub mod unified_vibe_parser;
// pub mod sppf_to_ast; // Temporarily disabled due to AST structure changes
pub mod sppf_to_ast_simple;
pub mod sppf_to_ast_converter;

pub use parser::{ParserState, ParseEffect, Constraint, NodeId, parse_with_gll};
pub use gll::{GLLParser, GLLGrammar, GLLRule, GLLSymbol, demo_complex_gll_verification};
pub use error::{ParseError as StructuredParseError, ErrorCategory, ErrorLocation, ParseErrorBuilder};
pub use error_helpers::{ErrorReporting, suggest_similar_tokens};

/// Example integration with Morpheus-style verification
pub fn demo_gll_with_verification() {
    println!("=== GLL Parser with Morpheus-style Verification Demo ===");
    
    // Create an ambiguous grammar: E -> E + E | E * E | n
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
    
    let grammar = GLLGrammar::new(rules, "E".to_string());
    let mut parser = GLLParser::new(grammar);
    
    // Parse ambiguous input: n + n * n
    let input = vec!["n".to_string(), "+".to_string(), "n".to_string(), "*".to_string(), "n".to_string()];
    
    match parser.parse(input) {
        Ok(roots) => {
            println!("✓ Parse successful! Found {} root(s)", roots.len());
            
            // Check ambiguity
            let sppf = parser.get_sppf();
            if sppf.is_ambiguous() {
                println!("✓ Grammar is ambiguous (as expected)");
                println!("  Number of parse trees: {}", sppf.count_trees());
            }
            
            // Get parser state for verification
            let state = parser.get_state();
            println!("\n=== Morpheus-style Verification ===");
            println!("Effects tracked: {}", state.effects.len());
            
            // Count effect types
            let mut semantic_actions = 0;
            let mut lookaheads = 0;
            let mut backtracks = 0;
            
            for effect in &state.effects {
                match effect {
                    ParseEffect::SemanticAction(_) => semantic_actions += 1,
                    ParseEffect::Lookahead(_) => lookaheads += 1,
                    ParseEffect::Backtrack => backtracks += 1,
                    _ => {}
                }
            }
            
            println!("  - Semantic actions: {}", semantic_actions);
            println!("  - Lookaheads: {}", lookaheads);
            println!("  - Backtracks: {}", backtracks);
            
            // Check constraints
            println!("\nConstraints generated: {}", state.constraints.len());
            for constraint in &state.constraints {
                match constraint {
                    Constraint::Termination { .. } => {
                        println!("  ✓ Termination constraint added");
                    }
                    _ => {}
                }
            }
            
            // GSS and SPPF statistics
            let gss = parser.get_gss();
            let sppf_stats = sppf.stats();
            
            println!("\n=== Parser Statistics ===");
            println!("GSS nodes: {}", gss.node_count());
            println!("GSS edges: {}", gss.edge_count());
            println!("SPPF nodes: {}", sppf_stats.total_nodes);
            println!("SPPF ambiguous nodes: {}", sppf_stats.ambiguous_nodes);
        }
        Err(e) => {
            println!("✗ Parse failed: {}", e);
        }
    }
}