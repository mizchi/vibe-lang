//! Reuse Wasmtime's compiled code between fresh runner processes.
//!
//! Wasmtime keys entries by the input bytes and compilation configuration,
//! including its compiler version. Guest state and host bindings are never
//! reused. Cache failures fall back to compilation, as does corrupt data in
//! Wasmtime's cache reader.

use std::ffi::OsStr;
use std::path::PathBuf;
use wasmtime::{Cache, CacheConfig};

pub(super) fn from_environment() -> Option<Cache> {
    make_cache(
        std::env::var_os("VIBE_NATIVE_CACHE").as_deref(),
        std::env::var_os("VIBE_NATIVE_CACHE_DIR").as_deref(),
        std::env::var_os("VIBE_HOME").as_deref(),
    )
}

fn make_cache(
    mode: Option<&OsStr>,
    directory: Option<&OsStr>,
    home: Option<&OsStr>,
) -> Option<Cache> {
    if mode == Some(OsStr::new("0")) {
        return None;
    }
    let mut config = CacheConfig::new();
    let directory = directory
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            home.filter(|h| !h.is_empty())
                .map(|h| PathBuf::from(h).join("cache"))
        });
    if let Some(directory) = directory {
        let directory = if directory.is_absolute() {
            directory
        } else {
            std::env::current_dir().ok()?.join(directory)
        };
        // Wasmtime's cleanup owns this directory. Keep neighboring caller
        // files outside it even when the override names a shared build root.
        config.with_directory(directory.join("viberun-native"));
    }
    Cache::new(config).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use wasmtime::{Config, Engine, Instance, Module, Store};

    static NEXT_DIRECTORY: AtomicUsize = AtomicUsize::new(0);

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let id = NEXT_DIRECTORY.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir()
                .join(format!("viberun-native-cache-{}-{id}", std::process::id()));
            fs::create_dir(&path).unwrap();
            Self(path)
        }

        fn cache(&self) -> Cache {
            make_cache(None, Some(self.0.join("cache").as_os_str()), None).unwrap()
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn engine(cache: Cache, fuel: bool) -> Engine {
        let mut config = Config::new();
        config.cache(Some(cache)).consume_fuel(fuel);
        Engine::new(&config).unwrap()
    }

    fn value(engine: &Engine, source: impl AsRef<[u8]>, fuel: bool) -> i32 {
        let module = Module::new(engine, source).unwrap();
        let mut store = Store::new(engine, ());
        if fuel {
            store.set_fuel(100).unwrap();
        }
        let instance = Instance::new(&mut store, &module, &[]).unwrap();
        let answer = instance
            .get_typed_func::<(), i32>(&mut store, "answer")
            .unwrap()
            .call(&mut store, ())
            .unwrap();
        if fuel {
            assert!(store.get_fuel().unwrap() < 100);
        }
        answer
    }

    const ONE: &str = "(module (func (export \"answer\") (result i32) i32.const 1))";
    const TWO: &str = "(module (func (export \"answer\") (result i32) i32.const 2))";

    #[test]
    fn code_is_reused_across_engines_but_guest_state_is_fresh() {
        let directory = TestDirectory::new();
        let cache = directory.cache();
        let source = "(module (global $n (mut i32) (i32.const 0))
          (func (export \"answer\") (result i32)
            global.get $n i32.const 1 i32.add global.set $n global.get $n))";
        assert_eq!(value(&engine(cache.clone(), false), source, false), 1);
        assert_eq!(cache.cache_misses(), 1);
        assert_eq!(value(&engine(cache.clone(), false), source, false), 1);
        assert_eq!(cache.cache_hits(), 1);
    }

    #[test]
    fn changed_bytes_at_the_same_path_invalidate_code() {
        let directory = TestDirectory::new();
        let cache = directory.cache();
        let engine = engine(cache.clone(), false);
        let path = directory.0.join("input.wat");
        fs::write(&path, ONE).unwrap();
        assert_eq!(value(&engine, fs::read(&path).unwrap(), false), 1);
        fs::write(&path, TWO).unwrap();
        assert_eq!(value(&engine, fs::read(&path).unwrap(), false), 2);
        assert_eq!(cache.cache_misses(), 2);
        assert_eq!(cache.cache_hits(), 0);
    }

    #[test]
    fn fuel_configuration_has_a_separate_entry_and_still_meters() {
        let directory = TestDirectory::new();
        let cache = directory.cache();
        assert_eq!(value(&engine(cache.clone(), false), ONE, false), 1);
        assert_eq!(value(&engine(cache.clone(), true), ONE, true), 1);
        assert_eq!(cache.cache_misses(), 2);
        assert_eq!(cache.cache_hits(), 0);
        assert_eq!(value(&engine(cache.clone(), true), ONE, true), 1);
        assert_eq!(cache.cache_hits(), 1);
    }

    #[test]
    fn disabled_and_unavailable_caches_do_not_block_execution() {
        let directory = TestDirectory::new();
        let unused = directory.0.join("unused");
        assert!(make_cache(Some(OsStr::new("0")), Some(unused.as_os_str()), None).is_none());
        assert!(!unused.exists());
        let file = directory.0.join("not-a-directory");
        fs::write(&file, "file").unwrap();
        assert!(make_cache(None, Some(file.as_os_str()), None).is_none());
    }

    #[test]
    fn configured_root_keeps_neighboring_files_outside_the_cache() {
        let directory = TestDirectory::new();
        let neighbor = directory.0.join("keep.txt");
        fs::write(&neighbor, "not a cache entry").unwrap();
        let cache = make_cache(None, Some(directory.0.as_os_str()), None).unwrap();
        assert_eq!(
            cache.directory(),
            &directory.0.join("viberun-native").canonicalize().unwrap()
        );
        assert_eq!(value(&engine(cache, false), ONE, false), 1);
        assert_eq!(fs::read_to_string(neighbor).unwrap(), "not a cache entry");
    }

    #[test]
    fn home_cache_is_private_and_explicit_directory_takes_precedence() {
        let directory = TestDirectory::new();
        let home = directory.0.join("home");
        let cache = make_cache(None, None, Some(home.as_os_str())).unwrap();
        assert_eq!(
            cache.directory(),
            &home.join("cache/viberun-native").canonicalize().unwrap()
        );
        let explicit = directory.0.join("explicit");
        let cache = make_cache(None, Some(explicit.as_os_str()), Some(home.as_os_str())).unwrap();
        assert_eq!(
            cache.directory(),
            &explicit.join("viberun-native").canonicalize().unwrap()
        );
        let disabled = directory.0.join("disabled-home");
        assert!(make_cache(Some(OsStr::new("0")), None, Some(disabled.as_os_str())).is_none());
        assert!(!disabled.exists());
    }

    fn corrupt_files(directory: &std::path::Path) {
        for entry in fs::read_dir(directory).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                corrupt_files(&path);
            } else {
                fs::write(path, "invalid compressed artifact").unwrap();
            }
        }
    }

    #[test]
    fn corrupt_cache_is_recompiled_with_the_same_answer() {
        let directory = TestDirectory::new();
        let cache = directory.cache();
        let engine = engine(cache.clone(), false);
        assert_eq!(value(&engine, ONE, false), 1);
        corrupt_files(cache.directory());
        assert_eq!(value(&engine, ONE, false), 1);
        assert_eq!(cache.cache_hits(), 0);
        assert_eq!(cache.cache_misses(), 2);
        assert_eq!(value(&engine, ONE, false), 1);
        assert_eq!(cache.cache_hits(), 1);
    }

    #[test]
    fn concurrent_writers_keep_a_usable_entry() {
        let directory = TestDirectory::new();
        let cache = directory.cache();
        std::thread::scope(|scope| {
            for _ in 0..4 {
                let cache = cache.clone();
                scope.spawn(move || {
                    assert_eq!(value(&engine(cache, false), ONE, false), 1);
                });
            }
        });
        let hits = cache.cache_hits();
        assert_eq!(value(&engine(cache.clone(), false), ONE, false), 1);
        assert_eq!(cache.cache_hits(), hits + 1);
    }
}
