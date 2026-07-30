# ADR-0084: resource kind パラメータ — capability effect と algebraic effect の型レベル区別

Status: proposed

Date: 2026-07-30

Related: ADR-0071(operation-level effect row/`OperationRef` — resource kind
はこの正規化に resource 引数を1本足すだけで乗る)、ADR-0075(
`S3[Posts]::get_object` の resource-qualified operation と
`Entry.requires ⊆ ComposedHost.provides` preflight — 本 ADR はこの形を
builtin effect 全般に一般化する)、ADR-0060(`region` の local resource
としての位置づけに関連する訂正提案を含む)、ADR-0068(`Async` の
non-transitive 方針と `Spawn` capability effect の分離に関連)、
ADR-0073(`Error`/`Exception` の checked effect 化 — 本 ADR の main row
規則が参照する core ambient effect カテゴリの前提)、
[docs/effect-taxonomy-review.md](effect-taxonomy-review.md)(本 ADR の
元になったレビュー)

## Context

vibe の `effect` / `with { }` 構文は Koka を参考にした代数的エフェクト
(抽象・DI 用途)を志向して設計されたが、実際の実装は Deno 由来の
「権限としての Effect」(`Fs`/`Env`/`Process`/`HttpServer` のような
粗粒度な capability grant)に寄っている。結果として、**同じ構文・同じ
`effect` キーワードに2つの異なる意味論が混在している**——外部リソースへの
アクセス許可(本来は wasm 境界の外の import/WIT 契約として宣言される
べきもの)と、handler による複数実装の切り替えが可能な代数的エフェクト
(wasm 境界とは無関係)。本 ADR はこの混在を型レベルでどう区別するかを
提案する。

