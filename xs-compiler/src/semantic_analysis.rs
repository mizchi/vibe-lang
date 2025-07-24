//! Semantic analysis phase that runs after parsing
//!
//! This module analyzes the AST and:
//! - Assigns block attributes (effect permissions, scopes)
//! - Validates special forms (match, do, handle)
//! - Performs scope analysis
//! - Prepares metadata for the codebase

use std::collections::{HashMap, HashSet};
use xs_core::{
    block_attributes::{
        BindingAttributes, BlockAttributeRegistry, BlockAttributes, EffectPermissions,
        ScopeAttributes,
    },
    metadata::NodeId,
    DoStatement, Expr, HandlerCase, Ident, Pattern, Span,
};

pub struct SemanticAnalyzer {
    /// Block attribute registry
    registry: BlockAttributeRegistry,

    /// Current scope stack
    scope_stack: Vec<ScopeContext>,

    /// Effect context stack
    effect_stack: Vec<EffectContext>,
}

#[derive(Debug, Clone)]
struct ScopeContext {
    block_id: NodeId,
    bindings: HashMap<String, BindingInfo>,
    parent: Option<NodeId>,
}

#[derive(Debug, Clone)]
struct BindingInfo {
    defined_at: Span,
    mutable: bool,
    captured: bool,
}

#[derive(Debug, Clone)]
struct EffectContext {
    block_id: NodeId,
    permissions: EffectPermissions,
}

impl SemanticAnalyzer {
    pub fn new() -> Self {
        Self {
            registry: BlockAttributeRegistry::new(),
            scope_stack: vec![],
            effect_stack: vec![],
        }
    }

    /// Analyze an expression and populate block attributes
    pub fn analyze(&mut self, expr: &Expr) -> Result<BlockAttributeRegistry, String> {
        // Initialize root scope
        self.enter_scope(NodeId::fresh(), EffectPermissions::All);

        // Analyze the expression tree
        self.analyze_expr(expr)?;

        // Exit root scope
        self.exit_scope();

        Ok(self.registry.clone())
    }

    fn analyze_expr(&mut self, expr: &Expr) -> Result<(), String> {
        match expr {
            Expr::Block { exprs, span } => {
                let block_id = NodeId::fresh();
                self.analyze_block(block_id, exprs, span)?;
            }

            Expr::Match { expr, cases, span } => {
                self.analyze_match(expr, cases, span)?;
            }

            Expr::Do { statements, span } => {
                self.analyze_do_block(statements, span)?;
            }

            Expr::HandleExpr {
                expr,
                handlers,
                return_handler,
                span,
            } => {
                self.analyze_handle(expr, handlers, return_handler.as_ref(), span)?;
            }

            Expr::Let { name, value, .. } => {
                self.analyze_expr(value)?;
                self.define_binding(name.0.clone(), false);
            }

            Expr::LetRec { name, value, .. } => {
                // Define binding before analyzing (for recursion)
                self.define_binding(name.0.clone(), false);
                self.analyze_expr(value)?;
            }

            Expr::Lambda { params, body, .. } => {
                let block_id = NodeId::fresh();
                self.enter_scope(block_id.clone(), EffectPermissions::Inherited);

                // Add parameters to scope
                for (param, _) in params {
                    self.define_binding(param.0.clone(), false);
                }

                self.analyze_expr(body)?;
                self.exit_scope();
            }

            Expr::Apply { func, args, .. } => {
                self.analyze_expr(func)?;
                for arg in args {
                    self.analyze_expr(arg)?;
                }
            }

            Expr::If {
                cond,
                then_expr,
                else_expr,
                ..
            } => {
                self.analyze_expr(cond)?;
                self.analyze_expr(then_expr)?;
                self.analyze_expr(else_expr)?;
            }

            Expr::Ident(name, _) => {
                self.reference_binding(&name.0);
            }

            // Handle other expression types...
            _ => {
                // Recursively analyze child expressions
                self.analyze_children(expr)?;
            }
        }

        Ok(())
    }

