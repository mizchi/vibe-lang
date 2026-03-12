# ADR-0014: Cranelift AOT バックエンド

- Date: 2026-02-17
- Status: proposed (未着手。WASM バックエンドが主経路であり優先度低)

## Context

既存の WASM バックエンド（ADR-0002）は可搬性に優れるが、ネイティブ実行のオーバーヘッドがある。AOT コンパイルにより、コンテンツアドレス化された決定的ビルド（ADR-0004）を維持しつつネイティブ性能を得たい。Cranelift は Rust エコシステムで成熟した codegen ライブラリであり、`cranelift-object` によるオブジェクトファイル出力をサポートしている。

## Decision

WASM バックエンドに加えて、Cranelift を AOT バックエンドとして追加する。

### パイプライン

```
Parse → Type-check → Internal IR → CLIF → cranelift-object → Native Object
```

### ABI

wasm 互換 ABI を採用:
- wasm のホスト import と同じ関数シグネチャで sandbox import を呼ぶ
- C ABI、全値は 32-bit タグ付き値
- 第1引数は `*mut VmContext`（不透明コンテキストポインタ）
- linear memory はコンテキスト経由で参照（オフセットは `u32`）

### 決定的ビルド

ビルド指紋に以下を含め、同一入力なら同一出力を保証する:
- 入力ソース + import モジュールハッシュ
- typed IR シリアライズ
- target triple + CPU features
- Cranelift 設定 (opt_level, regalloc, flags)
- ツールチェーンバージョン

### リンク戦略

- 配布ビルド: 外部リンカ (LLD / システムリンカ)
- sandbox 実行: カスタムローダ（object 解析 + リロケーション適用）
- ハイブリッド運用を許容

### 非目標

- WASM バックエンドの置き換え（追加ルートとして位置づけ）
- Wasmtime 内部 ABI/VMContext への強依存
- JIT を主経路にすること

## Consequences

- ネイティブ実行で WASM VM のオーバーヘッドを排除できる
- WASM sandbox モデルを維持するため、安全性・可搬性は損なわない
- sandbox ローダの実装が必要（object 解析、リロケーション、シンボル解決）
- プラットフォームごとの object 形式（ELF/Mach-O/COFF）とリロケーション対応が必要
- content-addressed ビルドとの整合性確保にツールチェーンバージョン管理が必要
