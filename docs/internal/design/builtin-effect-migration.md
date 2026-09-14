# Builtin Effect Migration Plan

## 現状: 2つのシステムが共存

```
旧 builtin effect          新 algebraic effect
───────────────           ──────────────────
Fs::read_file(path)       perform Fs::ReadFile(path)
with Net              with HttpServer
throw("msg")              perform Error::Throw("msg")
```

## 置き換えない判断基準

以下が全て満たされるまで、旧 builtin を維持する:

1. **関数越え perform** が handler dispatch で動く (CPS or stack switching)
2. **codegen** が `perform Fs::ReadFile` を `Fs::read_file` と同じ WASM import に変換できる
3. **移行ツール** (codemod) で自動変換できる
4. **パフォーマンス** が同等（benchmark で確認済み）

## 今できること: 新コードは effect で書く

```vibe
// 新しいモジュールを書くとき:
// ❌ 旧: with Net + Http::request(...)
// ✅ 新: with HttpClient + perform HttpClient::Request(...)

// 理由: テスト容易性、最小権限
```

## 移行フェーズ

### Phase 0 (現在): 共存
- 旧 builtin: 本番コード
- 新 effect: テスト用 mock、P3 HTTP handler
- `with Net` と `with HttpServer` は別物として共存

### Phase 1: Sugar 統一
- `Fs::read_file(path)` を内部的に `perform Fs::ReadFile(path)` に desugar
  (Error::Throw と同様のアプローチ)
- `with Net` を `with HttpServer + HttpClient + Socket + Fs + Process` の sugar に
- 既存コードは変更不要（互換 sugar で吸収）

### Phase 2: codegen 統一
- `perform Fs::ReadFile` → 旧 builtin と同じ WASM import にマッピング
- effect handler がなければ builtin fallback
- effect handler があれば handler の実装を使う

### Phase 3: 旧 builtin 廃止
- codemod: `Fs::read_file(path)` → `perform Fs::ReadFile(path)`
- `with Net` → `with HttpServer + ...` の明示指定を推奨
- 旧構文は deprecated warning

## 移行の判断指標

| 指標 | 現在 | Phase 1 目標 | Phase 3 目標 |
|------|------|------------|------------|
| 関数越え perform | ❌ inline only | ✅ CPS | ✅ |
| codegen 互換 | ❌ 別 import | ✅ 同一 import | ✅ |
| パフォーマンス | ✅ 0x overhead | ✅ 0x | ✅ 0x |
| テスト mock | ✅ (新 effect) | ✅ | ✅ |
| 既存コード互換 | ✅ | ✅ (sugar) | ⚠️ deprecated |

## 結論

**今は置き換えない。新コードで effect を使い、Phase 1 (sugar desugar) で橋渡し。**

旧 builtin は「Phase 2 で codegen が統一された時点」まで安定版として維持する。
`throw` → `perform Error::Throw` の成功パターンを `Fs` / `Http` に横展開する。