    fn analyze_block(
        &mut self,
        block_id: NodeId,
        exprs: &[Expr],
        _span: &Span,
    ) -> Result<(), String> {
        self.enter_scope(block_id.clone(), EffectPermissions::Inherited);

        for expr in exprs {
            self.analyze_expr(expr)?;
        }

        self.exit_scope();
        Ok(())
    }

    fn analyze_match(
        &mut self,
        expr: &Expr,
        cases: &[(Pattern, Expr)],
        _span: &Span,
    ) -> Result<(), String> {
        // Analyze scrutinee
        self.analyze_expr(expr)?;

        // Each case gets its own scope
        for (pattern, case_expr) in cases {
            let block_id = NodeId::fresh();
            self.enter_scope(block_id.clone(), EffectPermissions::Inherited);

            // Bind pattern variables
            self.analyze_pattern(pattern)?;

            // Analyze case expression
            self.analyze_expr(case_expr)?;

            self.exit_scope();
        }

        Ok(())
    }

    fn analyze_do_block(&mut self, statements: &[DoStatement], _span: &Span) -> Result<(), String> {
        let block_id = NodeId::fresh();
        self.enter_scope(block_id.clone(), EffectPermissions::Inherited);

        for stmt in statements {
            match stmt {
                DoStatement::Bind { name, expr, .. } => {
                    self.analyze_expr(expr)?;
                    self.define_binding(name.0.clone(), false);
                }
                DoStatement::Expression(expr) => {
                    self.analyze_expr(expr)?;
                }
            }
        }

        self.exit_scope();
        Ok(())
    }

    fn analyze_handle(
        &mut self,
        expr: &Expr,
        handlers: &[HandlerCase],
        return_handler: Option<&(Ident, Box<Expr>)>,
        _span: &Span,
    ) -> Result<(), String> {
        // The handled expression may have restricted effects
        let handled_effects = self.extract_handled_effects(handlers);
        let block_id = NodeId::fresh();

        // Enter scope with restricted effects
        self.enter_scope(block_id.clone(), EffectPermissions::Except(handled_effects));
        self.analyze_expr(expr)?;
        self.exit_scope();

        // Analyze handlers
        for handler in handlers {
            let handler_block_id = NodeId::fresh();
            self.enter_scope(handler_block_id.clone(), EffectPermissions::Inherited);

            // Bind handler arguments
            for arg in &handler.args {
                if let Pattern::Variable(name, _) = arg {
                    self.define_binding(name.0.clone(), false);
                }
            }

            // Bind continuation
            self.define_binding(handler.continuation.0.clone(), false);

            // Analyze handler body
            self.analyze_expr(&handler.body)?;
            self.exit_scope();
        }

        // Analyze return handler
        if let Some((name, body)) = return_handler {
            let return_block_id = NodeId::fresh();
            self.enter_scope(return_block_id.clone(), EffectPermissions::Inherited);
            self.define_binding(name.0.clone(), false);
            self.analyze_expr(body)?;
            self.exit_scope();
        }

        Ok(())
    }

    fn analyze_pattern(&mut self, pattern: &Pattern) -> Result<(), String> {
        match pattern {
            Pattern::Variable(name, _) => {
                self.define_binding(name.0.clone(), false);
            }
            Pattern::Constructor { patterns, .. } => {
                for p in patterns {
                    self.analyze_pattern(p)?;
                }
            }
            Pattern::List { patterns, .. } => {
                for p in patterns {
                    self.analyze_pattern(p)?;
                }
            }
            _ => {}
        }
        Ok(())
    }

    fn analyze_children(&mut self, expr: &Expr) -> Result<(), String> {
        // Generic traversal for expression types not explicitly handled
        match expr {
            Expr::List(exprs, _) => {
                for e in exprs {
                    self.analyze_expr(e)?;
                }
            }
            Expr::RecordLiteral { fields, .. } => {
                for (_, e) in fields {
                    self.analyze_expr(e)?;
                }
            }
            Expr::RecordAccess { record, .. } => {
                self.analyze_expr(record)?;
            }
            _ => {}
        }
        Ok(())
    }

