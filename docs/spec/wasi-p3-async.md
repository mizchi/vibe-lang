# WASI 0.3 (Preview 3) async — 設計と段階移行

Status: **proposed** (ADR-0012 を更新)。最終更新 2026-06-16。

WASI 0.3 は 2026-06-11 に ratify され、`stream<T>` / `future<T>` が Component
Model の first-class 型として導入された。本ドキュメントは vibe を WASI 0.3 の
async モデルへ寄せていくための設計判断と段階プランを定める。北極星は
**`async`/`await` + `Future[T]` + `Stream[T]`**、stream の抽象哲学は
**既存 `Iterator` に寄せた pull ベース**。

旧 [docs/report/support-wasip3.md](../report/support-wasip3.md)（2026-05-22、
同期 effect ベースの Model 1）の async 部分は本ドキュメントが supersede する。
同期 effect capability（`HttpRequest`/`HttpResponse`/`HttpClient` を `perform`
で扱う）は引き続き有効で、async はその上位に位置づける。

## 1. WASI 0.2 → 0.3 の要点

- `pollable` → `future<T>`、`input-stream`/`output-stream` → `stream<u8>`。
  `wasi:io` の poll/pollable は canonical ABI に吸収。
- `subscribe()` で pollable を取る代わりに、関数が `future<...>` を返す。
  `start-foo` / `finish-foo` の 2 段 API は `foo: async func(...)` に統合。
- 例: `read-via-stream: func() -> result<input-stream, error-code>`
  → `read-via-stream: func() -> tuple<stream<u8>, future<result<_, error-code>>>`。
- `wasi:http` は 0.2 の `proxy` world を廃し、**`wasi:http/service`** と
  **`wasi:http/middleware`** の 2 world に（vendored submodule で確認:
  `deps/wasmtime/crates/wasi-http/src/p3/wit/deps/http.wit` の `world service` /
  `world middleware`）。
- ランタイム: wasmtime **45** は 0.3 を **release candidate** として
  フラグ付きで実行（`-W component-model-async=y -W
  component-model-async-builtins=y` 等）。**46** が ratified `0.3.0` を
  async-by-default で同梱予定（本ドキュメント時点では未リリース、最新 stable
  は 45.0.2 / 2026-06-15）。

## 2. 言語モデル

### 2.1 型

- `Future[T]` — 単一の非同期値。`await f : T`。
- `Stream[T]` — pull ベースの **async iterator**。既存 `Iterator`/`Iterable`
  (ADR-0044) の形を踏襲する:

  ```vibe
  trait AsyncIterator[T] {
    next(Self) -> Future[Option[T]]   // None で終端
  }
  ```

  WASI 0.3 の `stream<u8>` は `ByteStream = Stream[Int]`（byte=Int）として
  露出する。HTTP の request/response body はこの `ByteStream`。

### 2.2 構文

vibe には `fn` キーワードが無く、関数は `let f: (A) -> B with { E } = (x) -> {}`
形式で副作用は effect row (`with { E }`) で表現する。したがって **`async`
キーワードは導入しない**。代わりに:

- **`await` は effectful な操作**で、`Async` effect を帯びる。`throw`→`Error`
  / `perform Eff::Op`→`Eff` と同じ扱い。「async 関数」= **effect row に
  `Async` を持つ関数**（`with { Async }`）であり、特別な宣言構文ではない。
  `await(f)` は `Future[T]` を待って `T` を得る。
- `Async` を持つ計算を非 `Async` 文脈で使うと、既存の effect-escape チェック
  (`checker_effects.vibe` の `EEEffectfulCallOutsideEffect`) がエラーにする。
- `for await x in s { ... }`（`Stream[T]` の逐次 pull、`s.next()` を `await`
  するループへ desugar）は M2 で導入予定の糖衣。

実体（状態機械 lowering）は §3 が担い、replay effect handler の上には載せない。

#### M1a 実装メモ（landed）

