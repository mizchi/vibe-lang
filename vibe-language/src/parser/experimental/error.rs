use std::fmt;
use serde::{Serialize, Deserialize};

/// AI-friendly error representation with structured information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ParseError {
    /// Error category for easy classification
    pub category: ErrorCategory,
    
    /// Human and AI readable error message
    pub message: String,
    
    /// Detailed error code for programmatic handling
    pub code: String,
    
    /// Location information
    pub location: ErrorLocation,
    
    /// Context around the error
    pub context: ErrorContext,
    
    /// Suggested fixes
    pub suggestions: Vec<Suggestion>,
    
    /// Additional metadata for AI processing
    pub metadata: ErrorMetadata,
}

/// Error categories for classification
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ErrorCategory {
    /// Syntax errors (missing tokens, unexpected tokens)
    Syntax,
    /// Type-related errors
    Type,
    /// Undefined variable or function
    Scope,
    /// Pattern matching errors
    Pattern,
    /// Module or import errors
    Module,
    /// Effect-related errors
    Effect,
    /// Left recursion or ambiguity issues
    Grammar,
}

/// Location information for the error
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ErrorLocation {
    /// File path (if available)
    pub file: Option<String>,
    
    /// Line number (1-indexed)
    pub line: usize,
    
    /// Column number (1-indexed)
    pub column: usize,
    
    /// Character offset from start
    pub offset: usize,
    
    /// Length of the error span
    pub length: usize,
}

/// Context around the error
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ErrorContext {
    /// Lines before the error
    pub before: Vec<String>,
    
    /// The line containing the error
    pub error_line: String,
    
    /// Lines after the error
    pub after: Vec<String>,
    
    /// Expected tokens/symbols at this position
    pub expected: Vec<String>,
    
    /// Actually found token/symbol
    pub found: Option<String>,
}

