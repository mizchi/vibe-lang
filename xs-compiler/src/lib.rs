//! XS Compiler - Type checking and memory optimization
//!
//! This crate combines type checking and memory optimization passes
//! for the XS language compiler.

// Re-export type checker functionality
mod effect_checker;
mod effect_inference;
mod improved_errors;
mod module_env;
pub mod semantic_analysis;

use effect_checker::EffectScheme;
#[cfg(test)]
mod test_effect_inference;
#[cfg(test)]
mod test_extensible_effects;

pub use module_env::{ExportedItem, ModuleEnv, ModuleInfo};

// Type checker exports
use std::collections::{HashMap, HashSet};
use xs_core::{DoStatement, Expr, Ident, Literal, Pattern, Span, Type, TypeDefinition, XsError, extensible_effects::ExtensibleEffectRow};

#[derive(Debug, Clone, PartialEq)]
pub struct TypeScheme {
    pub vars: Vec<String>,
    pub typ: Type,
    pub effects: Option<ExtensibleEffectRow>, // Track effects at type scheme level
    pub effect_vars: Vec<String>, // Effect variables for polymorphic effects
}

impl TypeScheme {
    pub fn mono(typ: Type) -> Self {
        TypeScheme {
            vars: Vec::new(),
            typ,
            effects: None,
            effect_vars: Vec::new(),
        }
    }
    
    pub fn mono_with_effects(typ: Type, effects: ExtensibleEffectRow) -> Self {
        TypeScheme {
            vars: Vec::new(),
            typ,
            effects: Some(effects),
            effect_vars: Vec::new(),
        }
    }
}

pub struct TypeEnv {
    bindings: Vec<HashMap<String, TypeScheme>>,
    type_definitions: HashMap<String, TypeDefinition>,
    modules: HashMap<String, HashMap<String, TypeScheme>>,
}

impl Default for TypeEnv {
    fn default() -> Self {
        let mut env = TypeEnv {
            bindings: vec![HashMap::new()],
            type_definitions: HashMap::new(),
            modules: HashMap::new(),
        };

        // Built-in functions - polymorphic arithmetic operators
        let num_var = || Type::Var("num".to_string());
        env.add_builtin(
            "+",
            Type::Function(
                Box::new(num_var()),
                Box::new(Type::Function(Box::new(num_var()), Box::new(num_var()))),
            ),
        );
        env.add_builtin(
            "-",
            Type::Function(
                Box::new(num_var()),
                Box::new(Type::Function(Box::new(num_var()), Box::new(num_var()))),
            ),
        );
        env.add_builtin(
            "*",
            Type::Function(
                Box::new(num_var()),
                Box::new(Type::Function(Box::new(num_var()), Box::new(num_var()))),
            ),
        );
        env.add_builtin(
            "==",
            Type::Function(
                Box::new(num_var()),
                Box::new(Type::Function(Box::new(num_var()), Box::new(Type::Bool))),
            ),
        );
        env.add_builtin(
            "/",
            Type::Function(
                Box::new(num_var()),
                Box::new(Type::Function(Box::new(num_var()), Box::new(num_var()))),
            ),
        );
        env.add_builtin(
            "%",
            Type::Function(
                Box::new(Type::Int),
                Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int))),
            ),
        );
        env.add_builtin(
            "=",
            Type::Function(
                Box::new(Type::Var("eq".to_string())),
                Box::new(Type::Function(Box::new(Type::Var("eq".to_string())), Box::new(Type::Bool))),
            ),
        );
        env.add_builtin(
            "<",
            Type::Function(
                Box::new(Type::Int),
                Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Bool))),
            ),
        );
        env.add_builtin(
            ">",
            Type::Function(
                Box::new(Type::Int),
                Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Bool))),
            ),
        );
        env.add_builtin(
            ">=",
            Type::Function(
                Box::new(Type::Int),
                Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Bool))),
            ),
        );
        env.add_builtin(
            "<=",
            Type::Function(
                Box::new(Type::Int),
                Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Bool))),
            ),
        );
        env.add_builtin(
            "!=",
            Type::Function(
                Box::new(Type::Int),
                Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Bool))),
            ),
        );

        env.add_builtin(
            "++",
            Type::Function(
                Box::new(Type::String),
                Box::new(Type::Function(
                    Box::new(Type::String),
                    Box::new(Type::String),
                )),
            ),
        );

        // Float arithmetic operators
        env.add_builtin(
            "+.",
            Type::Function(
                Box::new(Type::Float),
                Box::new(Type::Function(Box::new(Type::Float), Box::new(Type::Float))),
            ),
        );
        env.add_builtin(
            "-.",
            Type::Function(
                Box::new(Type::Float),
                Box::new(Type::Function(Box::new(Type::Float), Box::new(Type::Float))),
            ),
        );
        env.add_builtin(
            "*.",
            Type::Function(
                Box::new(Type::Float),
                Box::new(Type::Function(Box::new(Type::Float), Box::new(Type::Float))),
            ),
        );
        env.add_builtin(
            "/.",
            Type::Function(
                Box::new(Type::Float),
                Box::new(Type::Function(Box::new(Type::Float), Box::new(Type::Float))),
            ),
        );

        env.add_builtin(
            "cons",
            Type::Function(
                Box::new(Type::Var("a".to_string())),
                Box::new(Type::Function(
                    Box::new(Type::List(Box::new(Type::Var("a".to_string())))),
                    Box::new(Type::List(Box::new(Type::Var("a".to_string())))),
                )),
            ),
        );
        
        // Also register :: as an alias for cons
        env.add_builtin(
            "::",
            Type::Function(
                Box::new(Type::Var("a".to_string())),
                Box::new(Type::Function(
                    Box::new(Type::List(Box::new(Type::Var("a".to_string())))),
                    Box::new(Type::List(Box::new(Type::Var("a".to_string())))),
                )),
            ),
        );

        env.add_builtin(
            "head",
            Type::Function(
                Box::new(Type::List(Box::new(Type::Var("a".to_string())))),
                Box::new(Type::Var("a".to_string())),
            ),
        );

        env.add_builtin(
            "tail",
            Type::Function(
                Box::new(Type::List(Box::new(Type::Var("a".to_string())))),
                Box::new(Type::List(Box::new(Type::Var("a".to_string())))),
            ),
        );

        env.add_builtin(
            "length",
            Type::Function(
                Box::new(Type::List(Box::new(Type::Var("a".to_string())))),
                Box::new(Type::Int),
            ),
        );

        env.add_builtin(
            "empty?",
            Type::Function(
                Box::new(Type::List(Box::new(Type::Var("a".to_string())))),
                Box::new(Type::Bool),
            ),
        );

        env.add_builtin(
            "mod",
            Type::Function(
                Box::new(Type::Int),
                Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int))),
            ),
        );

        env.add_builtin(
            "print",
            Type::Function(
                Box::new(Type::Var("a".to_string())),
                Box::new(Type::Var("a".to_string())),
            ),
        );

        // Keep only essential built-ins that are not library functions
        // Everything else requires explicit import

        // No default module functions - require explicit use/import

        // Initialize builtin modules
        env.init_builtin_modules();

        env
    }
}

