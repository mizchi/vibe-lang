# WASM統合提案：SalsaとWASMコード生成の接続

## 現在のSalsaの役割

現在のSalsaは以下をキャッシュしています：

1. **パース結果**: ソースコード → AST
2. **型チェック結果**: AST → Type
3. **依存関係**: モジュール間の依存関係グラフ

## WASMコード生成に必要な追加ステップ

### 1. 現在のパイプライン
```
Source → Parse → AST → TypeCheck → Type
```

### 2. WASM対応パイプライン
```
Source → Parse → AST → TypeCheck → TypedAST → IR → Optimize → WASM
```

## Salsa統合のための拡張

### 新しいクエリの追加

```rust
#[salsa::query_group(WasmQueriesStorage)]
pub trait WasmQueries {
    /// AST to IR conversion
    fn to_ir(&self, key: SourcePrograms) -> Result<Arc<TypedIrExpr>, XsError>;
    
    /// IR optimization
    fn optimize_ir(&self, key: SourcePrograms) -> Result<Arc<TypedIrExpr>, XsError>;
    
    /// WASM code generation
    fn generate_wasm(&self, key: SourcePrograms) -> Result<Arc<WasmModule>, XsError>;
    
    /// WASM binary generation
    fn emit_wasm_binary(&self, key: SourcePrograms) -> Result<Arc<Vec<u8>>, XsError>;
}
```

### 実装例

```rust
/// AST to IR conversion
fn to_ir(db: &dyn WasmQueries, key: SourcePrograms) -> Result<Arc<TypedIrExpr>, XsError> {
    // 型チェック済みASTを取得
    let ast = db.parse_source(key)?;
    let ty = db.type_check(key)?;
    
    // IR変換器を使用
    let ir_converter = IrConverter::new();
    let ir = ir_converter.convert(&ast, &ty)?;
    
    Ok(Arc::new(ir))
}

/// WASM generation
fn generate_wasm(db: &dyn WasmQueries, key: SourcePrograms) -> Result<Arc<WasmModule>, XsError> {
    // 最適化済みIRを取得（キャッシュされる）
    let ir = db.optimize_ir(key)?;
    
    // WASMコード生成
    let mut codegen = CodeGenerator::new();
    let module = codegen.generate(&ir)?;
    
    Ok(Arc::new(module))
}
```

## インクリメンタルWASM生成の利点

1. **部分再コンパイル**: 変更された関数のみWASMを再生成
2. **依存関係追跡**: 変更の影響を受ける部分のみ再生成
3. **並列化**: 独立した関数は並列でWASM生成可能

## 実装アプローチ

### Phase 1: 基本的な統合
1. `WasmQueries` traitをSalsaデータベースに追加
2. AST → IR変換をSalsaクエリとして実装
3. IR → WASM生成をSalsaクエリとして実装

### Phase 2: 最適化
1. 関数レベルのキャッシュ（関数ごとにWASMを生成）
2. インライン展開などの最適化パスを個別のクエリに
3. リンク時最適化（LTO）のサポート

### Phase 3: 高度な機能
1. ホットリロード対応（変更された関数のWASMのみ更新）
2. デバッグ情報の生成
3. ソースマップの生成

## 実装上の課題

1. **IR設計**: 型付きIRが必要（現在は型なしIR）
2. **メモリ管理**: WASMのメモリモデルとの整合性
3. **エフェクトシステム**: WASMでのエフェクト実行方法

## 提案する次のステップ

1. `TypedIrExpr`の実装（型情報を保持するIR）
2. `WasmQueries` traitの追加
3. 簡単な関数でのエンドツーエンドテスト
4. ベンチマークによる性能評価