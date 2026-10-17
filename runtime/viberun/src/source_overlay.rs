//! Source overlay for `vibe mutate`: one file is read from a replacement.
//!
//! `VIBE_SOURCE_OVERLAY=<target>` together with
//! `VIBE_SOURCE_OVERLAY_WITH=<replacement>` makes every guest read of
//! `<target>` (`fs_read_file`, `fs_read_bytes`) answer the replacement's bytes,
//! and its `fs_stat_token` answer the replacement's token. The guest -- the
//! compiler -- therefore sees ONE consistent file system in which the target
//! holds the mutant: its persistent caches key on the stat token and the
//! content, so a mutant compile never reads a cache row of the original, and
//! the original's next compile never reads a row of the mutant.
//!
//! Nothing on disk is written. That is the point of doing this in the host
//! rather than by rewriting the target in place: a killed run cannot leave a
//! mutant behind in the user's tree, and a concurrent `vibe test` in the same
//! checkout never observes one.
//!
//! Paths are compared after canonicalisation, so `lib/x.vibe`,
//! `./lib/x.vibe` and the absolute spelling all name the target. A path that
//! does not exist cannot be the target (the target must exist for the overlay
//! to be armed), so a failed canonicalisation is simply "not overlaid".

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

struct Overlay {
    target: PathBuf,
    file_name: std::ffi::OsString,
    replacement: PathBuf,
}

fn overlay() -> Option<&'static Overlay> {
    static OVERLAY: OnceLock<Option<Overlay>> = OnceLock::new();
    OVERLAY
        .get_or_init(|| {
            let target = std::env::var_os("VIBE_SOURCE_OVERLAY").filter(|v| !v.is_empty())?;
            let replacement =
                std::env::var_os("VIBE_SOURCE_OVERLAY_WITH").filter(|v| !v.is_empty())?;
            // An overlay that names a missing file is a launcher bug, and
            // silently compiling the original instead would report every
            // mutant as surviving. Refuse loudly.
            let target = std::fs::canonicalize(&target).unwrap_or_else(|e| {
                eprintln!(
                    "viberun: VIBE_SOURCE_OVERLAY target {}: {e}",
                    Path::new(&target).display()
                );
                std::process::exit(2);
            });
            let replacement = PathBuf::from(replacement);
            if !replacement.is_file() {
                eprintln!(
                    "viberun: VIBE_SOURCE_OVERLAY_WITH {} is not a file",
                    replacement.display()
                );
                std::process::exit(2);
            }
            let file_name = target.file_name()?.to_os_string();
            Some(Overlay {
                target,
                file_name,
                replacement,
            })
        })
        .as_ref()
}

/// The file whose bytes and stat token stand for `path`: the replacement when
/// `path` names the overlaid target, otherwise `path` itself.
pub(super) fn source_overlay_resolve(path: &str) -> PathBuf {
    if let Some(ov) = overlay() {
        let p = Path::new(path);
        // Cheap reject first: canonicalising every path the compiler reads
        // would cost a syscall chain per read.
        if p.file_name() == Some(ov.file_name.as_os_str()) {
            if let Ok(canon) = std::fs::canonicalize(p) {
                if canon == ov.target {
                    return ov.replacement.clone();
                }
            }
        }
    }
    PathBuf::from(path)
}

/// `std::fs::read` through the overlay.
pub(super) fn source_overlay_read(path: &str) -> std::io::Result<Vec<u8>> {
    std::fs::read(source_overlay_resolve(path))
}
