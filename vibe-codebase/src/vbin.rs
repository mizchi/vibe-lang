//! VBin - Vibe言語のコンパクトなバイナリコードベースフォーマット
//!
//! UCMのようにコードベースをDBとして格納し、必要な定義だけを展開できる
//! バイナリストレージフォーマット。

use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};

use bincode;
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use flate2::Compression;
use serde::{Deserialize, Serialize};

use crate::codebase::{Codebase, Hash, Term, TypeDef};

/// VBinフォーマットのバージョン
const VBIN_VERSION: u32 = 1;

/// 固定サイズヘッダー（25バイト）
/// magic: 4 bytes
/// version: 4 bytes
/// index_offset: 8 bytes
/// metadata_offset: 8 bytes
/// compression: 1 byte
const HEADER_SIZE: usize = 25;

/// VBinインデックスエントリ
#[derive(Serialize, Deserialize, Debug, Clone)]
struct IndexEntry {
    /// 定義のハッシュ
    hash: Hash,
    /// 定義の種類（0: Term, 1: Type）
    kind: u8,
    /// データのオフセット
    offset: u64,
    /// データのサイズ
    size: u32,
    /// 直接の依存関係
    dependencies: Vec<Hash>,
}

/// VBinメタデータ
#[derive(Serialize, Deserialize, Debug)]
struct VBinMetadata {
    /// 作成日時（Unix timestamp）
    created_at: u64,
    /// 最終更新日時
    updated_at: u64,
    /// 総定義数
    total_definitions: u32,
    /// 名前空間情報
    namespaces: HashMap<String, Vec<Hash>>,
}

/// VBinストレージ - 効率的なバイナリコードベース管理
pub struct VBinStorage {
    path: String,
    /// メモリ内インデックスキャッシュ
    index_cache: Option<HashMap<Hash, IndexEntry>>,
}

/// ヘッダーをバイト配列に書き込む
fn write_header(
    magic: &[u8; 4],
    version: u32,
    index_offset: u64,
    metadata_offset: u64,
    compression: u8,
) -> [u8; HEADER_SIZE] {
    let mut header = [0u8; HEADER_SIZE];
    header[0..4].copy_from_slice(magic);
    header[4..8].copy_from_slice(&version.to_le_bytes());
    header[8..16].copy_from_slice(&index_offset.to_le_bytes());
    header[16..24].copy_from_slice(&metadata_offset.to_le_bytes());
    header[24] = compression;
    header
}

/// バイト配列からヘッダーを読み込む
fn read_header(bytes: &[u8; HEADER_SIZE]) -> Result<([u8; 4], u32, u64, u64, u8), String> {
    let mut magic = [0u8; 4];
    magic.copy_from_slice(&bytes[0..4]);

    let version = u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]);
    let index_offset = u64::from_le_bytes([
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
    ]);
    let metadata_offset = u64::from_le_bytes([
        bytes[16], bytes[17], bytes[18], bytes[19], bytes[20], bytes[21], bytes[22], bytes[23],
    ]);
    let compression = bytes[24];

    Ok((magic, version, index_offset, metadata_offset, compression))
}

impl VBinStorage {
    /// 新しいVBinストレージを作成
    pub fn new(path: String) -> Self {
        Self {
            path,
            index_cache: None,
        }
    }

