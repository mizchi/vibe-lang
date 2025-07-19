//! Pretty printer that considers metadata when formatting code

use crate::{Expr, Literal, Pattern, Ident, Type, TypeDefinition, Constructor};
use crate::metadata::{MetadataStore, NodeId, MetadataKind};

pub struct PrettyPrinter<'a> {
    metadata_store: Option<&'a MetadataStore>,
    indent_level: usize,
    indent_str: String,
}

impl<'a> PrettyPrinter<'a> {
    pub fn new() -> Self {
        Self {
            metadata_store: None,
            indent_level: 0,
            indent_str: "  ".to_string(),
        }
    }

    pub fn with_metadata(mut self, metadata: &'a MetadataStore) -> Self {
        self.metadata_store = Some(metadata);
        self
    }

    pub fn pretty_print(&self, expr: &Expr) -> String {
        self.format_expr(expr, None)
    }

    pub fn pretty_print_with_node(&self, expr: &Expr, node_id: &NodeId) -> String {
        self.format_expr(expr, Some(node_id))
    }

    fn format_expr(&self, expr: &Expr, node_id: Option<&NodeId>) -> String {
        let mut result = String::new();

        // 前置コメントを追加
        if let Some(id) = node_id {
            if let Some(store) = self.metadata_store {
                for comment in store.get_comments(id) {
                    result.push_str(&self.indent());
                    result.push_str(&format!("; {}\n", comment));
                }
            }
        }

        // 式本体をフォーマット
        let expr_str = match expr {
            Expr::Literal(lit, _) => self.format_literal(lit),
            Expr::Variable(ident, _) => ident.0.clone(),
            Expr::Lambda { params, body, .. } => {
                self.format_lambda(params, body)
            }
            Expr::Application { func, args, .. } => {
                self.format_application(func, args)
            }
            Expr::Let { name, value, .. } => {
                self.format_let(name, value)
            }
            Expr::LetRec { name, params, body, .. } => {
                self.format_let_rec(name, params, body)
            }
            Expr::If { cond, then_expr, else_expr, .. } => {
                self.format_if(cond, then_expr, else_expr)
            }
            Expr::List(items, _) => {
                self.format_list(items)
            }
            Expr::Cons { head, tail, .. } => {
                self.format_cons(head, tail)
            }
            Expr::Match { expr, cases, .. } => {
                self.format_match(expr, cases)
            }
            Expr::Rec { name, params, body, .. } => {
                self.format_rec(name, params, body)
            }
            Expr::TypeDef(typedef) => {
                self.format_type_def(typedef)
            }
            Expr::Constructor { name, args, .. } => {
                self.format_constructor(name, args)
            }
            Expr::Module { name, exports, body, .. } => {
                self.format_module(name, exports, body)
            }
            Expr::Import { module_name, alias, .. } => {
                self.format_import(module_name, alias)
            }
            Expr::QualifiedName { module_name, name, .. } => {
                format!("{}.{}", module_name.0, name.0)
            }
        };

        result.push_str(&self.indent());
        result.push_str(&expr_str);

        // 後置メタデータ（一時変数ラベルなど）を追加
        if let Some(id) = node_id {
            if let Some(store) = self.metadata_store {
                if let Some(label) = store.get_temp_var_label(id) {
                    result.push_str(&format!(" ; => {}", label));
                }
            }
        }

        result
    }

    fn indent(&self) -> String {
        self.indent_str.repeat(self.indent_level)
    }

    fn format_literal(&self, lit: &Literal) -> String {
        match lit {
            Literal::Int(n) => n.to_string(),
            Literal::Float(f) => f.to_string(),
            Literal::Bool(b) => b.to_string(),
            Literal::String(s) => format!("\"{}\"", s),
        }
    }

    fn format_lambda(&self, params: &[(Ident, Option<Type>)], body: &Expr) -> String {
        let params_str = params.iter()
            .map(|(ident, _)| ident.0.clone())
            .collect::<Vec<_>>()
            .join(" ");
        format!("(lambda ({}) {})", params_str, self.format_expr(body, None))
    }

    fn format_application(&self, func: &Expr, args: &[Expr]) -> String {
        let func_str = self.format_expr(func, None);
        let args_str = args.iter()
            .map(|arg| self.format_expr(arg, None))
            .collect::<Vec<_>>()
            .join(" ");
        format!("({} {})", func_str, args_str)
    }

    fn format_let(&self, name: &Ident, value: &Expr) -> String {
        format!("(let {} {})", name.0, self.format_expr(value, None))
    }

    fn format_let_rec(&self, name: &Ident, params: &[(Ident, Option<Type>)], body: &Expr) -> String {
        let params_str = params.iter()
            .map(|(ident, _)| ident.0.clone())
            .collect::<Vec<_>>()
            .join(" ");
        format!("(let-rec {} ({}) {})", name.0, params_str, self.format_expr(body, None))
    }

    fn format_if(&self, cond: &Expr, then_expr: &Expr, else_expr: &Expr) -> String {
        format!(
            "(if {} {} {})",
            self.format_expr(cond, None),
            self.format_expr(then_expr, None),
            self.format_expr(else_expr, None)
        )
    }

