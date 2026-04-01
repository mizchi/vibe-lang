# ADR-0043: ビルド時パーミッション駆動 DCE と定数分岐による強力なコード除去

- Date: 2026-03-31
- Status: proposed

## Context

### 現状の DCE

vibe の DCE (`src/frontend/dce.mbt`) は後方到達可能性分析に基づいている。エントリポイントから参照されない定義を除去する仕組みで、`dce_module()` / `dce_module_gc()` として codegen 前に実行される。

この DCE は「使われていない関数を消す」レベルであり、以下のケースには対応していない:

1. **パーミッション不足で到達不可能なコード**: ビルドプロファイルが `Fs` capability を持たない場合、`Fs::read_file` を呼ぶコードパス全体が実行されることはないが、DCE はそれを知らない
2. **定数分岐**: `if PLATFORM == "edge" { ... } else { ... }` のような定数条件が確定している分岐で、false 側を除去できない

### 設計意図

vibe は capability-based security を言語レベルで持つ (ADR-0041, ADR-0042)。ファイルモジュールのトップレベルは pure であり、副作用は `_start` の `with { Effects }` 宣言で明示する。この設計を活かせば、「宣言されていない capability に依存するコード → 到達不可能 → DCE 対象」という推論が成立する。

同時に、定数分岐（ビルド時に値が確定する条件式）を DCE と組み合わせることで、単一のソースコードから複数のデプロイターゲット向けに最適なバイナリを生成できる。

## Decision

### 1. Capability-driven DCE

ビルド時に利用可能な capability set を指定し、それに基づいて DCE を拡張する。

#### パーミッション指定 (Deno-style allow/deny)

Deno の `--allow-read` / `--deny-net` に倣いつつ、vibe の capability 体系に合わせてより細粒度にする。

**基本構文**: `--allow-<capability>[=<pattern>]` / `--deny-<capability>[=<pattern>]`

```bash
# --- ファイルシステム ---
vibe compile --allow-read app.vibe                     # 全パス読み取り許可
vibe compile --allow-read=/etc,/tmp app.vibe           # 特定パスのみ
vibe compile --allow-read --deny-read=/etc/passwd app.vibe  # 除外パターン
vibe compile --allow-write=/tmp app.vibe               # /tmp のみ書き込み
vibe compile --deny-write app.vibe                     # 書き込み全禁止

# --- ネットワーク ---
vibe compile --allow-net app.vibe                      # 全ホスト許可
vibe compile --allow-net=api.example.com app.vibe      # 特定ホストのみ
vibe compile --allow-net=*.example.com:443 app.vibe    # サブドメイン + ポート指定
vibe compile --deny-net=*.internal.corp app.vibe       # 内部ネットワーク拒否
vibe compile --allow-listen=8080,3000 app.vibe         # 特定ポートのみ listen

# --- プロセス ---
vibe compile --allow-run app.vibe                      # 全コマンド実行許可
vibe compile --allow-run=git,node app.vibe             # 特定コマンドのみ
vibe compile --deny-run=rm,sudo app.vibe               # 危険なコマンド拒否

# --- 環境変数 ---
vibe compile --allow-env app.vibe                      # 全環境変数
vibe compile --allow-env=HOME,PATH,NODE_ENV app.vibe   # 特定変数のみ
vibe compile --deny-env=AWS_SECRET_* app.vibe          # glob で秘密変数を拒否

# --- LLM / AI ---
vibe compile --allow-llm app.vibe                      # 全モデル
vibe compile --allow-llm=claude-*,gpt-4* app.vibe      # 特定モデルパターン
vibe compile --deny-llm app.vibe                       # LLM 呼び出し禁止

# --- MCP / A2A ---
vibe compile --allow-mcp=search,calculator app.vibe    # 特定ツールのみ
vibe compile --allow-a2a=reviewer,coder app.vibe       # 特定エージェントのみ

# --- システム ---
vibe compile --allow-clock app.vibe                    # 時刻取得
vibe compile --allow-random app.vibe                   # 乱数生成
vibe compile --allow-git=snapshot,rollback app.vibe    # Git 操作の一部

# --- プリセット (ショートハンド) ---
vibe compile --profile minimal app.vibe       # = --allow-read --allow-clock
vibe compile --profile sandbox app.vibe       # = --allow-read --allow-write=/tmp --allow-clock --allow-git=snapshot
vibe compile --profile server app.vibe        # = --allow-read --allow-net --allow-listen --allow-env --allow-clock
vibe compile --profile edge app.vibe          # = --allow-net --allow-clock (Fs なし)
vibe compile --profile agent app.vibe         # = --allow-net --allow-llm --allow-mcp --allow-a2a --allow-clock

# --- 全許可 (開発用デフォルト) ---
vibe compile --allow-all app.vibe
vibe compile app.vibe                         # = --allow-all (暗黙)
```