    /// コードベース全体をVBin形式で保存
    pub fn save_full(&mut self, codebase: &Codebase) -> Result<(), String> {
        let mut file =
            File::create(&self.path).map_err(|e| format!("Failed to create vbin file: {}", e))?;

        let mut data_offset = HEADER_SIZE as u64;
        let mut index = HashMap::new();
        let mut data_buffer = Vec::new();

        // 1. すべての定義をシリアライズしてデータセクションを構築
        for (hash, term) in &codebase.terms {
            let serialized =
                bincode::serialize(term).map_err(|e| format!("Failed to serialize term: {}", e))?;

            let dependencies = codebase
                .dependencies
                .get(hash)
                .cloned()
                .unwrap_or_default()
                .into_iter()
                .collect();

            let entry = IndexEntry {
                hash: hash.clone(),
                kind: 0, // Term
                offset: data_offset,
                size: serialized.len() as u32,
                dependencies,
            };

            index.insert(hash.clone(), entry);
            data_buffer.extend_from_slice(&serialized);
            data_offset += serialized.len() as u64;
        }

        for (hash, type_def) in &codebase.types {
            let serialized = bincode::serialize(type_def)
                .map_err(|e| format!("Failed to serialize type: {}", e))?;

            let entry = IndexEntry {
                hash: hash.clone(),
                kind: 1, // Type
                offset: data_offset,
                size: serialized.len() as u32,
                dependencies: Vec::new(), // 型は依存関係を持たない
            };

            index.insert(hash.clone(), entry);
            data_buffer.extend_from_slice(&serialized);
            data_offset += serialized.len() as u64;
        }

        // 2. インデックスをシリアライズ
        let index_data =
            bincode::serialize(&index).map_err(|e| format!("Failed to serialize index: {}", e))?;
        let index_offset = data_offset;

        // 3. メタデータを構築
        let metadata = VBinMetadata {
            created_at: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs(),
            updated_at: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs(),
            total_definitions: (codebase.terms.len() + codebase.types.len()) as u32,
            namespaces: codebase
                .term_names
                .iter()
                .filter(|(_, _)| true)
                .map(|(name, hash)| {
                    let namespace = name.split('.').next().unwrap_or("").to_string();
                    (namespace, vec![hash.clone()])
                })
                .fold(HashMap::new(), |mut acc, (ns, hashes)| {
                    acc.entry(ns).or_insert_with(Vec::new).extend(hashes);
                    acc
                }),
        };

        let metadata_data = bincode::serialize(&metadata)
            .map_err(|e| format!("Failed to serialize metadata: {}", e))?;
        let metadata_offset = index_offset + index_data.len() as u64;

        // 4. ヘッダーを作成して書き込む
        let header_data = write_header(
            &[b'V', b'B', b'I', b'N'],
            VBIN_VERSION,
            index_offset,
            metadata_offset,
            1, // gzip
        );

        // ヘッダーは非圧縮で書き込む
        file.write_all(&header_data).map_err(|e| e.to_string())?;

        // データ、インデックス、メタデータを圧縮
        let mut compressed_data = Vec::new();
        {
            let mut encoder = GzEncoder::new(&mut compressed_data, Compression::default());
            encoder.write_all(&data_buffer).map_err(|e| e.to_string())?;
            encoder.write_all(&index_data).map_err(|e| e.to_string())?;
            encoder
                .write_all(&metadata_data)
                .map_err(|e| e.to_string())?;
            encoder.finish().map_err(|e| e.to_string())?;
        }

        // 圧縮データを書き込む
        file.write_all(&compressed_data)
            .map_err(|e| e.to_string())?;

        // キャッシュを更新
        self.index_cache = Some(index);

        Ok(())
    }

    /// 特定の定義を取得（依存関係も含む）
    pub fn retrieve_with_dependencies(&mut self, hash: &Hash) -> Result<Codebase, String> {
        let mut codebase = Codebase::new();
        let mut to_load = vec![hash.clone()];
        let mut loaded = HashSet::new();

        // インデックスを読み込み
        self.ensure_index_loaded()?;
        let index = self.index_cache.as_ref().unwrap();

        while let Some(current_hash) = to_load.pop() {
            if loaded.contains(&current_hash) {
                continue;
            }

            if let Some(entry) = index.get(&current_hash) {
                // データを読み込み
                let data = self.read_entry(entry)?;

                match entry.kind {
                    0 => {
                        // Term
                        let term: Term = bincode::deserialize(&data)
                            .map_err(|e| format!("Failed to deserialize term: {}", e))?;
                        // 名前のマッピングを復元
                        if let Some(ref name) = term.name {
                            codebase
                                .term_names
                                .insert(name.clone(), current_hash.clone());
                        }
                        codebase.terms.insert(current_hash.clone(), term);
                    }
                    1 => {
                        // Type
                        let type_def: TypeDef = bincode::deserialize(&data)
                            .map_err(|e| format!("Failed to deserialize type: {}", e))?;
                        codebase
                            .type_names
                            .insert(type_def.name.clone(), current_hash.clone());
                        codebase.types.insert(current_hash.clone(), type_def);
                    }
                    _ => return Err("Unknown entry kind".to_string()),
                }

                // 依存関係を追加
                for dep in &entry.dependencies {
                    to_load.push(dep.clone());
                    codebase
                        .dependencies
                        .entry(current_hash.clone())
                        .or_insert_with(HashSet::new)
                        .insert(dep.clone());
                }

                loaded.insert(current_hash);
            }
        }

        Ok(codebase)
    }