impl TypeEnv {
    pub fn new() -> Self {
        Self::default()
    }

    fn add_builtin(&mut self, name: &str, typ: Type) {
        self.bindings[0].insert(name.to_string(), TypeScheme::mono(typ));
    }

    pub fn push_scope(&mut self) {
        self.bindings.push(HashMap::new());
    }

    pub fn pop_scope(&mut self) {
        self.bindings.pop();
    }

    pub fn add_binding(&mut self, name: String, scheme: TypeScheme) {
        if let Some(last) = self.bindings.last_mut() {
            last.insert(name, scheme);
        }
    }

    pub fn lookup(&self, name: &str) -> Option<&TypeScheme> {
        for scope in self.bindings.iter().rev() {
            if let Some(scheme) = scope.get(name) {
                return Some(scheme);
            }
        }
        None
    }

    pub fn add_type_definition(&mut self, name: String, def: TypeDefinition) {
        self.type_definitions.insert(name, def);
    }

    pub fn lookup_type_definition(&self, name: &str) -> Option<&TypeDefinition> {
        self.type_definitions.get(name)
    }

    fn init_builtin_modules(&mut self) {
        use xs_core::builtin_modules::BuiltinModuleRegistry;
        
        let registry = BuiltinModuleRegistry::new();
        
        for (module_name, module) in registry.all_modules() {
            let mut module_bindings = HashMap::new();
            for (func_name, func_type) in &module.functions {
                module_bindings.insert(func_name.clone(), TypeScheme::mono(func_type.clone()));
            }
            self.modules.insert(module_name.clone(), module_bindings);
        }
    }

    pub fn lookup_module_function(&self, module: &str, function: &str) -> Option<&TypeScheme> {
        self.modules.get(module)?.get(function)
    }
    
    /// Get all bindings from all scopes (for effect variable collection)
    pub fn all_bindings(&self) -> Vec<(&String, &TypeScheme)> {
        let mut bindings = Vec::new();
        
        // Collect from all scopes
        for scope in &self.bindings {
            for (name, scheme) in scope {
                bindings.push((name, scheme));
            }
        }
        
        // Also collect from modules
        for (_module_name, module_bindings) in &self.modules {
            for (name, scheme) in module_bindings {
                bindings.push((name, scheme));
            }
        }
        
        bindings
    }
}

pub struct TypeChecker {
    fresh_var_counter: usize,
    substitutions: HashMap<String, Type>,
    effect_checker: Option<effect_checker::EffectChecker>,
}

impl Default for TypeChecker {
    fn default() -> Self {
        Self::new()
    }
}

impl TypeChecker {
    pub fn new() -> Self {
        TypeChecker {
            fresh_var_counter: 0,
            substitutions: HashMap::new(),
            effect_checker: Some(effect_checker::EffectChecker::new()),
        }
    }
    
    pub fn new_without_effects() -> Self {
        TypeChecker {
            fresh_var_counter: 0,
            substitutions: HashMap::new(),
            effect_checker: None,
        }
    }

    fn fresh_var(&mut self) -> Type {
        let var = Type::Var(format!("a{}", self.fresh_var_counter));
        self.fresh_var_counter += 1;
        var
    }

