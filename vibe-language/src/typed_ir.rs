use crate::{Type, Effect, Literal};
use crate::ir::TypedIrExpr;
use serde::{Serialize, Deserialize};

/// Enhanced Typed IR with metadata for source preservation
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TypedIR {
    /// Content hash for this IR node
    pub hash: ContentHash,
    /// The typed expression
    pub expr: TypedIrExpr,
    /// Metadata for source reconstruction
    pub metadata: IRMetadata,
}

/// Content hash for content-addressed storage
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub struct ContentHash(pub String);

impl ContentHash {
    /// Create a new content hash from bytes
    pub fn new(bytes: &[u8]) -> Self {
        let hash = blake3::hash(bytes);
        ContentHash(hash.to_hex().to_string())
    }

    /// Create from an existing hash string
    pub fn from_string(s: String) -> Self {
        ContentHash(s)
    }
}

/// Metadata for preserving source information
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct IRMetadata {
    /// Original source syntax information
    pub source_syntax: SourceSyntax,
    /// Comments associated with this node
    pub comments: Vec<String>,
    /// Formatting preferences
    pub formatting: FormatPreferences,
    /// Source location information
    pub location: Option<SourceLocation>,
    /// Parent module/namespace
    pub namespace: Option<String>,
    /// Variable capture information
    pub captures: Vec<ContentHash>,
}

/// Information about the original source syntax
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SourceSyntax {
    /// Original syntax style (e.g., "let-in", "where", "fn", etc.)
    pub style: SyntaxStyle,
    /// Whether parentheses were used
    pub parenthesized: bool,
    /// Whether braces were used
    pub braced: bool,
    /// Original operator fixity if applicable
    pub fixity: Option<Fixity>,
    /// Original syntax sugar used
    pub sugar: Vec<SyntaxSugar>,
}

/// Syntax styles for different constructs
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum SyntaxStyle {
    /// let x = e in body
    LetIn,
    /// expr where x = e
    Where,
    /// fn x -> e
    FnArrow,
    /// \x -> e
    Lambda,
    /// function x = e
    Function,
    /// if-then-else
    IfThenElse,
    /// case-of
    CaseOf,
    /// match-with
    MatchWith,
    /// do-notation
    DoNotation,
    /// Pipeline operator
    Pipeline,
    /// Dollar operator
    Dollar,
}

