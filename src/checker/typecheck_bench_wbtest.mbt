// Microbenchmarks for checker internal hot paths.

// --- Test type fixtures ---

///|
/// Shallow type: (Int, String, Bool)
fn bench_ty_tuple3() -> @core.Type {
  @core.Type::Tuple([@core.Type::Int, @core.Type::String, @core.Type::Bool])
}

///|
/// Medium type: Func((Int, String) -> Array[Int])
fn bench_ty_func() -> @core.Type {
  @core.Type::Func(
    params=[
      @core.FuncParam::{
        name: "a",
        label: @core.ParamLabel::Positional,
        ty: @core.Type::Int,
        bounds: [],
      },
      @core.FuncParam::{
        name: "b",
        label: @core.ParamLabel::Positional,
        ty: @core.Type::String,
        bounds: [],
      },
    ],
    ret=@core.Type::Array(@core.Type::Int),
    effects=[],
  )
}

///|
/// Deep type: Func((Map[String, Array[Named("Foo", [Int])]]) -> Named("Bar", [String]))
fn bench_ty_deep() -> @core.Type {
  @core.Type::Func(
    params=[
      @core.FuncParam::{
        name: "m",
        label: @core.ParamLabel::Positional,
        ty: @core.Type::Map(
          @core.Type::String,
          @core.Type::Array(
            @core.Type::Named(name="Foo", args=[@core.Type::Int]),
          ),
        ),
        bounds: [],
      },
    ],
    ret=@core.Type::Named(name="Bar", args=[@core.Type::String]),
    effects=[],
  )
}

///|
/// Type with Var nodes for substitution benchmarks
fn bench_ty_with_vars() -> @core.Type {
  @core.Type::Func(
    params=[
      @core.FuncParam::{
        name: "x",
        label: @core.ParamLabel::Positional,
        ty: @core.Type::Var(100),
        bounds: [],
      },
      @core.FuncParam::{
        name: "y",
        label: @core.ParamLabel::Positional,
        ty: @core.Type::Array(@core.Type::Var(101)),
        bounds: [],
      },
    ],
    ret=@core.Type::Map(@core.Type::String, @core.Type::Var(100)),
    effects=[],
  )
}

///|
/// Type WITHOUT Var nodes (should skip fast via pre-check)
fn bench_ty_no_vars() -> @core.Type {
  @core.Type::Func(
    params=[
      @core.FuncParam::{
        name: "x",
        label: @core.ParamLabel::Positional,
        ty: @core.Type::Int,
        bounds: [],
      },
      @core.FuncParam::{
        name: "y",
        label: @core.ParamLabel::Positional,
        ty: @core.Type::Array(@core.Type::String),
        bounds: [],
      },
    ],
    ret=@core.Type::Map(@core.Type::String, @core.Type::Bool),
    effects=[],
  )
}

///|
/// Build an env with n substitutions: Var(base+i) → Int
fn bench_env_with_subs(n : Int) -> TypeEnv {
  let env = TypeEnv::new()
  for i in 0..<n {
    env.subs[100 + i] = @core.Type::Int
  }
  env.subs_version = n
  env
}

// === resolve_type ===

///|
test "bench: resolve_type.no_subs" (b : @bench.T) {
  let env = TypeEnv::new()
  let ty = bench_ty_func()
  b.bench(fn() { b.keep(resolve_type(env, ty)) })
}

///|
test "bench: resolve_type.with_subs.hit" (b : @bench.T) {
  let env = bench_env_with_subs(10)
  let ty = bench_ty_with_vars()
  b.bench(fn() { b.keep(resolve_type(env, ty)) })
}

///|
test "bench: resolve_type.with_subs.miss" (b : @bench.T) {
  let env = bench_env_with_subs(10)
  let ty = bench_ty_no_vars()
  b.bench(fn() { b.keep(resolve_type(env, ty)) })
}

///|
test "bench: resolve_type.deep_type" (b : @bench.T) {
  let env = bench_env_with_subs(10)
  let ty = bench_ty_deep()
  b.bench(fn() { b.keep(resolve_type(env, ty)) })
}

// === type_has_substitutable_var (pre-check) ===

///|
test "bench: type_has_substitutable_var.has_vars" (b : @bench.T) {
  let env = bench_env_with_subs(10)
  let ty = bench_ty_with_vars()
  b.bench(fn() { b.keep(type_has_substitutable_var(env, ty)) })
}

///|
test "bench: type_has_substitutable_var.no_vars" (b : @bench.T) {
  let env = bench_env_with_subs(10)
  let ty = bench_ty_no_vars()
  b.bench(fn() { b.keep(type_has_substitutable_var(env, ty)) })
}

///|
test "bench: type_has_substitutable_var.primitive" (b : @bench.T) {
  let env = bench_env_with_subs(10)
  b.bench(fn() { b.keep(type_has_substitutable_var(env, @core.Type::Int)) })
}

// === substitute_type_vars ===

