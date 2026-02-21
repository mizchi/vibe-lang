///|
pub fn TypeEnv::clone(self : TypeEnv) -> TypeEnv {
  {
    bindings: self.bindings.fork(),
    addr_types: self.addr_types.copy(),
    enum_defs: self.enum_defs.copy(),
    struct_defs: self.struct_defs.copy(),
    type_aliases: self.type_aliases.copy(),
    ctor_index: self.ctor_index.copy(),
    traits: self.traits.copy(),
    trait_impls: self.trait_impls.copy(),
    fn_versions: {},
    purities: self.purities.fork(),
    expr_types: self.expr_types,
    num_vars: self.num_vars.copy(),
    var_trait_bounds: self.var_trait_bounds.copy(),
    next_var: self.next_var,
    next_effect_var: self.next_effect_var,
    loop_depth: self.loop_depth,
    handle_arm_depth: self.handle_arm_depth,
    handle_resume_types: self.handle_resume_types.copy(),
    handle_resume_types_active: self.handle_resume_types_active,
    handle_arm_effect_name: self.handle_arm_effect_name,
    handle_arm_resume_expected: self.handle_arm_resume_expected,
    active_rec_fn: self.active_rec_fn,
    active_rec_fn_has_type_params: self.active_rec_fn_has_type_params,
    subs: self.subs.copy(),
    effect_subs: self.effect_subs.copy(),
    session_state: self.session_state,
  }
}

///|
pub fn TypeEnv::fork_for_check(self : TypeEnv) -> TypeEnv {
  {
    bindings: self.bindings.fork(),
    addr_types: self.addr_types.copy(),
    enum_defs: self.enum_defs.copy(),
    struct_defs: self.struct_defs.copy(),
    type_aliases: self.type_aliases.copy(),
    ctor_index: self.ctor_index.copy(),
    traits: self.traits.copy(),
    trait_impls: self.trait_impls.copy(),
    fn_versions: self.fn_versions.copy(),
    purities: self.purities.fork(),
    expr_types: self.expr_types,
    num_vars: self.num_vars.copy(),
    var_trait_bounds: self.var_trait_bounds.copy(),
    next_var: self.next_var,
    next_effect_var: self.next_effect_var,
    loop_depth: self.loop_depth,
    handle_arm_depth: self.handle_arm_depth,
    handle_resume_types: self.handle_resume_types.copy(),
    handle_resume_types_active: self.handle_resume_types_active,
    handle_arm_effect_name: self.handle_arm_effect_name,
    handle_arm_resume_expected: self.handle_arm_resume_expected,
    active_rec_fn: self.active_rec_fn,
    active_rec_fn_has_type_params: self.active_rec_fn_has_type_params,
    subs: self.subs.copy(),
    effect_subs: self.effect_subs.copy(),
    session_state: self.session_state,
  }
}

///|
/// Clone as an independent module-check environment.
/// Unlike `clone`/`fork_for_check`, this does not share `expr_types`.
pub fn TypeEnv::clone_for_module(self : TypeEnv) -> TypeEnv {
  {
    bindings: self.bindings.copy(),
    addr_types: {},
    enum_defs: self.enum_defs.copy(),
    struct_defs: self.struct_defs.copy(),
    type_aliases: self.type_aliases.copy(),
    ctor_index: self.ctor_index.copy(),
    traits: self.traits.copy(),
    trait_impls: self.trait_impls.copy(),
    fn_versions: self.fn_versions.copy(),
    purities: self.purities.copy(),
    expr_types: {},
    num_vars: {},
    var_trait_bounds: {},
    next_var: 0,
    next_effect_var: 0,
    loop_depth: 0,
    handle_arm_depth: 0,
    handle_resume_types: {},
    handle_resume_types_active: false,
    handle_arm_effect_name: None,
    handle_arm_resume_expected: None,
    active_rec_fn: None,
    active_rec_fn_has_type_params: false,
    subs: {},
    effect_subs: {},
    session_state: self.session_state,
  }
}

///|
/// Compact after eval: merge scoped bindings back and clear temp state.
pub fn TypeEnv::compact_for_eval(self : TypeEnv) -> TypeEnv {
  {
    bindings: self.bindings.merge_up_or_self(),
    addr_types: self.addr_types,
    enum_defs: self.enum_defs,
    struct_defs: self.struct_defs,
    type_aliases: self.type_aliases,
    ctor_index: self.ctor_index,
    traits: self.traits,
    trait_impls: self.trait_impls,
    fn_versions: self.fn_versions,
    purities: self.purities.merge_up_or_self(),
    expr_types: self.expr_types,
    subs: {},
    effect_subs: {},
    num_vars: {},
    var_trait_bounds: {},
    next_var: self.next_var,
    next_effect_var: self.next_effect_var,
    loop_depth: self.loop_depth,
    handle_arm_depth: 0,
    handle_resume_types: {},
    handle_resume_types_active: false,
    handle_arm_effect_name: None,
    handle_arm_resume_expected: None,
    active_rec_fn: self.active_rec_fn,
    active_rec_fn_has_type_params: self.active_rec_fn_has_type_params,
    session_state: self.session_state,
  }
}
