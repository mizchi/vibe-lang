use crate::parser::experimental::error::{ParseError, ParseErrorBuilder, ErrorCategory, ErrorContext, 
                   Suggestion, SuggestionCategory, ParseState, ErrorMetadata};
use crate::parser::experimental::gll::GLLParser;

/// Helper functions for generating AI-friendly error messages
pub trait ErrorReporting {
    /// Generate an error when an unexpected token is encountered
    fn unexpected_token_error(
        &self,
        expected: Vec<String>,
        found: String,
        position: usize,
    ) -> ParseError;
    
    /// Generate an error for missing tokens
    fn missing_token_error(
        &self,
        missing: String,
        position: usize,
    ) -> ParseError;
    
    /// Generate an error for ambiguous grammar
    fn ambiguity_error(
        &self,
        position: usize,
        parse_trees: usize,
    ) -> ParseError;
    
    /// Generate an error for left recursion issues
    fn left_recursion_error(
        &self,
        rule: String,
        position: usize,
    ) -> ParseError;
}

impl ErrorReporting for GLLParser {
    fn unexpected_token_error(
        &self,
        expected: Vec<String>,
        found: String,
        position: usize,
    ) -> ParseError {
        let (line, column) = self.position_to_line_column(position);
        
        ParseErrorBuilder::new(
            ErrorCategory::Syntax,
            format!("Unexpected token '{}' at position {}", found, position)
        )
        .at_location(line, column)
        .with_span(position, found.len())
        .expected(expected.clone())
        .found(&found)
        .suggest(
            format!("Replace '{}' with one of: {}", found, expected.join(", ")),
            expected.first().cloned().unwrap_or_default()
        )
        .build()
        .with_context(self.build_error_context(position))
        .with_metadata(self.build_error_metadata(position))
    }
    
    fn missing_token_error(
        &self,
        missing: String,
        position: usize,
    ) -> ParseError {
        let (line, column) = self.position_to_line_column(position);
        
        ParseErrorBuilder::new(
            ErrorCategory::Syntax,
            format!("Missing '{}' at position {}", missing, position)
        )
        .at_location(line, column)
        .with_span(position, 0)
        .expected(vec![missing.clone()])
        .suggest(
            format!("Insert '{}'", missing),
            missing
        )
        .build()
        .with_context(self.build_error_context(position))
        .with_metadata(self.build_error_metadata(position))
    }
    
    fn ambiguity_error(
        &self,
        position: usize,
        parse_trees: usize,
    ) -> ParseError {
        let (line, column) = self.position_to_line_column(position);
        
        ParseErrorBuilder::new(
            ErrorCategory::Grammar,
            format!("Ambiguous grammar detected: {} possible parse trees", parse_trees)
        )
        .at_location(line, column)
        .with_span(position, 10) // Approximate span
        .suggest(
            "Consider adding parentheses to disambiguate",
            "(...)"
        )
        .suggest(
            "Review operator precedence in grammar",
            ""
        )
        .build()
        .with_context(self.build_error_context(position))
        .with_metadata(self.build_error_metadata(position))
    }
    
    fn left_recursion_error(
        &self,
        rule: String,
        position: usize,
    ) -> ParseError {
        let (line, column) = self.position_to_line_column(position);
        
        ParseErrorBuilder::new(
            ErrorCategory::Grammar,
            format!("Left recursion detected in rule '{}'", rule)
        )
        .at_location(line, column)
        .with_span(position, 10)
        .suggest(
            "Refactor grammar to eliminate left recursion",
            format!("{}_tail", rule)
        )
        .build()
        .with_context(self.build_error_context(position))
        .with_metadata(self.build_error_metadata(position))
    }
}

/// Extension trait for GLLParser to support error reporting
impl GLLParser {
    /// Convert character position to line and column
    fn position_to_line_column(&self, position: usize) -> (usize, usize) {
        if self.input.is_empty() {
            return (1, 1);
        }
        
        let mut line = 1;
        let mut column = 1;
        let mut _current_pos = 0;
        
        for (i, token) in self.input.iter().enumerate() {
            if i >= position {
                break;
            }
            _current_pos += token.len() + 1; // +1 for space
            column += token.len() + 1;
            
            // Simple heuristic: if token contains newline, increment line
            if token.contains('\n') {
                line += token.matches('\n').count();
                column = 1;
            }
        }
        
        (line, column)
    }
    
    /// Build error context with surrounding tokens
    fn build_error_context(&self, position: usize) -> ErrorContext {
        let mut context = ErrorContext::default();
        
        // Ensure position is valid
        let token_position = position.min(self.input.len().saturating_sub(1));
        
        // Get tokens around the error position
        let start = token_position.saturating_sub(2);
        let end = (token_position + 3).min(self.input.len());
        
        // Build error line
        if !self.input.is_empty() && start < self.input.len() {
            let end_clamped = end.min(self.input.len());
            context.error_line = self.input[start..end_clamped].join(" ");
            
            if token_position < self.input.len() {
                context.found = Some(self.input[token_position].clone());
            } else {
                context.found = Some("<EOF>".to_string());
            }
        }
        
        // Add before/after context
        if start > 0 && !self.input.is_empty() {
            let before_end = start.min(self.input.len());
            context.before = vec![self.input[0..before_end].join(" ")];
        }
        if end < self.input.len() {
            context.after = vec![self.input[end..].join(" ")];
        }
        
        context
    }
    
