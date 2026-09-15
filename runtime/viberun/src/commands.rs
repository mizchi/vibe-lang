// Lazy Component Model command dispatch.
//
// Why this exists: the user-facing CLI is moving out of `runtime/vibe` (a
// shell script) and into vibe itself, which turns every subcommand into a
// call graph inside ONE core module. That module is what `runtime/vibe`
// hands this runner, and it has to carry every verb whether or not the
// invocation uses one. The Component Model gives each verb its own artifact
// with a canonical-ABI face, and this module is the half that makes only the
// invoked one cost anything: a manifest maps verb -> artifact, and nothing
// but the matched artifact is opened, validated, compiled, or instantiated.
//
// The contract, in two halves:
//
//   * a MANIFEST (`vibe-commands-v1`, TAB-separated) names the verbs; and
//   * each artifact is a component exporting
//       run: func(args: string) -> string
//     where `args` is the argv joined by NUL (a byte no path can contain)
//     and the result is framed by `vibe-command-result-v1`.
//
// Laziness is a property of `CommandManifest::resolve` + `Registry::load`:
// resolution is a scan over strings the manifest already holds, and the only
// filesystem read is of the path it returns. `scripts/test_component_lazy_dispatch.sh`
// is what proves an unrelated verb's artifact is never touched -- it makes
// the other entries unreadable and still expects a clean run.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use wasmtime::component::{Component, Linker as ComponentLinker};
use wasmtime::{bail, format_err, Engine, Result, Store, StoreLimits};

/// First non-comment line of a command manifest. A manifest without it is
/// refused rather than guessed at: every other line is `verb<TAB>path`, which
/// is a shape a stray TSV could accidentally have.
pub const MANIFEST_HEADER: &str = "vibe-commands-v1";

/// First line of what `run` returns. See `CommandResult::parse`.
pub const RESULT_HEADER: &str = "vibe-command-result-v1";

/// The component export every command artifact provides.
pub const COMMAND_EXPORT: &str = "run";

/// argv joined into the single `string` parameter. NUL cannot appear in a
/// POSIX path or in a shell argument, so the join is lossless and the split
/// needs no escaping.
pub const ARGV_SEPARATOR: char = '\0';

/// One manifest row. `path` is kept exactly as written so a diagnostic can
/// quote the manifest rather than an absolutized rewrite of it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandEntry {
    pub verb: String,
    pub path: String,
}

/// The parsed manifest. Holds strings only: parsing opens the manifest and
/// nothing else, which is what keeps dispatch lazy.
#[derive(Debug, Clone)]
pub struct CommandManifest {
    dir: PathBuf,
    entries: Vec<CommandEntry>,
}

