//! Linking for typed core-wasm imports (`import ./x.wasm { .. }`).
//!
//! The compiler lowers such an import to core imports whose module is
//! `vibe:wasm:<path>` (lib/@vibe/compiler/core/wasm_import_binding.vibe), one
//! field per exported function, named exactly as the export. When the foreign
//! module has a memory, the accessors `vibe:memory.load8_u (i32) -> i32`,
//! `vibe:memory.store8 (i32, i32)` and `vibe:memory.size () -> i64` are
//! imported from a SEPARATE module, `vibe:wasm-memory:<path>`, so that no
//! export of the foreign module -- whatever it is named -- can collide with
//! them. The foreign memory is not the vibe module's, so the host reads and
//! writes it; a shared one (wasmtime's `SharedMemory`, a pthreads build's) is
//! served the same way.
//!
//! `link_foreign_wasm_modules` instantiates each such module from `<path>`
//! (relative to `VIBE_WASM_LINK_DIR`, default the working directory -- where
//! the compiler resolved the import) in the program's own store and defines
//! its exports in the linker. A foreign module that itself imports anything is
//! refused with the list of what it needs: nothing here can satisfy another
//! module's host imports, and stubs would run it wrong. The same contract is
//! implemented for the node runner by scripts/wasm_vibe_host_runtime.js (linkForeignWasmModules).

use std::path::PathBuf;

use wasmtime::{
    bail, format_err, Caller, Extern, ExternType, Linker, Memory, Module, Result, SharedMemory, Store,
};

pub(super) const FOREIGN_PREFIX: &str = "vibe:wasm:";
pub(super) const FOREIGN_MEMORY_PREFIX: &str = "vibe:wasm-memory:";

/// The start of every error a foreign-call bridge raises from inside a call
/// (an Int that does not fit its WIT width, an out-of-range address, ...).
/// wasmtime wraps a host error as "error while executing at wasm backtrace",
/// and viberun prints the chain only under a debug variable, so main.rs looks
/// for this prefix in the chain and prints the reason -- the same narrow
/// rescue as CAPABILITY_WITHHELD_PREFIX (#2825). Measured: without it, CI
/// (no RUST_BACKTRACE) showed the backtrace alone.
pub(super) const FOREIGN_CALL_PREFIX: &str = "vibe wasm import: ";

/// The bridge's own reason for a trap, when there is one in the chain.
pub(super) fn foreign_call_refusal(error: &wasmtime::Error) -> Option<String> {
    error
        .chain()
        .map(|cause| cause.to_string())
        .find(|text| text.starts_with(FOREIGN_CALL_PREFIX))
}

/// The foreign module paths `module` imports from, through either the
/// functions' namespace or the accessors' one (a program may use only the
/// accessors), each once.
fn foreign_module_paths(module: &Module) -> Vec<String> {
    let mut paths: Vec<String> = Vec::new();
    for import in module.imports() {
        let m = import.module();
        let rel = if let Some(rest) = m.strip_prefix(FOREIGN_PREFIX) {
            rest
        } else if let Some(rest) = m.strip_prefix(FOREIGN_MEMORY_PREFIX) {
            rest
        } else {
            continue;
        };
        if !paths.iter().any(|p| p == rel) {
            paths.push(rel.to_string());
        }
    }
    paths
}

fn foreign_path(rel_str: &str) -> PathBuf {
    let rel = PathBuf::from(rel_str);
    if rel.is_absolute() {
        return rel;
    }
    match std::env::var_os("VIBE_WASM_LINK_DIR") {
        Some(dir) => PathBuf::from(dir).join(rel),
        None => rel,
    }
}

fn check_addr(op: &str, addr: i32, size: usize) -> Result<usize> {
    let a = addr as u32 as usize;
    if a >= size {
        bail!("{FOREIGN_CALL_PREFIX}{op}: address {a} is outside the foreign memory ({size} bytes)");
    }
    Ok(a)
}

/// A foreign module's memory as the accessors reach it.
#[derive(Clone)]
enum ForeignMemory {
    Plain(Memory),
    Shared(SharedMemory),
}

