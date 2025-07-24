use std::collections::HashMap;
use tower_lsp::lsp_types::{Position, Range};
use xs_core::{Expr, Span};

/// Maps between source positions and AST nodes
#[derive(Debug, Clone)]
pub struct SourceMap {
    /// Maps from byte position to line/column
    position_map: Vec<(usize, usize)>, // (line, column)
    
    /// Maps from AST node to source range
    node_ranges: HashMap<usize, Range>,
    
    /// Source text for reference
    source: String,
}

impl SourceMap {
    pub fn from_ast(expr: &Expr, source: &str) -> Self {
        let mut source_map = Self {
            position_map: Self::build_position_map(source),
            node_ranges: HashMap::new(),
            source: source.to_string(),
        };
        
        source_map.visit_expr(expr);
        source_map
    }

    fn build_position_map(source: &str) -> Vec<(usize, usize)> {
        let mut map = Vec::with_capacity(source.len());
        let mut line = 0;
        let mut column = 0;
        
        for ch in source.chars() {
            map.push((line, column));
            if ch == '\n' {
                line += 1;
                column = 0;
            } else {
                column += 1;
            }
        }
        
        map
    }

    fn visit_expr(&mut self, expr: &Expr) {
        match expr {
            Expr::Literal(_, span) => {
                self.add_node_range(span, expr);
            }
            Expr::Ident(_, span) => {
                self.add_node_range(span, expr);
            }
            Expr::Lambda { body, span, .. } => {
                self.add_node_range(span, expr);
                self.visit_expr(body);
            }
            Expr::Apply { func, args, span } => {
                self.add_node_range(span, expr);
                self.visit_expr(func);
                for arg in args {
                    self.visit_expr(arg);
                }
            }
            Expr::Let { value, span, .. } => {
                self.add_node_range(span, expr);
                self.visit_expr(value);
            }
            Expr::LetRec { value, span, .. } => {
                self.add_node_range(span, expr);
                self.visit_expr(value);
            }
            Expr::LetIn { value, body, span, .. } => {
                self.add_node_range(span, expr);
                self.visit_expr(value);
                self.visit_expr(body);
            }
            Expr::LetRecIn { value, body, span, .. } => {
                self.add_node_range(span, expr);
                self.visit_expr(value);
                self.visit_expr(body);
            }
            Expr::If { cond, then_expr, else_expr, span } => {
                self.add_node_range(span, expr);
                self.visit_expr(cond);
                self.visit_expr(then_expr);
                self.visit_expr(else_expr);
            }
            Expr::Match { expr: scrutinee, cases, span } => {
                self.add_node_range(span, expr);
                self.visit_expr(scrutinee);
                for (_, case_expr) in cases {
                    self.visit_expr(case_expr);
                }
            }
            Expr::List(elements, span) => {
                self.add_node_range(span, expr);
                for elem in elements {
                    self.visit_expr(elem);
                }
            }
            Expr::RecordAccess { record, span, .. } => {
                self.add_node_range(span, expr);
                self.visit_expr(record);
            }
            Expr::Module { body, span, .. } => {
                self.add_node_range(span, expr);
                for item in body {
                    self.visit_expr(item);
                }
            }
            Expr::Perform { args, span, .. } => {
                self.add_node_range(span, expr);
                for arg in args {
                    self.visit_expr(arg);
                }
            }
            Expr::Rec { body, span, .. } => {
                self.add_node_range(span, expr);
                self.visit_expr(body);
            }
            Expr::Block { exprs, span } => {
                self.add_node_range(span, expr);
                for e in exprs {
                    self.visit_expr(e);
                }
            }
            Expr::Constructor { span, .. } => {
                self.add_node_range(span, expr);
            }
            Expr::TypeDef { span, .. } => {
                self.add_node_range(span, expr);
            }
            Expr::Import { span, .. } => {
                self.add_node_range(span, expr);
            }
            Expr::Use { span, .. } => {
                self.add_node_range(span, expr);
            }
            Expr::QualifiedIdent { span, .. } => {
                self.add_node_range(span, expr);
            }
            Expr::Handler { body, span, .. } => {
                self.add_node_range(span, expr);
                self.visit_expr(body);
            }
            Expr::WithHandler { body, handler, span } => {
                self.add_node_range(span, expr);
                self.visit_expr(body);
                self.visit_expr(handler);
            }
            Expr::RecordUpdate { record, span, .. } => {
                self.add_node_range(span, expr);
                self.visit_expr(record);
            }
            _ => {}
        }
    }

    fn add_node_range(&mut self, span: &Span, expr: &Expr) {
        if let Some(range) = self.span_to_range(span) {
            // Use pointer as unique identifier for the node
            let node_id = expr as *const _ as usize;
            self.node_ranges.insert(node_id, range);
        }
    }

    pub fn span_to_range(&self, span: &Span) -> Option<Range> {
        let start_pos = self.position_map.get(span.start)?;
        let end_pos = self.position_map.get(span.end.saturating_sub(1))
            .or_else(|| self.position_map.last())?;
        
        Some(Range {
            start: Position {
                line: start_pos.0 as u32,
                character: start_pos.1 as u32,
            },
            end: Position {
                line: end_pos.0 as u32,
                character: (end_pos.1 + 1) as u32,
            },
        })
    }

    pub fn position_to_offset(&self, position: Position) -> Option<usize> {
        let target_line = position.line as usize;
        let target_char = position.character as usize;
        
        self.position_map.iter()
            .position(|(line, col)| *line == target_line && *col == target_char)
    }

    pub fn find_node_at_position(&self, position: Position) -> Option<Range> {
        let _offset = self.position_to_offset(position)?;
        
        // Find the smallest range containing the position
        let mut best_range: Option<Range> = None;
        let mut best_size = usize::MAX;
        
        for range in self.node_ranges.values() {
            if self.range_contains_position(range, position) {
                let size = self.range_size(range);
                if size < best_size {
                    best_size = size;
                    best_range = Some(range.clone());
                }
            }
        }
        
        best_range
    }

    fn range_contains_position(&self, range: &Range, position: Position) -> bool {
        (range.start.line < position.line || 
         (range.start.line == position.line && range.start.character <= position.character)) &&
        (range.end.line > position.line ||
         (range.end.line == position.line && range.end.character >= position.character))
    }

    fn range_size(&self, range: &Range) -> usize {
        if range.start.line == range.end.line {
            (range.end.character - range.start.character) as usize
        } else {
            // Approximate size for multi-line ranges
            ((range.end.line - range.start.line) as usize * 80) +
            range.end.character as usize
        }
    }
}