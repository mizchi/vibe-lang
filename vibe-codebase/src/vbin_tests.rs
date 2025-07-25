//! Tests for VBin storage format

#[cfg(test)]
mod tests {
    use super::super::codebase::{Codebase, Hash};
    use super::super::vbin::*;
    use tempfile::TempDir;

    fn create_test_codebase() -> Codebase {
        let mut codebase = Codebase::new();

        // Add some terms
        let expr1 =
            vibe_language::Expr::Literal(vibe_language::Literal::Int(42), vibe_language::Span::new(0, 2));
        let _hash1 = codebase
            .add_term(Some("answer".to_string()), expr1, vibe_language::Type::Int)
            .unwrap();

        let expr2 = vibe_language::Expr::Lambda {
            params: vec![(
                vibe_language::Ident("x".to_string()),
                Some(vibe_language::Type::Int),
            )],
            body: Box::new(vibe_language::Expr::Ident(
                vibe_language::Ident("x".to_string()),
                vibe_language::Span::new(0, 1),
            )),
            span: vibe_language::Span::new(0, 10),
        };
        let _hash2 = codebase
            .add_term(
                Some("identity".to_string()),
                expr2,
                vibe_language::Type::Function(
                    Box::new(vibe_language::Type::Int),
                    Box::new(vibe_language::Type::Int),
                ),
            )
            .unwrap();

        // Add dependency
        let expr3 = vibe_language::Expr::Apply {
            func: Box::new(vibe_language::Expr::Ident(
                vibe_language::Ident("identity".to_string()),
                vibe_language::Span::new(0, 8),
            )),
            args: vec![vibe_language::Expr::Ident(
                vibe_language::Ident("answer".to_string()),
                vibe_language::Span::new(0, 6),
            )],
            span: vibe_language::Span::new(0, 20),
        };
        codebase
            .add_term(Some("result".to_string()), expr3, vibe_language::Type::Int)
            .unwrap();

        codebase
    }

    #[test]
    fn test_vbin_save_and_load() {
        let temp_dir = TempDir::new().unwrap();
        let vbin_path = temp_dir.path().join("test.vbin");

        // Create and save codebase
        let original = create_test_codebase();
        let mut storage = VBinStorage::new(vbin_path.to_string_lossy().to_string());
        storage.save_full(&original).unwrap();

        // Load it back
        let mut storage2 = VBinStorage::new(vbin_path.to_string_lossy().to_string());
        let loaded = storage2.load_full().unwrap();

        // Verify contents
        assert_eq!(original.names().len(), loaded.names().len());

        for (name, hash) in original.names() {
            assert!(loaded.get_term_by_name(&name).is_some());
            assert_eq!(loaded.get_term_by_name(&name).unwrap().hash, hash);
        }
    }

    #[test]
    fn test_vbin_compression() {
        let temp_dir = TempDir::new().unwrap();
        let vbin_path = temp_dir.path().join("compressed.vbin");
        let bin_path = temp_dir.path().join("uncompressed.bin");

        // Create a large codebase
        let mut codebase = Codebase::new();
        for i in 0..100 {
            let expr =
                vibe_language::Expr::Literal(vibe_language::Literal::Int(i), vibe_language::Span::new(0, 4));
            codebase
                .add_term(Some(format!("num_{}", i)), expr, vibe_language::Type::Int)
                .unwrap();
        }

        // Save as VBin
        let mut vbin_storage = VBinStorage::new(vbin_path.to_string_lossy().to_string());
        vbin_storage.save_full(&codebase).unwrap();

        // Save as regular binary
        codebase.save(&bin_path).unwrap();

        // Compare file sizes
        let vbin_size = std::fs::metadata(&vbin_path).unwrap().len();
        let bin_size = std::fs::metadata(&bin_path).unwrap().len();

        // VBin should be smaller due to compression
        assert!(
            vbin_size < bin_size,
            "VBin size {} should be less than binary size {}",
            vbin_size,
            bin_size
        );
    }

    #[test]
    fn test_retrieve_with_dependencies() {
        let temp_dir = TempDir::new().unwrap();
        let vbin_path = temp_dir.path().join("deps.vbin");

        // Create codebase with dependencies
        let codebase = create_test_codebase();
        let mut storage = VBinStorage::new(vbin_path.to_string_lossy().to_string());
        storage.save_full(&codebase).unwrap();

        // Get the hash of "result" which depends on "identity" and "answer"
        let result_term = codebase.get_term_by_name("result").unwrap();
        let result_hash = &result_term.hash;

        // Retrieve with dependencies
        let mut storage2 = VBinStorage::new(vbin_path.to_string_lossy().to_string());
        let partial = storage2.retrieve_with_dependencies(result_hash).unwrap();

        // Should have all three terms
        assert_eq!(partial.names().len(), 3);
        assert!(partial.get_term_by_name("result").is_some());
        assert!(partial.get_term_by_name("identity").is_some());
        assert!(partial.get_term_by_name("answer").is_some());
    }