impl CommandManifest {
    /// Parse manifest text. `manifest_path` is used for two things: the
    /// directory relative artifact paths resolve against, and the name a
    /// diagnostic quotes.
    pub fn parse(manifest_path: &Path, text: &str) -> Result<Self> {
        let dir = manifest_path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("."));
        let shown = manifest_path.display();
        let mut entries: Vec<CommandEntry> = Vec::new();
        let mut header_seen = false;
        for (index, raw) in text.lines().enumerate() {
            let line_no = index + 1;
            let line = raw.trim_end_matches(['\r']);
            if line.trim().is_empty() || line.starts_with('#') {
                continue;
            }
            if !header_seen {
                if line.trim() != MANIFEST_HEADER {
                    bail!(
                        "{shown}:{line_no}: a command manifest must start with `{MANIFEST_HEADER}`, got `{line}`"
                    );
                }
                header_seen = true;
                continue;
            }
            let Some((verb, path)) = line.split_once('\t') else {
                bail!("{shown}:{line_no}: expected `<verb>\\t<artifact-path>`, got `{line}`");
            };
            let verb = verb.trim();
            let path = path.trim();
            if verb.is_empty() {
                bail!("{shown}:{line_no}: the verb is empty");
            }
            if verb.split_whitespace().count() != 1 {
                bail!("{shown}:{line_no}: the verb `{verb}` contains whitespace");
            }
            if path.is_empty() {
                bail!("{shown}:{line_no}: verb `{verb}` names no artifact");
            }
            // A duplicate would make dispatch depend on scan order, which is
            // exactly the kind of answer that is right until the file is
            // reordered. Refuse it here, where the manifest is in hand.
            if let Some(prev) = entries.iter().find(|e| e.verb == verb) {
                bail!(
                    "{shown}:{line_no}: verb `{verb}` is listed twice (already mapped to `{}`)",
                    prev.path
                );
            }
            entries.push(CommandEntry {
                verb: verb.to_string(),
                path: path.to_string(),
            });
        }
        if !header_seen {
            bail!("{shown}: empty manifest (expected a `{MANIFEST_HEADER}` header line)");
        }
        Ok(Self { dir, entries })
    }

    pub fn read(manifest_path: &Path) -> Result<Self> {
        let text = fs::read_to_string(manifest_path)
            .map_err(|e| format_err!("read {}: {e}", manifest_path.display()))?;
        Self::parse(manifest_path, &text)
    }

    pub fn verbs(&self) -> Vec<&str> {
        self.entries.iter().map(|e| e.verb.as_str()).collect()
    }

    /// The artifact path for `verb`, or `None`. No filesystem access: this is
    /// the step that must stay a pure function of the manifest text for
    /// dispatch to be lazy.
    pub fn resolve(&self, verb: &str) -> Option<PathBuf> {
        let entry = self.entries.iter().find(|e| e.verb == verb)?;
        let path = Path::new(&entry.path);
        Some(if path.is_absolute() {
            path.to_path_buf()
        } else {
            self.dir.join(path)
        })
    }
}

/// What a command component returned, after the frame is stripped.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandResult {
    pub exit: i32,
    pub stdout: String,
}

impl CommandResult {
    /// Parse the framed result.
    ///
    ///   vibe-command-result-v1\t<exit>\n
    ///   <everything after the first newline is stdout, verbatim>
    ///
    /// The frame is REQUIRED. Without it a command that trapped halfway and
    /// returned a partial string would exit 0 and look like a success, which
    /// is the silently-wrong failure this project ranks worst. A command that
    /// produces no output still sends the header line.
    pub fn parse(raw: &str) -> Result<Self> {
        let (head, stdout) = match raw.split_once('\n') {
            Some((head, rest)) => (head, rest),
            None => (raw, ""),
        };
        let Some((header, exit)) = head.split_once('\t') else {
            bail!(
                "the component's `{COMMAND_EXPORT}` export did not return a `{RESULT_HEADER}\\t<exit>` \
                 first line (got `{}`); a command returns that frame, then its output",
                truncate_for_message(head)
            );
        };
        if header != RESULT_HEADER {
            bail!(
                "unknown command result frame `{}`; this runner speaks `{RESULT_HEADER}`",
                truncate_for_message(header)
            );
        }
        let exit: i32 = exit.trim().parse().map_err(|_| {
            format_err!(
                "`{RESULT_HEADER}` exit code must be an integer, got `{}`",
                truncate_for_message(exit)
            )
        })?;
        if !(0..=255).contains(&exit) {
            bail!("`{RESULT_HEADER}` exit code {exit} is outside 0..=255");
        }
        Ok(Self {
            exit,
            stdout: stdout.to_string(),
        })
    }
}

fn truncate_for_message(s: &str) -> String {
    const MAX: usize = 80;
    if s.chars().count() <= MAX {
        return s.to_string();
    }
    let head: String = s.chars().take(MAX).collect();
    format!("{head}…")
}

/// Store data for a command instance. `limits` is the same
/// `MOONRUN_WT_MEMORY_MB` cap every other store in this runner carries.
pub struct CommandHost {
    limits: StoreLimits,
}

/// A component header is `\0asm` followed by version 13 / layer 1. A core
/// module carries version 1 / layer 0 in the same bytes, and reaching
/// `Component::from_binary` with one produces an opaque parse error — so
/// check first and name the build that would have produced the right thing.
fn require_component_header(path: &Path, bytes: &[u8]) -> Result<()> {
    const COMPONENT: [u8; 8] = [0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00];
    const CORE: [u8; 8] = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];
    let shown = path.display();
    match bytes.get(..8) {
        Some(head) if head == COMPONENT => Ok(()),
        Some(head) if head == CORE => bail!(
            "{shown} is a core module, not a component; build it with `vibe build --component {shown}`"
        ),
        _ => bail!("{shown} is not a wasm binary"),
    }
}

