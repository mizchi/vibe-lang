//! Runtime support for effect handlers
//!
//! This module provides the runtime implementation of algebraic effect handlers.

use std::collections::HashMap;
use vibe_language::{Environment, Expr, Ident, Span, Value, XsError};

/// Effect handler context during evaluation
#[derive(Debug, Clone)]
pub struct EffectContext {
    /// Stack of active handlers
    handlers: Vec<HandlerFrame>,
}

#[derive(Debug, Clone)]
struct HandlerFrame {
    /// Effect name -> handler implementation
    handlers: HashMap<String, HandlerImpl>,
}

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct HandlerImpl {
    patterns: Vec<vibe_language::Pattern>,
    continuation_name: Ident,
    body: Expr,
    env: Environment,
}

impl EffectContext {
    pub fn new() -> Self {
        Self {
            handlers: Vec::new(),
        }
    }

    /// Push a new handler frame
    pub fn push_handlers(&mut self, handlers: HashMap<String, HandlerImpl>) {
        self.handlers.push(HandlerFrame { handlers });
    }

    /// Pop the most recent handler frame
    pub fn pop_handlers(&mut self) {
        self.handlers.pop();
    }

    /// Find a handler for the given effect
    pub fn find_handler(&self, effect_name: &str) -> Option<&HandlerImpl> {
        // Search from the most recent handler frame backwards
        for frame in self.handlers.iter().rev() {
            if let Some(handler) = frame.handlers.get(effect_name) {
                return Some(handler);
            }
        }
        None
    }
}

/// Continuation value for resuming computation
#[derive(Debug, Clone)]
pub struct Continuation {
    /// The expression to evaluate when resumed
    pub expr: Expr,
    /// The environment at the point of suspension
    pub env: Environment,
    /// The effect context at the point of suspension
    pub effect_context: EffectContext,
}

impl Continuation {
    /// Create a new continuation
    pub fn new(expr: Expr, env: Environment, effect_context: EffectContext) -> Self {
        Self {
            expr,
            env,
            effect_context,
        }
    }
}

/// Perform an effect, potentially suspending the computation
pub fn perform_effect(
    effect_name: &str,
    args: Vec<Value>,
    current_expr: Expr,
    env: &Environment,
    effect_context: &EffectContext,
) -> Result<EffectResult, XsError> {
    if let Some(handler) = effect_context.find_handler(effect_name) {
        // Create a continuation for the rest of the computation
        let continuation = Continuation::new(current_expr, env.clone(), effect_context.clone());

        Ok(EffectResult::Handled {
            handler: handler.clone(),
            args,
            continuation,
        })
    } else {
        // No handler found - this is an unhandled effect
        Ok(EffectResult::Unhandled {
            effect_name: effect_name.to_string(),
            args,
        })
    }
}

/// Result of performing an effect
#[derive(Debug, Clone)]
pub enum EffectResult {
    /// Effect was handled by a handler
    Handled {
        handler: HandlerImpl,
        args: Vec<Value>,
        continuation: Continuation,
    },
    /// Effect was not handled
    Unhandled {
        effect_name: String,
        args: Vec<Value>,
    },
}

/// Built-in effect implementations
pub mod builtin_effects {
    use super::*;
    use vibe_language::Value;

    /// Perform a built-in IO effect
    pub fn perform_io(effect_name: &str, args: &[Value]) -> Result<Value, XsError> {
        match effect_name {
            "print" => {
                if let Some(Value::String(s)) = args.get(0) {
                    println!("{}", s);
                    Ok(Value::Constructor {
                        name: Ident("Unit".to_string()),
                        values: vec![],
                    })
                } else {
                    Err(XsError::RuntimeError(
                        Span::new(0, 0),
                        "print expects a string argument".to_string(),
                    ))
                }
            }
            "read-line" => {
                use std::io::{self, BufRead};
                let stdin = io::stdin();
                let mut line = String::new();
                stdin.lock().read_line(&mut line).map_err(|e| {
                    XsError::RuntimeError(Span::new(0, 0), format!("IO error: {}", e))
                })?;
                // Remove trailing newline
                if line.ends_with('\n') {
                    line.pop();
                    if line.ends_with('\r') {
                        line.pop();
                    }
                }
                Ok(Value::String(line))
            }
            _ => Err(XsError::RuntimeError(
                Span::new(0, 0),
                format!("Unknown IO effect: {}", effect_name),
            )),
        }
    }

    /// Perform a built-in State effect
    pub fn perform_state(
        effect_name: &str,
        args: &[Value],
        state: &mut Option<Value>,
    ) -> Result<Value, XsError> {
        match effect_name {
            "get-state" => {
                if let Some(ref s) = state {
                    Ok(s.clone())
                } else {
                    Err(XsError::RuntimeError(
                        Span::new(0, 0),
                        "State not initialized".to_string(),
                    ))
                }
            }
            "set-state" => {
                if let Some(new_state) = args.get(0) {
                    *state = Some(new_state.clone());
                    Ok(Value::Constructor {
                        name: Ident("Unit".to_string()),
                        values: vec![],
                    })
                } else {
                    Err(XsError::RuntimeError(
                        Span::new(0, 0),
                        "set-state expects an argument".to_string(),
                    ))
                }
            }
            _ => Err(XsError::RuntimeError(
                Span::new(0, 0),
                format!("Unknown State effect: {}", effect_name),
            )),
        }
    }

    /// Perform a built-in Error effect
    pub fn perform_error(effect_name: &str, args: &[Value]) -> Result<Value, XsError> {
        match effect_name {
            "error" => {
                if let Some(Value::String(msg)) = args.get(0) {
                    Err(XsError::RuntimeError(
                        Span::new(0, 0),
                        format!("Error effect: {}", msg),
                    ))
                } else {
                    Err(XsError::RuntimeError(
                        Span::new(0, 0),
                        "error expects a string message".to_string(),
                    ))
                }
            }
            _ => Err(XsError::RuntimeError(
                Span::new(0, 0),
                format!("Unknown Error effect: {}", effect_name),
            )),
        }
    }
}