    #[test]
    fn test_retrieve_namespace() {
        let temp_dir = TempDir::new().unwrap();
        let vbin_path = temp_dir.path().join("namespaces.vbin");

        // Create codebase with namespaces
        let mut codebase = Codebase::new();

        // Math namespace
        // Skip float tests for now due to OrderedFloat privacy
        codebase
            .add_term(
                Some("Math.add".to_string()),
                vibe_language::Expr::Literal(vibe_language::Literal::Int(1), vibe_language::Span::new(0, 1)),
                vibe_language::Type::Int,
            )
            .unwrap();

        codebase
            .add_term(
                Some("Math.mul".to_string()),
                vibe_language::Expr::Literal(vibe_language::Literal::Int(2), vibe_language::Span::new(0, 1)),
                vibe_language::Type::Int,
            )
            .unwrap();

        // String namespace
        codebase
            .add_term(
                Some("String.empty".to_string()),
                vibe_language::Expr::Literal(
                    vibe_language::Literal::String("".to_string()),
                    vibe_language::Span::new(0, 2),
                ),
                vibe_language::Type::String,
            )
            .unwrap();

        let mut storage = VBinStorage::new(vbin_path.to_string_lossy().to_string());
        storage.save_full(&codebase).unwrap();

        // Retrieve Math namespace
        let mut storage2 = VBinStorage::new(vbin_path.to_string_lossy().to_string());
        let math_cb = storage2.retrieve_namespace("Math").unwrap();

        assert_eq!(math_cb.names().len(), 2);
        assert!(math_cb.get_term_by_name("Math.add").is_some());
        assert!(math_cb.get_term_by_name("Math.mul").is_some());
        assert!(math_cb.get_term_by_name("String.empty").is_none());
    }

    #[test]
    fn test_vbin_stats() {
        let temp_dir = TempDir::new().unwrap();
        let vbin_path = temp_dir.path().join("stats.vbin");

        let codebase = create_test_codebase();
        let mut storage = VBinStorage::new(vbin_path.to_string_lossy().to_string());
        storage.save_full(&codebase).unwrap();

        // Get stats
        let mut storage2 = VBinStorage::new(vbin_path.to_string_lossy().to_string());
        let stats = storage2.stats().unwrap();

        assert_eq!(stats.term_count, 3);
        assert_eq!(stats.type_count, 0);
        assert_eq!(stats.total_definitions, 3);
        assert!(stats.total_size > 0);
        assert!(stats.namespace_count > 0);
        assert!(stats.created_at > 0);
        assert!(stats.updated_at > 0);
    }

    #[test]
    fn test_contains_check() {
        let temp_dir = TempDir::new().unwrap();
        let vbin_path = temp_dir.path().join("contains.vbin");

        let codebase = create_test_codebase();
        let answer_hash = codebase.get_term_by_name("answer").unwrap().hash.clone();

        let mut storage = VBinStorage::new(vbin_path.to_string_lossy().to_string());
        storage.save_full(&codebase).unwrap();

        // Check contains
        let mut storage2 = VBinStorage::new(vbin_path.to_string_lossy().to_string());
        assert!(storage2.contains(&answer_hash).unwrap());

        let fake_hash =
            Hash::from_hex("0000000000000000000000000000000000000000000000000000000000000000")
                .unwrap();
        assert!(!storage2.contains(&fake_hash).unwrap());
    }

    #[test]
    fn test_list_hashes() {
        let temp_dir = TempDir::new().unwrap();
        let vbin_path = temp_dir.path().join("list.vbin");

        let codebase = create_test_codebase();
        let expected_count = codebase.names().len();

        let mut storage = VBinStorage::new(vbin_path.to_string_lossy().to_string());
        storage.save_full(&codebase).unwrap();

        // List all hashes
        let mut storage2 = VBinStorage::new(vbin_path.to_string_lossy().to_string());
        let hashes = storage2.list_hashes().unwrap();

        assert_eq!(hashes.len(), expected_count);
    }

    #[test]
    fn test_merge_codebases() {
        let mut cb1 = Codebase::new();
        cb1.add_term(
            Some("foo".to_string()),
            vibe_language::Expr::Literal(vibe_language::Literal::Int(1), vibe_language::Span::new(0, 1)),
            vibe_language::Type::Int,
        )
        .unwrap();

        let mut cb2 = Codebase::new();
        cb2.add_term(
            Some("bar".to_string()),
            vibe_language::Expr::Literal(vibe_language::Literal::Int(2), vibe_language::Span::new(0, 1)),
            vibe_language::Type::Int,
        )
        .unwrap();

        cb1.merge(cb2);

        assert_eq!(cb1.names().len(), 2);
        assert!(cb1.get_term_by_name("foo").is_some());
        assert!(cb1.get_term_by_name("bar").is_some());
    }
}
