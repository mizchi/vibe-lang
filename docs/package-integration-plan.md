# vibe-package と vpm の vibe-codebase への統合計画

## 現状分析

### vibe-package
- パッケージ管理の基本機能を提供
  - `manifest`: package.vibeファイルの読み書き
  - `hash`: パッケージハッシュの計算
  - `cache`: ローカルパッケージキャッシュ
  - `registry`: パッケージレジストリ（ローカル/リモート）
  - `resolver`: 依存関係解決

### vpm
- CLIツール（vibe-packageを使用）
- コマンド: init, install, publish, search, info, list, clear, update

### vibe-codebase
- コードベース管理（content-addressed storage）
- インクリメンタルコンパイル
- テスト実行とキャッシュ
- VBin形式のサポート
- 名前空間管理

## 統合方針

### 1. モジュール統合
vibe-packageのモジュールをvibe-codebaseに移動：

```
vibe-codebase/src/
  # 既存のモジュール
  codebase.rs
  vbin.rs
  ...
  
  # パッケージ管理モジュール（新規追加）
  package/
    mod.rs          # pub mod manifest, hash, cache, registry, resolver
    manifest.rs     # PackageManifest
    cache.rs        # PackageCache  
    registry.rs     # Registry traits
    resolver.rs     # 依存関係解決
```

### 2. 統合の利点

1. **コードの重複排除**
   - Hash型が両方に存在 → 統一
   - VBin形式とパッケージ形式の統合

2. **機能の相乗効果**
   - パッケージをコードベースとして直接管理
   - インクリメンタルコンパイルでパッケージビルドを高速化
   - テストランナーでパッケージテストを実行

3. **シンプルな依存関係**
   - vibe-package削除でクレート数削減
   - vpmをvshに統合でバイナリ統一

### 3. CLI統合案

vpmのコマンドをvshのサブコマンドとして追加：

```bash
# 現在
vpm init my-package
vpm install
vpm publish

# 統合後
vsh package init my-package
vsh package install
vsh package publish

# または短縮形
vsh pkg init my-package
vsh pkg install  
vsh pkg publish
```

### 4. 実装手順

1. **Phase 1: モジュール移動**
   - vibe-packageのソースをvibe-codebase/src/packageに移動
   - 依存関係の調整
   - テストの移行

2. **Phase 2: 重複機能の統合**
   - Hash型の統一
   - VBinとパッケージ形式の統合
   - キャッシュシステムの統合

3. **Phase 3: CLI統合**
   - vpmのCLI部分をvsh/src/package_commands.rsに移動
   - vshのCommand enumに追加
   - ヘルプとドキュメントの更新

4. **Phase 4: クリーンアップ**
   - vibe-packageクレートの削除
   - vpmクレートの削除
   - Cargo.tomlの更新

## 互換性の考慮

- 既存のpackage.vibeファイルは引き続きサポート
- ローカルレジストリの形式も維持
- 移行期間中は両方のCLIをサポート可能

## まとめ

この統合により：
- クレート数が削減され、プロジェクト構造がシンプルに
- パッケージ管理とコードベース管理が統一された体験に
- ビルド時間の短縮とメンテナンスの簡素化