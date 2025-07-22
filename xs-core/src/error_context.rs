//! AI-friendly error reporting with rich context

use crate::{Expr, Pattern, Span, Type};
use std::fmt;

/// Rich error context for AI understanding
#[derive(Debug, Clone)]
pub struct ErrorContext {
    /// The main error message
    pub message: String,
    /// The error category for classification
    pub category: ErrorCategory,
    /// Source code snippet with error location
    pub snippet: Option<CodeSnippet>,
    /// Suggested fixes
    pub suggestions: Vec<Suggestion>,
    /// Related errors or warnings
    pub related: Vec<RelatedInfo>,
    /// Structured data for AI processing
    pub metadata: ErrorMetadata,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ErrorCategory {
    Syntax,
    Type,
    Scope,
    Pattern,
    Module,
    Runtime,
}

#[derive(Debug, Clone)]
pub struct CodeSnippet {
    pub source: String,
    pub span: Span,
    pub line_number: usize,
    pub column_number: usize,
    pub highlighted_text: String,
}

#[derive(Debug, Clone)]
pub struct Suggestion {
    pub description: String,
    pub replacement: Option<String>,
    pub confidence: SuggestionConfidence,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SuggestionConfidence {
    High,
    Medium,
    Low,
}

#[derive(Debug, Clone)]
pub struct RelatedInfo {
    pub message: String,
    pub location: Option<Span>,
    pub severity: Severity,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Severity {
    Error,
    Warning,
    Info,
}

#[derive(Debug, Clone)]
pub struct ErrorMetadata {
    /// Expected type in type errors
    pub expected_type: Option<Type>,
    /// Actual type in type errors
    pub actual_type: Option<Type>,
    /// Undefined identifier
    pub undefined_name: Option<String>,
    /// Available similar names
    pub similar_names: Vec<String>,
    /// Pattern that failed to match
    pub failed_pattern: Option<Pattern>,
    /// Expression that caused the error
    pub error_expr: Option<Box<Expr>>,
}

impl ErrorContext {
    pub fn new(message: String, category: ErrorCategory) -> Self {
        Self {
            message,
            category,
            snippet: None,
            suggestions: Vec::new(),
            related: Vec::new(),
            metadata: ErrorMetadata {
                expected_type: None,
                actual_type: None,
                undefined_name: None,
                similar_names: Vec::new(),
                failed_pattern: None,
                error_expr: None,
            },
        }
    }

    pub fn with_snippet(mut self, source: &str, span: Span) -> Self {
        let (line_number, column_number, highlighted) = extract_snippet(source, &span);
        self.snippet = Some(CodeSnippet {
            source: source.to_string(),
            span,
            line_number,
            column_number,
            highlighted_text: highlighted,
        });
        self
    }

    pub fn with_suggestion(mut self, suggestion: Suggestion) -> Self {
        self.suggestions.push(suggestion);
        self
    }

    pub fn with_type_info(mut self, expected: Type, actual: Type) -> Self {
        self.metadata.expected_type = Some(expected);
        self.metadata.actual_type = Some(actual);
        self
    }

    pub fn with_undefined_name(mut self, name: &str, similar: Vec<String>) -> Self {
        self.metadata.undefined_name = Some(name.to_string());
        self.metadata.similar_names = similar;
        self
    }

    /// Format for AI consumption (structured)
    pub fn to_ai_format(&self) -> String {
        let mut parts = vec![format!("ERROR[{}]: {}", self.category_str(), self.message)];

        if let Some(ref snippet) = self.snippet {
            parts.push(format!(
                "Location: line {}, column {}",
                snippet.line_number, snippet.column_number
            ));
            parts.push(format!("Code: {}", snippet.highlighted_text));
        }

        if let Some(ref expected) = self.metadata.expected_type {
            if let Some(ref actual) = self.metadata.actual_type {
                parts.push(format!(
                    "Type mismatch: expected {expected:?}, found {actual:?}"
                ));
            }
        }

        if let Some(ref name) = self.metadata.undefined_name {
            parts.push(format!("Undefined: '{name}'"));
            if !self.metadata.similar_names.is_empty() {
                parts.push(format!(
                    "Similar: {}",
                    self.metadata.similar_names.join(", ")
                ));
            }
        }

        if !self.suggestions.is_empty() {
            parts.push("Suggestions:".to_string());
            for (i, suggestion) in self.suggestions.iter().enumerate() {
                parts.push(format!("  {}. {}", i + 1, suggestion.description));
                if let Some(ref replacement) = suggestion.replacement {
                    parts.push(format!("     Replace with: {replacement}"));
                }
            }
        }

        parts.join("\n")
    }

    fn category_str(&self) -> &str {
        match self.category {
            ErrorCategory::Syntax => "SYNTAX",
            ErrorCategory::Type => "TYPE",
            ErrorCategory::Scope => "SCOPE",
            ErrorCategory::Pattern => "PATTERN",
            ErrorCategory::Module => "MODULE",
            ErrorCategory::Runtime => "RUNTIME",
        }
    }
}

impl fmt::Display for ErrorContext {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.to_ai_format())
    }
}

fn extract_snippet(source: &str, span: &Span) -> (usize, usize, String) {
    let mut line_number = 1;
    let mut column_number = 1;

    for (i, ch) in source.chars().enumerate() {
        if i == span.start {
            break;
        }
        if ch == '\n' {
            line_number += 1;
            column_number = 1;
        } else {
            column_number += 1;
        }
    }

    // Extract the line containing the error
    let line_start = source[..span.start].rfind('\n').map(|i| i + 1).unwrap_or(0);
    let line_end = source[span.start..]
        .find('\n')
        .map(|i| span.start + i)
        .unwrap_or(source.len());
    let line = &source[line_start..line_end];

    (line_number, column_number, line.to_string())
}

/// Builder for creating rich error contexts
pub struct ErrorBuilder {
    context: ErrorContext,
}

impl ErrorBuilder {
    pub fn new(category: ErrorCategory, message: impl Into<String>) -> Self {
        Self {
            context: ErrorContext::new(message.into(), category),
        }
    }