    /// 名前空間内のすべての定義を取得
    pub fn retrieve_namespace(&mut self, namespace: &str) -> Result<Codebase, String> {
        // メタデータを読み込み
        let metadata = self.read_metadata()?;

        if let Some(hashes) = metadata.namespaces.get(namespace) {
            let mut codebase = Codebase::new();

            for hash in hashes {
                let partial = self.retrieve_with_dependencies(hash)?;
                codebase.merge(partial);
            }

            Ok(codebase)
        } else {
            Ok(Codebase::new())
        }
    }

    /// インデックスがロードされていることを確認
    fn ensure_index_loaded(&mut self) -> Result<(), String> {
        if self.index_cache.is_some() {
            return Ok(());
        }

        let mut file =
            File::open(&self.path).map_err(|e| format!("Failed to open vbin file: {}", e))?;

        // ヘッダーを読み込み（非圧縮）
        let mut header_buf = [0u8; HEADER_SIZE];
        file.read_exact(&mut header_buf)
            .map_err(|e| e.to_string())?;

        let (magic, version, index_offset, metadata_offset, _compression) =
            read_header(&header_buf)?;

        if magic != [b'V', b'B', b'I', b'N'] {
            return Err(format!(
                "Invalid vbin file format. Expected {:?}, got {:?}",
                [b'V', b'B', b'I', b'N'],
                magic
            ));
        }

        if version != VBIN_VERSION {
            return Err(format!("Unsupported vbin version: {}", version));
        }

        // 残りのデータ（圧縮部分）を読み込み
        let mut decoder = GzDecoder::new(file);
        let mut all_data = Vec::new();
        decoder
            .read_to_end(&mut all_data)
            .map_err(|e| e.to_string())?;

        let index_start = (index_offset - HEADER_SIZE as u64) as usize;
        let index_end = (metadata_offset - HEADER_SIZE as u64) as usize;
        let index_data = &all_data[index_start..index_end];

        let index: HashMap<Hash, IndexEntry> = bincode::deserialize(index_data)
            .map_err(|e| format!("Failed to deserialize index: {}", e))?;

        self.index_cache = Some(index);
        Ok(())
    }

    /// エントリのデータを読み込み
    fn read_entry(&self, entry: &IndexEntry) -> Result<Vec<u8>, String> {
        let mut file =
            File::open(&self.path).map_err(|e| format!("Failed to open vbin file: {}", e))?;

        // ヘッダーをスキップして圧縮データ部分へ
        file.seek(SeekFrom::Start(HEADER_SIZE as u64))
            .map_err(|e| e.to_string())?;

        let mut decoder = GzDecoder::new(file);
        let mut all_data = Vec::new();
        decoder
            .read_to_end(&mut all_data)
            .map_err(|e| e.to_string())?;

        let start = (entry.offset - HEADER_SIZE as u64) as usize;
        let end = start + entry.size as usize;

        Ok(all_data[start..end].to_vec())
    }

    /// メタデータを読み込み
    fn read_metadata(&self) -> Result<VBinMetadata, String> {
        let mut file =
            File::open(&self.path).map_err(|e| format!("Failed to open vbin file: {}", e))?;

        // ヘッダーを読み込み（非圧縮）
        let mut header_buf = [0u8; HEADER_SIZE];
        file.read_exact(&mut header_buf)
            .map_err(|e| e.to_string())?;

        let (_, _, _, metadata_offset, _) = read_header(&header_buf)?;

        // 圧縮データを読み込み
        let mut decoder = GzDecoder::new(file);
        let mut all_data = Vec::new();
        decoder
            .read_to_end(&mut all_data)
            .map_err(|e| e.to_string())?;

        let metadata_start = (metadata_offset - HEADER_SIZE as u64) as usize;
        let metadata_data = &all_data[metadata_start..];

        bincode::deserialize(metadata_data)
            .map_err(|e| format!("Failed to deserialize metadata: {}", e))
    }
}

/// Codebaseの拡張メソッド
impl Codebase {
    /// 別のコードベースをマージ
    pub fn merge(&mut self, other: Codebase) {
        self.terms.extend(other.terms);
        self.types.extend(other.types);
        // Merge term names
        for (name, hash) in other.term_names {
            self.term_names.insert(name, hash);
        }
        // Merge type names
        for (name, hash) in other.type_names {
            self.type_names.insert(name, hash);
        }

        for (hash, deps) in other.dependencies {
            self.dependencies
                .entry(hash)
                .or_insert_with(HashSet::new)
                .extend(deps);
        }

        for (hash, deps) in other.dependents {
            self.dependents
                .entry(hash)
                .or_insert_with(HashSet::new)
                .extend(deps);
        }
    }
}