    fn handle_use(&mut self, env: &mut TypeEnv, path: &[String], items: &Option<Vec<Ident>>) -> Result<(), XsError> {
        use xs_core::lib_modules::get_module_functions;
        
        // Get available functions for the module
        let available_functions = get_module_functions(path)
            .ok_or_else(|| XsError::TypeError(
                Span::new(0, 0),
                format!("Unknown module path: {}", path.join("/")),
            ))?;
        
        if let Some(items) = items {
            // Import only specific items
            for item in items {
                let func_name = &item.0;
                if let Some(func_type) = available_functions.get(func_name) {
                    env.add_builtin(func_name, func_type.clone());
                } else {
                    return Err(XsError::TypeError(
                        Span::new(0, 0),
                        format!("Function '{}' not found in module {}", func_name, path.join("/")),
                    ));
                }
            }
        } else {
            // Import all functions from the module
            for (name, typ) in available_functions.into_iter() {
                env.add_builtin(&name, typ);
            }
        }
        
        Ok(())
    }

    fn substitute(&self, typ: &Type) -> Type {
        self.substitute_with_map(typ, &HashMap::new())
    }

    fn unify(&mut self, t1: &Type, t2: &Type) -> Result<(), String> {
        let t1 = self.substitute(t1);
        let t2 = self.substitute(t2);

        match (&t1, &t2) {
            (Type::Int, Type::Int) => Ok(()),
            (Type::Float, Type::Float) => Ok(()),
            (Type::Bool, Type::Bool) => Ok(()),
            (Type::String, Type::String) => Ok(()),
            (Type::Var(v1), Type::Var(v2)) if v1 == v2 => Ok(()),
            (Type::Var(v), t) | (t, Type::Var(v)) => {
                if Self::occurs_check(v, t) {
                    Err(format!("Infinite type: {v} occurs in {t:?}"))
                } else {
                    self.substitutions.insert(v.clone(), t.clone());
                    Ok(())
                }
            }
            (Type::Function(p1, r1), Type::Function(p2, r2)) => {
                self.unify(p1, p2)?;
                self.unify(r1, r2)
            }
            (Type::FunctionWithEffect { from: f1, to: t1, effects: e1 }, 
             Type::FunctionWithEffect { from: f2, to: t2, effects: e2 }) => {
                self.unify(f1, f2)?;
                self.unify(t1, t2)?;
                // TODO: unify effects
                if e1 != e2 {
                    // For now, just check equality
                    Err(format!("Cannot unify effects: {:?} and {:?}", e1, e2))
                } else {
                    Ok(())
                }
            }
            // Allow unifying pure functions with effectful functions
            (Type::Function(p1, r1), Type::FunctionWithEffect { from: p2, to: r2, .. }) |
            (Type::FunctionWithEffect { from: p1, to: r1, .. }, Type::Function(p2, r2)) => {
                self.unify(p1, p2)?;
                self.unify(r1, r2)
            }
            (Type::List(e1), Type::List(e2)) => self.unify(e1, e2),
            _ => {
                let error_msg = match (&t1, &t2) {
                    (Type::Int, Type::Float) | (Type::Float, Type::Int) => {
                        format!(
                            "Cannot unify {} with {}.\n\
                            Hint: For float arithmetic, use operators with dots: +. -. *. /.\n\
                            Example: (+. 1.8 32.0) instead of (+ 1.8 32.0)"
                        , t1, t2)
                    }
                    _ => format!("Cannot unify {} with {}", t1, t2),
                };
                Err(error_msg)
            }
        }
    }

    fn occurs_check(var: &str, typ: &Type) -> bool {
        match typ {
            Type::Var(v) => v == var,
            Type::Function(param, ret) => {
                Self::occurs_check(var, param) || Self::occurs_check(var, ret)
            }
            Type::List(elem) => Self::occurs_check(var, elem),
            _ => false,
        }
    }

    fn instantiate(&mut self, scheme: &TypeScheme) -> Type {
        let mut subst = HashMap::new();
        for var in &scheme.vars {
            subst.insert(var.clone(), self.fresh_var());
        }
        
        let instantiated_typ = self.substitute_with_map(&scheme.typ, &subst);
        
        // If the scheme has effects, instantiate them too
        if let (Some(effects), Some(effect_checker)) = (&scheme.effects, &mut self.effect_checker) {
            if !scheme.effect_vars.is_empty() {
                let instantiated_effects = effect_checker.instantiate_effects(&EffectScheme {
                    vars: scheme.effect_vars.clone(),
                    effects: effects.clone(),
                });
                
                // Apply instantiated effects to function types
                match instantiated_typ {
                    Type::Function(from, to) => {
                        return Type::FunctionWithEffect {
                            from,
                            to,
                            effects: self.extensible_to_effect_row(instantiated_effects),
                        };
                    }
                    _ => {}
                }
            }
        }
        
        instantiated_typ
    }

