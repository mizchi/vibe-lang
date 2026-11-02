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
//! implemented for the node runner by scripts/wasm_foreign_link.js.

use std::path::PathBuf;

use wasmtime::{bail, format_err, Caller, Extern, Linker, Memory, Module, Result, Store};

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
