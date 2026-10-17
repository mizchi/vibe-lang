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
//! Paths are compared by file identity (device and inode; canonical path off
//! unix), so `lib/x.vibe`, `./lib/x.vibe`, the absolute spelling and a symlink
//! of another name all name the target. A path that does not exist cannot be
//! the target (the target must exist for the overlay to be armed), so a failed
//! stat is simply "not overlaid".

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

struct Overlay {
    #[cfg(not(unix))]
    target: PathBuf,
    /// (device, inode) of the target on unix: one `stat` per read decides
    /// whether a path names it, under ANY spelling -- a symlink whose basename
    /// differs from the target's included.
    #[cfg(unix)]
    identity: (u64, u64),
    replacement: PathBuf,
}

#[cfg(unix)]
fn file_identity(path: &Path) -> Option<(u64, u64)> {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata(path).ok().map(|m| (m.dev(), m.ino()))
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
            Some(Overlay {
                #[cfg(unix)]
                identity: file_identity(&target)?,
                #[cfg(not(unix))]
                target,
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
        #[cfg(unix)]
        let hit = file_identity(p) == Some(ov.identity);
        #[cfg(not(unix))]
        let hit = std::fs::canonicalize(p).is_ok_and(|canon| canon == ov.target);
        if hit {
            return ov.replacement.clone();
        }
    }
    PathBuf::from(path)
}

/// `std::fs::read` through the overlay.
pub(super) fn source_overlay_read(path: &str) -> std::io::Result<Vec<u8>> {
    std::fs::read(source_overlay_resolve(path))
}