`docs/effect-taxonomy-review.md` は Effect 設計見直しの非公式レビュー
文書であり、冒頭で「方向性が固まった項目から個別の小さい ADR に順次
切り出す」と明記している。本 ADR はそのうち最も設計が固まっている
「resource kind パラメータによる型レベル区別」の提案(#1197 「Effect の
単位を再考する」に対応、統合 issue #1218 で追跡)を切り出したもの。

### 前提となる既存 ADR

| ADR/Issue | 内容 | 状態 |
| --- | --- | --- |
| ADR-0050 | `handle`/`perform`/`resume` の正式構文。`Error` は built-in effect、`throw` は sugar | proposed |
| ADR-0071 | `effectset` — operation-level effect row(`Env::get` 単位の細粒度)。6項目中5項目が実装済み | proposed(ほぼ実装済) |
| ADR-0075 | `.vibex` runtime contract。semantic requirement と resource claim の分離、`S3[Posts]::get_object` 型の resource-qualified operation、compile/plan/apply/run のフェーズ分離、task/spawn authority delegation | proposed(Phase 0 完了、Phase 1 一部) |
| ADR-0060 | `let mut` と cross-scope write を `Write[r]`(Koka の `st<h>` 風 region)に統一する案 | proposed(停滞) |
| ADR-0073 | `Error` を完全 checked effect にする(#944 と対) | accepted |
| ADR-0068 | `Async::suspend`/`Spawn` を operation-level effect にするが、Async は意図的に non-transitive(色付け回避) | proposed |
| #1143 | ambient builtin effect(Fs/Env/Stdout)の WIT マッピングが無い | open |

`Exception[E]` の型階層設計、動的 optional-permission 機構、`Spawnable[r]`
の evidence fork-safety 検査は本 ADR のスコープ外(下記
`Rejected / deferred alternatives` および `docs/effect-taxonomy-review.md`
参照)。

## Decision

### resource kind パラメータによる区別

新しいキーワードを増やさず、**effect operation が resource kind
パラメータを持つかどうか**を capability / algebraic effect の区別の
マーカーにする。

```vibe skip
// algebraic effect: resource kind なし → in-process, WIT 無関係, handle で完結
effect Logger { Log(String) -> Unit }

// capability effect: resource kind パラメータを持つ → wasm 境界を越える,
// resource claim 必須, contract hash/WIT projection の対象, plan/apply/bind ライフサイクルに乗る
effect Fs[R: Fs::Root] { read_file(String) -> Bytes }
```

ADR-0075 の `S3[Posts]::get_object` はまさにこの形。既存の builtin
effect(`Fs`/`Env`/`Process`/`HttpServer`/`Stdout`)は現在 resource kind
を持たない設計なので、移行には retrofit が必要(後述の段階計画)。

### main の closed row 規則

ADR-0075 は「`main` の宣言 row は closed かつ実際の transitive
requirement と exact 一致」を要求しているが、resource kind の有無で
**解決責任**が分かれる。

- resource kind あり(capability)→ ADR-0075 の Instantiate/Run フェーズで
  host/provider が解決する(`Entry.requires ⊆ ComposedHost.provides`)。
- resource kind なし(algebraic)→ host は解決できない。`main` に届く前に
  プログラム自身が `handle` で discharge しておく必要がある。

ここから次のチェッカー規則を提案する: **`main` の宣言 row の要素は
(a) resource kind を持つ capability effect、または (b) 言語が予約する
少数の core ambient effect(`Exception` 等)のいずれかでなければ
ならない**。

### singleton resource kind

`Stdout`/`Env`/`Process` などは複数インスタンスを持たない「プロセス全体
で1つの capability」なので、明示的な `resource` 宣言なしに暗黙提供される
**singleton resource kind**(`Process::Root`)が必要になる。

```vibe skip
effect Stdout[_: Process::Root] { write_stream(String) -> Unit }
```

これにより「`main` の row の要素はすべて resource kind を持つ」という
規則を崩さずに既存 builtin を retrofit できる。

### Resource の一般化

`resource X : Kind = <literal>` という形で、Env キーも S3 バケットと同じ
resource 宣言として扱える。

```vibe skip
resource DatabaseUrl : Env::Key = "DATABASE_URL"

fn connect_db() -> Option[String] with { Env::Read[DatabaseUrl] } {
  perform Env[DatabaseUrl]::get()
}
```

`resource SrcTree : Fs::Root` のような論理ルートについては、path
containment の検証を vibe のランタイムが既に使っている wasmtime の
**WASI preopen** 機構にそのまま乗せられる見込みがある。WASI preopen は
「あるディレクトリ fd を guest に渡し、そこからの相対パス以外は
`path_open` レベルで拒否する」という OS/ランタイム側の確定的な
confinement であり、文字列 prefix チェックよりも本質的に安全(prefix
チェックはシンボリックリンク差し替えによる TOCTOU の穴を持ちがちだが、
WASI preopen は resolve 自体を confine するので構造的にこの穴が無い)。
現状 `VIBE_PREOPEN_DIR` は単一グローバル preopen なので、複数
`resource X : Fs::Root` をサポートするには複数 preopen への拡張が
必要になる(wasmtime はネイティブに複数 preopen をサポートするため、
vibe ホストランタイム側の対応のみで足りる見込み)。`Env::Key`/
`S3::Bucket` のような非ファイルシステム系 resource には WASI preopen
相当の仕組みが無いので、そちらは provider 側の単純な equality/allow-list
チェックで足りる。

## 段階計画

`Fs`/`Env`/`Process`/`Stdout`/`HttpServer` を resource-kind 形へ移行する
ための段階計画。

- **Phase 0**: ADR-0075 Phase 2(`resource` 宣言/resolution、未着手)を
  先に着地させる。`Process::Root` のような singleton resource kind を
  特別扱いとして追加する。
- **Phase 1(最重要・安全)**: `builtins_fs.vibe`/`builtins_system.vibe`
  (Env/Process)/`builtins_net.vibe`(HttpServer)を内部表現だけ
  resource-kind 付きに retrofit する。表面構文(`perform
  Fs::read_file(...)`、`with { Fs }`)は無変更とし、resource 引数省略時
  は暗黙に `Fs[Process::Root]` へ展開する sugar として扱う(ADR-0071 が
  `with { Env }` を全 operation の shorthand にしたのと同じ形の拡張を
  resource 軸でもう一段行うだけ)。この段階でソース側の変更は不要。
- **Phase 2**: `Fs[SrcTree]::read_file` 等の明示形をオプトインで追加する。
- **Phase 3**: `main` の row 規則(capability + core ambient effect の
  み)を有効化する。Phase 1 で `Fs` が既に暗黙 resource を持つため既存
  `.vibex` は無風。
- **Phase 4**: WIT 生成の retrofit(#1143 の実装債務解消、後述)。
- **Phase 5**: ADR-0043(`--allow`/`--deny`)との統合。

selfhost 上の留意点として、Phase 1〜3 は表面構文を変えないため、compiler
自身のソース(`lib/@vibe/compiler/` 内の `Fs`/`Env` 呼び出し)は無変更の
ままでよい。bootstrap bump が必要になるのは Phase 2 の明示形を compiler
自身が使い始めたくなった場合のみで、優先度の低い任意の後続作業として
切り離せる。

影響範囲は `builtins_fs.vibe` / `builtins_system.vibe` /
`builtins_net.vibe` / `checker_effects.vibe` の ambient effect 集合
(`Stdout`/`Stdin`/`Stderr`/`Profiler`)。`Exception`/`Async` は別扱い
なのでこのバッチには含めない。

### WIT 生成(#1143)との関係

現状の「ambient builtin effect の WIT マッピングが無い」という状態は、
概念の誤りではなく実装債務である(`wit_gen.vibe` が effect ごとの WIT
生成テーブルを持ち、`Fs`/`Env`/`Stdout` が単に未登録なだけ)。resource
kind retrofit 後は `Fs`/`Env`/`Stdout` も `S3[Posts]::...` と構造的に
同じ capability effect になるため、ADR-0075 の「WIT world は residual
contract の ABI projection」機構にそのまま乗り、特別扱い/comment
fallback が不要になる(Phase 4)。ただし #1143 本来の要求である
「Wasmtime 非依存の host runtime execution contract を WIT で明文化する」
こと自体は、resource kind retrofit の副産物としては自動的には得られず、
別途 `.wit` ファイル/内部契約文書としての切り出し作業が必要——これは本
ADR のスコープ外とする(下記 `Rejected / deferred alternatives`)。

### 検証方針

- 各提案ごとに `fixtures/*.vibe` で最小再現を先に書き、seed compiler が
  新構文を理解できるようになってから bootstrap bump する
  ([bootstrap.md](bootstrap.md) の運用ルールに従う)。
- 破壊的変更(`Fs`/`Env` 等 builtin の resource-kind 化)は既存
  fixture/test への影響範囲を `bash scripts/compiler_gate.sh` と
  `bash scripts/unit_test_runner.sh` で確認しながら段階導入する。

## Rejected / deferred alternatives

- **動的 optional-permission 機構**(`Required`/`Optional` markers、
  `perform?`、`Attempt[T,E]`、`BindingLock.optional_resolution`): 本 ADR
  の resource-qualified `OperationRef` を前提とする別の設計判断であり、
  本 ADR のスコープには含めない。本 ADR が accepted になった後、別 ADR
  として切り出す(詳細な設計は
  [effect-taxonomy-review.md](effect-taxonomy-review.md) の「動的
  フォールバック許可」節に残す)。
- **#1143 の WIT contract 本体の解消**: resource-kind retrofit は
  #1143 の実装債務(ambient builtin effect の WIT 特別扱い)を構造的に
  解消するが、#1143 本来の要求(Wasmtime 非依存の host contract WIT
  ファイル)はこの ADR の範囲を超える別の作業として残る。
- **Deno 風の interactive permission request**(`Deno.permissions
  .request()` 相当): 実行中に人間へインタラクティブに prompt する方式は、
  ADR-0075 の「authority は run 中不変、instantiate 前に一括検査」という
  原則と衝突するため採用しない。

## Open Questions

- resource kind の型パラメータ構文の詳細: `effect Fs[R: Fs::Root]` と
  いう記法は便宜的な表記であり、既存の generic effect(`State[T]`)の
  型パラメータ構文とどう統一するかは未検討。
- `main` の row 規則を破壊的変更として導入するタイミング: Phase 1 の
  retrofit が完了していれば既存 `.vibex` は無風のはずだが、実際の
  fixture コーパスでの検証が前提。
- WASI preopen の複数化(`Resource の一般化` 節)が Phase 1 のスコープに
  入るか、それとも独立した後続作業とするか。

## 参照した実装箇所

- `lib/@vibe/compiler/checker/checker_effects.vibe` — 現行の effect row
  checker 本体。`label_is_effect_var`、`decl_authorizes_effect`、
  `check_perform_effects_expr_tx`。
- `lib/@vibe/compiler/checker/builtins_*.vibe` — 現行 builtin effect
  (`Fs`/`Env`/`Process`/`HttpServer`)の宣言。retrofit 対象。
- [effectset.md](effectset.md)(ADR-0071 実体)、
  [vibex-runtime-contract.md](vibex-runtime-contract.md)(ADR-0075 実体)、
  [adr.md](adr.md)(ADR-0060/0068/0073 エントリ)。
- `docs/wit/vibe-compiler-host.wit`、`docs/effect-wit-mapping.md` —
  #1143 の WIT ねじれの現状。
