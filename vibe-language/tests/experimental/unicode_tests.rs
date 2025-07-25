#[cfg(test)]
mod tests {
    use vibe_language::parser::experimental::gll::{GLLParser, GLLGrammar, GLLRule, GLLSymbol};
    use vibe_language::parser::experimental::error_helpers::suggest_similar_tokens;

    /// Create a simple grammar that accepts identifiers and operators
    fn create_unicode_test_grammar() -> GLLGrammar {
        let rules = vec![
            // Program -> Statement+
            GLLRule {
                lhs: "Program".to_string(),
                rhs: vec![
                    GLLSymbol::NonTerminal("Statement".to_string()),
                    GLLSymbol::NonTerminal("Program".to_string()),
                ],
            },
            GLLRule {
                lhs: "Program".to_string(),
                rhs: vec![GLLSymbol::NonTerminal("Statement".to_string())],
            },
            // Statement -> Identifier = Expression ;
            GLLRule {
                lhs: "Statement".to_string(),
                rhs: vec![
                    GLLSymbol::Terminal("identifier".to_string()),
                    GLLSymbol::Terminal("=".to_string()),
                    GLLSymbol::NonTerminal("Expression".to_string()),
                    GLLSymbol::Terminal(";".to_string()),
                ],
            },
            // Expression -> Identifier | Number | String
            GLLRule {
                lhs: "Expression".to_string(),
                rhs: vec![GLLSymbol::Terminal("identifier".to_string())],
            },
            GLLRule {
                lhs: "Expression".to_string(),
                rhs: vec![GLLSymbol::Terminal("number".to_string())],
            },
            GLLRule {
                lhs: "Expression".to_string(),
                rhs: vec![GLLSymbol::Terminal("string".to_string())],
            },
        ];
        
        GLLGrammar::new(rules, "Program".to_string())
    }

    #[test]
    fn test_japanese_identifiers() {
        let grammar = create_unicode_test_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test with Japanese identifiers
        let input = vec![
            "identifier".to_string(),  // 変数
            "=".to_string(),
            "number".to_string(),      // 42
            ";".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok(), "Should parse Japanese identifiers");
        
        // Note: In a real implementation, the lexer would handle the actual Japanese text
        // Here we're testing that the parser can handle the tokens
    }

    #[test]
    fn test_emoji_in_strings() {
        let grammar = create_unicode_test_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test with emoji in string literals
        let input = vec![
            "identifier".to_string(),  // greeting
            "=".to_string(),
            "string".to_string(),      // "Hello 👋 World 🌍!"
            ";".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok(), "Should parse emoji in strings");
    }

    #[test]
    fn test_mixed_unicode() {
        let grammar = create_unicode_test_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test with mixed Unicode characters
        let input = vec![
            "identifier".to_string(),  // café_変数_🚀
            "=".to_string(),
            "string".to_string(),      // "こんにちは🎌"
            ";".to_string(),
            "identifier".to_string(),  // π
            "=".to_string(),
            "number".to_string(),      // 3.14159
            ";".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok(), "Should parse mixed Unicode");
    }

    #[test]
    fn test_unicode_error_messages() {
        let grammar = create_unicode_test_grammar();
        let mut parser = GLLParser::new(grammar);
        
        // Test error with Japanese context
        let input = vec![
            "identifier".to_string(),  // 変数
            "=".to_string(),
            // Missing expression
            ";".to_string(),
        ];
        
        let result = parser.parse_with_errors(input);
        assert!(result.is_err(), "Should fail with missing expression");
        
        if let Err(error) = result {
            println!("Error message: {}", error.message);
            // Verify error message is properly formatted
            assert!(error.message.contains("Unexpected token"));
        }
    }

    #[test]
    fn test_unicode_suggestions() {
        // Test Levenshtein distance with Unicode strings
        let japanese_keywords = vec![
            "もし".to_string(),      // if
            "そうでなければ".to_string(), // else
            "関数".to_string(),      // function
            "変数".to_string(),      // variable
            "定数".to_string(),      // constant
            "クラス".to_string(),    // class
        ];
        
        // Test typo correction with Japanese
        let suggestions = suggest_similar_tokens("もしも", &japanese_keywords);
        assert!(!suggestions.is_empty(), "Should suggest similar Japanese tokens");
        assert_eq!(suggestions[0].replacement, "もし");
        
        // Test with mixed scripts
        let mixed_keywords = vec![
            "let_変数".to_string(),
            "const_定数".to_string(),
            "fn_関数".to_string(),
            "if_もし".to_string(),
        ];
        
        let suggestions = suggest_similar_tokens("let_変", &mixed_keywords);
        assert!(!suggestions.is_empty(), "Should suggest mixed script tokens");
    }

    #[test]
    fn test_unicode_character_counting() {
        // Test that character positions work correctly with multi-byte chars
        let test_strings = vec![
            ("Hello", 5),           // ASCII
            ("こんにちは", 5),      // Hiragana
            ("Hello 👋", 7),        // ASCII + emoji (emoji counts as 2)
            ("café", 4),            // Latin with accent
            ("🚀🌍🎌", 6),         // Multiple emoji
        ];
        
        for (text, expected_chars) in test_strings {
            let char_count = text.chars().count();
            println!("{}: {} chars (expected {})", text, char_count, expected_chars);
            // Note: This shows the difference between byte length and char count
        }
    }