    fn substitute_with_map(&self, typ: &Type, subst: &HashMap<String, Type>) -> Type {
        match typ {
            Type::Var(name) => {
                // First check the provided substitution map
                if let Some(new_type) = subst.get(name) {
                    new_type.clone()
                } else if let Some(subst_type) = self.substitutions.get(name) {
                    // Then check the global substitutions and recursively substitute
                    self.substitute_with_map(subst_type, subst)
                } else {
                    typ.clone()
                }
            }
            Type::Function(param, ret) => Type::Function(
                Box::new(self.substitute_with_map(param, subst)),
                Box::new(self.substitute_with_map(ret, subst)),
            ),
            Type::FunctionWithEffect { from, to, effects } => Type::FunctionWithEffect {
                from: Box::new(self.substitute_with_map(from, subst)),
                to: Box::new(self.substitute_with_map(to, subst)),
                effects: effects.clone(), // TODO: substitute effect variables
            },
            Type::List(elem) => Type::List(Box::new(self.substitute_with_map(elem, subst))),
            Type::UserDefined { name, type_params } => Type::UserDefined {
                name: name.clone(),
                type_params: type_params.iter().map(|t| self.substitute_with_map(t, subst)).collect(),
            },
            _ => typ.clone(),
        }
    }

    fn generalize(&self, typ: &Type, env: &TypeEnv) -> TypeScheme {
        let typ = self.substitute(typ);
        let free_vars = Self::free_type_vars(&typ);
        let env_vars = self.env_type_vars(env);
        let vars: Vec<String> = free_vars.difference(&env_vars).cloned().collect();
        TypeScheme { vars, typ, effects: None, effect_vars: Vec::new() }
    }
    
    fn generalize_with_effects(&mut self, typ: &Type, env: &TypeEnv) -> TypeScheme {
        let typ = self.substitute(typ);
        let free_vars = Self::free_type_vars(&typ);
        let env_vars = self.env_type_vars(env);
        let vars: Vec<String> = free_vars.difference(&env_vars).cloned().collect();
        
        // Extract effects from function types
        let (effects, effect_vars) = match &typ {
            Type::FunctionWithEffect { effects, .. } => {
                let extensible_effects = self.effect_row_to_extensible(effects.clone());
                if let Some(effect_checker) = &mut self.effect_checker {
                    let effect_scheme = effect_checker.generalize_effects(
                        &extensible_effects,
                        env
                    );
                    (Some(extensible_effects), effect_scheme.vars)
                } else {
                    (Some(extensible_effects), Vec::new())
                }
            }
            _ => (None, Vec::new())
        };
        
        TypeScheme { vars, typ, effects, effect_vars }
    }

    fn free_type_vars(typ: &Type) -> HashSet<String> {
        match typ {
            Type::Var(name) => {
                let mut set = HashSet::new();
                set.insert(name.clone());
                set
            }
            Type::Function(param, ret) => {
                let mut vars = Self::free_type_vars(param);
                vars.extend(Self::free_type_vars(ret));
                vars
            }
            Type::FunctionWithEffect { from, to, .. } => {
                let mut vars = Self::free_type_vars(from);
                vars.extend(Self::free_type_vars(to));
                vars
            }
            Type::List(elem) => Self::free_type_vars(elem),
            _ => HashSet::new(),
        }
    }

    fn env_type_vars(&self, env: &TypeEnv) -> HashSet<String> {
        let mut vars = HashSet::new();
        for scope in &env.bindings {
            for scheme in scope.values() {
                let scheme_vars = Self::free_type_vars(&scheme.typ);
                let scheme_bound_vars: HashSet<String> = scheme.vars.iter().cloned().collect();
                vars.extend(scheme_vars.difference(&scheme_bound_vars).cloned());
            }
        }
        vars
    }

    /// Convert ExtensibleEffectRow to EffectRow
    fn extensible_to_effect_row(&self, ext_row: xs_core::extensible_effects::ExtensibleEffectRow) -> xs_core::effects::EffectRow {
        use xs_core::effects::{Effect, EffectRow, EffectSet};
        use xs_core::extensible_effects::ExtensibleEffectRow;
        
        match ext_row {
            ExtensibleEffectRow::Empty => EffectRow::Concrete(EffectSet::pure()),
            ExtensibleEffectRow::Single(effect) => {
                let mut set = EffectSet::pure();
                // Convert effect name to Effect enum
                match effect.name.as_str() {
                    "IO" => set.add(Effect::IO),
                    "State" => set.add(Effect::State),
                    "Exception" => set.add(Effect::Error), // Effect::Error instead of Exception
                    "Async" => set.add(Effect::Async),
                    _ => {}, // Unknown effects are ignored for now
                }
                EffectRow::Concrete(set)
            }
            ExtensibleEffectRow::Extend(effect, rest) => {
                // Recursively build the effect set
                let mut set = match self.extensible_to_effect_row(*rest) {
                    EffectRow::Concrete(s) => s,
                    _ => EffectSet::pure(),
                };
                // Add the current effect
                match effect.name.as_str() {
                    "IO" => set.add(Effect::IO),
                    "State" => set.add(Effect::State),
                    "Exception" => set.add(Effect::Error), // Effect::Error instead of Exception
                    "Async" => set.add(Effect::Async),
                    _ => {},
                }
                EffectRow::Concrete(set)
            }
            ExtensibleEffectRow::Variable(var) => {
                // Convert to effect variable
                EffectRow::Variable(xs_core::effects::EffectVar(var))
            }
            ExtensibleEffectRow::Union(left, right) => {
                // Union both sides
                let left_row = self.extensible_to_effect_row(*left);
                let right_row = self.extensible_to_effect_row(*right);
                match (left_row, right_row) {
                    (EffectRow::Concrete(mut left_set), EffectRow::Concrete(right_set)) => {
                        // Merge the sets using iter() method
                        for effect in right_set.iter() {
                            left_set.add(effect.clone());
                        }
                        EffectRow::Concrete(left_set)
                    }
                    _ => {
                        // For now, if either side has variables, default to pure
                        // This should be improved with proper effect unification
                        EffectRow::Concrete(EffectSet::pure())
                    }
                }
            }
        }
    }
    