front-end は **lexer/parser/AST/core-Type の変更ゼロ**で着地した:

- `await` は予約語ではないため `await(f)` は通常の呼び出し
  `ECall(EIdent("await"), [f])` として既存 parser でそのまま通る。
- checker builtin として登録（`vibe/compiler/checker/builtins_async.vibe`、
  `lookup_builtin` 経由）:
  - `await : (Future[T]) -> T with { Async }`（`throw` と同型、effect=`Async`）
  - `Future::ready : (T) -> Future[T]`（pure、テスト用に future を構築）
- `Future[T]` は `CtNamed("Future", [..])` で構造的に表現（core `Type` enum
  非変更）。要素型は他 builtin と同様 `CtUnknown`（gradual）。
- `Async` は open string の effect 名なので effect-escape チェックがそのまま
  機能する。検証: `checker_async_test.vibe` 6/6、`checker_effects_test.vibe`
  19/19（無回帰）。bundle 再生成済み（sync OK）。

### 2.3 同期 effect との関係

vibe の既存 effect system（`handle`/`perform`/`resume`）は **replay ベース・
同期**で、`handle` あたり ~16K perform の hard bound を持つ（ADR-0055, #553,
#556）。長寿命の async stream をこの replay-memo に載せると破綻するため、
**async は effect handler の replay 機構の上に build しない**。`Async` は
型レベルの effect row 注釈としてのみ用い、codegen は専用の状態機械 lowering
（§3）に分岐する。同期 effect（Error/Stdout/HttpRequest 等）の意味論・実装は
不変。

## 3. codegen 戦略: Component Model async canonical ABI（stackless）

vibe は compiled でネイティブ coroutine を持たないため、各 `async` 関数を
**状態機械（stackless coroutine）に lower** し、Component Model async の
canonical built-ins を直接呼ぶ。これは wit-bindgen が Python/JS/C# 向けに採る
方式と同じで、**WASM stack-switching proposal（エンジン未安定）に依存しない**。

使用する canonical built-ins（wasmtime 45 のフラグ — §3.1 の M1b spike で
確定 — `-W concurrency-support=y -W component-model-async=y` ＋ stackful
form では `-W component-model-async-stackful=y`）:

- `future.new` / `future.read` / `future.write` / `future.cancel-read`
- `stream.new` / `stream.read` / `stream.write` / `stream.cancel-read`
- `task.return`（async export の結果返却）/ `task.wait` 相当の
  `waitable-set.new` / `waitable-set.wait` / `waitable.join`
- `async-lower` / `async-lift`（import/export の async 呼び出し規約）

lowering 概要:

1. `async fn` を、suspend point（各 `await` / `for await` の `stream.read`）で
   分割した状態機械関数へ変換。ローカルは線形メモリ上の frame に退避。
2. `await f` は `future.read` を発行し、`BLOCKED` なら `waitable-set.wait` に
   登録して制御を返す。完了時に状態機械を resume。
3. `Stream[T]::next()` は `stream.read`（1 要素ぶん）を `future` 化して返す。
   `for await` はこれを繰り返し、`None`（EOF）で終了。
4. async export（HTTP handler 等）は `task.return` で結果を返し、
   `async-lift` 規約で wasmtime に lift される。

この lowering は selfhost compiler 側
(`vibe/compiler/codegen/`) に実装する（CLAUDE.md の source-of-truth 方針）。
既存の effect region / replay 機構とは独立した新パスとする。

### 3.1 M1b feasibility spike（landed、実測 — wasmtime 45.0.0 / x86_64 linux）

wit-bindgen の `async func() -> u32` を手動で最小化し、async-lifted export が
wasmtime 45 で**実際に動く**ことと、emit すべき最小形を確定した
（blueprint: `src/x/cm_async/cm_async_lift_probe.wat`、戻り値 42 を確認）。

確定した最小形（callback-less / **stackful** form）:

- 戻り値型の component type は async: `(type (func async (result T)))`。
- `task.return` は `(core func (canon task.return (result T)))` で lower し、
  core module に import として供給。