/// Suggested fix for the error
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Suggestion {
    /// Description of the suggestion
    pub description: String,
    
    /// Code to replace the error with
    pub replacement: String,
    
    /// Confidence level (0.0 to 1.0)
    pub confidence: f64,
    
    /// Category of suggestion
    pub category: SuggestionCategory,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SuggestionCategory {
    /// Fix typo or misspelling
    Typo,
    /// Add missing syntax
    Missing,
    /// Remove extra syntax
    Extra,
    /// Reorder elements
    Reorder,
    /// Import required module
    Import,
    /// Type conversion
    TypeConversion,
}

/// Additional metadata for AI processing
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ErrorMetadata {
    /// Parse state when error occurred
    pub parse_state: ParseState,
    
    /// Tokens consumed before error
    pub tokens_consumed: usize,
    
    /// Remaining input length
    pub remaining_input: usize,
    
    /// Grammar rules being processed
    pub active_rules: Vec<String>,
    
    /// Effects tracked up to this point
    pub effects: Vec<String>,
    
    /// Ambiguity information
    pub ambiguity: Option<AmbiguityInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ParseState {
    /// Current grammar rule
    pub rule: String,
    
    /// Position in the rule
    pub position: usize,
    
    /// Stack depth
    pub stack_depth: usize,
    
    /// Current non-terminal being parsed
    pub nonterminal: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AmbiguityInfo {
    /// Number of possible parse trees at this point
    pub parse_trees: usize,
    
    /// Conflicting rules
    pub conflicting_rules: Vec<String>,
    
    /// Ambiguity type
    pub ambiguity_type: AmbiguityType,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AmbiguityType {
    /// Shift/reduce conflict
    ShiftReduce,
    /// Reduce/reduce conflict
    ReduceReduce,
    /// Left recursion ambiguity
    LeftRecursion,
    /// Operator precedence ambiguity
    Precedence,
}

impl ParseError {
    /// Create a new syntax error
    pub fn syntax(message: impl Into<String>, location: ErrorLocation) -> Self {
        Self {
            category: ErrorCategory::Syntax,
            message: message.into(),
            code: "E001".to_string(),
            location,
            context: ErrorContext::default(),
            suggestions: Vec::new(),
            metadata: ErrorMetadata::default(),
        }
    }
    
    /// Add context to the error
    pub fn with_context(mut self, context: ErrorContext) -> Self {
        self.context = context;
        self
    }
    
    /// Add a suggestion
    pub fn add_suggestion(mut self, suggestion: Suggestion) -> Self {
        self.suggestions.push(suggestion);
        self
    }
    
    /// Set metadata
    pub fn with_metadata(mut self, metadata: ErrorMetadata) -> Self {
        self.metadata = metadata;
        self
    }
    
    /// Generate AI-friendly JSON representation
    pub fn to_ai_json(&self) -> String {
        serde_json::to_string_pretty(self).unwrap_or_else(|_| "{}".to_string())
    }
    
    /// Generate human-readable error message
    pub fn to_human_readable(&self) -> String {
        let mut output = String::new();
        
        // Header
        output.push_str(&format!("ERROR[{}]: {}\n", 
            self.category_str(), 
            self.message
        ));
        
        // Location
        if let Some(ref file) = self.location.file {
            output.push_str(&format!("Location: {}:{}:{}\n", 
                file, 
                self.location.line, 
                self.location.column
            ));
        } else {
            output.push_str(&format!("Location: line {}, column {}\n", 
                self.location.line, 
                self.location.column
            ));
        }
        
        // Context
        if !self.context.before.is_empty() || !self.context.after.is_empty() {
            output.push_str("\nContext:\n");
            for line in &self.context.before {
                output.push_str(&format!("  {}\n", line));
            }
            output.push_str(&format!("> {}\n", self.context.error_line));
            output.push_str(&format!("  {}^\n", " ".repeat(self.location.column - 1)));
            for line in &self.context.after {
                output.push_str(&format!("  {}\n", line));
            }
        }
        
        // Expected vs Found
        if !self.context.expected.is_empty() {
            output.push_str(&format!("\nExpected: {}\n", self.context.expected.join(" | ")));
            if let Some(ref found) = self.context.found {
                output.push_str(&format!("Found: {}\n", found));
            }
        }
        
        // Suggestions
        if !self.suggestions.is_empty() {
            output.push_str("\nSuggestions:\n");
            for (i, suggestion) in self.suggestions.iter().enumerate() {
                output.push_str(&format!("  {}. {}\n", i + 1, suggestion.description));
                if !suggestion.replacement.is_empty() {
                    output.push_str(&format!("     Replace with: {}\n", suggestion.replacement));
                }
            }
        }
        
        output
    }
    
    fn category_str(&self) -> &'static str {
        match self.category {
            ErrorCategory::Syntax => "SYNTAX",
            ErrorCategory::Type => "TYPE",
            ErrorCategory::Scope => "SCOPE",
            ErrorCategory::Pattern => "PATTERN",
            ErrorCategory::Module => "MODULE",
            ErrorCategory::Effect => "EFFECT",
            ErrorCategory::Grammar => "GRAMMAR",
        }
    }
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.to_human_readable())
    }
}

impl std::error::Error for ParseError {}

// Default implementations
impl Default for ErrorContext {
    fn default() -> Self {
        Self {
            before: Vec::new(),
            error_line: String::new(),
            after: Vec::new(),
            expected: Vec::new(),
            found: None,
        }
    }
}

impl Default for ErrorMetadata {
    fn default() -> Self {
        Self {
            parse_state: ParseState {
                rule: String::new(),
                position: 0,
                stack_depth: 0,
                nonterminal: None,
            },
            tokens_consumed: 0,
            remaining_input: 0,
            active_rules: Vec::new(),
            effects: Vec::new(),
            ambiguity: None,
        }
    }
}

/// Error builder for convenient error construction
pub struct ParseErrorBuilder {
    error: ParseError,
}

impl ParseErrorBuilder {
    pub fn new(category: ErrorCategory, message: impl Into<String>) -> Self {
        Self {
            error: ParseError {
                category,
                message: message.into(),
                code: Self::default_code(category),
                location: ErrorLocation {
                    file: None,
                    line: 1,
                    column: 1,
                    offset: 0,
                    length: 1,
                },
                context: ErrorContext::default(),
                suggestions: Vec::new(),
                metadata: ErrorMetadata::default(),
            },
        }
    }
    
    pub fn at_location(mut self, line: usize, column: usize) -> Self {
        self.error.location.line = line;
        self.error.location.column = column;
        self
    }
    
    pub fn with_span(mut self, offset: usize, length: usize) -> Self {
        self.error.location.offset = offset;
        self.error.location.length = length;
        self
    }
    
    pub fn expected(mut self, expected: Vec<String>) -> Self {
        self.error.context.expected = expected;
        self
    }
    
    pub fn found(mut self, found: impl Into<String>) -> Self {
        self.error.context.found = Some(found.into());
        self
    }
    
    pub fn suggest(mut self, description: impl Into<String>, replacement: impl Into<String>) -> Self {
        self.error.suggestions.push(Suggestion {
            description: description.into(),
            replacement: replacement.into(),
            confidence: 0.8,
            category: SuggestionCategory::Missing,
        });
        self
    }
    
    pub fn build(self) -> ParseError {
        self.error
    }
    
    fn default_code(category: ErrorCategory) -> String {
        match category {
            ErrorCategory::Syntax => "E001",
            ErrorCategory::Type => "E002",
            ErrorCategory::Scope => "E003",
            ErrorCategory::Pattern => "E004",
            ErrorCategory::Module => "E005",
            ErrorCategory::Effect => "E006",
            ErrorCategory::Grammar => "E007",
        }.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_error_builder() {
        let error = ParseErrorBuilder::new(ErrorCategory::Syntax, "Unexpected token")
            .at_location(5, 10)
            .expected(vec!["identifier".to_string(), "number".to_string()])
            .found("+")
            .suggest("Add identifier before operator", "x +")
            .build();
        
        assert_eq!(error.category, ErrorCategory::Syntax);
        assert_eq!(error.location.line, 5);
        assert_eq!(error.location.column, 10);
        assert_eq!(error.context.expected, vec!["identifier", "number"]);
        assert_eq!(error.context.found, Some("+".to_string()));
        assert_eq!(error.suggestions.len(), 1);
    }
    
    #[test]
    fn test_ai_json_output() {
        let error = ParseError::syntax("Missing semicolon", ErrorLocation {
            file: Some("test.vibe".to_string()),
            line: 10,
            column: 15,
            offset: 150,
            length: 1,
        });
        
        let json = error.to_ai_json();
        
        // Check for capitalized "Syntax" in the serialized JSON (with space due to pretty print)
        assert!(json.contains("\"category\": \"Syntax\""), "JSON was: {}", json);
        assert!(json.contains("\"message\": \"Missing semicolon\""));
        assert!(json.contains("\"line\": 10"));
    }
}