///|
test "bench: substitute_type_vars.has_vars" (b : @bench.T) {
  let subs : Map[Int, @core.Type] = {}
  subs[100] = @core.Type::Int
  subs[101] = @core.Type::String
  let ty = bench_ty_with_vars()
  b.bench(fn() { b.keep(substitute_type_vars(ty, subs)) })
}

///|
test "bench: substitute_type_vars.no_vars" (b : @bench.T) {
  let subs : Map[Int, @core.Type] = {}
  subs[100] = @core.Type::Int
  let ty = bench_ty_no_vars()
  b.bench(fn() { b.keep(substitute_type_vars(ty, subs)) })
}

// === type_tree_any ===

///|
test "bench: type_tree_any.shallow" (b : @bench.T) {
  let ty = bench_ty_tuple3()
  let pred = fn(t : @core.Type) -> Bool {
    match t {
      @core.Type::Named(..) => true
      _ => false
    }
  }
  b.bench(fn() { b.keep(type_tree_any(ty, pred)) })
}

///|
test "bench: type_tree_any.deep" (b : @bench.T) {
  let ty = bench_ty_deep()
  let pred = fn(t : @core.Type) -> Bool {
    match t {
      @core.Type::Var(_) => true
      _ => false
    }
  }
  b.bench(fn() { b.keep(type_tree_any(ty, pred)) })
}

// === instantiate_scheme ===

///|
test "bench: instantiate_scheme.monomorphic" (b : @bench.T) {
  let env = TypeEnv::new()
  let scheme = TypeScheme::{
    vars: [],
    num_vars: [],
    effect_vars: [],
    trait_bounds: {},
    ty: bench_ty_func(),
  }
  b.bench(fn() { b.keep(instantiate_scheme(env, scheme)) })
}

///|
test "bench: instantiate_scheme.polymorphic2" (b : @bench.T) {
  let env = TypeEnv::new()
  let scheme = TypeScheme::{
    vars: [1, 2],
    num_vars: [],
    effect_vars: [],
    trait_bounds: {},
    ty: @core.Type::Func(
      params=[
        @core.FuncParam::{
          name: "x",
          label: @core.ParamLabel::Positional,
          ty: @core.Type::Var(1),
          bounds: [],
        },
      ],
      ret=@core.Type::Var(2),
      effects=[],
    ),
  }
  b.bench(fn() { b.keep(instantiate_scheme(env, scheme)) })
}

// === unify_types ===

///|
test "bench: unify_types.identical_primitive" (b : @bench.T) {
  let env = TypeEnv::new()
  b.bench(fn() {
    b.keep(
      unify_types(env, @core.Type::Int, @core.Type::Int) catch {
        _ => false
      },
    )
  })
}

///|
test "bench: unify_types.identical_func" (b : @bench.T) {
  let env = TypeEnv::new()
  let ty = bench_ty_func()
  b.bench(fn() { b.keep(unify_types(env, ty, ty) catch { _ => false }) })
}

///|
test "bench: unify_types.var_binding" (b : @bench.T) {
  let ty = @core.Type::Array(@core.Type::Int)
  b.bench(fn() {
    let env = TypeEnv::new()
    b.keep(unify_types(env, @core.Type::Var(1), ty) catch { _ => false })
  })
}

///|
test "bench: unify_types.deep_structural" (b : @bench.T) {
  let ty1 = bench_ty_deep()
  let ty2 = bench_ty_deep()
  b.bench(fn() {
    let env = TypeEnv::new()
    b.keep(unify_types(env, ty1, ty2) catch { _ => false })
  })
}

// === normalize_type ===

///|
test "bench: normalize_type.primitive" (b : @bench.T) {
  let env = TypeEnv::new()
  b.bench(fn() {
    b.keep(normalize_type(env, @core.Type::Int) catch { _ => @core.Type::Int })
  })
}

///|
test "bench: normalize_type.no_named" (b : @bench.T) {
  let env = TypeEnv::new()
  let ty = bench_ty_func()
  b.bench(fn() { b.keep(normalize_type(env, ty) catch { _ => ty }) })
}

///|
test "bench: normalize_type.with_named" (b : @bench.T) {
  let env = TypeEnv::new()
  let ty = bench_ty_deep()
  b.bench(fn() { b.keep(normalize_type(env, ty) catch { _ => ty }) })
}

// === transform_type_structure ===

///|
test "bench: transform_type_structure.identity" (b : @bench.T) {
  let ty = bench_ty_deep()
  let walk = fn(t : @core.Type) -> @core.Type { t }
  let has_target = fn(_t : @core.Type) -> Bool { false }
  b.bench(fn() { b.keep(transform_type_structure(ty, walk, has_target)) })
}

///|
test "bench: transform_type_structure.walk_all" (b : @bench.T) {
  let ty = bench_ty_deep()
  let walk = fn(t : @core.Type) -> @core.Type { t }
  let has_target = fn(_t : @core.Type) -> Bool { true }
  b.bench(fn() { b.keep(transform_type_structure(ty, walk, has_target)) })
}