impl ForeignMemory {
    fn size<T: 'static>(&self, caller: &Caller<'_, T>) -> usize {
        match self {
            ForeignMemory::Plain(m) => m.data_size(caller),
            ForeignMemory::Shared(m) => m.data_size(),
        }
    }

    /// `a` has passed `check_addr` against `size`.
    fn load<T: 'static>(&self, caller: &Caller<'_, T>, a: usize) -> u8 {
        match self {
            ForeignMemory::Plain(m) => m.data(caller)[a],
            // SAFETY: `a` is in bounds, and a shared memory's bytes are
            // `UnsafeCell`s precisely so that a plain read is allowed; viberun
            // runs the foreign module on this thread only.
            ForeignMemory::Shared(m) => unsafe { *m.data()[a].get() },
        }
    }

    fn store<T: 'static>(&self, caller: &mut Caller<'_, T>, a: usize, value: u8) {
        match self {
            ForeignMemory::Plain(m) => m.data_mut(caller)[a] = value,
            // SAFETY: as for `load`.
            ForeignMemory::Shared(m) => unsafe { *m.data()[a].get() = value },
        }
    }
}

/// Instantiate and define every `vibe:wasm:<path>` module `module` imports.
/// Returns how many were linked. Shadowing is enabled for the definitions so
/// a linker reused for a fresh store (one instance per test block) can be
/// re-linked against that store's own foreign instances.
pub(super) fn link_foreign_wasm_modules<T: 'static>(
    linker: &mut Linker<T>,
    store: &mut Store<T>,
    module: &Module,
) -> Result<usize> {
    let paths = foreign_module_paths(module);
    if paths.is_empty() {
        return Ok(0);
    }
    linker.allow_shadowing(true);
    let engine = store.engine().clone();
    for rel in &paths {
        let name = format!("{FOREIGN_PREFIX}{rel}");
        let memory_name = format!("{FOREIGN_MEMORY_PREFIX}{rel}");
        let path = foreign_path(rel);
        let foreign = Module::from_file(&engine, &path)
            .map_err(|e| format_err!("cannot link '{name}': reading {}: {e}", path.display()))?;
        let needs: Vec<String> = foreign
            .imports()
            .map(|i| format!("{}.{}", i.module(), i.name()))
            .collect();
        if !needs.is_empty() {
            let shown: Vec<&str> = needs.iter().take(8).map(|s| s.as_str()).collect();
            bail!(
                "cannot link '{name}': it imports {} item(s) and viberun provides none to a foreign module: {}{}",
                needs.len(),
                shown.join(", "),
                if needs.len() > 8 { ", ..." } else { "" }
            );
        }
        let instance = Linker::<T>::new(&engine)
            .instantiate(&mut *store, &foreign)
            .map_err(|e| format_err!("cannot link '{name}': instantiating {}: {e}", path.display()))?;
        // Only the reactor initializer `_initialize: () -> ()` runs: an
        // ordinary export that happens to have that name (another
        // signature) is just an export, and calling it with no arguments
        // would fail the whole link.
        if let Ok(init) = instance.get_typed_func::<(), ()>(&mut *store, "_initialize") {
            init.call(&mut *store, ())
                .map_err(|e| format_err!("cannot link '{name}': _initialize trapped: {e}"))?;
        }
        // The first exported memory, plain or shared: a shared one (a
        // pthreads build) arrives as `Extern::SharedMemory`, a different
        // object, and the binding offers the accessors for both kinds.
        let mut memory: Option<ForeignMemory> = None;
        let exports: Vec<(String, Extern)> = instance
            .exports(&mut *store)
            .map(|e| (e.name().to_string(), e.into_extern()))
            .collect();
        for (field, ext) in exports {
            if memory.is_none() {
                match &ext {
                    Extern::Memory(m) => memory = Some(ForeignMemory::Plain(*m)),
                    Extern::SharedMemory(m) => memory = Some(ForeignMemory::Shared(m.clone())),
                    _ => {}
                }
            }
            linker.define(&mut *store, name.as_str(), field.as_str(), ext)?;
        }
        if let Some(mem) = memory {
            let load = mem.clone();
            linker.func_wrap(
                memory_name.as_str(),
                "vibe:memory.load8_u",
                move |caller: Caller<'_, T>, addr: i32| -> Result<i32> {
                    let a = check_addr("vibe:memory.load8_u", addr, load.size(&caller))?;
                    Ok(load.load(&caller, a) as i32)
                },
            )?;
            let store8 = mem.clone();
            linker.func_wrap(
                memory_name.as_str(),
                "vibe:memory.store8",
                move |mut caller: Caller<'_, T>, addr: i32, value: i32| -> Result<()> {
                    let a = check_addr("vibe:memory.store8", addr, store8.size(&caller))?;
                    store8.store(&mut caller, a, value as u8);
                    Ok(())
                },
            )?;
            linker.func_wrap(memory_name.as_str(), "vibe:memory.size", move |caller: Caller<'_, T>| -> i64 {
                mem.size(&caller) as i64
            })?;
        }
    }
    linker.allow_shadowing(false);
    Ok(paths.len())
}