#### allow/deny の解決規則

1. **deny は allow より優先**: `--allow-read --deny-read=/etc/shadow` → `/etc/shadow` 以外は読める
2. **未指定 = 禁止**: `--allow-read` なしに `Fs::read_file` を使うコードは capability pruning の対象
3. **パターンなし = 全許可/全禁止**: `--allow-net` = 全ホスト許可、`--deny-net` = 全ホスト禁止
4. **glob パターン**: パス系は `/tmp/**`、ホスト系は `*.example.com`、環境変数は `AWS_*` など

#### パーミッション → effect マッピング

CLI フラグは内部で effect availability に変換される:

| CLI フラグ | effect | DCE 対象 (フラグなし時) |
|-----------|--------|----------------------|
| `--allow-read` | `Fs` (read 系) | `Fs::read_file`, `Fs::read_dir`, ... |
| `--allow-write` | `Fs` (write 系) | `Fs::write_file`, `Fs::append_file`, ... |
| `--allow-net` | `Http`, `Socket` | `Http::get`, `Http::post`, `Socket::connect`, ... |
| `--allow-listen` | `HttpServer` | `Http::listen`, `Socket::listen`, ... |
| `--allow-run` | `Process` | `sh()`, `sh_lines()`, `Process::spawn`, ... |
| `--allow-env` | `Env` | `Env::get`, `Env::set`, ... |
| `--allow-llm` | `Llm` | `Llm::complete`, `Rlm::run`, ... |
| `--allow-mcp` | `Mcp` | `Mcp::call`, ... |
| `--allow-a2a` | `A2a` | `A2a::delegate`, ... |
| `--allow-clock` | `Clock` | `Clock::now`, ... |
| `--allow-random` | `Random` | `Random::int`, `Random::bytes`, ... |
| `--allow-git` | `Git` | `Git::snapshot`, `Git::rollback`, ... |

`Fs` effect は `--allow-read` と `--allow-write` で独立制御できる。`read` のみ許可の場合、`Fs::write_file` を呼ぶコードだけが pruning される。

#### 細粒度パーミッションと `@build` 定数

パスやホストの細粒度制約は DCE では使わない（静的に判定できない）。DCE は effect レベルの粗粒度で動作し、パターンレベルの制約はランタイムで enforce する:

```
// --allow-read=/tmp --deny-read=/etc
// → DCE: Fs read 系は残す (allow-read が存在するので)
// → ランタイム: /etc/passwd を読もうとすると PermissionDenied

// ただし @build で明示分岐すれば DCE が効く:
let config = if @build.allowed("read", "/etc") {
  Fs::read_file("/etc/app.conf")     // deny-read=/etc なら除去
} else {
  "default config"
}
```

#### DCE の拡張フェーズ

既存の DCE パイプラインに 2 つのフェーズを追加する:

```
parse → typecheck → [capability pruning] → [constant folding] → DCE → codegen
```

**Phase A: Capability Pruning**

