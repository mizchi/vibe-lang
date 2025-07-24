#[cfg(test)]
mod import_hash_tests {
    use xs_core::{Expr, Ident, parser::parse};

    #[test]
    fn test_import_with_hash() {
        let input = "import Math@abc123";
        let expr = parse(input).expect("Failed to parse import with hash");
        
        match expr {
            Expr::Import { module_name, hash, as_name, .. } => {
                assert_eq!(module_name.0, "Math");
                assert_eq!(hash, Some("abc123".to_string()));
                assert_eq!(as_name, None);
            }
            _ => panic!("Expected Import expression"),
        }
    }

    #[test]
    fn test_import_with_hash_and_alias() {
        let input = "import Math@def456 as OldMath";
        let expr = parse(input).expect("Failed to parse import with hash and alias");
        
        match expr {
            Expr::Import { module_name, hash, as_name, .. } => {
                assert_eq!(module_name.0, "Math");
                assert_eq!(hash, Some("def456".to_string()));
                assert_eq!(as_name, Some(Ident("OldMath".to_string())));
            }
            _ => panic!("Expected Import expression"),
        }
    }

    #[test]
    fn test_import_with_numeric_hash() {
        let input = "import Math@123456";
        let expr = parse(input).expect("Failed to parse import with numeric hash");
        
        match expr {
            Expr::Import { module_name, hash, as_name, .. } => {
                assert_eq!(module_name.0, "Math");
                assert_eq!(hash, Some("123456".to_string()));
                assert_eq!(as_name, None);
            }
            _ => panic!("Expected Import expression"),
        }
    }

    #[test]
    fn test_regular_import_without_hash() {
        let input = "import Math";
        let expr = parse(input).expect("Failed to parse regular import");
        
        match expr {
            Expr::Import { module_name, hash, as_name, .. } => {
                assert_eq!(module_name.0, "Math");
                assert_eq!(hash, None);
                assert_eq!(as_name, None);
            }
            _ => panic!("Expected Import expression"),
        }
    }

    #[test]
    fn test_import_qualified_module_with_hash() {
        let input = "import Data.List@abc123";
        let expr = parse(input).expect("Failed to parse qualified import with hash");
        
        match expr {
            Expr::Import { module_name, hash, as_name, .. } => {
                assert_eq!(module_name.0, "Data.List");
                assert_eq!(hash, Some("abc123".to_string()));
                assert_eq!(as_name, None);
            }
            _ => panic!("Expected Import expression"),
        }
    }
}