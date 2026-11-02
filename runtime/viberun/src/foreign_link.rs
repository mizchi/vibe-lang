//! Linking for typed core-wasm imports (`import ./x.wasm { .. }`).
//!
//! The compiler lowers such an import to core imports whose module is
//! `vibe:wasm:<path>` (lib/@vibe/compiler/core/wasm_import_binding.vibe):
//! one field per exported function, named exactly as the export, plus
//! `vibe:memory.load8_u (i32) -> i32`, `vibe:memory.store8 (i32, i32)` and
//! `vibe:memory.size () -> i64` when the foreign module has a memory. The
//! foreign memory is not the vibe module's, so the host reads and writes it.
//!
//! `link_foreign_wasm_modules` instantiates each such module from `<path>`
//! (relative to `VIBE_WASM_LINK_DIR`, default the working directory -- where
//! the compiler resolved the import) in the program's own store and defines
//! its exports in the linker. A foreign module that itself imports anything is
//! refused with the list of what it needs: nothing here can satisfy another
//! module's host imports, and stubs would run it wrong. The same contract is
//! implemented for the node runner by scripts/wasm_vibe_host_runtime.js (linkForeignWasmModules).

use std::path::PathBuf;

use wasmtime::{bail, format_err, Caller, Extern, ExternType, Linker, Memory, Module, Result, Store};

pub(super) const FOREIGN_PREFIX: &str = "vibe:wasm:";

fn foreign_module_names(module: &Module) -> Vec<String> {
    let mut names: Vec<String> = Vec::new();
    for import in module.imports() {
        let m = import.module();
        if m.starts_with(FOREIGN_PREFIX) && !names.iter().any(|n| n == m) {
            names.push(m.to_string());
        }
    }
    names
}

fn foreign_path(name: &str) -> PathBuf {
    let rel = PathBuf::from(&name[FOREIGN_PREFIX.len()..]);
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
        bail!("{op}: address {a} is outside the foreign memory ({size} bytes)");
    }
    Ok(a)
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
    let names = foreign_module_names(module);
    if names.is_empty() {
        return Ok(0);
    }
    linker.allow_shadowing(true);
    let engine = store.engine().clone();
    for name in &names {
        let path = foreign_path(name);
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
        if let Some(init) = instance.get_func(&mut *store, "_initialize") {
            init.call(&mut *store, &[], &mut [])
                .map_err(|e| format_err!("cannot link '{name}': _initialize trapped: {e}"))?;
        }
        let mut memory: Option<Memory> = None;
        let exports: Vec<(String, Extern)> = instance
            .exports(&mut *store)
            .map(|e| (e.name().to_string(), e.into_extern()))
            .collect();
        for (field, ext) in exports {
            if memory.is_none() {
                if let Extern::Memory(m) = &ext {
                    memory = Some(*m);
                }
            }
            linker.define(&mut *store, name.as_str(), field.as_str(), ext)?;
        }
        if let Some(mem) = memory {
            linker.func_wrap(
                name.as_str(),
                "vibe:memory.load8_u",
                move |caller: Caller<'_, T>, addr: i32| -> Result<i32> {
                    let data = mem.data(&caller);
                    let a = check_addr("vibe:memory.load8_u", addr, data.len())?;
                    Ok(data[a] as i32)
                },
            )?;
            linker.func_wrap(
                name.as_str(),
                "vibe:memory.store8",
                move |mut caller: Caller<'_, T>, addr: i32, value: i32| -> Result<()> {
                    let data = mem.data_mut(&mut caller);
                    let a = check_addr("vibe:memory.store8", addr, data.len())?;
                    data[a] = value as u8;
                    Ok(())
                },
            )?;
            linker.func_wrap(name.as_str(), "vibe:memory.size", move |caller: Caller<'_, T>| -> i64 {
                mem.data_size(&caller) as i64
            })?;
        }
    }
    linker.allow_shadowing(false);
    Ok(names.len())
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

fn int_to_cval(field: &str, ty: &CType, v: i64) -> Result<CVal> {
    let out_of_range = || {
        format_err!("{field}: {v} does not fit the component's {ty:?} parameter")
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
        other => bail!("{field}: parameter type {other:?} is not bridged"),
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
        other => bail!("{field}: result {other:?} is not bridged"),
    };
    let min = -(1i128 << 62);
    let max = (1i128 << 62) - 1;
    if wide < min || wide > max {
        bail!("{field}: result {wide} does not fit a 63-bit Int");
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
            let func = instance.get_func(&mut *store, field.as_str()).ok_or_else(|| {
                format_err!("cannot link '{name}': the component exports no function '{field}'")
            })?;
            let fty = func.ty(&*store);
            let params: Vec<CType> = fty.params().map(|(_, t)| t).collect();
            let results: Vec<CType> = fty.results().collect();
            if params.len() != core_ty.params().len() || results.len() != core_ty.results().len() {
                bail!("cannot link '{name}': '{field}' does not have the shape this program was compiled against; rebuild it");
            }
            let label = field.clone();
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
                                    format_err!("{label}: argument {} is not valid UTF-8, which a component string must be", i + 1)
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