1. ビルドプロファイルから利用可能な effect set を導出
2. 各関数の effect 宣言 (`with { Fs, Net }`) をプロファイルと照合
3. 利用不可能な effect を要求する関数を「到達不可能」としてマーク
4. 到達不可能な関数を呼び出す側も、その呼び出しを含むパスが到達不可能かを伝播

```
// profile: --capabilities "Net"
// → Fs は利用不可能

let read_config = () -> String with { Fs } {    // ← 到達不可能としてマーク
  Fs::read_file("config.json")
}

let fetch_config = () -> String with { Net } {  // ← 残る
  Http::get("https://config.example.com/config.json")
}
```

**Phase B: Constant Branch Elimination**

ビルド時定数が確定している条件分岐の false 側を除去する:

```
let config = if @build.has_capability("Fs") {
  read_config()       // ← Fs なしのプロファイルでは除去
} else {
  fetch_config()      // ← 残る
}
```

### 2. 定数分岐の仕組み

#### ビルド時定数

`@build` 名前空間でビルド時に確定する値を提供する:

```
// effect レベルの判定 (DCE の粗粒度スイッチ)
@build.has_capability("Fs")        // -> Bool  --allow-read または --allow-write があるか
@build.has_capability("Net")       // -> Bool  --allow-net があるか
@build.has_capability("Process")   // -> Bool  --allow-run があるか
@build.has_capability("Llm")       // -> Bool  --allow-llm があるか

// 細粒度パーミッション判定 (パターンレベル)
@build.allowed("read")             // -> Bool  --allow-read があるか
@build.allowed("read", "/etc")     // -> Bool  /etc の読み取りが allow かつ deny されていないか
@build.allowed("write", "/tmp")    // -> Bool  /tmp への書き込みが許可されているか
@build.allowed("net", "*.github.com")  // -> Bool  github.com へのアクセスが許可されているか
@build.allowed("run", "git")       // -> Bool  git コマンドの実行が許可されているか
@build.allowed("env", "HOME")      // -> Bool  HOME 環境変数の読み取りが許可されているか
@build.allowed("llm", "claude-*")  // -> Bool  claude 系モデルの呼び出しが許可されているか

// プロファイル・ターゲット
@build.profile()                   // -> String ("minimal", "sandbox", "edge", ...)
@build.target()                    // -> String ("wasm", "wasm-gc", "component")
```

これらは checker 通過後、codegen 前に定数に置換される。

パターンなしの `@build.allowed("read")` は effect レベルの判定と同等。パターン付きの `@build.allowed("read", "/etc")` は CLI の allow/deny パターンを静的にマッチし、確定できる場合のみ定数化する。確定できない場合（動的パスなど）はランタイムチェックにフォールバック。

#### 定数畳み込みと分岐除去

```
// ソースコード (粗粒度: effect レベル)
let result = if @build.has_capability("Fs") {
  Fs::read_file("data.txt")
} else {
  "default"
}
// --profile edge (Fs なし) でビルド後:
// → "default"  (dead branch 除去)


// 細粒度: パスパターンレベル
let secret = if @build.allowed("read", "/etc/secrets") {
  Fs::read_file("/etc/secrets/api_key.txt")
} else if @build.allowed("env", "API_KEY") {
  Env::get("API_KEY")
} else {
  ""
}
// --allow-read=/tmp --deny-read=/etc --allow-env=API_KEY でビルド後:
// → Env::get("API_KEY") のみ残る


// コマンド制限
let version = if @build.allowed("run", "git") {
  sh("git rev-parse HEAD")
} else {
  "unknown"
}
// --deny-run=git でビルド後:
// → "unknown" のみ残る
```

#### `match` 式での定数分岐

```
let backend = match @build.target() {
  "wasm-gc" => use_gc_allocator()
  "wasm"    => use_linear_allocator()
  _         => use_fallback()
}
// --target wasm-gc でビルド後:
// → use_gc_allocator() のみ残る


// プロファイルによる機能切り替え
let ai_provider = match @build.profile() {
  "agent" => AiProvider::full()       // LLM + MCP + A2A
  "server" => AiProvider::headless()  // LLM のみ
  _ => AiProvider::none()             // AI 機能なし
}
```

