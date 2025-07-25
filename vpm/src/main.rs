use clap::{Parser, Subcommand};
use anyhow::Result;
use colored::*;
use vibe_package::{
    cache::PackageCache,
    manifest::PackageManifest,
    hash::calculate_package_hash,
    registry::LocalRegistry,
    resolver::PackageRegistry,
    PackageHash,
};
use std::path::Path;

#[derive(Parser)]
#[command(name = "vpm")]
#[command(about = "Vibe Package Manager", long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Initialize a new package
    Init {
        /// Package name
        name: String,
    },
    
    /// Install dependencies
    Install {
        /// Package to install (name or name#hash)
        package: Option<String>,
        
        /// Save to dependencies
        #[arg(long)]
        save: bool,
    },
    
    /// Publish package to registry
    Publish {
        /// Registry URL (defaults to local)
        #[arg(long)]
        registry: Option<String>,
    },
    
    /// Search for packages
    Search {
        /// Search query
        query: String,
    },
    
    /// Show package information
    Info {
        /// Package name or hash
        package: String,
    },
    
    /// List installed packages
    List,
    
    /// Clear package cache
    Clear,
    
    /// Update package dependencies
    Update,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Init { name } => init_package(&name)?,
        Commands::Install { package, save } => install_package(package.as_deref(), save).await?,
        Commands::Publish { registry } => publish_package(registry.as_deref()).await?,
        Commands::Search { query } => search_packages(&query)?,
        Commands::Info { package } => show_package_info(&package)?,
        Commands::List => list_packages()?,
        Commands::Clear => clear_cache()?,
        Commands::Update => update_packages().await?,
    }

    Ok(())
}

fn init_package(name: &str) -> Result<()> {
    println!("{} {}", "Initializing package:".green().bold(), name);

    // Check if package.vibe already exists
    let manifest_path = Path::new("package.vibe");
    if manifest_path.exists() {
        println!("{}", "package.vibe already exists!".red());
        return Ok(());
    }

    // Create basic package structure
    let mut manifest = PackageManifest::new(name.to_string());
    manifest.package.version = Some("0.1.0".to_string());
    manifest.entry.main = Some("src/main.vibe".to_string());
    manifest.entry.lib = Some("src/lib.vibe".to_string());

    // Save manifest
    manifest.save_to_file(manifest_path)?;

    // Create src directory
    std::fs::create_dir_all("src")?;
    
    // Create main.vibe
    std::fs::write(
        "src/main.vibe",
        r#"# Main entry point
let main = fn {} = {
    print "Hello from Vibe!"
}
"#,
    )?;

    // Create lib.vibe
    std::fs::write(
        "src/lib.vibe",
        r#"# Library exports
export { greet }

let greet = fn name: String = {
    "Hello, " ++ name ++ "!"
}
"#,
    )?;

    println!("{}", "✓ Package initialized successfully!".green());
    println!("  Created: package.vibe");
    println!("  Created: src/main.vibe");
    println!("  Created: src/lib.vibe");

    Ok(())
}

async fn install_package(package: Option<&str>, save: bool) -> Result<()> {
    let cache = PackageCache::new(PackageCache::default_cache_dir()?)?;
    
    if let Some(package_spec) = package {
        // Install specific package
        println!("{} {}", "Installing:".cyan().bold(), package_spec);
        
        // Parse package specification (name or name#hash)
        let (_name, _hash) = if let Some(pos) = package_spec.find('#') {
            let (name, hash_str) = package_spec.split_at(pos);
            (name, Some(&hash_str[1..]))
        } else {
            (package_spec, None)
        };

        // TODO: Implement actual installation
        println!("{} Package installation not yet implemented", "!".yellow());
        
        if save {
            // TODO: Update package.vibe
            println!("{} Saving to dependencies not yet implemented", "!".yellow());
        }
    } else {
        // Install from package.vibe
        let manifest = PackageManifest::load_from_file(Path::new("package.vibe"))?;
        println!("{} dependencies from package.vibe", "Installing".cyan().bold());
        
        for (name, dep) in &manifest.dependencies {
            println!("  {} {}", "→".cyan(), format!("{}#{}", name, dep.hash));
        }
        
        if manifest.dependencies.is_empty() {
            println!("{}", "No dependencies to install".yellow());
        }
    }

    Ok(())
}

async fn publish_package(registry: Option<&str>) -> Result<()> {
    println!("{}", "Publishing package...".cyan().bold());

    // Load manifest
    let manifest = PackageManifest::load_from_file(Path::new("package.vibe"))?;
    
    // Validate package
    if manifest.package.version.is_none() {
        println!("{}", "Error: Package version is required for publishing".red());
        return Ok(());
    }

    // Calculate package hash
    let hash = calculate_package_hash(Path::new("."))?;
    
    println!("  Package: {}", manifest.package.name);
    println!("  Version: {}", manifest.package.version.as_ref().unwrap());
    println!("  Hash: #{}", hash.to_hex());

    if registry.is_some() {
        println!("{} Remote registry publishing not yet implemented", "!".yellow());
    } else {
        // Use local registry
        let registry_dir = dirs::home_dir()
            .unwrap()
            .join(".vibe")
            .join("registry");
        let mut local_registry = LocalRegistry::new(registry_dir)?;
        
        // Publish to local registry
        local_registry.publish(&manifest, &hash, Path::new("."))?;
        
        println!("{}", "✓ Published to local registry!".green());
    }

    Ok(())
}