    pub fn type_mismatch(expected: Type, actual: Type) -> Self {
        let message = format!(
            "Type mismatch: expected type '{}', but found type '{}'",
            type_to_string(&expected),
            type_to_string(&actual)
        );
        Self::new(ErrorCategory::Type, message).with_types(expected, actual)
    }

    pub fn undefined_variable(name: &str) -> Self {
        let message = format!("Undefined variable: '{name}'");
        Self::new(ErrorCategory::Scope, message)
    }

    pub fn pattern_mismatch(pattern: &Pattern, value_type: &Type) -> Self {
        let message = format!(
            "Pattern '{}' does not match value of type '{}'",
            pattern_to_string(pattern),
            type_to_string(value_type)
        );
        Self::new(ErrorCategory::Pattern, message)
    }

    pub fn with_types(mut self, expected: Type, actual: Type) -> Self {
        self.context = self.context.with_type_info(expected, actual);
        self
    }

    pub fn with_snippet(mut self, source: &str, span: Span) -> Self {
        self.context = self.context.with_snippet(source, span);
        self
    }

    pub fn suggest(mut self, description: impl Into<String>, replacement: Option<String>) -> Self {
        self.context.suggestions.push(Suggestion {
            description: description.into(),
            replacement,
            confidence: SuggestionConfidence::Medium,
        });
        self
    }

    pub fn suggest_high_confidence(
        mut self,
        description: impl Into<String>,
        replacement: String,
    ) -> Self {
        self.context.suggestions.push(Suggestion {
            description: description.into(),
            replacement: Some(replacement),
            confidence: SuggestionConfidence::High,
        });
        self
    }

    pub fn with_similar_names(mut self, name: &str, similar: Vec<String>) -> Self {
        self.context = self.context.with_undefined_name(name, similar);
        self
    }

    pub fn build(self) -> ErrorContext {
        self.context
    }
}

// Helper functions for formatting
fn type_to_string(ty: &Type) -> String {
    match ty {
        Type::Int => "Int".to_string(),
        Type::Bool => "Bool".to_string(),
        Type::String => "String".to_string(),
        Type::Float => "Float".to_string(),
        Type::List(t) => format!("List[{}]", type_to_string(t)),
        Type::Function(a, b) => format!("{} -> {}", type_to_string(a), type_to_string(b)),
        Type::FunctionWithEffect { from, to, effects } => {
            if effects.is_pure() {
                format!("{} -> {}", type_to_string(from), type_to_string(to))
            } else {
                format!(
                    "{} -> {} ! {}",
                    type_to_string(from),
                    type_to_string(to),
                    effects
                )
            }
        }
        Type::Var(v) => format!("'{v}"),
        Type::UserDefined { name, .. } => name.clone(),
        Type::Record { fields } => {
            let field_strs: Vec<String> = fields.iter()
                .map(|(name, ty)| format!("{}: {}", name, type_to_string(ty)))
                .collect();
            format!("{{ {} }}", field_strs.join(", "))
        },
        // Note: Type::Constructor doesn't exist in current implementation
        // ADT types are represented differently
    }
}

fn pattern_to_string(pattern: &Pattern) -> String {
    match pattern {
        Pattern::Variable(ident, _) => ident.0.clone(),
        Pattern::Wildcard(_) => "_".to_string(),
        Pattern::Literal(lit, _) => format!("{lit:?}"),
        Pattern::List { patterns, .. } => {
            let items = patterns
                .iter()
                .map(pattern_to_string)
                .collect::<Vec<_>>()
                .join(", ");
            format!("[{items}]")
        }
        Pattern::Constructor { name, patterns, .. } => {
            let args = patterns
                .iter()
                .map(pattern_to_string)
                .collect::<Vec<_>>()
                .join(", ");
            if args.is_empty() {
                name.0.clone()
            } else {
                format!("{}({})", name.0, args)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_type_mismatch_error() {
        let error = ErrorBuilder::type_mismatch(Type::Int, Type::String)
            .suggest(
                "Consider converting the string to an integer",
                Some("int_of_string".to_string()),
            )
            .build();

        let ai_format = error.to_ai_format();
        assert!(ai_format.contains("Type mismatch"));
        assert!(ai_format.contains("expected Int"));
        assert!(ai_format.contains("found String"));
    }

    #[test]
    fn test_undefined_variable_error() {
        let error = ErrorBuilder::undefined_variable("foo")
            .with_similar_names("foo", vec!["for".to_string(), "fold".to_string()])
            .suggest_high_confidence("Did you mean 'for'?", "for".to_string())
            .build();

        let ai_format = error.to_ai_format();
        assert!(ai_format.contains("Undefined: 'foo'"));
        assert!(ai_format.contains("Similar: for, fold"));
        assert!(ai_format.contains("Did you mean 'for'?"));
    }

    #[test]
    fn test_snippet_extraction() {
        let source = "let x = 42\nlet y = true\nlet z = x + y";
        let span = Span::new(24, 37); // "let z = x + y"

        let error = ErrorBuilder::type_mismatch(Type::Int, Type::Bool)
            .with_snippet(source, span)
            .build();

        assert!(error.snippet.is_some());
        let snippet = error.snippet.unwrap();
        assert_eq!(snippet.line_number, 3);
        assert_eq!(snippet.highlighted_text, "let z = x + y");
    }
}