    /// Build error metadata with parse state information
    fn build_error_metadata(&self, position: usize) -> ErrorMetadata {
        ErrorMetadata {
            parse_state: ParseState {
                rule: "Unknown".to_string(), // Would need current rule tracking
                position: position,
                stack_depth: self.gss.node_count(),
                nonterminal: None,
            },
            tokens_consumed: position.min(self.input.len()),
            remaining_input: self.input.len().saturating_sub(position),
            active_rules: Vec::new(), // Would need active rule tracking
            effects: self.state.effects.iter()
                .map(|e| format!("{:?}", e))
                .take(5) // Limit to recent effects
                .collect(),
            ambiguity: if self.sppf.is_ambiguous() {
                Some(crate::parser::experimental::error::AmbiguityInfo {
                    parse_trees: self.sppf.count_trees(),
                    conflicting_rules: Vec::new(), // Would need conflict detection
                    ambiguity_type: crate::parser::experimental::error::AmbiguityType::Precedence,
                })
            } else {
                None
            },
        }
    }
}

/// Smart suggestion generator using Levenshtein distance
pub fn suggest_similar_tokens(input: &str, candidates: &[String]) -> Vec<Suggestion> {
    let mut suggestions = Vec::new();
    
    for candidate in candidates {
        let distance = levenshtein_distance(input, candidate);
        if distance <= 2 { // Max edit distance of 2
            let confidence = 1.0 - (distance as f64 / input.len().max(candidate.len()) as f64);
            suggestions.push(Suggestion {
                description: format!("Did you mean '{}'?", candidate),
                replacement: candidate.clone(),
                confidence,
                category: SuggestionCategory::Typo,
            });
        }
    }
    
    suggestions.sort_by(|a, b| b.confidence.partial_cmp(&a.confidence).unwrap());
    suggestions.truncate(3); // Top 3 suggestions
    suggestions
}

/// Calculate Levenshtein distance between two strings
fn levenshtein_distance(s1: &str, s2: &str) -> usize {
    let len1 = s1.len();
    let len2 = s2.len();
    let mut matrix = vec![vec![0; len2 + 1]; len1 + 1];
    
    for i in 0..=len1 {
        matrix[i][0] = i;
    }
    for j in 0..=len2 {
        matrix[0][j] = j;
    }
    
    for (i, c1) in s1.chars().enumerate() {
        for (j, c2) in s2.chars().enumerate() {
            let cost = if c1 == c2 { 0 } else { 1 };
            matrix[i + 1][j + 1] = std::cmp::min(
                std::cmp::min(
                    matrix[i][j + 1] + 1,    // deletion
                    matrix[i + 1][j] + 1      // insertion
                ),
                matrix[i][j] + cost          // substitution
            );
        }
    }
    
    matrix[len1][len2]
}

/// Generate contextual suggestions based on parse state
pub fn generate_contextual_suggestions(
    error: &ParseError,
    _grammar_context: &GrammarContext,
) -> Vec<Suggestion> {
    let mut suggestions = Vec::new();
    
    match error.category {
        ErrorCategory::Syntax => {
            // Suggest based on expected tokens
            if !error.context.expected.is_empty() {
                for expected in &error.context.expected {
                    suggestions.push(Suggestion {
                        description: format!("Insert {} here", expected),
                        replacement: expected.clone(),
                        confidence: 0.7,
                        category: SuggestionCategory::Missing,
                    });
                }
            }
        }
        ErrorCategory::Type => {
            // Suggest type conversions
            suggestions.push(Suggestion {
                description: "Add type annotation".to_string(),
                replacement: ": Type".to_string(),
                confidence: 0.6,
                category: SuggestionCategory::TypeConversion,
            });
        }
        ErrorCategory::Scope => {
            // Suggest imports or definitions
            suggestions.push(Suggestion {
                description: "Import missing module".to_string(),
                replacement: "import Module".to_string(),
                confidence: 0.5,
                category: SuggestionCategory::Import,
            });
        }
        _ => {}
    }
    
    suggestions
}

/// Context for grammar-aware suggestions
pub struct GrammarContext {
    pub keywords: Vec<String>,
    pub operators: Vec<String>,
    pub types: Vec<String>,
    pub functions: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_levenshtein_distance() {
        assert_eq!(levenshtein_distance("", ""), 0);
        assert_eq!(levenshtein_distance("hello", "hello"), 0);
        assert_eq!(levenshtein_distance("hello", "hallo"), 1);
        assert_eq!(levenshtein_distance("hello", "hullo"), 1);
        assert_eq!(levenshtein_distance("hello", "hxllo"), 1);
        assert_eq!(levenshtein_distance("hello", "helo"), 1);
        assert_eq!(levenshtein_distance("hello", "helloo"), 1);
    }
    
    #[test]
    fn test_suggest_similar_tokens() {
        let candidates = vec![
            "if".to_string(),
            "else".to_string(),
            "then".to_string(),
            "let".to_string(),
            "match".to_string(),
        ];
        
        let suggestions = suggest_similar_tokens("iff", &candidates);
        assert!(!suggestions.is_empty());
        assert_eq!(suggestions[0].replacement, "if");
        
        let suggestions = suggest_similar_tokens("lett", &candidates);
        assert!(!suggestions.is_empty());
        assert_eq!(suggestions[0].replacement, "let");
    }
}