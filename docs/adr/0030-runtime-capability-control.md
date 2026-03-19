# ADR-0030: Runtime Capability Control (Deno-style --allow flags)

- Date: 2026-03-19
- Status: proposed
- Related: ADR-0003 (effect system), ADR-0027 (capability-based DCE), ADR-0021 (effect + #import)

## Context

vibe のエフェクトシステムは **コンパイル時** に副作用を型レベルで追跡する。
しかし **ランタイム** での capability 制御がない。

- 型チェックで `with { Fs }` が必要と分かっても、実行時に fs アクセスを制限できない
- 信頼できないコードの実行（plugin, user script）で sandbox が必要
- Deno の `--allow-read`, `--allow-net` が参考モデル

## Decision

### 3層の capability 制御

```
Layer 1: Type System (compile-time)
  effect Fs { ReadFile(String) -> String }
  with { Fs } — 関数が Fs capability を要求することを宣言

Layer 2: Build Profile (compile-time, ADR-0027)
  vibe compile --profile edge app.vibe
  → Fs 不要なら DCE、必要なのに profile にないなら error

Layer 3: Runtime Permission (runtime) ← NEW
  vibe run --allow-fs=read --allow-net=api.example.com app.vibe
  → perform Fs::ReadFile("/etc/passwd") → PermissionDenied
```

### Runtime Permission Model

#### CLI flags

```bash
# Filesystem
--allow-read              # 全パス読み取り許可
--allow-read=/tmp,/data   # 特定パス限定
--allow-write             # 全パス書き込み許可
--allow-write=/tmp        # 特定パス限定

# Network
--allow-net               # 全ネットワーク許可
--allow-net=api.example.com,cdn.example.com  # ドメイン限定

# Process
--allow-run               # sh() 許可
--allow-run=ls,cat        # 特定コマンド限定

# Environment
--allow-env               # 全環境変数許可
--allow-env=HOME,PATH     # 特定変数限定

# All
--allow-all               # 全 capability 許可 (開発用)
```

#### Permission check の実装ポイント

```
perform Fs::ReadFile(path)
  ↓ desugar
Fs::read_file(path)
  ↓ codegen
WASM import: "wasi:filesystem/types@0.2.6" "read"
  ↓ runtime (wasmtime host)
permission_check("fs:read", path)  ← HERE
  ↓ allow or deny
```

3つの実装箇所の候補:

**Option A: WASM host level (wasmtime hook)**
```
wasmtime の WASI 実装に permission check を注入。
import が呼ばれるたびに path/domain をチェック。
```
- Pro: 完全に信頼できる（WASM sandbox 内から回避不可能）
- Con: wasmtime カスタムビルドが必要

**Option B: vibe runtime level (builtin wrapper)**
```
Fs::read_file(path) の builtin 実装に permission check を追加。
vibe の runtime (MoonBit host) でチェック。
```
- Pro: 既存の runtime に追加するだけ
- Con: native 実行時のみ有効。WASM deploy では wasmtime 側が必要

**Option C: effect handler level (vibe layer)**
```
let sandboxed = handle {
  app()
} {
  Fs::ReadFile(path) => {
    if is_allowed_path(path) { resume(real_read_file(path)) }
    else { throw("PermissionDenied: " + path) }
  }
}
```
- Pro: vibe 言語内で完結。ユーザーがカスタム policy を書ける
- Con: 関数越え perform が必要（現状は inline のみ）

### 推奨: Option B + C のハイブリッド

```
Phase 1 (即座): Option B — vibe runtime に permission table を追加
  - CLI flags → PermissionTable struct
  - builtin 実行前に check
  - PermissionDenied → throw (Error effect)

Phase 2 (将来): Option C — effect handler で policy をユーザー定義
  - 関数越え perform が動くようになったら
  - Middleware パターンで capability を attenuate

Phase 3 (将来): Option A — WASM component model の capability
  - Component Model の import/export で capability を制御
  - ADR-0027 の build profile と統合
```

### Permission Table の設計

```vibe
// Runtime に追加される型
struct PermissionTable {
  fs_read: PermissionScope;    // AllowAll | AllowPaths([String]) | Deny
  fs_write: PermissionScope;
  net: PermissionScope;        // AllowAll | AllowDomains([String]) | Deny
  run: PermissionScope;        // AllowAll | AllowCommands([String]) | Deny
  env: PermissionScope;        // AllowAll | AllowKeys([String]) | Deny
}

enum PermissionScope {
  AllowAll;
  AllowList(Array[String]);    // paths, domains, commands, keys
  Deny
}
```

### Effect System との統合

```
perform Fs::ReadFile(path)
  ↓ desugar
Call("Fs::read_file", [path])
  ↓ runtime builtin handler
fn fs_read_file(rt: Runtime, path: String) -> String {
  rt.permissions.check_fs_read(path)?;  // ← permission check
  wasi_read_file(path)                  // ← actual IO
}
```

型レベル (`with { Fs }`) とランタイムレベル (`--allow-read`) の二重チェック:

| 状況 | 型チェック | ランタイム | 結果 |
|------|----------|----------|------|
| `with { Fs }` + `--allow-read` | ✅ | ✅ | 実行 |
| `with { Fs }` + `--allow-read=/tmp` + path=/etc | ✅ | ❌ | PermissionDenied |
| `with { Fs }` なし | ❌ compile error | — | コンパイルエラー |
| `with { Fs }` + flag なし | ✅ | ❌ | PermissionDenied |

### Effect handler による policy カスタマイズ (Phase 2)

```vibe
effect Policy {
  CheckFsRead(String) -> Bool;
  CheckNetConnect(String, Int) -> Bool
}

// ユーザー定義 policy
let my_policy = handle {
  app()
} {
  Policy::CheckFsRead(path) => {
    resume(String::starts_with(path, "/tmp"))
  },
  Policy::CheckNetConnect(host, _port) => {
    resume(String::ends_with(host, ".example.com"))
  }
}
```

### Component Model との統合 (Phase 3)

```wit
// Component の import に capability を明示
world sandbox {
  import fs: interface {
    read-file: func(path: string) -> string;
    // write-file は import しない → 書き込み不可
  }
}
```

WASM Component Model では import しない capability は構造的に使えない。
build profile (ADR-0027) で import セットを制限すれば、ランタイムチェック不要。

## 多層 vs 一括: Component Model 境界での意味論

### 問題

Component Model で compose されたとき、capability の authority は誰か？

```
Standalone:     app.wasm → wasmtime → WASI host → real filesystem
                app が --allow-read を宣言 → 有効

Composed:       parent.wasm → plug(app.wasm)
                parent が Fs 実装を提供 → --allow-read は無意味
                parent が mock Fs を注入する可能性

P3 HTTP:        adapter.wasm → plug(handler.wasm) → wasmtime serve
                adapter が authority、handler は adapter 経由のみ
```

### 設計決定: Context-dependent authority

**多層チェックは standalone のみ。compose 時は Component Model が一括制御。**

```
┌─────────────────────────────────────────────────┐
│ vibe run (standalone)                            │
│                                                  │
│   Layer 1: Type (compile) ← 開発者が宣言        │
│   Layer 2: Build DCE      ← profile で制限      │
│   Layer 3: Runtime flag   ← 運用者が制限        │
│   Layer 4: WASI host      ← wasmtime が制限     │
│                                                  │
│   全層が独立にチェック（defense in depth）        │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│ component compose (plug)                         │
│                                                  │
│   Layer 1: Type (compile) ← 開発者が宣言        │
│   Layer 2: Build DCE      ← import セットで制限 │
│   Layer 3: Runtime flag   ← 無効（parent制御）   │
│   Layer 4: Parent import  ← parent が authority  │
│                                                  │
│   Component Model の import/export が唯一の真実  │
└─────────────────────────────────────────────────┘
```

### 原則

1. **Standalone**: `--allow-*` flag で runtime check。Deno と同じモデル
2. **Composed**: Component Model の import が capability。flag は無視
3. **型レベル**: 常に有効（compile error は context に依存しない）
4. **Build DCE**: profile に応じて import セットを制限（composed でも有効）

### なぜ compose 時に runtime flag を無効にするか

- Parent が mock/proxy/sandbox を提供する場合、child の制限は不適切
- Component Model の import/export は **構造的 capability** — import しないものは使えない
- 二重チェックは「誰が authority か」の混乱を招く
- Parent が trust boundary を管理する責任を持つ

### CLI の区別

```bash
# Standalone: runtime flag が有効
vibe run --allow-read=/tmp --allow-net app.vibe

# Compile: build DCE が有効、runtime flag は embed しない
vibe compile --profile edge app.vibe

# Compose: Component Model が authority
vibe compile --compose-p3 handler.vibe --adapter adapter.wasm
# → handler の capability は adapter が決定

# Component 単体テスト: mock handler で capability を注入
vibe test --mock-fs --mock-net app.vibe
```

## Consequences

良い面:
- Context に応じた適切な authority: standalone は runtime flag、compose は CM
- 型レベルの追跡は常に有効（開発者の意図を記録）
- Component Model との整合: import = capability という CM の哲学と一致
- Deno 風 UX は standalone でのみ、compose 時は Deno より安全

悪い面:
- 2つの context で挙動が異なる（ユーザーの混乱リスク）
- standalone の runtime check にオーバーヘッド
- Permission flag の管理コスト
- Phase 2 (handler policy) は関数越え perform 依存