    /// Convert EffectRow to ExtensibleEffectRow
    fn effect_row_to_extensible(&self, row: xs_core::effects::EffectRow) -> xs_core::extensible_effects::ExtensibleEffectRow {
        use xs_core::effects::{Effect, EffectRow};
        use xs_core::extensible_effects::{ExtensibleEffectRow, EffectInstance};
        
        match row {
            EffectRow::Concrete(set) => {
                let mut result = ExtensibleEffectRow::Empty;
                for effect in set.iter() {
                    let effect_name = match effect {
                        Effect::IO => "IO",
                        Effect::State => "State",
                        Effect::Error => "Exception",
                        Effect::Async => "Async",
                        Effect::Network => "Network",
                        Effect::FileSystem => "FileSystem",
                        Effect::Random => "Random",
                        Effect::Time => "Time",
                        Effect::Log => "Log",
                        Effect::Pure => continue,
                    };
                    result = result.add_effect(EffectInstance::new(effect_name.to_string()));
                }
                result
            }
            EffectRow::Variable(var) => ExtensibleEffectRow::Variable(var.0),
            EffectRow::Extension(set, var) => {
                let base = self.effect_row_to_extensible(EffectRow::Concrete(set));
                match base {
                    ExtensibleEffectRow::Empty => ExtensibleEffectRow::Variable(var.0),
                    _ => ExtensibleEffectRow::Union(
                        Box::new(base),
                        Box::new(ExtensibleEffectRow::Variable(var.0))
                    ),
                }
            }
        }
    }

    pub fn check(&mut self, expr: &Expr, env: &mut TypeEnv) -> Result<Type, String> {
        let typ = self.check_with_effects(expr, env)?;
        Ok(typ)
    }
    
