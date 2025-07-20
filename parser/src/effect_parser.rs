//! Parser for effect annotations in XS language
//!
//! Handles parsing of effect syntax like:
//! - (-> Int Int ! IO)
//! - (-> String String ! {IO, Error})

use crate::{Parser, Token};
use xs_core::{Effect, EffectRow, EffectSet, EffectVar, Type, XsError};

impl<'a> Parser<'a> {
    /// Parse effect annotation after '!' token
    /// Either a single effect, effect set {E1, E2}, or effect variable
    pub fn parse_effect_annotation(&mut self) -> Result<EffectRow, XsError> {
        // Skip the '!' token
        if matches!(self.current_token, Some((Token::Exclamation, _))) {
            self.advance()?;
        }

        match &self.current_token {
            Some((Token::LeftBrace, _)) => {
                // Effect set: {IO, Error, ...}
                self.parse_effect_set()
            }
            Some((Token::Symbol(name), _)) => {
                // Single effect or effect variable
                if name.chars().next().unwrap_or(' ').is_lowercase() {
                    // Effect variable (starts with lowercase)
                    let var = EffectVar(name.clone());
                    self.advance()?;
                    Ok(EffectRow::Variable(var))
                } else {
                    // Single concrete effect
                    let effect = self.parse_single_effect()?;
                    Ok(EffectRow::Concrete(EffectSet::single(effect)))
                }
            }
            _ => {
                // Default to pure if no effect specified
                Ok(EffectRow::pure())
            }
        }
    }

    /// Parse a set of effects: {E1, E2, ...}
    fn parse_effect_set(&mut self) -> Result<EffectRow, XsError> {
        self.advance()?; // consume '{'

        let mut effects = Vec::new();

        loop {
            if matches!(self.current_token, Some((Token::RightBrace, _))) {
                break;
            }

            effects.push(self.parse_single_effect()?);

            match &self.current_token {
                Some((Token::Comma, _)) => {
                    self.advance()?;
                    // Allow trailing comma
                    if matches!(self.current_token, Some((Token::RightBrace, _))) {
                        break;
                    }
                }
                Some((Token::RightBrace, _)) => break,
                _ => {
                    let pos = self
                        .current_token
                        .as_ref()
                        .map(|(_, span)| span.start)
                        .unwrap_or(0);
                    return Err(XsError::ParseError(
                        pos,
                        "Expected ',' or '}' in effect set".to_string(),
                    ));
                }
            }
        }

        self.advance()?; // consume '}'

        if effects.is_empty() {
            Ok(EffectRow::pure())
        } else {
            Ok(EffectRow::Concrete(EffectSet::from_effects(effects)))
        }
    }

    /// Parse a single effect
    fn parse_single_effect(&mut self) -> Result<Effect, XsError> {
        match &self.current_token {
            Some((Token::Symbol(name), _)) => {
                let effect = match name.as_str() {
                    "Pure" => Effect::Pure,
                    "IO" => Effect::IO,
                    "State" => Effect::State,
                    "Error" => Effect::Error,
                    "Async" => Effect::Async,
                    "Network" => Effect::Network,
                    "FileSystem" => Effect::FileSystem,
                    "Random" => Effect::Random,
                    "Time" => Effect::Time,
                    "Log" => Effect::Log,
                    _ => {
                        let pos = self
                            .current_token
                            .as_ref()
                            .map(|(_, span)| span.start)
                            .unwrap_or(0);
                        return Err(XsError::ParseError(pos, format!("Unknown effect: {name}")));
                    }
                };
                self.advance()?;
                Ok(effect)
            }
            _ => {
                let pos = self
                    .current_token
                    .as_ref()
                    .map(|(_, span)| span.start)
                    .unwrap_or(0);
                Err(XsError::ParseError(pos, "Expected effect name".to_string()))
            }
        }
    }

    /// Parse a function type with optional effects
    /// (-> T1 T2) or (-> T1 T2 ! E)
    pub fn parse_function_type_with_effects(&mut self) -> Result<Type, XsError> {
        let start_pos = self
            .current_token
            .as_ref()
            .map(|(_, span)| span.start)
            .unwrap_or(0);
        // '->' has already been consumed by parse_type
        self.advance()?; // consume '->'

        let mut types = Vec::new();

        // Parse argument and return types
        while !matches!(self.current_token, Some((Token::RightParen, _)))
            && !matches!(self.current_token, Some((Token::Exclamation, _)))
        {
            types.push(self.parse_type()?);
        }

        if types.len() < 2 {
            return Err(XsError::ParseError(
                start_pos,
                "Function type requires at least 2 types".to_string(),
            ));
        }

        // Check for effect annotation
        let effects = if matches!(self.current_token, Some((Token::Exclamation, _))) {
            self.parse_effect_annotation()?
        } else {
            EffectRow::pure()
        };

        self.advance()?; // consume ')'

        // Build the function type from right to left
        let mut result_type = types.pop().unwrap();
        while let Some(arg_type) = types.pop() {
            if types.is_empty() && !matches!(effects, EffectRow::Concrete(ref e) if e.is_pure()) {
                // Apply effects to the outermost function
                result_type = Type::FunctionWithEffect {
                    from: Box::new(arg_type),
                    to: Box::new(result_type),
                    effects: effects.clone(),
                };
            } else {
                result_type = Type::Function(Box::new(arg_type), Box::new(result_type));
            }
        }

        Ok(result_type)
    }
}
