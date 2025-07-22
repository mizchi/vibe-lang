//! Improved type checker with AI-friendly error messages

use xs_core::error_context::{ErrorBuilder, ErrorCategory};
use xs_core::{Ident, Span, Type, XsError};

/// Helper functions for generating better type error messages
#[allow(dead_code)]
pub struct TypeErrorHelper {
    /// Known variable names for similarity suggestions
    known_names: Vec<String>,
}

#[allow(dead_code)]
impl TypeErrorHelper {
    #[allow(dead_code)]
    pub fn new() -> Self {
        Self {
            known_names: Vec::new(),
        }
    }

    #[allow(dead_code)]
    pub fn with_known_names(mut self, names: Vec<String>) -> Self {
        self.known_names = names;
        self
    }

    /// Generate improved type mismatch error
    #[allow(dead_code)]
    pub fn type_mismatch(&self, expected: &Type, actual: &Type, span: Span) -> XsError {
        let context = ErrorBuilder::type_mismatch(expected.clone(), actual.clone())
            .with_snippet("", span.clone()) // Source will be added later
            .suggest_high_confidence(
                self.suggest_type_conversion(actual, expected),
                self.conversion_code(actual, expected),
            )
            .build();

        XsError::TypeError(span, context.to_ai_format())
    }

    /// Generate improved undefined variable error
    #[allow(dead_code)]
    pub fn undefined_variable(&self, name: &str, _span: Span) -> XsError {
        let similar = self.find_similar_names(name);
        let mut builder =
            ErrorBuilder::undefined_variable(name).with_similar_names(name, similar.clone());

        if let Some(best_match) = similar.first() {
            builder = builder.suggest_high_confidence(
                format!("Did you mean '{best_match}'?"),
                best_match.clone(),
            );
        }

        let _context = builder.build();
        XsError::UndefinedVariable(Ident(name.to_string()))
    }

    /// Suggest type conversion based on types
    #[allow(dead_code)]
    fn suggest_type_conversion(&self, from: &Type, to: &Type) -> String {
        match (from, to) {
            (Type::String, Type::Int) => {
                "Convert string to integer using 'int_of_string'".to_string()
            }
            (Type::Int, Type::String) => {
                "Convert integer to string using 'string_of_int'".to_string()
            }
            (Type::Float, Type::Int) => "Convert float to integer using 'int_of_float'".to_string(),
            (Type::Int, Type::Float) => "Convert integer to float using 'float_of_int'".to_string(),
            (Type::List(_), Type::Int) => "Get list length using 'length' function".to_string(),
            (Type::Bool, Type::String) => {
                "Convert boolean to string using 'string_of_bool'".to_string()
            }
            _ => format!(
                "Type '{}' cannot be used where '{}' is expected",
                self.type_to_readable(from),
                self.type_to_readable(to)
            ),
        }
    }

    /// Generate conversion code
    #[allow(dead_code)]
    fn conversion_code(&self, from: &Type, to: &Type) -> String {
        match (from, to) {
            (Type::String, Type::Int) => "(int_of_string <expr>)".to_string(),
            (Type::Int, Type::String) => "(string_of_int <expr>)".to_string(),
            (Type::Float, Type::Int) => "(int_of_float <expr>)".to_string(),
            (Type::Int, Type::Float) => "(float_of_int <expr>)".to_string(),
            (Type::List(_), Type::Int) => "(length <expr>)".to_string(),
            (Type::Bool, Type::String) => "(string_of_bool <expr>)".to_string(),
            _ => "<no automatic conversion available>".to_string(),
        }
    }

    /// Convert type to readable string
    #[allow(dead_code)]
    #[allow(clippy::only_used_in_recursion)]
    fn type_to_readable(&self, ty: &Type) -> String {
        match ty {
            Type::Int => "integer".to_string(),
            Type::Bool => "boolean".to_string(),
            Type::String => "string".to_string(),
            Type::Float => "floating-point number".to_string(),
            Type::List(t) => format!("list of {}", self.type_to_readable(t)),
            Type::Function(a, b) => format!(
                "function from {} to {}",
                self.type_to_readable(a),
                self.type_to_readable(b)
            ),
            Type::FunctionWithEffect { from, to, effects } => {
                if effects.is_pure() {
                    format!(
                        "function from {} to {}",
                        self.type_to_readable(from),
                        self.type_to_readable(to)
                    )
                } else {
                    format!(
                        "function from {} to {} with effects {}",
                        self.type_to_readable(from),
                        self.type_to_readable(to),
                        effects
                    )
                }
            }
            Type::Var(v) => format!("type variable {v}"),
            Type::UserDefined { name, type_params } => {
                if type_params.is_empty() {
                    name.to_string()
                } else {
                    format!("{} with {} type parameter(s)", name, type_params.len())
                }
            }
        }
    }

