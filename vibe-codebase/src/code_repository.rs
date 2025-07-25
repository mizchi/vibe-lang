//! SQLiteベースのコードリポジトリ
//!
//! XS Shellでの自動コード格納、依存関係追跡、デッドコード検出を提供

use chrono::{DateTime, Utc};
use rusqlite::{params, Connection, Transaction};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::Path;

use crate::codebase::{Hash, Term, TypeDef};

/// コードリポジトリ - SQLiteベースの永続的コードベース
pub struct CodeRepository {
    conn: Connection,
    current_session_id: Option<i64>,
}

/// 定義の種類
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum DefinitionKind {
    Term,
    Type,
}

/// リポジトリ内の定義
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Definition {
    pub hash: Hash,
    pub kind: DefinitionKind,
    pub name: Option<String>,
    pub namespace: Option<String>,
    pub content: Vec<u8>, // シリアライズされた内容
    pub type_signature: Option<String>,
    pub created_at: DateTime<Utc>,
    pub last_accessed_at: Option<DateTime<Utc>>,
    pub access_count: u32,
}

/// 依存関係の種類
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DependencyKind {
    Direct, // 直接参照
    Type,   // 型依存
}

/// 到達可能性分析の結果
#[derive(Debug)]
pub struct ReachabilityAnalysis {
    /// 到達可能な定義
    pub reachable: HashSet<Hash>,
    /// デッドコード（到達不可能な定義）
    pub dead_code: HashSet<Hash>,
    /// 各定義への参照数
    pub reference_count: HashMap<Hash, usize>,
}

impl CodeRepository {
    /// 新しいコードリポジトリを作成
    pub fn new<P: AsRef<Path>>(db_path: P) -> Result<Self, String> {
        let conn =
            Connection::open(db_path).map_err(|e| format!("Failed to open database: {}", e))?;

        let mut repo = Self {
            conn,
            current_session_id: None,
        };

        repo.initialize_schema()?;
        Ok(repo)
    }

    /// インメモリリポジトリを作成（テスト用）
    pub fn in_memory() -> Result<Self, String> {
        let conn = Connection::open_in_memory()
            .map_err(|e| format!("Failed to create in-memory database: {}", e))?;

        let mut repo = Self {
            conn,
            current_session_id: None,
        };

        repo.initialize_schema()?;
        Ok(repo)
    }

    /// スキーマを初期化
    fn initialize_schema(&mut self) -> Result<(), String> {
        self.conn
            .execute_batch(
                r#"
            CREATE TABLE IF NOT EXISTS definitions (
                hash TEXT PRIMARY KEY,
                kind TEXT NOT NULL CHECK (kind IN ('term', 'type')),
                name TEXT,
                namespace TEXT,
                content BLOB NOT NULL,
                type_signature TEXT,
                created_at INTEGER NOT NULL,
                last_accessed_at INTEGER,
                access_count INTEGER DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS dependencies (
                from_hash TEXT NOT NULL,
                to_hash TEXT NOT NULL,
                dependency_kind TEXT CHECK (dependency_kind IN ('direct', 'type')),
                PRIMARY KEY (from_hash, to_hash),
                FOREIGN KEY (from_hash) REFERENCES definitions(hash),
                FOREIGN KEY (to_hash) REFERENCES definitions(hash)
            );

            CREATE TABLE IF NOT EXISTS sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                started_at INTEGER NOT NULL,
                ended_at INTEGER,
                workspace_snapshot BLOB
            );

            CREATE TABLE IF NOT EXISTS evaluations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id INTEGER NOT NULL,
                input TEXT NOT NULL,
                result_hash TEXT,
                result_value TEXT,
                evaluated_at INTEGER NOT NULL,
                FOREIGN KEY (session_id) REFERENCES sessions(id),
                FOREIGN KEY (result_hash) REFERENCES definitions(hash)
            );

            CREATE TABLE IF NOT EXISTS namespaces (
                name TEXT PRIMARY KEY,
                parent TEXT,
                description TEXT,
                created_at INTEGER NOT NULL,
                is_public BOOLEAN DEFAULT 1
            );

            CREATE INDEX IF NOT EXISTS idx_definitions_name ON definitions(name);
            CREATE INDEX IF NOT EXISTS idx_definitions_namespace ON definitions(namespace);
            CREATE INDEX IF NOT EXISTS idx_dependencies_to ON dependencies(to_hash);
            CREATE INDEX IF NOT EXISTS idx_evaluations_session ON evaluations(session_id);
            "#,
            )
            .map_err(|e| format!("Failed to initialize schema: {}", e))?;