// ---------------------------------------------------------------------------
// Components (`import ./greeter.component.wasm { greet }`)
//
// The compiler lowers a component import to core imports of module
// `vibe:component:<path>`, one per exported function, all i64: an Int param
// arrives untagged, a `string` param as the raw pointer of a vibe Bytes
// object holding its bytes, an Int result leaves untagged and a `string`
// result as a packed vibe string. This side instantiates the component in the
// program's store and does the canonical-ABI work through wasmtime's dynamic
// `Val` interface, so the conversions -- and the range check of each Int
// against its WIT width -- live here, next to the types that decide them.

use wasmtime::component::{Component, Linker as ComponentLinker, Type as CType, Val as CVal};
use wasmtime::Val;

use super::{vibe_alloc_packed_str, vibe_read_packed_bytes, HostState};

pub(super) const COMPONENT_PREFIX: &str = "vibe:component:";

/// A WIT type's name as the compiler spells it in a component field
/// (`wib_cv_name`); `?` for a type the bridge does not carry, which can never
/// equal a compiled signature.
fn wit_type_name(ty: &CType) -> &'static str {
    match ty {
        CType::Bool => "bool",
        CType::S8 => "s8",
        CType::U8 => "u8",
        CType::S16 => "s16",
        CType::U16 => "u16",
        CType::S32 => "s32",
        CType::U32 => "u32",
        CType::S64 => "s64",
        CType::U64 => "u64",
        CType::Float32 => "f32",
        CType::Float64 => "f64",
        CType::Char => "char",
        CType::String => "string",
        _ => "?",
    }
}

/// `<params>-><results>`, the signature half of a component field.
fn component_sig_text(params: &[CType], results: &[CType]) -> String {
    let ps: Vec<&str> = params.iter().map(wit_type_name).collect();
    let rs: Vec<&str> = results.iter().map(wit_type_name).collect();
    format!("{}->{}", ps.join(","), rs.join(","))
}

fn int_to_cval(field: &str, ty: &CType, v: i64) -> Result<CVal> {
    let out_of_range = || {
        format_err!("{FOREIGN_CALL_PREFIX}{field}: {v} does not fit the component's {ty:?} parameter")
    };
    Ok(match ty {
        CType::S8 => CVal::S8(i8::try_from(v).map_err(|_| out_of_range())?),
        CType::U8 => CVal::U8(u8::try_from(v).map_err(|_| out_of_range())?),
        CType::S16 => CVal::S16(i16::try_from(v).map_err(|_| out_of_range())?),
        CType::U16 => CVal::U16(u16::try_from(v).map_err(|_| out_of_range())?),
        CType::S32 => CVal::S32(i32::try_from(v).map_err(|_| out_of_range())?),
        CType::U32 => CVal::U32(u32::try_from(v).map_err(|_| out_of_range())?),
        CType::S64 => CVal::S64(v),
        CType::U64 => CVal::U64(u64::try_from(v).map_err(|_| out_of_range())?),
        other => bail!("{FOREIGN_CALL_PREFIX}{field}: parameter type {other:?} is not bridged"),
    })
}

/// A component Int result as the untagged i64 the binding tags; one that
/// needs more than 63 bits is an error rather than a different number.
fn cval_to_int(field: &str, v: &CVal) -> Result<i64> {
    let wide: i128 = match v {
        CVal::S8(x) => *x as i128,
        CVal::U8(x) => *x as i128,
        CVal::S16(x) => *x as i128,
        CVal::U16(x) => *x as i128,
        CVal::S32(x) => *x as i128,
        CVal::U32(x) => *x as i128,
        CVal::S64(x) => *x as i128,
        CVal::U64(x) => *x as i128,
        other => bail!("{FOREIGN_CALL_PREFIX}{field}: result {other:?} is not bridged"),
    };
    let min = -(1i128 << 62);
    let max = (1i128 << 62) - 1;
    if wide < min || wide > max {
        bail!("{FOREIGN_CALL_PREFIX}{field}: result {wide} does not fit a 63-bit Int");
    }
    Ok(wide as i64)
}