/// Operator fixity information
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Fixity {
    pub associativity: Associativity,
    pub precedence: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum Associativity {
    Left,
    Right,
    None,
}

/// Syntax sugar that was used
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum SyntaxSugar {
    /// List literal [1, 2, 3]
    ListLiteral,
    /// String interpolation
    StringInterpolation,
    /// Record punning { x, y }
    RecordPunning,
    /// Section (+ 1)
    Section,
    /// Wildcard lambda \_ -> e
    WildcardLambda,
    /// Optional type T?
    OptionalType,
    /// Tuple syntax
    TupleSyntax,
}

/// Formatting preferences from the original source
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FormatPreferences {
    /// Indentation style
    pub indent_style: IndentStyle,
    /// Indentation width
    pub indent_width: usize,
    /// Line ending style
    pub line_ending: LineEnding,
    /// Maximum line width
    pub max_width: usize,
    /// Trailing comma preference
    pub trailing_comma: TrailingComma,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum IndentStyle {
    Spaces,
    Tabs,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum LineEnding {
    Lf,
    CrLf,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum TrailingComma {
    Always,
    Never,
    Multiline,
}

/// Source location information
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SourceLocation {
    pub file: Option<String>,
    pub start_line: usize,
    pub start_column: usize,
    pub end_line: usize,
    pub end_column: usize,
}

/// Builder for TypedIR
pub struct TypedIRBuilder {
    metadata: IRMetadata,
}

impl TypedIRBuilder {
    pub fn new() -> Self {
        Self {
            metadata: IRMetadata {
                source_syntax: SourceSyntax {
                    style: SyntaxStyle::LetIn,
                    parenthesized: false,
                    braced: false,
                    fixity: None,
                    sugar: vec![],
                },
                comments: vec![],
                formatting: FormatPreferences::default(),
                location: None,
                namespace: None,
                captures: vec![],
            },
        }
    }

    pub fn with_style(mut self, style: SyntaxStyle) -> Self {
        self.metadata.source_syntax.style = style;
        self
    }

    pub fn with_location(mut self, location: SourceLocation) -> Self {
        self.metadata.location = Some(location);
        self
    }

    pub fn with_namespace(mut self, namespace: String) -> Self {
        self.metadata.namespace = Some(namespace);
        self
    }

    pub fn with_comments(mut self, comments: Vec<String>) -> Self {
        self.metadata.comments = comments;
        self
    }

    pub fn with_sugar(mut self, sugar: Vec<SyntaxSugar>) -> Self {
        self.metadata.source_syntax.sugar = sugar;
        self
    }

    pub fn build(self, expr: TypedIrExpr) -> TypedIR {
        // Calculate content hash
        let serialized = bincode::serialize(&expr).unwrap();
        let hash = ContentHash::new(&serialized);

        TypedIR {
            hash,
            expr,
            metadata: self.metadata,
        }
    }
}

impl Default for FormatPreferences {
    fn default() -> Self {
        Self {
            indent_style: IndentStyle::Spaces,
            indent_width: 2,
            line_ending: LineEnding::Lf,
            max_width: 100,
            trailing_comma: TrailingComma::Multiline,
        }
    }
}

/// Storage format for the codebase
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredTypedIR {
    /// The typed IR
    pub ir: TypedIR,
    /// Type information
    pub ty: Type,
    /// Effect information
    pub effects: Vec<Effect>,
    /// Dependencies (other content hashes)
    pub dependencies: Vec<ContentHash>,
    /// Metadata version for migration
    pub version: u32,
}

impl StoredTypedIR {
    pub const CURRENT_VERSION: u32 = 1;

    pub fn new(ir: TypedIR, ty: Type, effects: Vec<Effect>) -> Self {
        // Extract dependencies from the IR
        let dependencies = Self::extract_dependencies(&ir.expr);
        
        Self {
            ir,
            ty,
            effects,
            dependencies,
            version: Self::CURRENT_VERSION,
        }
    }

    /// Extract content hashes of dependencies
    fn extract_dependencies(_expr: &TypedIrExpr) -> Vec<ContentHash> {
        // TODO: Implement dependency extraction
        // This would walk the expression tree and collect references to other definitions
        vec![]
    }
}

/// Utilities for working with TypedIR
impl TypedIR {
    /// Create a simple TypedIR without metadata
    pub fn simple(expr: TypedIrExpr) -> Self {
        TypedIRBuilder::new().build(expr)
    }

    /// Check if this IR can be displayed using a specific syntax style
    pub fn supports_style(&self, style: &SyntaxStyle) -> bool {
        match (&self.expr, style) {
            (TypedIrExpr::Let { .. }, SyntaxStyle::LetIn) => true,
            (TypedIrExpr::Let { .. }, SyntaxStyle::Where) => true,
            (TypedIrExpr::Lambda { .. }, SyntaxStyle::Lambda) => true,
            (TypedIrExpr::Lambda { .. }, SyntaxStyle::FnArrow) => true,
            (TypedIrExpr::If { .. }, SyntaxStyle::IfThenElse) => true,
            (TypedIrExpr::Match { .. }, SyntaxStyle::CaseOf) => true,
            (TypedIrExpr::Match { .. }, SyntaxStyle::MatchWith) => true,
            _ => false,
        }
    }

    /// Get the type of this IR expression
    pub fn get_type(&self) -> &Type {
        self.expr.get_type()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Type;

    #[test]
    fn test_content_hash() {
        let data = b"hello world";
        let hash1 = ContentHash::new(data);
        let hash2 = ContentHash::new(data);
        assert_eq!(hash1, hash2);

        let different = b"goodbye world";
        let hash3 = ContentHash::new(different);
        assert_ne!(hash1, hash3);
    }

    #[test]
    fn test_typed_ir_builder() {
        let expr = TypedIrExpr::Literal {
            value: Literal::Int(42),
            ty: Type::Int,
        };

        let ir = TypedIRBuilder::new()
            .with_style(SyntaxStyle::LetIn)
            .with_namespace("Math.Utils".to_string())
            .build(expr.clone());

        assert_eq!(ir.expr, expr);
        assert_eq!(ir.metadata.source_syntax.style, SyntaxStyle::LetIn);
        assert_eq!(ir.metadata.namespace, Some("Math.Utils".to_string()));
    }

    #[test]
    fn test_serialization() {
        let expr = TypedIrExpr::Literal {
            value: Literal::Int(42),
            ty: Type::Int,
        };

        let ir = TypedIR::simple(expr);
        
        let serialized = bincode::serialize(&ir).unwrap();
        let deserialized: TypedIR = bincode::deserialize(&serialized).unwrap();
        
        assert_eq!(ir, deserialized);
    }

    #[test]
    fn test_stored_typed_ir() {
        let expr = TypedIrExpr::Literal {
            value: Literal::Int(42),
            ty: Type::Int,
        };

        let ir = TypedIR::simple(expr);
        let stored = StoredTypedIR::new(ir, Type::Int, vec![]);

        assert_eq!(stored.ty, Type::Int);
        assert_eq!(stored.version, StoredTypedIR::CURRENT_VERSION);
        assert!(stored.effects.is_empty());
    }

    #[test]
    fn test_syntax_sugar() {
        let sugar = vec![
            SyntaxSugar::ListLiteral,
            SyntaxSugar::OptionalType,
        ];

        let expr = TypedIrExpr::List {
            elements: vec![],
            elem_ty: Type::Int,
            ty: Type::List(Box::new(Type::Int)),
        };

        let ir = TypedIRBuilder::new()
            .with_sugar(sugar.clone())
            .build(expr);

        assert_eq!(ir.metadata.source_syntax.sugar, sugar);
    }

    #[test]
    fn test_format_preferences() {
        let prefs = FormatPreferences {
            indent_style: IndentStyle::Tabs,
            indent_width: 4,
            line_ending: LineEnding::CrLf,
            max_width: 120,
            trailing_comma: TrailingComma::Always,
        };

        let serialized = bincode::serialize(&prefs).unwrap();
        let deserialized: FormatPreferences = bincode::deserialize(&serialized).unwrap();
        
        assert_eq!(prefs, deserialized);
    }
}