- async lift は `(canon lift (core func ...) async)`（callback 無し）。
- **stackful form では core function は値を返さない（void）**。結果は
  `task.return` 経由のみで届ける。status-i32 を返すのは callback/stackless
  form で、stackful では reject される。
- フラグ: `-W concurrency-support=y -W component-model-async=y
  -W component-model-async-stackful=y`。

**設計含意（重要）**: stackful form なら **backend は straight-line code を
emit できる**（結果計算 → `task.return` → return）。await を含む場合も
`future.read` / `waitable-set.wait` で**ブロックする直線コード**を書けばよく、
§3 冒頭の明示的 stackless 状態機械分割は **不要**。wasmtime の
`component-model-async-stackful` は host fiber 実装で、WASM stack-switching
proposal（非 x86_64 で未サポート）とは別物のため、エンジン依存も回避できる。
これは当初の stackless 設計を大幅に簡素化する。

トレードオフ / 未確認:
- callback/stackless form（wit-bindgen が採用）は stackful フラグ不要
  （`concurrency-support=y component-model-async=y` のみで動作）だが、明示的な
  callback 状態機械の生成が必要で codegen が重い。**PoC は stackful 直線形を
  主とし、callback form を portable fallback として記録**。
- `component-model-async-stackful` の非 x86_64 / wasmtime 46 default での
  可用性は要確認。
- 別途、`component-model-async-builtins` は **wasmtime 45.0.0 では無効な
  `-W` フラグ**（M0 で誤記載していた。docs/report も修正）。

検証基盤: 既存 `src/x/cm_async/cm_async_probe.wat`（flag 受理の sync probe）に
加え、本 spike の `cm_async_lift_probe.wat`（async-lift 実動 probe）を追加。

### 3.2 M1b 実装ブループリント（byte-level encoding map）

`cm_async_lift_probe.wat` を `wasm-tools dump` して抽出した、selfhost encoder が
emit すべき正確なバイト列（wasmtime 45 で検証済み）。`component_codegen.vibe`
は既に async func type opcode `0x43`(67) と sync canon lift を持つので、不足は
(a) async lift option、(b) `task.return` canon、(c) core 側の import + void entry。

**core module**（`linked_compile.vibe`、async entry のとき）:
- import section: `import "cm" "task-return"`、func 型 `(param i32) (result)`
  = `02 63 6d  0b 74 61 73 6b 2d 72 65 74 75 72 6e  00 00`
  （module名"cm" / name"task-return" / kind=func(00) / typeidx=0）。
- entry func body: 値を計算し `call $task_return` して **void で return**
  = 例 `41 2a  10 00  0b`（i32.const 42; call task_return; end）。
- 型: task_return 用 `(param i32)->()` = `60 01 7f 00`、entry `()->()` = `60 00 00`。

**component sections**（`component_codegen.vibe`）:
- task.return canon: section `08`、内容 `01` + `09 00 79 00`
  （`09`=task.return opcode、`00 79`=result Some(u32, valtype `0x79`)、`00`=options空）。
  valtype をパラメタ化（s32=`0x7a`? 等は要確認、u32=`0x79` は実測済み）。
- async component func type: `43 00 00 79`
  （`0x43`=async functype opcode、`00`=params数0、`00`=result-form tag、`79`=u32）。
  既存 `emit_comp_func_type(is_async=1)` が `0x43` を出すが result は s64(`0x78`)
  固定 — 結果型をパラメタ化する必要あり。
- core instance: task.return core func を `FromExports`("task-return") で 1 つの
  core instance にし、main module 実体化の `cm` 引数に渡す。
- async canon lift: `00 00 <core_func_idx> 01 06 00`
  （`00`=lift, `00`=func sort, core_func_idx, options vec len `01`, **async opt
  `0x06`**, type_idx）。現 `emit_canon_lift_func` は options に async(`0x06`)を
  含めないので async 変種を追加する。