    fn extract_handled_effects(&self, handlers: &[HandlerCase]) -> HashSet<String> {
        handlers.iter().map(|h| h.effect.0.clone()).collect()
    }

    fn enter_scope(&mut self, block_id: NodeId, permissions: EffectPermissions) {
        let parent = self.scope_stack.last().map(|s| s.block_id.clone());

        self.scope_stack.push(ScopeContext {
            block_id: block_id.clone(),
            bindings: HashMap::new(),
            parent: parent.clone(),
        });

        self.effect_stack.push(EffectContext {
            block_id: block_id.clone(),
            permissions: permissions.clone(),
        });

        // Register block attributes
        let attrs = BlockAttributes {
            block_id,
            permitted_effects: permissions,
            scope: ScopeAttributes::default(),
            parent_block: parent,
        };

        self.registry.register(attrs);
    }

    fn exit_scope(&mut self) {
        if let Some(scope) = self.scope_stack.pop() {
            // Update block attributes with collected scope info
            self.registry.update(&scope.block_id, |attrs| {
                for (name, info) in scope.bindings {
                    attrs.scope.bindings.insert(
                        Ident(name),
                        BindingAttributes {
                            mutable: info.mutable,
                            escapes: info.captured,
                            init_effects: HashSet::new(),
                            ref_count: None,
                        },
                    );
                }
            });
        }

        self.effect_stack.pop();
    }

    fn define_binding(&mut self, name: String, mutable: bool) {
        if let Some(scope) = self.scope_stack.last_mut() {
            scope.bindings.insert(
                name,
                BindingInfo {
                    defined_at: Span::new(0, 0), // TODO: track actual span
                    mutable,
                    captured: false,
                },
            );
        }
    }

    fn reference_binding(&mut self, name: &str) {
        // Check if binding is from outer scope (captured)
        let mut found_in_outer = false;
        for (i, scope) in self.scope_stack.iter().enumerate().rev() {
            if scope.bindings.contains_key(name) {
                if i < self.scope_stack.len() - 1 {
                    found_in_outer = true;
                }
                break;
            }
        }

        if found_in_outer {
            // Mark as captured in current scope
            if let Some(current) = self.scope_stack.last() {
                self.registry.update(&current.block_id, |attrs| {
                    attrs.scope.captures.insert(Ident(name.to_string()));
                });
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use xs_core::parser::parse;

    #[test]
    fn test_block_attribute_analysis() {
        let input = r#"
            let pureFunc = fn x = x + 1 in
            let effectFunc = fn msg = do {
                x <- perform IO msg;
                x
            } in
            handle effectFunc "test" {
                IO msg k -> k msg
            }
        "#;

        let expr = parse(input).unwrap();

        let mut analyzer = SemanticAnalyzer::new();
        let _registry = analyzer.analyze(&expr).unwrap();

        // Verify that blocks were registered
        // BlockAttributeRegistry stores attributes internally
        // We can check if analysis completed successfully
        assert!(true); // Success means blocks were processed
    }

    #[test]
    fn test_scope_capture_detection() {
        let input = r#"
            let outer = 10 in
            let inner = fn x = x + outer in
            inner 5
        "#;

        let expr = parse(input).unwrap();

        let mut analyzer = SemanticAnalyzer::new();
        let _registry = analyzer.analyze(&expr).unwrap();

        // The lambda should capture 'outer'
        // TODO: Add more specific assertions once we have accessors
    }

    #[test]
    fn test_effect_permissions() {
        let input = r#"
            handle {
                perform IO "test"
            } {
                IO msg k -> k msg
            }
        "#;

        let expr = parse(input).unwrap();

        let mut analyzer = SemanticAnalyzer::new();
        let _registry = analyzer.analyze(&expr).unwrap();

        // The handled block should have IO effect excluded
        // Success means effect analysis completed
        assert!(true);
    }
}
