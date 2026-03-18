//! Tree-sitter grammar for the Vibe programming language.

use std::sync::OnceLock;

extern "C" {
    fn tree_sitter_vibe() -> *const ();
}

static LANGUAGE: OnceLock<tree_sitter::Language> = OnceLock::new();

/// Returns the tree-sitter [`Language`] for Vibe.
pub fn language() -> &'static tree_sitter::Language {
    LANGUAGE.get_or_init(|| unsafe {
        let ptr = tree_sitter_vibe();
        tree_sitter::Language::from_raw(ptr)
    })
}

/// The content of the [`node-types.json`] file for this grammar.
pub const NODE_TYPES: &str = include_str!("../../src/node-types.json");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_can_load_grammar() {
        let mut parser = tree_sitter::Parser::new();
        parser
            .set_language(language())
            .expect("Error loading Vibe grammar");
    }
}