- export: 既存 `emit_comp_export_section` を流用。

**フラグ**: `-W concurrency-support=y -W component-model-async=y
-W component-model-async-stackful=y`。

最初の縦串 PoC は await 無し（`() -> Int with { Async }` の body が定数 / 純粋
計算）で `task.return` 経路を通し、その後 `await(Future::ready(x))` → 単一
`future.read` ブロックへ広げる。

### 3.3 M1b codegen stage 1（landed）+ stage 2 の前提発見

**stage 1（done）**: `component_codegen.vibe` に async component emitter を実装:
`emit_canon_task_return` / `emit_canon_lift_async_section`（async canonopt
`0x06`）/ `emit_comp_async_functype_section`（opcode `0x43`）/
`comp_emit_component_wasm_async`。`component_codegen_test.vibe` 10/10 で、emit
結果が §3.2 の検証済みバイト列と一致すること（および sync lift には async
option が混入しないこと）を確認。emitter は既存 sync lift と同じ構成ヘルパ
（header / core module / core instance / alias / export）を再利用するため、
runnable な probe とのバイト一致＝全体も valid と判断できる。

**stage 2 で判明した前提（重要）**: selfhost ツリーには **`--component`
オーケストレーションが存在しない**（`comp_emit_component_wasm*` は定義・テスト
のみで、CLI からは呼ばれていない。`vibe compile --component` / `--compose-p3`
の実体は host (`src/`) 側）。したがって「実 `.vibe` → async component を
`vibe compile` で生成して wasmtime で動かす」真の E2E には、まず **selfhost 側に
component-compile オーケストレーション（entry → core wasm → component wrap）を
構築する**必要がある。これは linked_compile の小改修ではなく独立した feature で、
core-side の async entry 生成（`cm.task-return` import + void entry）もその中に
位置づくべき。M1b は「emitter（stage 1, done）」と「orchestration + core-side
（stage 2, 別 feature）」に再分割する。

stage 2 の真の E2E 検証は、selfhost component-compile orchestration 着地後に
`vibe compile --component async.vibe` → wasmtime 45 で実施する。それまでの
emitter の正しさは byte-exact 一致（runnable probe 基準）で担保する。

### 3.4 M1b-2 アプローチ確定（trampoline、実測済み）

core-side（`linked_compile.vibe`）を改修せずに済む **trampoline 方式**を実測で
確定した（`src/x/cm_async/cm_async_trampoline_probe.wat`、wasmtime 45 で 42）。
selfhost は既に entry を `run : () -> i64`（値を直接 return）で core wasm に
コンパイルできるので、それを**そのまま main module** とし、小さな async
**trampoline module**（`("main","run")` と `("cm","task-return")` を import、
void `run` = `call entry; call task-return`）で包む。string-lift が 2 つ目の
core module を合成するのと同じ構造で、`linked_compile.vibe` は無改修。

確定した component core-func index 空間: `task.return` canon = 0 / alias
`main."run"` = 1 / alias `tramp."run"` = 2、async lift は core func 2 を参照。
trampoline core module は result valtype（vibe Int = i64 = `0x7e`）を埋めた
ほぼ定数のバイト列（`comp_generate_string_trampoline` と同じ要領で生成可能）。

これで M1b-2 の codegen アプローチは実機で裏付けられた。残る emitter 実装は:
`comp_generate_async_trampoline(core_valtype)`（trampoline module 生成）+
`comp_emit_component_wasm_async_trampolined(main_core, entry_name, valtype)`
（2 module 合成: main / tramp / task.return canon / instances(main, cm,
env-alias, tramp) / async functype / alias tramp.run / async lift / export）。
さらに orchestration（async entry → main core wasm → wrap → 出力）と CLI 配線。

## 4. WASI 0.3 境界マッピング