    pub fn check_with_effects(&mut self, expr: &Expr, env: &mut TypeEnv) -> Result<Type, String> {
        // Check effects if effect checker is enabled
        if let Some(effect_checker) = &mut self.effect_checker {
            let _effects = effect_checker.infer_effects(expr, env)?;
            // TODO: Store effects in type annotation
        }
        
        match expr {
            Expr::Literal(lit, _) => match lit {
                Literal::Int(_) => Ok(Type::Int),
                Literal::Float(_) => Ok(Type::Float),
                Literal::Bool(_) => Ok(Type::Bool),
                Literal::String(_) => Ok(Type::String),
            },

            Expr::Ident(Ident(name), _) => match env.lookup(name) {
                Some(scheme) => Ok(self.instantiate(scheme)),
                None => Err(format!("Undefined variable: {name}")),
            },

            Expr::List(exprs, _) => {
                if exprs.is_empty() {
                    Ok(Type::List(Box::new(self.fresh_var())))
                } else {
                    let elem_type = self.check(&exprs[0], env)?;
                    for expr in &exprs[1..] {
                        let t = self.check(expr, env)?;
                        self.unify(&elem_type, &t)?;
                    }
                    Ok(Type::List(Box::new(self.substitute(&elem_type))))
                }
            }

            Expr::Let {
                name,
                type_ann,
                value,
                ..
            } => {
                // Check if this is a function that references itself (recursive)
                let is_recursive = match value.as_ref() {
                    Expr::Lambda { body, .. } => {
                        xs_core::recursion_detector::is_recursive(name, body)
                    }
                    _ => false,
                };

                let value_type = if is_recursive {
                    // Handle as recursive function
                    let var_type = type_ann.clone().unwrap_or_else(|| self.fresh_var());
                    env.push_scope();
                    env.add_binding(name.0.clone(), TypeScheme::mono(var_type.clone()));
                    
                    let actual_type = self.check(value, env)?;
                    self.unify(&var_type, &actual_type)?;
                    
                    env.pop_scope();
                    self.substitute(&var_type)
                } else {
                    // Handle as non-recursive binding
                    self.check(value, env)?
                };

                if let Some(ann) = type_ann {
                    self.unify(&value_type, ann)?;
                }

                let scheme = self.generalize_with_effects(&value_type, env);
                env.add_binding(name.0.clone(), scheme);
                Ok(value_type)
            }

            Expr::LetRec {
                name,
                type_ann,
                value,
                ..
            } => {
                let var_type = type_ann.clone().unwrap_or_else(|| self.fresh_var());
                env.add_binding(name.0.clone(), TypeScheme::mono(var_type.clone()));

                let value_type = self.check(value, env)?;
                self.unify(&var_type, &value_type)?;

                let final_type = self.substitute(&var_type);
                let scheme = self.generalize_with_effects(&final_type, env);
                env.add_binding(name.0.clone(), scheme);

                Ok(final_type)
            }

            Expr::LetIn {
                name,
                type_ann,
                value,
                body,
                ..
            } => {
                env.push_scope();

                let value_type = self.check(value, env)?;

                if let Some(ann) = type_ann {
                    self.unify(&value_type, ann)?;
                }

                let scheme = self.generalize(&value_type, env);
                env.add_binding(name.0.clone(), scheme);

                let body_type = self.check(body, env)?;
                env.pop_scope();

                Ok(body_type)
            }

            Expr::Lambda { params, body, .. } => {
                env.push_scope();
                let mut param_types = Vec::new();

                for (Ident(param_name), param_type_ann) in params {
                    let param_type = param_type_ann.clone().unwrap_or_else(|| self.fresh_var());
                    param_types.push(param_type.clone());
                    env.add_binding(param_name.clone(), TypeScheme::mono(param_type));
                }

                // Infer body type
                let body_type = self.check(body, env)?;
                
                // Infer effects from the lambda body
                let body_effects = if let Some(effect_checker) = &mut self.effect_checker {
                    effect_checker.infer_effects(body, env)?
                } else {
                    // If no effect checker, assume pure
                    xs_core::extensible_effects::ExtensibleEffectRow::pure()
                };
                
                env.pop_scope();

                // Build function type with effects if necessary
                let mut result_type = body_type;
                let effect_row = self.extensible_to_effect_row(body_effects);
                
                for param_type in param_types.into_iter().rev() {
                    if effect_row.is_pure() {
                        result_type = Type::Function(Box::new(param_type), Box::new(result_type));
                    } else {
                        result_type = Type::FunctionWithEffect {
                            from: Box::new(param_type),
                            to: Box::new(result_type),
                            effects: effect_row.clone(),
                        };
                    }
                }

                Ok(result_type)
            }

            Expr::Rec {
                name,
                params,
                return_type,
                body,
                ..
            } => {
                // First, create a fresh type variable for the recursive function
                let rec_type = self.fresh_var();

                env.push_scope();

                // Add the recursive binding with the fresh type
                env.add_binding(name.0.clone(), TypeScheme::mono(rec_type.clone()));

                // Create function type
                let mut param_types = Vec::new();
                for (Ident(param_name), param_type_ann) in params {
                    let param_type = param_type_ann.clone().unwrap_or_else(|| self.fresh_var());
                    param_types.push(param_type.clone());
                    env.add_binding(param_name.clone(), TypeScheme::mono(param_type));
                }

                let body_type = self.check(body, env)?;

                if let Some(ret_type) = return_type {
                    self.unify(&body_type, ret_type)?;
                }

                let mut func_type = self.substitute(&body_type);
                for param_type in param_types.into_iter().rev() {
                    func_type = Type::Function(Box::new(param_type), Box::new(func_type));
                }

                // Unify the recursive type with the actual function type
                self.unify(&rec_type, &func_type)?;

                env.pop_scope();

                let final_type = self.substitute(&func_type);
                Ok(final_type)
            }

            Expr::If {
                cond,
                then_expr,
                else_expr,
                ..
            } => {
                let cond_type = self.check(cond, env)?;
                self.unify(&cond_type, &Type::Bool)?;

                let then_type = self.check(then_expr, env)?;
                let else_type = self.check(else_expr, env)?;
                self.unify(&then_type, &else_type)?;

                Ok(self.substitute(&then_type))
            }

            Expr::Apply { func, args, .. } => {
                let func_type = self.check(func, env)?;

                let mut current_type = func_type;
                for arg in args {
                    let arg_type = self.check(arg, env)?;
                    let result_type = self.fresh_var();

                    let expected_func_type =
                        Type::Function(Box::new(arg_type.clone()), Box::new(result_type.clone()));

                    self.unify(&current_type, &expected_func_type)?;
                    current_type = self.substitute(&result_type);
                }

                Ok(current_type)
            }

            Expr::Match { expr, cases, .. } => {
                let expr_type = self.check(expr, env)?;
                let mut result_type = None;

                for (pattern, case_expr) in cases {
                    env.push_scope();
                    self.check_pattern(pattern, &expr_type, env)?;
                    let case_type = self.check(case_expr, env)?;

                    if let Some(ref expected_type) = result_type {
                        self.unify(expected_type, &case_type)?;
                    } else {
                        result_type = Some(case_type);
                    }

                    env.pop_scope();
                }

                result_type.ok_or_else(|| "Empty match expression".to_string())
            }

            Expr::Constructor { args, .. } => {
                // TODO: Look up constructor in type definitions
                // For now, return a fresh type variable
                let result_type = self.fresh_var();

                for arg in args {
                    self.check(arg, env)?;
                }

                Ok(result_type)
            }

            Expr::TypeDef { definition, .. } => {
                env.add_type_definition(definition.name.clone(), definition.clone());

                // Add constructors to environment
                for constructor in &definition.constructors {
                    let mut cons_type = Type::UserDefined {
                        name: definition.name.clone(),
                        type_params: definition
                            .type_params
                            .iter()
                            .map(|p| Type::Var(p.clone()))
                            .collect(),
                    };

                    // Build constructor function type
                    for field_type in constructor.fields.iter().rev() {
                        cons_type =
                            Type::Function(Box::new(field_type.clone()), Box::new(cons_type));
                    }

                    let scheme = if definition.type_params.is_empty() {
                        TypeScheme::mono(cons_type)
                    } else {
                        TypeScheme {
                            vars: definition.type_params.clone(),
                            typ: cons_type,
                            effects: None,
                            effect_vars: vec![],
                        }
                    };

                    env.add_binding(constructor.name.clone(), scheme);
                }

                Ok(Type::Int) // Type definitions don't have a runtime value
            }

            Expr::Module { .. } => {
                // TODO: Implement module type checking
                Ok(Type::Int)
            }

            Expr::Import { .. } => {
                // TODO: Implement import type checking
                Ok(Type::Int)
            }

            Expr::Use { path, items, .. } => {
                // Handle use statement - import functions into current environment
                self.handle_use(env, path, items).map_err(|e| e.to_string())?;
                Ok(Type::Unit) // Use statements produce unit value
            }

            Expr::QualifiedIdent { module_name, name, .. } => {
                // Handle namespace access like Int.toString
                let module = &module_name.0;
                let func = &name.0;
                
                match env.lookup_module_function(module, func) {
                    Some(scheme) => Ok(self.instantiate(scheme)),
                    None => Err(format!(
                        "Undefined function: {}.{}",
                        module, func
                    )),
                }
            }

            Expr::Handler { cases, body, .. } => {
                // Check the body to get its type and effects
                let body_type = self.check(body, env)?;
                
                // For now, return the body type
                // TODO: Properly check handler cases and effect types
                for (_effect_name, _patterns, _continuation, handler_body) in cases {
                    let _ = self.check(handler_body, env)?;
                }
                
                Ok(body_type)
            }
            
            Expr::WithHandler { handler, body, .. } => {
                // Check handler and body
                let _ = self.check(handler, env)?;
                let body_type = self.check(body, env)?;
                
                // The type of with-handler is the type of the body
                // with some effects handled by the handler
                Ok(body_type)
            }
            
            Expr::Perform { effect: _, args, .. } => {
                // Check all arguments
                for arg in args {
                    let _ = self.check(arg, env)?;
                }
                
                // The type of perform depends on the effect's signature
                // For now, return a fresh type variable
                // TODO: Look up effect signature and return proper type
                Ok(self.fresh_var())
            }

            Expr::Pipeline { expr, func, .. } => {
                let expr_type = self.check(expr, env)?;
                let func_type = self.check(func, env)?;

                let result_type = self.fresh_var();
                let expected_func_type =
                    Type::Function(Box::new(expr_type), Box::new(result_type.clone()));

                self.unify(&func_type, &expected_func_type)?;
                Ok(self.substitute(&result_type))
            }

            Expr::Block { exprs, .. } => {
                if exprs.is_empty() {
                    Ok(Type::Unit)
                } else {
                    env.push_scope();
                    let mut last_type = Type::Unit;
                    
                    for expr in exprs {
                        last_type = self.check(expr, env)?;
                    }
                    
                    env.pop_scope();
                    Ok(last_type)
                }
            }

            Expr::Hole { name, type_hint, span } => {
                if let Some(hint) = type_hint {
                    Ok(hint.clone())
                } else {
                    Err(format!(
                        "Hole '{}' at position {} requires type annotation",
                        name.as_deref().unwrap_or("@"),
                        span.start
                    ))
                }
            }

            Expr::Do { statements, .. } => {
                // Process each statement in the do block
                let mut result_type = Type::Unit;
                
                for statement in statements {
                    match statement {
                        DoStatement::Bind { name, expr, .. } => {
                            // Type check the expression being bound
                            let expr_type = self.check(expr, env)?;
                            
                            // TODO: For now, we just add the binding to the environment
                            // In the future, this should handle effect types properly
                            env.add_binding(name.0.clone(), TypeScheme {
                                vars: vec![],
                                typ: expr_type,
                                effects: None,
                                effect_vars: vec![],
                            });
                        }
                        DoStatement::Expression(expr) => {
                            // The last expression determines the type of the do block
                            result_type = self.check(expr, env)?;
                        }
                    }
                }
                
                Ok(result_type)
            }

            Expr::RecordLiteral { fields, .. } => {
                // Type check each field and collect their types
                let mut field_types = Vec::new();
                for (name, expr) in fields {
                    let ty = self.check(expr, env)?;
                    field_types.push((name.0.clone(), ty));
                }
                
                // Sort fields by name for consistent type representation
                field_types.sort_by(|a, b| a.0.cmp(&b.0));
                
                Ok(Type::Record { fields: field_types })
            }

            Expr::RecordAccess { record, field, .. } => {
                // First check if this is a namespace access (e.g., Int.toString)
                if let Expr::Ident(module_name, _) = record.as_ref() {
                    // Check if this is a known module name (starts with uppercase)
                    if module_name.0.chars().next().map_or(false, |c| c.is_uppercase()) {
                        match env.lookup_module_function(&module_name.0, &field.0) {
                            Some(scheme) => return Ok(self.instantiate(scheme)),
                            None => {
                                // Not a module function, continue with record access
                            }
                        }
                    }
                }
                
                // Normal record field access
                let record_type = self.check(record, env)?;
                
                match &record_type {
                    Type::Record { fields } => {
                        // Find the field type
                        for (fname, ftype) in fields {
                            if fname == &field.0 {
                                return Ok(ftype.clone());
                            }
                        }
                        Err(format!("Field '{}' not found in record", field.0))
                    }
                    Type::Var(_) => {
                        // If it's a type variable, we need to constrain it to be a record
                        // For now, return a fresh type variable
                        Ok(self.fresh_var())
                    }
                    _ => Err(format!("Cannot access field '{}' on non-record type", field.0))
                }
            }

            Expr::RecordUpdate { record, updates, .. } => {
                let record_type = self.check(record, env)?;
                
                match record_type {
                    Type::Record { mut fields } => {
                        // Type check updates and update field types
                        for (update_name, update_expr) in updates {
                            let update_type = self.check(update_expr, env)?;
                            let mut found = false;
                            
                            for (fname, ftype) in &mut fields {
                                if fname == &update_name.0 {
                                    *ftype = update_type.clone();
                                    found = true;
                                    break;
                                }
                            }
                            
                            if !found {
                                return Err(format!("Field '{}' not found in record", update_name.0));
                            }
                        }
                        
                        Ok(Type::Record { fields })
                    }
                    Type::Var(_) => {
                        // If it's a type variable, return it as is for now
                        Ok(record_type)
                    }
                    _ => Err("Cannot update fields on non-record type".to_string())
                }
            }
            
            Expr::LetRecIn { name, type_ann, value, body, .. } => {
                // Similar to LetRec but with a body expression
                let value_type = if let Some(ann) = type_ann {
                    ann.clone()
                } else {
                    self.fresh_var()
                };
                
                // Add name to environment for recursive calls
                env.push_scope();
                env.add_binding(name.0.clone(), TypeScheme::mono(value_type.clone()));
                
                // Type check the value
                let inferred_type = self.check(value, env)?;
                self.unify(&value_type, &inferred_type)?;
                
                // Update binding with generalized type
                let gen_scheme = self.generalize(&inferred_type, env);
                env.add_binding(name.0.clone(), gen_scheme);
                
                // Type check the body
                let body_type = self.check(body, env)?;
                env.pop_scope();
                
                Ok(body_type)
            }
            
            Expr::HandleExpr { expr, handlers: _, return_handler: _, .. } => {
                // Type check the handled expression
                let expr_type = self.check(expr, env)?;
                
                // TODO: Implement proper effect handler type checking
                // For now, just return the expression type
                Ok(expr_type)
            }
        }
    }

