//! Exercise the runner entrypoint, including its environment-to-engine wiring.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicUsize, Ordering};

static NEXT_DIRECTORY: AtomicUsize = AtomicUsize::new(0);

struct Fixture(PathBuf);

impl Fixture {
    fn new() -> Self {
        let id = NEXT_DIRECTORY.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "viberun-native-cache-process-{}-{id}",
            std::process::id()
        ));
        fs::create_dir(&path).unwrap();
        let fixture = Self(path);
        fixture.write_module(false);
        fixture
    }

    fn write_module(&self, trap: bool) {
        // One () -> () function exported as _start. The changed input traps.
        let mut bytes =
            b"\0asm\x01\0\0\0\x01\x04\x01\x60\0\0\x03\x02\x01\0\x07\x0a\x01\x06_start\0\0\x0a"
                .to_vec();
        bytes.extend_from_slice(if trap {
            b"\x05\x01\x03\0\0\x0b"
        } else {
            b"\x04\x01\x02\0\x0b"
        });
        fs::write(self.0.join("input.wasm"), bytes).unwrap();
    }

    fn run(&self, enabled: bool, cache: &Path) -> Output {
        self.run_with_paths(enabled, Some(cache), None)
    }

    fn run_with_paths(&self, enabled: bool, cache: Option<&Path>, home: Option<&Path>) -> Output {
        let runner = std::env::var_os("VIBE_NATIVE_CACHE_TEST_BIN")
            .unwrap_or_else(|| env!("CARGO_BIN_EXE_viberun").into());
        let mut command = Command::new(runner);
        command
            .arg(self.0.join("input.wasm"))
            .env("VIBE_NATIVE_CACHE", if enabled { "1" } else { "0" })
            .env_remove("VIBE_NATIVE_CACHE_DIR")
            .env_remove("VIBE_HOME")
            .env_remove("VIBE_FUEL")
            .env_remove("VIBE_MEM_SAMPLE_MS")
            .env_remove("VIBE_CRASH_DIAG_OUT");
        if let Some(cache) = cache {
            command.env("VIBE_NATIVE_CACHE_DIR", cache);
        }
        if let Some(home) = home {
            command.env("VIBE_HOME", home);
        }
        command.output().unwrap()
    }
}

#[test]
fn default_cache_follows_home_and_explicit_override_wins() {
    let fixture = Fixture::new();
    let first = fixture.0.join("home-a");
    let second = fixture.0.join("home-b");
    for home in [&first, &second] {
        assert!(fixture
            .run_with_paths(true, None, Some(home))
            .status
            .success());
        let cache = home.join("cache/viberun-native");
        assert!(cache.is_dir(), "native cache escaped VIBE_HOME");
        assert!(!artifact_files(&cache).is_empty());
    }
    let unused = fixture.0.join("unused-home");
    let explicit = fixture.0.join("explicit");
    assert!(fixture
        .run_with_paths(true, Some(&explicit), Some(&unused))
        .status
        .success());
    assert!(explicit.join("viberun-native").is_dir());
    assert!(!unused.exists());
    assert!(fixture
        .run_with_paths(false, None, Some(&unused))
        .status
        .success());
    assert!(!unused.exists());
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn artifact_files(directory: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    for entry in fs::read_dir(directory).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            files.extend(artifact_files(&path));
        } else if path.extension().is_none() {
            files.push(path);
        }
    }
    files
}

#[test]
fn entrypoint_populates_cache_and_observes_changed_input() {
    let fixture = Fixture::new();
    let cache = fixture.0.join("cache");
    let cold = fixture.run(true, &cache);
    assert!(cold.status.success(), "{:?}", cold);
    assert!(cache.is_dir(), "runner did not configure its native cache");
    assert!(!artifact_files(&cache).is_empty());
    let warm = fixture.run(true, &cache);
    assert!(warm.status.success(), "{:?}", warm);
    assert_eq!(cold.stdout, warm.stdout);
    fixture.write_module(true);
    let changed = fixture.run(true, &cache);
    assert!(!changed.status.success(), "stale cached code hid the trap");
    assert!(
        String::from_utf8_lossy(&changed.stderr).contains("wasm backtrace"),
        "changed module failed before executing: {:?}",
        changed
    );
}

#[test]
fn entrypoint_rebuilds_corrupt_code_and_can_disable_cache() {
    let fixture = Fixture::new();
    let cache = fixture.0.join("cache");
    assert!(fixture.run(true, &cache).status.success());
    let files = artifact_files(&cache);
    assert!(!files.is_empty());
    for path in files {
        fs::write(path, "invalid compressed artifact").unwrap();
    }
    assert!(fixture.run(true, &cache).status.success());
    let unused = fixture.0.join("disabled");
    assert!(fixture.run(false, &unused).status.success());
    assert!(!unused.exists());
    let unavailable = fixture.0.join("file");
    fs::write(&unavailable, "not a directory").unwrap();
    assert!(fixture.run(true, &unavailable).status.success());
}

#[test]
fn cache_cleanup_is_confined_to_its_private_namespace() {
    let fixture = Fixture::new();
    let neighbor = fixture.0.join("keep.txt");
    fs::write(&neighbor, "not a code-cache entry").unwrap();
    let output = fixture.run(true, &fixture.0);
    assert!(output.status.success(), "{:?}", output);
    assert!(
        fixture.0.join("viberun-native").is_dir(),
        "cache must own a private namespace, not the caller's directory"
    );
    assert_eq!(
        fs::read_to_string(&neighbor).unwrap(),
        "not a code-cache entry"
    );
    assert!(fixture.run(true, &fixture.0).status.success());
    assert!(fixture.0.join("input.wasm").is_file());
}
