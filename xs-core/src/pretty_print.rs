//! Pretty printer that considers metadata when formatting code

use crate::metadata::{MetadataStore, NodeId};
use crate::{Constructor, Expr, Ident, Literal, Pattern, Type, TypeDefinition};

pub struct PrettyPrinter<'a> {
    metadata_store: Option<&'a MetadataStore>,
    indent_level: usize,
    indent_str: String,
}

impl<'a> Default for PrettyPrinter<'a> {
    fn default() -> Self {
        Self::new()
    }
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
                    result.push_str(&format!("; {comment}\n"));
                }
            }
        }

        // 式本体をフォーマット
        let expr_str = match expr {
            Expr::Literal(lit, _) => self.format_literal(lit),
            Expr::Ident(ident, _) => ident.0.clone(),
            Expr::Lambda { params, body, .. } => self.format_lambda(params, body),
            Expr::Apply { func, args, .. } => self.format_application(func, args),
            Expr::Let { name, value, .. } => self.format_let(name, value),
            Expr::LetRec { name, value, .. } => self.format_let(name, value),
            Expr::LetIn {
                name, value, body, ..
            } => self.format_let_in(name, value, body),
            Expr::If {
                cond,
                then_expr,
                else_expr,
                ..
            } => self.format_if(cond, then_expr, else_expr),
            Expr::List(items, _) => self.format_list(items),
            // Cons is not a variant in current Expr
            // Lists are handled by Expr::List
            Expr::Match { expr, cases, .. } => self.format_match(expr, cases),
            Expr::Rec {
                name, params, body, ..
            } => self.format_rec(name, params, body),
            Expr::TypeDef { definition, .. } => self.format_type_def(definition),
            Expr::Constructor { name, args, .. } => self.format_constructor(name, args),
            Expr::Module {
                name,
                exports,
                body,
                ..
            } => self.format_module(name, exports, body),
            Expr::Import { module_name, .. } => {
                format!("(import {})", module_name.0)
            }
            Expr::Use { path, items, .. } => {
                let path_str = path.join("/");
                match items {
                    Some(items) => {
                        let items_str = items.iter().map(|i| &i.0).cloned().collect::<Vec<_>>().join(", ");
                        format!("(use {} ({}))", path_str, items_str)
                    }
                    None => format!("(use {})", path_str),
                }
            }
            Expr::QualifiedIdent {
                module_name, name, ..
            } => {
                format!("{}.{}", module_name.0, name.0)
            }
            Expr::Handler { cases, body, .. } => {
                let cases_str = cases
                    .iter()
                    .map(|(effect, patterns, cont, expr)| {
                        let patterns_str = patterns
                            .iter()
                            .map(|p| self.format_pattern(p))
                            .collect::<Vec<_>>()
                            .join(" ");
                        format!(
                            "[({} {}) {} {}]",
                            effect.0,
                            patterns_str,
                            cont.0,
                            self.format_expr(expr, None)
                        )
                    })
                    .collect::<Vec<_>>()
                    .join(" ");
                format!("(handler {} {})", cases_str, self.format_expr(body, None))
            }
            Expr::WithHandler { handler, body, .. } => {
                format!(
                    "(with-handler {} {})",
                    self.format_expr(handler, None),
                    self.format_expr(body, None)
                )
            }
            Expr::Perform { effect, args, .. } => {
                let args_str = args
                    .iter()
                    .map(|arg| self.format_expr(arg, None))
                    .collect::<Vec<_>>()
                    .join(" ");
                format!("(perform {} {})", effect.0, args_str)
            }
            Expr::Pipeline { expr, func, .. } => {
                format!(
                    "{} |> {}",
                    self.format_expr(expr, None),
                    self.format_expr(func, None)
                )
            }
            Expr::Block { exprs, .. } => {
                let exprs_str = exprs
                    .iter()
                    .map(|e| self.format_expr(e, None))
                    .collect::<Vec<_>>()
                    .join("; ");
                format!("{{ {} }}", exprs_str)
            }
            Expr::Hole { name, type_hint, .. } => {
                match (name, type_hint) {
                    (Some(n), Some(t)) => format!("@{}:{}", n, t),
                    (Some(n), None) => format!("@{}", n),
                    (None, Some(t)) => format!("@:{}", t),
                    (None, None) => "@".to_string(),
                }
            }
            Expr::Do { effects, body, .. } => {
                if effects.is_empty() {
                    format!("do {}", self.format_expr(body, None))
                } else {
                    format!("do <{}> {}", effects.join(", "), self.format_expr(body, None))
                }
            }
            Expr::RecordLiteral { fields, .. } => {
                let fields_str = fields
                    .iter()
                    .map(|(k, v)| format!("{}: {}", k.0, self.format_expr(v, None)))
                    .collect::<Vec<_>>()
                    .join(", ");
                format!("{{ {} }}", fields_str)
            }
            Expr::RecordAccess { record, field, .. } => {
                format!("{}.{}", self.format_expr(record, None), field.0)
            }
            Expr::RecordUpdate { record, updates, .. } => {
                let updates_str = updates
                    .iter()
                    .map(|(k, v)| format!("{}: {}", k.0, self.format_expr(v, None)))
                    .collect::<Vec<_>>()
                    .join(", ");
                format!("{{ {} | {} }}", self.format_expr(record, None), updates_str)
            }
        };

        result.push_str(&self.indent());
        result.push_str(&expr_str);

        // 後置メタデータ（一時変数ラベルなど）を追加
        if let Some(id) = node_id {
            if let Some(store) = self.metadata_store {
                if let Some(label) = store.get_temp_var_label(id) {
                    result.push_str(&format!(" ; => {label}"));
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
            Literal::String(s) => format!("\"{s}\""),
        }
    }

    fn format_lambda(&self, params: &[(Ident, Option<Type>)], body: &Expr) -> String {
        let params_str = params
            .iter()
            .map(|(ident, _)| ident.0.clone())
            .collect::<Vec<_>>()
            .join(" ");
        format!("(fn ({}) {})", params_str, self.format_expr(body, None))
    }

    fn format_application(&self, func: &Expr, args: &[Expr]) -> String {
        let func_str = self.format_expr(func, None);
        let args_str = args
            .iter()
            .map(|arg| self.format_expr(arg, None))
            .collect::<Vec<_>>()
            .join(" ");
        format!("({func_str} {args_str})")
    }

    fn format_let(&self, name: &Ident, value: &Expr) -> String {
        format!("(let {} {})", name.0, self.format_expr(value, None))
    }

    fn format_let_in(&self, name: &Ident, value: &Expr, body: &Expr) -> String {
        format!(
            "(let {} {} in {})",
            name.0,
            self.format_expr(value, None),
            self.format_expr(body, None)
        )
    }

    #[allow(dead_code)]
    fn format_let_rec(
        &self,
        name: &Ident,
        params: &[(Ident, Option<Type>)],
        body: &Expr,
    ) -> String {
        let params_str = params
            .iter()
            .map(|(ident, _)| ident.0.clone())
            .collect::<Vec<_>>()
            .join(" ");
        format!(
            "(let-rec {} ({}) {})",
            name.0,
            params_str,
            self.format_expr(body, None)
        )
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
            let items_str = items
                .iter()
                .map(|item| self.format_expr(item, None))
                .collect::<Vec<_>>()
                .join(" ");
            format!("(list {items_str})")
        }
    }

    #[allow(dead_code)]
    fn format_cons(&self, head: &Expr, tail: &Expr) -> String {
        format!(
            "(cons {} {})",
            self.format_expr(head, None),
            self.format_expr(tail, None)
        )
    }

    fn format_match(&self, expr: &Expr, cases: &[(Pattern, Expr)]) -> String {
        let expr_str = self.format_expr(expr, None);
        let cases_str = cases
            .iter()
            .map(|(pat, expr)| {
                format!(
                    "({} {})",
                    self.format_pattern(pat),
                    self.format_expr(expr, None)
                )
            })
            .collect::<Vec<_>>()
            .join(" ");
        format!("(match {expr_str} {cases_str})")
    }

    fn format_pattern(&self, pattern: &Pattern) -> String {
        match pattern {
            Pattern::Variable(ident, _) => ident.0.clone(),
            Pattern::Wildcard(_) => "_".to_string(),
            Pattern::Literal(lit, _) => self.format_literal(lit),
            Pattern::List { patterns, .. } => {
                if patterns.is_empty() {
                    "(list)".to_string()
                } else {
                    let patterns_str = patterns
                        .iter()
                        .map(|p| self.format_pattern(p))
                        .collect::<Vec<_>>()
                        .join(" ");
                    format!("(list {patterns_str})")
                }
            }
            Pattern::Constructor { name, patterns, .. } => {
                let patterns_str = patterns
                    .iter()
                    .map(|p| self.format_pattern(p))
                    .collect::<Vec<_>>()
                    .join(" ");
                format!("({} {})", name.0, patterns_str)
            }
        }
    }

    fn format_rec(&self, name: &Ident, params: &[(Ident, Option<Type>)], body: &Expr) -> String {
        let params_str = params
            .iter()
            .map(|(ident, _)| ident.0.clone())
            .collect::<Vec<_>>()
            .join(" ");
        format!(
            "(rec {} ({}) {})",
            name.0,
            params_str,
            self.format_expr(body, None)
        )
    }

    fn format_type_def(&self, typedef: &TypeDefinition) -> String {
        let type_params = if typedef.type_params.is_empty() {
            String::new()
        } else {
            format!(" {}", typedef.type_params.join(" "))
        };

        let constructors = typedef
            .constructors
            .iter()
            .map(|c| self.format_constructor_def(c))
            .collect::<Vec<_>>()
            .join(" ");

        format!("(type {}{} {})", typedef.name, type_params, constructors)
    }

    fn format_constructor_def(&self, constructor: &Constructor) -> String {
        if constructor.fields.is_empty() {
            format!("({})", constructor.name)
        } else {
            let fields = constructor
                .fields
                .iter()
                .map(|t| format!("{t:?}")) // TODO: Proper type formatting
                .collect::<Vec<_>>()
                .join(" ");
            format!("({} {})", constructor.name, fields)
        }
    }

    fn format_constructor(&self, name: &Ident, args: &[Expr]) -> String {
        if args.is_empty() {
            name.0.clone()
        } else {
            let args_str = args
                .iter()
                .map(|arg| self.format_expr(arg, None))
                .collect::<Vec<_>>()
                .join(" ");
            format!("({} {})", name.0, args_str)
        }
    }

    fn format_module(&self, name: &Ident, exports: &[Ident], body: &[Expr]) -> String {
        let exports_str = exports
            .iter()
            .map(|ident| ident.0.clone())
            .collect::<Vec<_>>()
            .join(" ");

        let body_str = body
            .iter()
            .map(|expr| self.format_expr(expr, None))
            .collect::<Vec<_>>()
            .join("\n");

        format!("(module {} (export {}) {})", name.0, exports_str, body_str)
    }

    #[allow(dead_code)]
    fn format_import(&self, module_name: &Ident, alias: &Option<Ident>) -> String {
        if let Some(alias) = alias {
            format!("(import {} as {})", module_name.0, alias.0)
        } else {
            format!("(import {})", module_name.0)
        }
    }
}

/// 簡単な pretty print 関数
pub fn pretty_print(expr: &Expr) -> String {
    PrettyPrinter::new().pretty_print(expr)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::metadata::AstBuilder;
    use crate::Span;

    #[test]
    fn test_pretty_print_with_comments() {
        let expr = Expr::Let {
            name: Ident("x".to_string()),
            type_ann: None,
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
            body: Box::new(Expr::Ident(Ident("x".to_string()), Span::new(0, 1))),
            span: Span::new(0, 10),
        };

        let printer = PrettyPrinter::new();
        let result = printer.pretty_print(&expr);

        assert_eq!(result, "(fn (x) x)");
    }
}