/// Instantiate and bridge every `vibe:component:<path>` module `module`
/// imports. A component that itself imports anything is refused with the list.
pub(super) fn link_component_modules(
    linker: &mut Linker<HostState>,
    store: &mut Store<HostState>,
    module: &Module,
) -> Result<usize> {
    let mut names: Vec<String> = Vec::new();
    for import in module.imports() {
        let m = import.module();
        if m.starts_with(COMPONENT_PREFIX) && !names.iter().any(|n| n == m) {
            names.push(m.to_string());
        }
    }
    if names.is_empty() {
        return Ok(0);
    }
    linker.allow_shadowing(true);
    let engine = store.engine().clone();
    for name in &names {
        let rel = PathBuf::from(&name[COMPONENT_PREFIX.len()..]);
        let path = if rel.is_absolute() {
            rel
        } else {
            match std::env::var_os("VIBE_WASM_LINK_DIR") {
                Some(dir) => PathBuf::from(dir).join(rel),
                None => rel,
            }
        };
        let component = Component::from_file(&engine, &path)
            .map_err(|e| format_err!("cannot link '{name}': reading {}: {e}", path.display()))?;
        let needs: Vec<String> = component
            .component_type()
            .imports(&engine)
            .map(|(n, _)| n.to_string())
            .collect();
        if !needs.is_empty() {
            bail!(
                "cannot link '{name}': the component imports {} item(s) and viberun provides none to an imported component: {}",
                needs.len(),
                needs.join(", ")
            );
        }
        let instance = ComponentLinker::<HostState>::new(&engine)
            .instantiate(&mut *store, &component)
            .map_err(|e| format_err!("cannot link '{name}': instantiating {}: {e}", path.display()))?;
        let fields: Vec<(String, wasmtime::FuncType)> = module
            .imports()
            .filter(|i| i.module() == name.as_str())
            .filter_map(|i| match i.ty() {
                ExternType::Func(ft) => Some((i.name().to_string(), ft)),
                _ => None,
            })
            .collect();
        for (field, core_ty) in fields {
            // `<export>#<WIT signature it was compiled against>`, e.g.
            // `add#s32,s32->s32` (wasm_component_field in the compiler).
            let (export, expected) = match field.rsplit_once('#') {
                Some((e, sig)) => (e.to_string(), sig.to_string()),
                None => bail!("cannot link '{name}': import '{field}' carries no WIT signature; rebuild the program with this compiler"),
            };
            let func = instance.get_func(&mut *store, export.as_str()).ok_or_else(|| {
                format_err!("cannot link '{name}': the component exports no function '{export}'")
            })?;
            let fty = func.ty(&*store);
            let params: Vec<CType> = fty.params().map(|(_, t)| t).collect();
            let results: Vec<CType> = fty.results().collect();
            // Every value crosses in an i64 slot, so the core type cannot
            // tell `-> s32` from `-> string`: compare the WIT signature, or a
            // component rebuilt after the program would be converted by its
            // NEW types and answer, say, a packed string pointer as an Int.
            let actual = component_sig_text(&params, &results);
            if actual != expected {
                bail!(
                    "cannot link '{name}': '{export}' is now ({actual}) but the program was compiled against ({expected}); rebuild the program"
                );
            }
            if params.len() != core_ty.params().len() || results.len() != core_ty.results().len() {
                bail!("cannot link '{name}': '{export}' does not have the shape this program was compiled against; rebuild it");
            }
            let label = export.clone();
            linker.func_new(
                name.as_str(),
                field.as_str(),
                core_ty,
                move |mut caller, args, rets| {
                    let mut vals = Vec::with_capacity(params.len());
                    for (i, ty) in params.iter().enumerate() {
                        let raw = args[i].unwrap_i64();
                        vals.push(match ty {
                            CType::String => {
                                let bytes = vibe_read_packed_bytes(&mut caller, raw)?;
                                CVal::String(String::from_utf8(bytes).map_err(|_| {
                                    format_err!("{FOREIGN_CALL_PREFIX}{label}: argument {} is not valid UTF-8, which a component string must be", i + 1)
                                })?)
                            }
                            other => int_to_cval(&label, other, raw)?,
                        });
                    }
                    let mut outs = vec![CVal::Bool(false); results.len()];
                    func.call(&mut caller, &vals, &mut outs)?;
                    if let Some(out) = outs.first() {
                        rets[0] = match out {
                            CVal::String(s) => Val::I64(vibe_alloc_packed_str(&mut caller, s)?),
                            other => Val::I64(cval_to_int(&label, other)?),
                        };
                    }
                    Ok(())
                },
            )?;
        }
    }
    linker.allow_shadowing(false);
    Ok(names.len())
}