/// Lazily loads and caches the components a manifest names.
///
/// `load` is where the laziness lives: a verb that is never dispatched has
/// its artifact neither read nor compiled, and a verb dispatched twice in one
/// process compiles once.
pub struct CommandRegistry {
    engine: Engine,
    manifest: CommandManifest,
    loaded: HashMap<String, Component>,
}

impl CommandRegistry {
    pub fn new(engine: Engine, manifest: CommandManifest) -> Self {
        Self {
            engine,
            manifest,
            loaded: HashMap::new(),
        }
    }

    /// Number of components compiled so far. The laziness assertion in the
    /// unit tests reads this; the gate asserts the same property from
    /// outside, through file permissions.
    #[cfg(test)]
    pub fn loaded_count(&self) -> usize {
        self.loaded.len()
    }

    pub fn load(&mut self, verb: &str) -> Result<&Component> {
        if !self.loaded.contains_key(verb) {
            let Some(path) = self.manifest.resolve(verb) else {
                let mut known = self.manifest.verbs();
                known.sort_unstable();
                bail!(
                    "unknown command `{verb}`; this manifest defines: {}",
                    if known.is_empty() {
                        "(none)".to_string()
                    } else {
                        known.join(", ")
                    }
                );
            };
            let component = compile_component(&self.engine, &path)?;
            self.loaded.insert(verb.to_string(), component);
        }
        Ok(self
            .loaded
            .get(verb)
            .expect("just inserted the verb's component"))
    }
}

/// Load one artifact. A `.cwasm` is a wasmtime AOT image and is deserialized;
/// anything else is a component binary and is compiled.
///
/// Whether an entry is precompiled is the MANIFEST's decision, never a
/// freshness heuristic here: a runner that picked a sibling `.cwasm` when it
/// looked newer would answer from a stale image the moment mtimes lied (which
/// on a CI runner they routinely do — see scripts/ensure_viberun.sh).
fn compile_component(engine: &Engine, path: &Path) -> Result<Component> {
    if path.extension().and_then(|e| e.to_str()) == Some("cwasm") {
        // Safety: same contract as `load_module`'s `.cwasm` branch — the image
        // must have been produced by `--precompile-component` from an engine
        // with this configuration. wasmtime checks its own compatibility
        // header and refuses a mismatch.
        return unsafe { Component::deserialize_file(engine, path) }
            .map_err(|e| format_err!("deserialize {}: {e}", path.display()));
    }
    let bytes = fs::read(path).map_err(|e| format_err!("read {}: {e}", path.display()))?;
    require_component_header(path, &bytes)?;
    Component::from_binary(engine, &bytes)
        .map_err(|e| format_err!("component {}: {e}", path.display()))
}

/// AOT-compile a component so dispatch pays no Cranelift cost.
pub fn precompile_component(engine: &Engine, input: &str, output: Option<&str>) -> Result<PathBuf> {
    let input_path = PathBuf::from(input);
    let bytes = fs::read(&input_path).map_err(|e| format_err!("read {input}: {e}"))?;
    require_component_header(&input_path, &bytes)?;
    let image = engine
        .precompile_component(&bytes)
        .map_err(|e| format_err!("precompile_component {input}: {e}"))?;
    let out = match output {
        Some(p) => PathBuf::from(p),
        None => input_path.with_extension("cwasm"),
    };
    fs::write(&out, image).map_err(|e| format_err!("write {}: {e}", out.display()))?;
    Ok(out)
}