### 3. Effect 到達可能性の伝播規則

capability pruning は以下の規則で伝播する:

1. **直接呼び出し**: `f()` が到達不可能 → `f()` を含む式は到達不可能
2. **条件分岐内**: `if cond { f() } else { g() }` — `f` が到達不可能でも `g` が到達可能なら式全体は到達可能（`f` 側の分岐のみ除去）
3. **handle ブロック**: `handle { f() } { Effect(_) => fallback }` — `f` の effect が利用不可能でも、handler の fallback が存在するなら式全体は到達可能
4. **高階関数**: 関数値として渡される場合は静的に判定できないため、pruning しない（保守的）

```
// 規則 3 の例: handle による graceful degradation
let data = handle {
  Fs::read_file("cache.txt")      // Fs なしでも…
} {
  Fs(_) => "no local cache"       // handler があるので式全体は到達可能
}
```

### 4. DCE レポート

ビルド時に除去されたコードの統計を出力する:

```
$ vibe compile --profile edge --report-dce app.vibe

Capability DCE:
  ✓ Net          — available (12 functions retained)
  ✓ ClockRead    — available (2 functions retained)
  ✗ Fs           — unavailable (8 functions removed, ~3.2 KB saved)
  ✗ Process      — unavailable (3 functions removed, ~1.1 KB saved)

Constant branch elimination:
  4 branches folded (2 @build.has_capability, 2 @build.target)

Standard DCE:
  15 unreferenced definitions removed

Total: 26 definitions removed, ~8.5 KB saved
  Output: app.wasm (45.2 KB, gzip 18.1 KB)
```

### 5. 段階的な導入計画

#### Phase 1: 定数分岐の基盤

- `@build.has_capability()` / `@build.target()` / `@build.profile()` を組み込み関数として追加
- checker で型を `Bool` / `String` として扱う
- codegen 前に定数置換パスを追加
- 定数条件の `if` / `match` で dead branch を除去

#### Phase 2: Capability-driven pruning

- `--profile` / `--capabilities` CLI オプションを追加
- effect 宣言からビルドプロファイルへの照合ロジックを追加
- 到達不可能関数のマーキングと伝播
- DCE レポートの出力

#### Phase 3: 高度な最適化

- `handle` ブロックの fallback 解析
- cross-module DCE（複数ファイルバンドル時）
- size budget 制約（`--max-size 100KB` で超過時に警告）

## Consequences

### Good

- **デプロイターゲットごとの最適化**: edge / browser / server で同じソースから最小バイナリを生成できる
- **capability model との一貫性**: 型システムの effect 宣言がそのまま DCE の入力になる。新しい概念を導入しない
- **段階的な導入**: Phase 1 の定数分岐だけでも即効性がある。capability pruning は後から追加できる
- **セキュリティとサイズの同時改善**: 使わない capability のコードが物理的にバイナリから消えることで、attack surface も縮小する
- **wasm-gc / linear の分岐**: `@build.target()` で backend 固有のコードを書き分け、他方を DCE で消せる

### Bad

- **ビルド時定数の導入**: `@build.*` は新しい名前空間。乱用するとソースコードの可読性が下がる
- **DCE の複雑化**: capability pruning の伝播規則が複雑。特に高階関数や動的ディスパッチでは保守的になる
- **ビルドキャッシュの粒度**: プロファイルが変わるとキャッシュが無効になる

### Neutral

- 既存の DCE (`dce_module` 系) は変更なし。新しいフェーズは前段に追加される
- `--profile` を指定しない場合（デフォルト = developer）、capability pruning は何も消さない。後方互換
- effect system 自体の仕様変更は不要。既存の `with { Effects }` 宣言をそのまま利用する