    fn check_pattern(
        &mut self,
        pattern: &Pattern,
        expected_type: &Type,
        env: &mut TypeEnv,
    ) -> Result<(), String> {
        match pattern {
            Pattern::Wildcard(_) => Ok(()),

            Pattern::Literal(lit, _) => {
                let lit_type = match lit {
                    Literal::Int(_) => Type::Int,
                    Literal::Float(_) => Type::Float,
                    Literal::Bool(_) => Type::Bool,
                    Literal::String(_) => Type::String,
                };
                self.unify(expected_type, &lit_type)
            }

            Pattern::Variable(Ident(name), _) => {
                env.add_binding(name.clone(), TypeScheme::mono(expected_type.clone()));
                Ok(())
            }

            Pattern::Constructor { name, patterns, .. } => {
                // Handle :: (cons) constructor specially
                if name.0 == "::" {
                    // For lists, we expect [head, tail] patterns
                    if patterns.len() == 2 {
                        // If expected_type is a type variable, unify it with List(elem)
                        let (elem_type, list_type) = match expected_type {
                            Type::List(elem) => ((**elem).clone(), expected_type.clone()),
                            Type::Var(_) => {
                                // Create fresh element type and unify
                                let elem = self.fresh_var();
                                let list = Type::List(Box::new(elem.clone()));
                                self.unify(expected_type, &list)?;
                                (elem, list)
                            }
                            _ => return Err(":: pattern expects a list type".to_string()),
                        };
                        
                        // Check head pattern with element type
                        self.check_pattern(&patterns[0], &elem_type, env)?;
                        
                        // Check tail pattern with list type
                        self.check_pattern(&patterns[1], &list_type, env)?;
                        
                        Ok(())
                    } else {
                        Err(":: constructor expects exactly 2 patterns".to_string())
                    }
                } else {
                    // For other constructors, look up in type definitions
                    // TODO: Implement general constructor pattern checking
                    Ok(())
                }
            }

            Pattern::List { patterns, .. } => {
                let elem_type = self.fresh_var();
                let list_type = Type::List(Box::new(elem_type.clone()));
                self.unify(expected_type, &list_type)?;

                for pattern in patterns {
                    self.check_pattern(pattern, &elem_type, env)?;
                }

                Ok(())
            }
        }
    }
}

// Memory optimization module
mod perceus;
pub use perceus::{transform_to_ir, PerceusTransform};

// Re-export commonly used types
pub use xs_core::ir::IrExpr;

// Public API function for type checking
pub fn type_check(expr: &Expr) -> Result<Type, XsError> {
    let mut type_checker = TypeChecker::new();
    let mut type_env = TypeEnv::new();
    type_checker
        .check(expr, &mut type_env)
        .map_err(|e| XsError::TypeError(expr.span().clone(), e))
}