    fn format_list(&self, items: &[Expr]) -> String {
        if items.is_empty() {
            "(list)".to_string()
        } else {
            let items_str = items.iter()
                .map(|item| self.format_expr(item, None))
                .collect::<Vec<_>>()
                .join(" ");
            format!("(list {})", items_str)
        }
    }

    fn format_cons(&self, head: &Expr, tail: &Expr) -> String {
        format!(
            "(cons {} {})",
            self.format_expr(head, None),
            self.format_expr(tail, None)
        )
    }

    fn format_match(&self, expr: &Expr, cases: &[(Pattern, Expr)]) -> String {
        let expr_str = self.format_expr(expr, None);
        let cases_str = cases.iter()
            .map(|(pat, expr)| format!("({} {})", self.format_pattern(pat), self.format_expr(expr, None)))
            .collect::<Vec<_>>()
            .join(" ");
        format!("(match {} {})", expr_str, cases_str)
    }

    fn format_pattern(&self, pattern: &Pattern) -> String {
        match pattern {
            Pattern::Variable(ident) => ident.0.clone(),
            Pattern::Wildcard => "_".to_string(),
            Pattern::Literal(lit) => self.format_literal(lit),
            Pattern::List(patterns) => {
                if patterns.is_empty() {
                    "(list)".to_string()
                } else {
                    let patterns_str = patterns.iter()
                        .map(|p| self.format_pattern(p))
                        .collect::<Vec<_>>()
                        .join(" ");
                    format!("(list {})", patterns_str)
                }
            }
            Pattern::Constructor(name, patterns) => {
                let patterns_str = patterns.iter()
                    .map(|p| self.format_pattern(p))
                    .collect::<Vec<_>>()
                    .join(" ");
                format!("({} {})", name.0, patterns_str)
            }
        }
    }

    fn format_rec(&self, name: &Ident, params: &[(Ident, Option<Type>)], body: &Expr) -> String {
        let params_str = params.iter()
            .map(|(ident, _)| ident.0.clone())
            .collect::<Vec<_>>()
            .join(" ");
        format!("(rec {} ({}) {})", name.0, params_str, self.format_expr(body, None))
    }

    fn format_type_def(&self, typedef: &TypeDefinition) -> String {
        let type_params = if typedef.type_params.is_empty() {
            String::new()
        } else {
            format!(" {}", typedef.type_params.join(" "))
        };
        
        let constructors = typedef.constructors.iter()
            .map(|c| self.format_constructor_def(c))
            .collect::<Vec<_>>()
            .join(" ");
        
        format!("(type {}{} {})", typedef.name.0, type_params, constructors)
    }

    fn format_constructor_def(&self, constructor: &Constructor) -> String {
        if constructor.fields.is_empty() {
            format!("({})", constructor.name.0)
        } else {
            let fields = constructor.fields.iter()
                .map(|t| format!("{:?}", t)) // TODO: Proper type formatting
                .collect::<Vec<_>>()
                .join(" ");
            format!("({} {})", constructor.name.0, fields)
        }
    }

    fn format_constructor(&self, name: &Ident, args: &[Expr]) -> String {
        if args.is_empty() {
            name.0.clone()
        } else {
            let args_str = args.iter()
                .map(|arg| self.format_expr(arg, None))
                .collect::<Vec<_>>()
                .join(" ");
            format!("({} {})", name.0, args_str)
        }
    }

    fn format_module(&self, name: &Ident, exports: &[Ident], body: &[Expr]) -> String {
        let exports_str = exports.iter()
            .map(|ident| ident.0.clone())
            .collect::<Vec<_>>()
            .join(" ");
        
        let body_str = body.iter()
            .map(|expr| self.format_expr(expr, None))
            .collect::<Vec<_>>()
            .join("\n");
        
        format!("(module {} (export {}) {})", name.0, exports_str, body_str)
    }

    fn format_import(&self, module_name: &Ident, alias: &Option<Ident>) -> String {
        if let Some(alias) = alias {
            format!("(import {} as {})", module_name.0, alias.0)
        } else {
            format!("(import {})", module_name.0)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Span;
    use crate::metadata::AstBuilder;

    #[test]
    fn test_pretty_print_with_comments() {
        let expr = Expr::Let {
            name: Ident("x".to_string()),
            value: Box::new(Expr::Literal(Literal::Int(42), Span::new(0, 2))),
            span: Span::new(0, 10),
        };

        let mut builder = AstBuilder::new();
        let node_id = NodeId::new();
        builder.with_comment(node_id.clone(), "This is x".to_string(), None);
        builder.with_temp_var(node_id.clone(), "x_temp".to_string(), None);
        let metadata = builder.finish();

        let printer = PrettyPrinter::new().with_metadata(&metadata);
        let result = printer.pretty_print_with_node(&expr, &node_id);

        assert!(result.contains("; This is x"));
        assert!(result.contains("(let x 42)"));
        assert!(result.contains("; => x_temp"));
    }

    #[test]
    fn test_pretty_print_without_metadata() {
        let expr = Expr::Lambda {
            params: vec![(Ident("x".to_string()), None)],
            body: Box::new(Expr::Variable(Ident("x".to_string()), Span::new(0, 1))),
            span: Span::new(0, 10),
        };

        let printer = PrettyPrinter::new();
        let result = printer.pretty_print(&expr);

        assert_eq!(result, "(lambda (x) x)");
    }
}