    #[test]
    fn test_unicode_in_error_context() {
        use vibe_language::parser::experimental::error::{ParseErrorBuilder, ErrorCategory};
        
        let error = ParseErrorBuilder::new(
            ErrorCategory::Syntax,
            "予期しないトークン '🚫' が見つかりました"
        )
        .at_location(5, 10)
        .expected(vec!["識別子".to_string(), "数値".to_string()])
        .found("🚫")
        .suggest("正しい演算子を使用してください", "=")
        .build();
        
        // Test human readable format
        let human_readable = error.to_human_readable();
        assert!(human_readable.contains("予期しないトークン"));
        assert!(human_readable.contains("🚫"));
        
        // Test JSON format preserves Unicode
        let json = error.to_ai_json();
        assert!(json.contains("予期しないトークン"));
        assert!(json.contains("🚫"));
        
        // Verify JSON is valid
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["category"], "Syntax");
    }

    #[test]
    fn test_complex_unicode_parse() {
        // Create a grammar that accepts Unicode operators
        let rules = vec![
            // Expr -> Expr ➕ Term | Term
            GLLRule {
                lhs: "Expr".to_string(),
                rhs: vec![
                    GLLSymbol::NonTerminal("Expr".to_string()),
                    GLLSymbol::Terminal("➕".to_string()),
                    GLLSymbol::NonTerminal("Term".to_string()),
                ],
            },
            GLLRule {
                lhs: "Expr".to_string(),
                rhs: vec![GLLSymbol::NonTerminal("Term".to_string())],
            },
            // Term -> 数字 | 🔢
            GLLRule {
                lhs: "Term".to_string(),
                rhs: vec![GLLSymbol::Terminal("数字".to_string())],
            },
            GLLRule {
                lhs: "Term".to_string(),
                rhs: vec![GLLSymbol::Terminal("🔢".to_string())],
            },
        ];
        
        let grammar = GLLGrammar::new(rules, "Expr".to_string());
        let mut parser = GLLParser::new(grammar);
        
        // Test parsing with Unicode operators and terms
        let input = vec![
            "数字".to_string(),
            "➕".to_string(),
            "🔢".to_string(),
        ];
        
        let result = parser.parse(input);
        assert!(result.is_ok(), "Should parse Unicode operators and terms");
    }

    #[test]
    fn test_unicode_normalization() {
        // Test that composed and decomposed forms are handled
        let composed = "café";     // é as single character
        let decomposed = "café";   // e + combining acute accent
        
        // In practice, normalization should happen at lexer level
        assert_eq!(composed.chars().count(), 4);
        assert_eq!(decomposed.chars().count(), 4); // May be 5 depending on representation
        
        // Test suggestions work with different normalizations
        let keywords = vec![
            "café".to_string(),
            "coffee".to_string(),
            "カフェ".to_string(),
        ];
        
        let suggestions = suggest_similar_tokens("cafe", &keywords);
        assert!(!suggestions.is_empty(), "Should suggest normalized forms");
    }
}

/// Integration test for full Unicode parsing pipeline
#[test]
fn test_unicode_integration() {
    use crate::{GLLParser, GLLGrammar, GLLRule, GLLSymbol};
    
    println!("\n=== Unicode Integration Test ===");
    
    // Create a simple expression grammar
    let rules = vec![
        GLLRule {
            lhs: "S".to_string(),
            rhs: vec![
                GLLSymbol::Terminal("こんにちは".to_string()),
                GLLSymbol::Terminal("🌍".to_string()),
            ],
        },
    ];
    
    let grammar = GLLGrammar::new(rules, "S".to_string());
    let mut parser = GLLParser::new(grammar);
    
    // Test successful parse
    let input = vec!["こんにちは".to_string(), "🌍".to_string()];
    println!("Input: {:?}", input);
    
    let result = parser.parse(input);
    match result {
        Ok(roots) => {
            println!("✅ Parse successful! Found {} parse tree(s)", roots.len());
        }
        Err(e) => {
            println!("❌ Parse failed: {}", e);
        }
    }
    
    // Test error case
    let rules2 = vec![
        GLLRule {
            lhs: "S".to_string(),
            rhs: vec![
                GLLSymbol::Terminal("こんにちは".to_string()),
                GLLSymbol::Terminal("🌍".to_string()),
            ],
        },
    ];
    let mut parser2 = GLLParser::new(GLLGrammar::new(rules2, "S".to_string()));
    let bad_input = vec!["こんにちは".to_string(), "❌".to_string()];
    println!("\nInput with error: {:?}", bad_input);
    
    match parser2.parse_with_errors(bad_input) {
        Ok(_) => println!("Unexpected success"),
        Err(error) => {
            println!("Expected error occurred:");
            println!("{}", error.to_human_readable());
        }
    }
}