| vibe | WASI 0.3 |
|---|---|
| `Future[T]` | `future<T'>`（`T'` は T の canonical 表現） |
| `Stream[T]` | `stream<T'>`、`ByteStream` = `stream<u8>` |
| `async fn handler(...)` export | `wasi:http/service` の `handle: async func(request) -> result<response>` |
| outbound `await HttpClient::fetch(...)` | `wasi:http` client の async func（`future<response>`） |
| request body / response body | `stream<u8>`（`ByteStream`）。Phase1 の "body 渡せない" 問題を 0.3 ネイティブに解消 |

worlds: 受信は `wasi:http/service`、proxy/中継は `wasi:http/middleware`。

## 5. バージョン / WIT 整合（M0、本コミットで実施）

WASI 0.3 RC のバージョン文字列がリポジトリ内で 3 重にズレていた:

- repo の P3 アダプタ/プローブスクリプト: `@0.3.0-rc-2026-02-09`
- vendored wasmtime submodule の WIT: `@0.3.0-rc-2026-03-15`
- legacy MoonBit host codegen (`src/codegen/*`): `@0.3.0-draft`
- ratify 済み最終版: `@0.3.0`

M0 では **selfhost / adapter 経路を vendored submodule の実体
`@0.3.0-rc-2026-03-15` に統一**する（アダプタの `include`/`import` 文字列が
ランタイム提供の WIT と一致しないと wit-bindgen が解決失敗するため、これは
correctness 修正）。`src/codegen/*` の `@0.3.0-draft` は legacy host 経路
（CLAUDE.md: `src/` は通常触らない）なので M0 では据え置き、別途追跡する。
wasmtime install 既定は 45.0.0 → 45.0.2（WASIp1 fd_renumber leak の security
patch、p3 WIT 不変）。

ratified `0.3.0` への最終 cutover は wasmtime 46（async-by-default）リリース
時に、フラグ撤去とあわせて行う。

## 6. 段階プラン

| Stage | 内容 | 状態 |
|---|---|---|
| **M0** | wasmtime 45.0.2 bump、P3 WIT 文字列を `rc-2026-03-15` に統一、ADR-0012 更新 + 本 spec 起票 | done |
| **M1a** | async front-end: `await` builtin (`(Future[T]) -> T with { Async }`) + `Future::ready` + `Future[T]`=CtNamed、effect-escape 検証。lexer/parser/core-Type 非変更 | done |
| **M1b-1** | codegen emitter（component 側）: `comp_emit_component_wasm_async` + `task.return` canon + async lift + async functype。byte-exact verified（test 10/10） | done |
| **M1b-2a** | アプローチ確定（**trampoline 方式**、`linked_compile` 無改修）を実測（`cm_async_trampoline_probe.wat` が wasmtime 45 で 42）。2-module 合成の exact byte blueprint 確定 | done |
| **M1b-2b** | emitter 実装: `comp_generate_async_trampoline` + `comp_emit_component_wasm_async_trampolined`（2-module 合成）+ byte test | 未着手 |
| **M1b-2c** | selfhost component-compile orchestration（async entry → main core wasm → wrap → 出力）+ `--component` async 検出 → `vibe compile --component` で wasmtime 45 真の E2E | 未着手 |
| **M2** | `Stream[T]`/`ByteStream` を `stream.read` 上の async iterator に。HTTP body を stream 化、`for await` | 未着手 |
| **M3** | outbound async HTTP client（`Future[Response]` + streaming body）、`wasi:http/service` + `middleware` world | 未着手 |
| **M4** | parity/gate/CI、docs、ADR-0012 → accepted | 未着手 |

## 7. 未解決事項

- canonical ABI の async 状態機械を selfhost codegen で生成する際の frame
  レイアウト / suspend-resume の具体表現（M1 で確定）。
- `Async` effect row と既存 effect row 推論の統合（await 透過性、`async fn`
  の effect 注釈規則）。
- `T` → canonical `T'` の表現（特に enum/record を `future`/`stream` 要素に
  する場合）。
- wasmtime 46 リリース後の ratified `0.3.0` cutover とフラグ撤去のタイミング。