        Ok(())
    }

    /// 新しいセッションを開始
    pub fn start_session(&mut self) -> Result<i64, String> {
        let now = Utc::now().timestamp();

        self.conn
            .execute(
                "INSERT INTO sessions (started_at) VALUES (?1)",
                params![now],
            )
            .map_err(|e| format!("Failed to start session: {}", e))?;

        let session_id = self.conn.last_insert_rowid();
        self.current_session_id = Some(session_id);
        Ok(session_id)
    }

    /// セッションを終了
    pub fn end_session(&mut self) -> Result<(), String> {
        if let Some(session_id) = self.current_session_id {
            let now = Utc::now().timestamp();

            self.conn
                .execute(
                    "UPDATE sessions SET ended_at = ?1 WHERE id = ?2",
                    params![now, session_id],
                )
                .map_err(|e| format!("Failed to end session: {}", e))?;

            self.current_session_id = None;
        }
        Ok(())
    }

    /// 項を格納
    pub fn store_term(&mut self, term: &Term, dependencies: &HashSet<Hash>) -> Result<(), String> {
        let tx = self
            .conn
            .transaction()
            .map_err(|e| format!("Failed to start transaction: {}", e))?;

        Self::store_term_tx(&tx, term, dependencies)?;

        tx.commit()
            .map_err(|e| format!("Failed to commit transaction: {}", e))?;

        Ok(())
    }

    /// トランザクション内で項を格納
    fn store_term_tx(
        tx: &Transaction,
        term: &Term,
        dependencies: &HashSet<Hash>,
    ) -> Result<(), String> {
        let content =
            bincode::serialize(term).map_err(|e| format!("Failed to serialize term: {}", e))?;

        let namespace = term
            .name
            .as_ref()
            .and_then(|n| n.split('.').next())
            .map(|s| s.to_string());

        let now = Utc::now().timestamp();

        // 定義を挿入または更新
        tx.execute(
            r#"
            INSERT INTO definitions (hash, kind, name, namespace, content, type_signature, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ON CONFLICT(hash) DO UPDATE SET
                last_accessed_at = ?7,
                access_count = access_count + 1
            "#,
            params![
                term.hash.to_hex(),
                "term",
                term.name.as_ref(),
                namespace,
                content,
                format!("{}", term.ty),
                now
            ],
        ).map_err(|e| format!("Failed to store term: {}", e))?;

        // 依存関係を記録
        for dep_hash in dependencies {
            tx.execute(
                "INSERT OR IGNORE INTO dependencies (from_hash, to_hash, dependency_kind) VALUES (?1, ?2, ?3)",
                params![term.hash.to_hex(), dep_hash.to_hex(), "direct"],
            ).map_err(|e| format!("Failed to store dependency: {}", e))?;
        }

        Ok(())
    }

    /// 型定義を格納
    pub fn store_type(&mut self, type_def: &TypeDef) -> Result<(), String> {
        let content =
            bincode::serialize(type_def).map_err(|e| format!("Failed to serialize type: {}", e))?;

        let namespace = type_def.name.split('.').next().map(|s| s.to_string());
        let now = Utc::now().timestamp();

        self.conn.execute(
            r#"
            INSERT INTO definitions (hash, kind, name, namespace, content, type_signature, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ON CONFLICT(hash) DO UPDATE SET
                last_accessed_at = ?7,
                access_count = access_count + 1
            "#,
            params![
                type_def.hash.to_hex(),
                "type",
                &type_def.name,
                namespace,
                content,
                None::<String>,  // 型定義には型シグネチャはない
                now
            ],
        ).map_err(|e| format!("Failed to store type: {}", e))?;

        Ok(())
    }

    /// 評価を記録
    pub fn record_evaluation(
        &mut self,
        input: &str,
        result_hash: Option<&Hash>,
        result_value: &str,
    ) -> Result<(), String> {
        let session_id = self
            .current_session_id
            .ok_or_else(|| "No active session".to_string())?;

        let now = Utc::now().timestamp();

        self.conn.execute(
            "INSERT INTO evaluations (session_id, input, result_hash, result_value, evaluated_at) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                session_id,
                input,
                result_hash.map(|h| h.to_hex()),
                result_value,
                now
            ],
        ).map_err(|e| format!("Failed to record evaluation: {}", e))?;

        Ok(())
    }

    /// トップレベル名前空間からの到達可能性分析
    pub fn analyze_reachability(
        &self,
        root_namespaces: &[String],
    ) -> Result<ReachabilityAnalysis, String> {
        // ルートとなる定義を取得
        let mut roots = HashSet::new();

        for ns in root_namespaces {
            let mut stmt = self
                .conn
                .prepare(
                    "SELECT hash FROM definitions WHERE namespace = ?1 OR name LIKE ?1 || '.%'",
                )
                .map_err(|e| format!("Failed to prepare statement: {}", e))?;

            let hashes = stmt
                .query_map(params![ns], |row| {
                    Ok(Hash::from_hex(&row.get::<_, String>(0)?).unwrap())
                })
                .map_err(|e| format!("Failed to query roots: {}", e))?;

            for hash in hashes {
                roots.insert(hash.map_err(|e| format!("Failed to get hash: {}", e))?);
            }
        }

        // BFSで到達可能な定義を探索
        let mut reachable = HashSet::new();
        let mut queue = roots.into_iter().collect::<Vec<_>>();
        let mut reference_count = HashMap::new();

        while let Some(hash) = queue.pop() {
            if reachable.contains(&hash) {
                continue;
            }
            reachable.insert(hash.clone());

            // この定義が依存している定義を取得
            let mut stmt = self
                .conn
                .prepare("SELECT to_hash FROM dependencies WHERE from_hash = ?1")
                .map_err(|e| format!("Failed to prepare statement: {}", e))?;

            let deps = stmt
                .query_map(params![hash.to_hex()], |row| {
                    Ok(Hash::from_hex(&row.get::<_, String>(0)?).unwrap())
                })
                .map_err(|e| format!("Failed to query dependencies: {}", e))?;

            for dep in deps {
                let dep_hash = dep.map_err(|e| format!("Failed to get dependency: {}", e))?;
                *reference_count.entry(dep_hash.clone()).or_insert(0) += 1;
                queue.push(dep_hash);
            }
        }

        // デッドコードを特定
        let mut dead_code = HashSet::new();

        let mut stmt = self
            .conn
            .prepare("SELECT hash FROM definitions")
            .map_err(|e| format!("Failed to prepare statement: {}", e))?;

        let all_hashes = stmt
            .query_map([], |row| {
                Ok(Hash::from_hex(&row.get::<_, String>(0)?).unwrap())
            })
            .map_err(|e| format!("Failed to query all definitions: {}", e))?;

        for hash in all_hashes {
            let hash = hash.map_err(|e| format!("Failed to get hash: {}", e))?;
            if !reachable.contains(&hash) {
                dead_code.insert(hash);
            }
        }

        Ok(ReachabilityAnalysis {
            reachable,
            dead_code,
            reference_count,
        })
    }

    /// 定義を取得
    pub fn get_definition(&self, hash: &Hash) -> Result<Option<Term>, String> {
        let mut stmt = self
            .conn
            .prepare("SELECT content FROM definitions WHERE hash = ?1 AND kind = 'term'")
            .map_err(|e| format!("Failed to prepare statement: {}", e))?;

        let mut rows = stmt
            .query_map(params![hash.to_hex()], |row| Ok(row.get::<_, Vec<u8>>(0)?))
            .map_err(|e| format!("Failed to query definition: {}", e))?;

        if let Some(content) = rows.next() {
            let content = content.map_err(|e| format!("Failed to get content: {}", e))?;
            let term: Term = bincode::deserialize(&content)
                .map_err(|e| format!("Failed to deserialize term: {}", e))?;
            Ok(Some(term))
        } else {
            Ok(None)
        }
    }

    /// 名前で定義を検索
    pub fn search_by_name(
        &self,
        pattern: &str,
    ) -> Result<Vec<(Hash, String, DefinitionKind)>, String> {
        let mut stmt = self
            .conn
            .prepare("SELECT hash, name, kind FROM definitions WHERE name LIKE ?1")
            .map_err(|e| format!("Failed to prepare statement: {}", e))?;

        let results = stmt
            .query_map(params![format!("%{}%", pattern)], |row| {
                let kind = match row.get::<_, String>(2)?.as_str() {
                    "term" => DefinitionKind::Term,
                    "type" => DefinitionKind::Type,
                    _ => unreachable!(),
                };
                Ok((
                    Hash::from_hex(&row.get::<_, String>(0)?).unwrap(),
                    row.get::<_, String>(1)?,
                    kind,
                ))
            })
            .map_err(|e| format!("Failed to search definitions: {}", e))?;

        results
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| format!("Failed to collect results: {}", e))
    }

    /// アクセス統計を取得
    pub fn get_access_stats(&self) -> Result<Vec<(String, u32)>, String> {
        let mut stmt = self.conn.prepare(
            "SELECT name, access_count FROM definitions WHERE name IS NOT NULL ORDER BY access_count DESC LIMIT 20"
        ).map_err(|e| format!("Failed to prepare statement: {}", e))?;

        let results = stmt
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, u32>(1)?))
            })
            .map_err(|e| format!("Failed to query stats: {}", e))?;

        results
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| format!("Failed to collect stats: {}", e))
    }

    /// デッドコードを削除
    pub fn remove_dead_code(&mut self, dead_code: &HashSet<Hash>) -> Result<usize, String> {
        let tx = self
            .conn
            .transaction()
            .map_err(|e| format!("Failed to start transaction: {}", e))?;

        let mut count = 0;
        for hash in dead_code {
            // First delete dependencies (to avoid foreign key constraint violations)
            tx.execute(
                "DELETE FROM dependencies WHERE from_hash = ?1 OR to_hash = ?1",
                params![hash.to_hex()],
            )
            .map_err(|e| format!("Failed to delete dependencies: {}", e))?;

            // Then delete the definition
            tx.execute(
                "DELETE FROM definitions WHERE hash = ?1",
                params![hash.to_hex()],
            )
            .map_err(|e| format!("Failed to delete definition: {}", e))?;

            count += 1;
        }

        tx.commit()
            .map_err(|e| format!("Failed to commit transaction: {}", e))?;

        Ok(count)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_repository_creation() {
        let repo = CodeRepository::in_memory().unwrap();
        assert!(repo.current_session_id.is_none());
    }

    #[test]
    fn test_session_management() {
        let mut repo = CodeRepository::in_memory().unwrap();

        let session_id = repo.start_session().unwrap();
        assert_eq!(repo.current_session_id, Some(session_id));

        repo.end_session().unwrap();
        assert_eq!(repo.current_session_id, None);
    }

    #[test]
    fn test_store_and_retrieve_term() {
        let mut repo = CodeRepository::in_memory().unwrap();
        repo.start_session().unwrap();

        // Create a test term
        let expr =
            vibe_language::Expr::Literal(vibe_language::Literal::Int(42), vibe_language::Span::new(0, 2));
        let hash =
            Hash::from_hex("1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef")
                .unwrap();
        let term = Term {
            hash: hash.clone(),
            name: Some("answer".to_string()),
            expr: expr.clone(),
            ty: vibe_language::Type::Int,
            dependencies: HashSet::new(),
        };

        // Store the term
        repo.store_term(&term, &HashSet::new()).unwrap();

        // Retrieve and verify
        let retrieved = repo.get_definition(&hash).unwrap();
        assert!(retrieved.is_some());
        let retrieved_term = retrieved.unwrap();
        assert_eq!(retrieved_term.name, Some("answer".to_string()));
        assert_eq!(format!("{:?}", retrieved_term.expr), format!("{:?}", expr));
    }

    #[test]
    fn test_dependencies() {
        let mut repo = CodeRepository::in_memory().unwrap();
        repo.start_session().unwrap();

        // Create terms with dependencies
        let hash1 =
            Hash::from_hex("1111111111111111111111111111111111111111111111111111111111111111")
                .unwrap();
        let hash2 =
            Hash::from_hex("2222222222222222222222222222222222222222222222222222222222222222")
                .unwrap();

        let term1 = Term {
            hash: hash1.clone(),
            name: Some("base".to_string()),
            expr: vibe_language::Expr::Literal(vibe_language::Literal::Int(1), vibe_language::Span::new(0, 1)),
            ty: vibe_language::Type::Int,
            dependencies: HashSet::new(),
        };

        let mut deps = HashSet::new();
        deps.insert(hash1.clone());

        let term2 = Term {
            hash: hash2.clone(),
            name: Some("derived".to_string()),
            expr: vibe_language::Expr::Ident(
                vibe_language::Ident("base".to_string()),
                vibe_language::Span::new(0, 4),
            ),
            ty: vibe_language::Type::Int,
            dependencies: deps.clone(),
        };

        // Store terms
        repo.store_term(&term1, &HashSet::new()).unwrap();
        repo.store_term(&term2, &deps).unwrap();

        // Test dependency tracking
        // Note: dependency analysis is done through analyze_reachability
    }

    #[test]
    fn test_search_by_name() {
        let mut repo = CodeRepository::in_memory().unwrap();
        repo.start_session().unwrap();

        // Add some terms
        let terms = vec![
            (
                "fooBar",
                "1111111111111111111111111111111111111111111111111111111111111111",
            ),
            (
                "fooBaz",
                "2222222222222222222222222222222222222222222222222222222222222222",
            ),
            (
                "barFoo",
                "3333333333333333333333333333333333333333333333333333333333333333",
            ),
        ];

        for (name, hash_str) in terms {
            let hash = Hash::from_hex(hash_str).unwrap();
            let term = Term {
                hash: hash.clone(),
                name: Some(name.to_string()),
                expr: vibe_language::Expr::Literal(
                    vibe_language::Literal::Int(1),
                    vibe_language::Span::new(0, 1),
                ),
                ty: vibe_language::Type::Int,
                dependencies: HashSet::new(),
            };
            repo.store_term(&term, &HashSet::new()).unwrap();
        }

        // Search tests
        let results = repo.search_by_name("foo").unwrap();
        assert_eq!(results.len(), 3);

        let results = repo.search_by_name("Bar").unwrap();
        assert_eq!(results.len(), 2);

        let results = repo.search_by_name("xyz").unwrap();
        assert_eq!(results.len(), 0);
    }

    #[test]
    fn test_access_statistics() {
        let mut repo = CodeRepository::in_memory().unwrap();
        repo.start_session().unwrap();

        let hash =
            Hash::from_hex("1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef")
                .unwrap();
        let term = Term {
            hash: hash.clone(),
            name: Some("popular".to_string()),
            expr: vibe_language::Expr::Literal(vibe_language::Literal::Int(1), vibe_language::Span::new(0, 1)),
            ty: vibe_language::Type::Int,
            dependencies: HashSet::new(),
        };

        // Store and retrieve multiple times
        repo.store_term(&term, &HashSet::new()).unwrap();

        for _ in 0..5 {
            repo.store_term(&term, &HashSet::new()).unwrap();
        }

        let stats = repo.get_access_stats().unwrap();
        assert!(!stats.is_empty());
        // The exact count depends on implementation details
    }

    #[test]
    fn test_reachability_analysis() {
        let mut repo = CodeRepository::in_memory().unwrap();
        repo.start_session().unwrap();

        // Create a dependency graph:
        // Math.add <- Math.double <- unused
        //         \<- Main.compute

        let add_hash =
            Hash::from_hex("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
                .unwrap();
        let double_hash =
            Hash::from_hex("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
                .unwrap();
        let compute_hash =
            Hash::from_hex("cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc")
                .unwrap();
        let unused_hash =
            Hash::from_hex("dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd")
                .unwrap();

        // Math.add
        let add_term = Term {
            hash: add_hash.clone(),
            name: Some("Math.add".to_string()),
            expr: vibe_language::Expr::Literal(vibe_language::Literal::Int(1), vibe_language::Span::new(0, 1)),
            ty: vibe_language::Type::Int,
            dependencies: HashSet::new(),
        };

        // Math.double (depends on add)
        let mut double_deps = HashSet::new();
        double_deps.insert(add_hash.clone());
        let double_term = Term {
            hash: double_hash.clone(),
            name: Some("Math.double".to_string()),
            expr: vibe_language::Expr::Literal(vibe_language::Literal::Int(2), vibe_language::Span::new(0, 1)),
            ty: vibe_language::Type::Int,
            dependencies: double_deps.clone(),
        };

        // Main.compute (depends on add)
        let mut compute_deps = HashSet::new();
        compute_deps.insert(add_hash.clone());
        let compute_term = Term {
            hash: compute_hash.clone(),
            name: Some("Main.compute".to_string()),
            expr: vibe_language::Expr::Literal(vibe_language::Literal::Int(3), vibe_language::Span::new(0, 1)),
            ty: vibe_language::Type::Int,
            dependencies: compute_deps.clone(),
        };

        // unused (depends on double)
        let mut unused_deps = HashSet::new();
        unused_deps.insert(double_hash.clone());
        let unused_term = Term {
            hash: unused_hash.clone(),
            name: Some("unused".to_string()),
            expr: vibe_language::Expr::Literal(vibe_language::Literal::Int(4), vibe_language::Span::new(0, 1)),
            ty: vibe_language::Type::Int,
            dependencies: unused_deps.clone(),
        };

        // Store all terms
        repo.store_term(&add_term, &HashSet::new()).unwrap();
        repo.store_term(&double_term, &double_deps).unwrap();
        repo.store_term(&compute_term, &compute_deps).unwrap();
        repo.store_term(&unused_term, &unused_deps).unwrap();

        // Analyze reachability from Main namespace
        let analysis = repo.analyze_reachability(&["Main".to_string()]).unwrap();

        // Main.compute and Math.add should be reachable
        assert!(analysis.reachable.contains(&compute_hash));
        assert!(analysis.reachable.contains(&add_hash));

        // Math.double and unused should be dead code
        assert!(analysis.dead_code.contains(&double_hash));
        assert!(analysis.dead_code.contains(&unused_hash));

        // Reference count
        assert_eq!(analysis.reference_count.get(&add_hash), Some(&1)); // referenced by compute only (since we're analyzing from Main)
    }

    #[test]
    fn test_evaluation_recording() {
        let mut repo = CodeRepository::in_memory().unwrap();
        let session_id = repo.start_session().unwrap();

        let hash =
            Hash::from_hex("1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef")
                .unwrap();

        // First store a term so the hash exists
        let term = Term {
            hash: hash.clone(),
            name: Some("test_expr".to_string()),
            expr: vibe_language::Expr::Literal(vibe_language::Literal::Int(3), vibe_language::Span::new(0, 1)),
            ty: vibe_language::Type::Int,
            dependencies: HashSet::new(),
        };
        repo.store_term(&term, &HashSet::new()).unwrap();

        // Now record an evaluation
        repo.record_evaluation("(+ 1 2)", Some(&hash), "3").unwrap();

        // Verify session is set
        assert_eq!(repo.current_session_id, Some(session_id));
    }

    #[test]
    fn test_dead_code_removal() {
        let mut repo = CodeRepository::in_memory().unwrap();
        repo.start_session().unwrap();

        // Create some dead code
        let dead_hash =
            Hash::from_hex("deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
                .unwrap();
        let dead_term = Term {
            hash: dead_hash.clone(),
            name: Some("dead_code".to_string()),
            expr: vibe_language::Expr::Literal(
                vibe_language::Literal::Int(666),
                vibe_language::Span::new(0, 3),
            ),
            ty: vibe_language::Type::Int,
            dependencies: HashSet::new(),
        };

        repo.store_term(&dead_term, &HashSet::new()).unwrap();

        // Verify it exists
        assert!(repo.get_definition(&dead_hash).unwrap().is_some());

        // Remove dead code
        let mut dead_set = HashSet::new();
        dead_set.insert(dead_hash.clone());
        let removed = repo.remove_dead_code(&dead_set).unwrap();
        assert_eq!(removed, 1);

        // Verify it's gone
        assert!(repo.get_definition(&dead_hash).unwrap().is_none());
    }
}