/// Serve the read-only filesystem face the compiler's vfs componentization
/// emits (`comp_emit_component_wasm_string_handler_vfs`): four root-level
/// imports, all keyed by path.
///
/// Semantics are the CORE lane's, verbatim, so a module behaves the same
/// whether it was built as a core module or as a component:
/// `read-file`/`read-dir` fail on a missing path, `read-dir` returns the
/// sorted entry names joined by "\n", and `stat-token` is
/// `vibe_stat_token`'s digest (0 = missing, -1 = symlink).
fn register_vfs_imports(
    linker: &mut ComponentLinker<CommandHost>,
    stat_token: fn(&str) -> i64,
) -> Result<()> {
    let mut root = linker.root();
    root.func_wrap(
        "read-file",
        |_store, (path,): (String,)| -> Result<(String,)> {
            let content =
                fs::read(&path).map_err(|e| format_err!("command vfs read-file '{path}': {e}"))?;
            Ok((String::from_utf8_lossy(&content).into_owned(),))
        },
    )?;
    root.func_wrap("exists", |_store, (path,): (String,)| -> Result<(bool,)> {
        Ok((Path::new(&path).exists(),))
    })?;
    root.func_wrap(
        "read-dir",
        |_store, (path,): (String,)| -> Result<(String,)> {
            let mut names: Vec<String> = fs::read_dir(&path)
                .map_err(|e| format_err!("command vfs read-dir '{path}': {e}"))?
                .filter_map(|ent| ent.ok())
                .map(|ent| ent.file_name().to_string_lossy().into_owned())
                .collect();
            names.sort();
            Ok((names.join("\n"),))
        },
    )?;
    root.func_wrap(
        "stat-token",
        move |_store, (path,): (String,)| -> Result<(i64,)> { Ok((stat_token(&path),)) },
    )?;
    Ok(())
}

/// Instantiate one already-compiled component and drive its `run` export.
///
/// The linker carries the vfs face unconditionally. A component that imports
/// none of it (the pure face) simply never asks for those definitions —
/// wasmtime matches imports the component declares, and ignores the rest.
pub fn invoke_command(
    engine: &Engine,
    component: &Component,
    argv: &[String],
    limits: StoreLimits,
    stat_token: fn(&str) -> i64,
) -> Result<CommandResult> {
    let mut linker: ComponentLinker<CommandHost> = ComponentLinker::new(engine);
    register_vfs_imports(&mut linker, stat_token)?;
    let mut store = Store::new(engine, CommandHost { limits });
    store.limiter(|host| &mut host.limits);
    let instance = linker.instantiate(&mut store, component)?;
    let run = instance
        .get_typed_func::<(&str,), (String,)>(&mut store, COMMAND_EXPORT)
        .map_err(|e| {
            format_err!(
                "this component does not export `{COMMAND_EXPORT}: func(args: string) -> string` ({e})"
            )
        })?;
    let joined = join_argv(argv);
    // No `post_return`: wasmtime 47 deprecated it as a no-op (the call now
    // runs it internally), and calling it here is a warning, not a safeguard.
    let (raw,) = run.call(&mut store, (joined.as_str(),))?;
    CommandResult::parse(&raw)
}