/// 差分保存のためのデルタ形式
#[derive(Serialize, Deserialize, Debug)]
pub struct VBinDelta {
    /// ベースとなるVBinファイルのハッシュ
    base_hash: [u8; 32],
    /// 追加された定義
    added: Vec<(Hash, DeltaEntry)>,
    /// 削除された定義
    removed: Vec<Hash>,
    /// 更新されたメタデータ
    metadata_updates: HashMap<String, String>,
}

#[derive(Serialize, Deserialize, Debug)]
enum DeltaEntry {
    Term(Term),
    Type(TypeDef),
}

impl VBinStorage {
    /// 差分を適用してVBinファイルを更新
    pub fn apply_delta(&mut self, _delta: &VBinDelta) -> Result<(), String> {
        // TODO: 差分適用の実装
        Ok(())
    }

    /// コードベース全体を読み込み
    pub fn load_full(&mut self) -> Result<Codebase, String> {
        // インデックスを読み込み
        self.ensure_index_loaded()?;
        let index = self.index_cache.as_ref().unwrap();

        let mut codebase = Codebase::new();

        // すべてのエントリを読み込み
        for (hash, entry) in index {
            let data = self.read_entry(entry)?;

            match entry.kind {
                0 => {
                    // Term
                    let term: Term = bincode::deserialize(&data)
                        .map_err(|e| format!("Failed to deserialize term: {}", e))?;
                    // 名前のマッピングを復元
                    if let Some(ref name) = term.name {
                        codebase.term_names.insert(name.clone(), hash.clone());
                    }
                    codebase.terms.insert(hash.clone(), term);
                }
                1 => {
                    // Type
                    let type_def: TypeDef = bincode::deserialize(&data)
                        .map_err(|e| format!("Failed to deserialize type: {}", e))?;
                    // 型名のマッピングを復元
                    codebase
                        .type_names
                        .insert(type_def.name.clone(), hash.clone());
                    codebase.types.insert(hash.clone(), type_def);
                }
                _ => return Err("Unknown entry kind".to_string()),
            }

            // 依存関係を復元
            if !entry.dependencies.is_empty() {
                codebase
                    .dependencies
                    .insert(hash.clone(), entry.dependencies.iter().cloned().collect());
            }
        }

        // 逆引き依存関係を再構築
        for (from, deps) in &codebase.dependencies {
            for to in deps {
                codebase
                    .dependents
                    .entry(to.clone())
                    .or_insert_with(HashSet::new)
                    .insert(from.clone());
            }
        }

        Ok(codebase)
    }

    /// 特定のハッシュが存在するか確認
    pub fn contains(&mut self, hash: &Hash) -> Result<bool, String> {
        self.ensure_index_loaded()?;
        Ok(self.index_cache.as_ref().unwrap().contains_key(hash))
    }

    /// すべてのハッシュを列挙
    pub fn list_hashes(&mut self) -> Result<Vec<Hash>, String> {
        self.ensure_index_loaded()?;
        Ok(self.index_cache.as_ref().unwrap().keys().cloned().collect())
    }

    /// 統計情報を取得
    pub fn stats(&mut self) -> Result<VBinStats, String> {
        self.ensure_index_loaded()?;
        let metadata = self.read_metadata()?;
        let index = self.index_cache.as_ref().unwrap();

        let mut term_count = 0;
        let mut type_count = 0;
        let mut total_size = 0;

        for entry in index.values() {
            match entry.kind {
                0 => term_count += 1,
                1 => type_count += 1,
                _ => {}
            }
            total_size += entry.size as u64;
        }

        Ok(VBinStats {
            term_count,
            type_count,
            total_definitions: metadata.total_definitions,
            total_size,
            namespace_count: metadata.namespaces.len(),
            created_at: metadata.created_at,
            updated_at: metadata.updated_at,
        })
    }
}

/// VBinストレージの統計情報
#[derive(Debug)]
pub struct VBinStats {
    pub term_count: usize,
    pub type_count: usize,
    pub total_definitions: u32,
    pub total_size: u64,
    pub namespace_count: usize,
    pub created_at: u64,
    pub updated_at: u64,
}