fn search_packages(query: &str) -> Result<()> {
    println!("{} '{}'", "Searching for:".cyan().bold(), query);

    // Search in local registry
    let registry_dir = dirs::home_dir()
        .unwrap()
        .join(".vibe")
        .join("registry");
    let registry = LocalRegistry::new(registry_dir)?;
    let results = registry.search_by_name(query);

    if results.is_empty() {
        println!("{}", "No packages found".yellow());
    } else {
        println!("\n{}", "Found packages:".green());
        for entry in results {
            println!("  {} - #{}", entry.name.bold(), &entry.latest[..12]);
            if !entry.versions.is_empty() {
                println!("    Versions:");
                for version in &entry.versions {
                    println!("      {} - #{} {}", 
                        version.version, 
                        &version.hash[..12],
                        if version.yanked { "(yanked)" } else { "" }
                    );
                }
            }
        }
    }

    Ok(())
}

fn show_package_info(package: &str) -> Result<()> {
    println!("{} {}", "Package info for:".cyan().bold(), package);

    // Try to parse as hash
    if package.starts_with('#') || package.len() == 64 {
        let hash_str = package.trim_start_matches('#');
        if let Ok(hash) = PackageHash::from_hex(hash_str) {
            // Check cache first
            let cache = PackageCache::new(PackageCache::default_cache_dir()?)?;
            if cache.has_package(&hash) {
                let package_dir = cache.get_package(&hash)?;
                let manifest = PackageManifest::load_from_file(&package_dir.join("package.vibe"))?;
                
                display_manifest_info(&manifest);
                return Ok(());
            }
            
            // Check registry
            let registry_dir = dirs::home_dir()
                .unwrap()
                .join(".vibe")
                .join("registry");
            let registry = LocalRegistry::new(registry_dir)?;
            if let Ok(manifest) = registry.get_manifest(&hash) {
                display_manifest_info(&manifest);
                return Ok(());
            }
        }
    } else {
        // Try to find by name in registry
        let registry_dir = dirs::home_dir()
            .unwrap()
            .join(".vibe")
            .join("registry");
        let registry = LocalRegistry::new(registry_dir)?;
        
        // Use PackageRegistry trait method
        if let Ok(hash) = registry.find_package(package, None) {
            if let Ok(manifest) = registry.get_manifest(&hash) {
                display_manifest_info(&manifest);
                println!("\n{} #{}", "Package Hash:".dimmed(), hash.to_hex());
                return Ok(());
            }
        }
    }

    println!("{} Package not found", "!".yellow());
    Ok(())
}

fn list_packages() -> Result<()> {
    println!("{}", "Installed packages:".cyan().bold());

    let cache = PackageCache::new(PackageCache::default_cache_dir()?)?;
    let packages = cache.list_packages();

    if packages.is_empty() {
        println!("{}", "No packages installed".yellow());
    } else {
        for (hash, entry) in packages {
            println!("  {} #{}", entry.name.bold(), &hash[..12]);
            if let Some(version) = &entry.version {
                println!("    Version: {}", version);
            }
            if !entry.dependencies.is_empty() {
                println!("    Dependencies: {}", entry.dependencies.join(", "));
            }
        }
    }

    // Show cache size
    match cache.cache_size() {
        Ok(size) => {
            let size_mb = size as f64 / 1_048_576.0;
            println!("\n{} {:.2} MB", "Total cache size:".dimmed(), size_mb);
        }
        Err(_) => {}
    }

    Ok(())
}

fn clear_cache() -> Result<()> {
    println!("{}", "Clearing package cache...".yellow().bold());

    let mut cache = PackageCache::new(PackageCache::default_cache_dir()?)?;
    cache.clear()?;

    println!("{}", "✓ Cache cleared successfully!".green());
    Ok(())
}

async fn update_packages() -> Result<()> {
    println!("{}", "Updating packages...".cyan().bold());
    println!("{} Package updates not yet implemented", "!".yellow());
    Ok(())
}

fn display_manifest_info(manifest: &PackageManifest) {
    println!("\n{}", "Package Information:".green());
    println!("  Name: {}", manifest.package.name.bold());
    
    if let Some(version) = &manifest.package.version {
        println!("  Version: {}", version);
    }
    
    if let Some(author) = &manifest.package.author {
        println!("  Author: {}", author);
    }
    
    if let Some(license) = &manifest.package.license {
        println!("  License: {}", license);
    }
    
    if let Some(description) = &manifest.package.description {
        println!("  Description: {}", description);
    }

    if !manifest.dependencies.is_empty() {
        println!("\n{}", "Dependencies:".green());
        for (name, dep) in &manifest.dependencies {
            println!("  {} → #{}", name, &dep.hash[..12]);
        }
    }

    if !manifest.exports.is_empty() {
        println!("\n{}", "Exports:".green());
        for export in &manifest.exports {
            println!("  - {}", export);
        }
    }
}