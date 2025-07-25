pub mod gss;
pub mod sppf;
pub mod parser;

pub use gss::{GSSNode, GSSEdge, GraphStructuredStack};
pub use sppf::{SPPFNode, SharedPackedParseForest};
pub use parser::{GLLParser, GLLGrammar, GLLRule, GLLSymbol};

/// Demo function for complex GLL verification
pub fn demo_complex_gll_verification() {
    println!("Complex GLL verification demo moved to tests");
}