    /// Find similar variable names using edit distance
    #[allow(dead_code)]
    fn find_similar_names(&self, name: &str) -> Vec<String> {
        let mut candidates: Vec<(String, usize)> = self
            .known_names
            .iter()
            .filter_map(|known| {
                let distance = levenshtein_distance(name, known);
                if distance <= 2 {
                    Some((known.clone(), distance))
                } else {
                    None
                }
            })
            .collect();

        candidates.sort_by_key(|(_, dist)| *dist);
        candidates
            .into_iter()
            .map(|(name, _)| name)
            .take(3)
            .collect()
    }
}

/// Calculate Levenshtein distance between two strings
#[allow(dead_code)]
fn levenshtein_distance(s1: &str, s2: &str) -> usize {
    let len1 = s1.chars().count();
    let len2 = s2.chars().count();
    let mut matrix = vec![vec![0; len2 + 1]; len1 + 1];

    for (i, row) in matrix.iter_mut().enumerate().take(len1 + 1) {
        row[0] = i;
    }
    for j in 0..=len2 {
        matrix[0][j] = j;
    }

    for (i, c1) in s1.chars().enumerate() {
        for (j, c2) in s2.chars().enumerate() {
            let cost = if c1 == c2 { 0 } else { 1 };
            matrix[i + 1][j + 1] = std::cmp::min(
                std::cmp::min(
                    matrix[i][j + 1] + 1, // deletion
                    matrix[i + 1][j] + 1, // insertion
                ),
                matrix[i][j] + cost, // substitution
            );
        }
    }

    matrix[len1][len2]
}

/// Pattern matching error helper
#[allow(dead_code)]
pub fn pattern_error_helper(pattern_type: &Type, value_type: &Type, span: Span) -> XsError {
    let mut builder = ErrorBuilder::new(
        ErrorCategory::Pattern,
        format!(
            "Pattern expects type '{}' but value has type '{}'",
            type_string(pattern_type),
            type_string(value_type)
        ),
    );

    // Add specific suggestions for common pattern mistakes
    match (pattern_type, value_type) {
        (Type::List(_), Type::UserDefined { name, .. }) if name == "Nil" || name == "Cons" => {
            builder = builder.suggest(
                "Use (list) pattern for empty lists or (list h t) for cons patterns",
                Some("(match expr ((list) ...) ((list h t) ...))".to_string()),
            );
        }
        (Type::UserDefined { name: p_name, .. }, Type::UserDefined { name: v_name, .. })
            if p_name != v_name =>
        {
            builder = builder.suggest(
                format!("Expected constructor '{p_name}' but found '{v_name}'"),
                None,
            );
        }
        _ => {}
    }

    let context = builder.build();
    XsError::TypeError(span, context.to_ai_format())
}

#[allow(dead_code)]
fn type_string(ty: &Type) -> String {
    match ty {
        Type::Int => "Int".to_string(),
        Type::Bool => "Bool".to_string(),
        Type::String => "String".to_string(),
        Type::Float => "Float".to_string(),
        Type::List(t) => format!("(List {})", type_string(t)),
        Type::Function(a, b) => format!("({} -> {})", type_string(a), type_string(b)),
        Type::FunctionWithEffect { from, to, effects } => {
            if effects.is_pure() {
                format!("({} -> {})", type_string(from), type_string(to))
            } else {
                format!("({} -> {} ! {effects})", type_string(from), type_string(to))
            }
        }
        Type::Var(v) => v.clone(),
        Type::UserDefined { name, type_params } => {
            if type_params.is_empty() {
                name.to_string()
            } else {
                format!(
                    "({} {})",
                    name,
                    type_params
                        .iter()
                        .map(type_string)
                        .collect::<Vec<_>>()
                        .join(" ")
                )
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_type_mismatch_suggestions() {
        let helper = TypeErrorHelper::new();
        let error = helper.type_mismatch(&Type::String, &Type::Int, Span::new(0, 10));

        match error {
            XsError::TypeError(_, msg) => {
                assert!(msg.contains("Convert integer to string"));
                assert!(msg.contains("string_of_int"));
            }
            _ => panic!("Expected TypeError"),
        }
    }

    #[test]
    fn test_similar_name_suggestions() {
        let helper = TypeErrorHelper::new().with_known_names(vec![
            "map".to_string(),
            "filter".to_string(),
            "fold".to_string(),
        ]);

        let error = helper.undefined_variable("mpa", Span::new(0, 3));

        match error {
            XsError::UndefinedVariable(ident) => {
                assert_eq!(ident.0, "mpa");
            }
            _ => panic!("Expected UndefinedVariable"),
        }
    }

    #[test]
    fn test_levenshtein_distance() {
        assert_eq!(levenshtein_distance("map", "mpa"), 2);
        assert_eq!(levenshtein_distance("filter", "fitler"), 2);
        assert_eq!(levenshtein_distance("same", "same"), 0);
    }
}