/// argv -> the single `string` parameter. See `ARGV_SEPARATOR`.
pub fn join_argv(argv: &[String]) -> String {
    argv.join(&ARGV_SEPARATOR.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest(text: &str) -> Result<CommandManifest> {
        CommandManifest::parse(Path::new("/w/commands.tsv"), text)
    }

    #[test]
    fn manifest_resolves_relative_to_its_own_directory() {
        let m = manifest("vibe-commands-v1\ncheck\tc/check.component.wasm\n").unwrap();
        assert_eq!(
            m.resolve("check"),
            Some(PathBuf::from("/w/c/check.component.wasm"))
        );
        assert_eq!(m.resolve("build"), None);
    }

    #[test]
    fn manifest_keeps_an_absolute_path_absolute() {
        let m = manifest("vibe-commands-v1\ncheck\t/opt/check.component.wasm\n").unwrap();
        assert_eq!(
            m.resolve("check"),
            Some(PathBuf::from("/opt/check.component.wasm"))
        );
    }

    #[test]
    fn manifest_skips_comments_and_blank_lines() {
        let m = manifest("# header\n\nvibe-commands-v1\n\n# verbs\ncheck\ta.wasm\n").unwrap();
        assert_eq!(m.verbs(), vec!["check"]);
    }

    #[test]
    fn manifest_requires_the_version_header() {
        let err = manifest("check\ta.wasm\n").unwrap_err().to_string();
        assert!(err.contains("vibe-commands-v1"), "{err}");
        assert!(err.contains(":1:"), "{err}");
    }

    #[test]
    fn manifest_refuses_a_duplicate_verb() {
        let err = manifest("vibe-commands-v1\ncheck\ta.wasm\ncheck\tb.wasm\n")
            .unwrap_err()
            .to_string();
        assert!(err.contains("listed twice"), "{err}");
    }

    #[test]
    fn manifest_refuses_a_row_without_a_tab() {
        let err = manifest("vibe-commands-v1\ncheck a.wasm\n")
            .unwrap_err()
            .to_string();
        assert!(err.contains("<verb>"), "{err}");
    }

    #[test]
    fn manifest_refuses_an_empty_artifact_path() {
        let err = manifest("vibe-commands-v1\ncheck\t\n").unwrap_err().to_string();
        assert!(err.contains("names no artifact"), "{err}");
    }

    #[test]
    fn manifest_refuses_a_file_with_no_rows_at_all() {
        let err = manifest("# only a comment\n").unwrap_err().to_string();
        assert!(err.contains("empty manifest"), "{err}");
    }

    #[test]
    fn result_frame_splits_exit_from_output() {
        let r = CommandResult::parse("vibe-command-result-v1\t0\nhello\nworld\n").unwrap();
        assert_eq!(r.exit, 0);
        assert_eq!(r.stdout, "hello\nworld\n");
    }

    #[test]
    fn result_frame_allows_an_empty_payload() {
        let r = CommandResult::parse("vibe-command-result-v1\t3").unwrap();
        assert_eq!(r.exit, 3);
        assert_eq!(r.stdout, "");
    }

    #[test]
    fn result_without_the_frame_is_refused_not_treated_as_success() {
        let err = CommandResult::parse("hello").unwrap_err().to_string();
        assert!(err.contains("vibe-command-result-v1"), "{err}");
    }

    #[test]
    fn result_frame_refuses_a_non_numeric_exit() {
        let err = CommandResult::parse("vibe-command-result-v1\tok\n")
            .unwrap_err()
            .to_string();
        assert!(err.contains("must be an integer"), "{err}");
    }

    #[test]
    fn result_frame_refuses_an_out_of_range_exit() {
        let err = CommandResult::parse("vibe-command-result-v1\t256\n")
            .unwrap_err()
            .to_string();
        assert!(err.contains("0..=255"), "{err}");
    }

    #[test]
    fn result_frame_refuses_a_foreign_version() {
        let err = CommandResult::parse("vibe-command-result-v9\t0\n")
            .unwrap_err()
            .to_string();
        assert!(err.contains("unknown command result frame"), "{err}");
    }

    #[test]
    fn argv_joins_with_nul_so_spaces_survive() {
        let argv = vec!["check".to_string(), "a b.vibe".to_string()];
        assert_eq!(join_argv(&argv), "check\u{0}a b.vibe");
    }

    #[test]
    fn a_core_module_is_named_as_such_instead_of_failing_to_parse() {
        let core = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];
        let err = require_component_header(Path::new("a.wasm"), &core)
            .unwrap_err()
            .to_string();
        assert!(err.contains("vibe build --component"), "{err}");
    }

    #[test]
    fn a_component_header_passes_the_check() {
        let component = [0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00];
        assert!(require_component_header(Path::new("a.wasm"), &component).is_ok());
    }

    #[test]
    fn an_unknown_verb_names_the_ones_the_manifest_has() {
        let engine = Engine::default();
        let m = manifest("vibe-commands-v1\ncheck\ta.wasm\nbuild\tb.wasm\n").unwrap();
        let mut registry = CommandRegistry::new(engine, m);
        // `unwrap_err` needs `T: Debug`, and `Component` has no Debug impl.
        let err = match registry.load("fmt") {
            Ok(_) => panic!("an unknown verb resolved to a component"),
            Err(e) => e.to_string(),
        };
        assert!(err.contains("unknown command `fmt`"), "{err}");
        assert!(err.contains("build, check"), "{err}");
        // The failed lookup must not have compiled anything.
        assert_eq!(registry.loaded_count(), 0);
    }
}
