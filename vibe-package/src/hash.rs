use crate::{PackageHash, Result, PackageError};
use sha2::{Sha256, Digest};
use std::path::Path;
use std::fs;
use std::io::Read;
use walkdir::WalkDir;

/// Calculate hash for a package directory
pub fn calculate_package_hash(package_dir: &Path) -> Result<PackageHash> {
    let mut hasher = Sha256::new();
    let mut entries = Vec::new();

    // Collect all files in sorted order for deterministic hashing
    for entry in WalkDir::new(package_dir)
        .follow_links(false)
        .into_iter()
        .filter_map(|e| e.ok())
    {
        if entry.file_type().is_file() {
            let path = entry.path();
            let relative_path = path.strip_prefix(package_dir)
                .map_err(|e| PackageError::Io(std::io::Error::new(
                    std::io::ErrorKind::Other,
                    e.to_string()
                )))?;
            
            // Skip certain files
            if should_skip_file(relative_path) {
                continue;
            }

            entries.push((relative_path.to_path_buf(), path.to_path_buf()));
        }
    }

    // Sort entries for deterministic order
    entries.sort_by(|a, b| a.0.cmp(&b.0));

    // Hash each file
    for (relative_path, full_path) in entries {
        // Hash the relative path
        hasher.update(relative_path.to_string_lossy().as_bytes());
        hasher.update(b"\0"); // Null separator

        // Hash the file contents
        let mut file = fs::File::open(&full_path)?;
        let mut buffer = Vec::new();
        file.read_to_end(&mut buffer)?;
        hasher.update(&buffer);
        hasher.update(b"\0"); // Null separator
    }

    let result = hasher.finalize();
    let mut hash = [0u8; 32];
    hash.copy_from_slice(&result);
    Ok(PackageHash(hash))
}

/// Calculate hash for a single file
pub fn calculate_file_hash(file_path: &Path) -> Result<PackageHash> {
    let mut file = fs::File::open(file_path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0; 8192];

    loop {
        let bytes_read = file.read(&mut buffer)?;
        if bytes_read == 0 {
            break;
        }
        hasher.update(&buffer[..bytes_read]);
    }

    let result = hasher.finalize();
    let mut hash = [0u8; 32];
    hash.copy_from_slice(&result);
    Ok(PackageHash(hash))
}

/// Calculate hash for code content
pub fn calculate_content_hash(content: &str) -> PackageHash {
    let mut hasher = Sha256::new();
    hasher.update(content.as_bytes());
    let result = hasher.finalize();
    let mut hash = [0u8; 32];
    hash.copy_from_slice(&result);
    PackageHash(hash)
}

/// Check if a file should be skipped during hashing
fn should_skip_file(path: &Path) -> bool {
    // Skip hidden files and directories
    for component in path.components() {
        if let Some(name) = component.as_os_str().to_str() {
            if name.starts_with('.') && name != "." && name != ".." {
                return true;
            }
        }
    }

    // Skip common non-source files
    if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
        match name {
            "package-lock.json" | "yarn.lock" | "Cargo.lock" => return true,
            _ => {}
        }
    }

    // Skip common directories
    if let Some(first) = path.components().next() {
        if let Some(name) = first.as_os_str().to_str() {
            match name {
                "target" | "dist" | "build" | "node_modules" => return true,
                _ => {}
            }
        }
    }

    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;
    use std::fs;

    #[test]
    fn test_content_hash() {
        let content1 = "let x = 42";
        let content2 = "let x = 42";
        let content3 = "let x = 43";

        let hash1 = calculate_content_hash(content1);
        let hash2 = calculate_content_hash(content2);
        let hash3 = calculate_content_hash(content3);

        // Same content should produce same hash
        assert_eq!(hash1, hash2);
        // Different content should produce different hash
        assert_ne!(hash1, hash3);
    }

    #[test]
    fn test_file_hash() -> Result<()> {
        let temp_dir = TempDir::new().unwrap();
        let file_path = temp_dir.path().join("test.vibe");
        
        fs::write(&file_path, "let main = fn {} = print \"Hello\"")?;
        
        let hash1 = calculate_file_hash(&file_path)?;
        let hash2 = calculate_file_hash(&file_path)?;
        
        // Same file should produce same hash
        assert_eq!(hash1, hash2);
        
        // Change file content
        fs::write(&file_path, "let main = fn {} = print \"World\"")?;
        let hash3 = calculate_file_hash(&file_path)?;
        
        // Different content should produce different hash
        assert_ne!(hash1, hash3);
        
        Ok(())
    }

    #[test]
    fn test_package_hash() -> Result<()> {
        let temp_dir = TempDir::new().unwrap();
        let package_dir = temp_dir.path();
        
        // Create package structure
        fs::write(package_dir.join("main.vibe"), "let main = fn {} = 42")?;
        fs::create_dir(package_dir.join("src"))?;
        fs::write(package_dir.join("src/lib.vibe"), "let lib = fn x = x + 1")?;
        
        let hash1 = calculate_package_hash(package_dir)?;
        let hash2 = calculate_package_hash(package_dir)?;
        
        // Same package should produce same hash
        assert_eq!(hash1, hash2);
        
        // Add new file
        fs::write(package_dir.join("src/helper.vibe"), "let helper = fn {} = 0")?;
        let hash3 = calculate_package_hash(package_dir)?;
        
        // Modified package should produce different hash
        assert_ne!(hash1, hash3);
        
        Ok(())
    }
}