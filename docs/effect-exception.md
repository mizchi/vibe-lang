# ADR-0085: `Error` を `Exception[E]` へ改名し型階層を導入する

Status: proposed

Date: 2026-07-30

Related: ADR-0073(`Error` の checked effect 化 — 本 ADR はこれを rename・
generic 化する、ADR-0073 自体は accepted のまま変更しない)、ADR-0071(
generic effect instantiation 正規化 — `Exception[IoError]` と
`Exception[ParseError]` を別 `OperationRef` として扱う土台をそのまま
流用する)、ADR-0050(`handle`/`perform`/`resume` 正式構文、`Error`
built-in effect・`throw` sugar の起点)、ADR-0084(resource kind
パラメータ — 本 ADR の `Exception[E]` は同 ADR が定義する「main の row を
素通りできる core ambient effect」カテゴリの具体化)、
[docs/effect-taxonomy-review.md](effect-taxonomy-review.md)(本 ADR の
元になったレビュー)

## Context

現状 `with { Error }` と `Throw`/`throw(x)` の関係が汎用的すぎて
わかりづらい、という指摘(#1136「Rename: Error -> Exception」)から出発し、
[WASM exception-handling proposal](https://github.com/WebAssembly/exception-handling/blob/master/proposals/exception-handling/Exceptions.md)
のセマンティクスに寄せる方向で `Error` を `Exception` へ改名する案を検討
した。単純な改名にとどまらず、型別例外(`IOException` 等)を見据えた
型階層設計まで検討が進んだため、両方を本 ADR の対象とする。

ADR-0073 は `Error` を完全 checked effect にすることを既に accepted と
している。本 ADR はその意味論(checked、`main` の row を素通りできる、
未処理は outer handler が診断付き失敗へ変換する)を変更せず、名前と型
パラメータのみを変更する rename + 拡張として位置づける——ADR-0073 を
supersede するものではない。

`docs/effect-taxonomy-review.md` の「Async / Exception の特殊扱い」節は
`Exception` 改名案と `Async` の分解案の2つの独立したサブセクションを
含むが、統合 issue #1218 の対応表では `Async` はどの Issue にも紐付いて
おらず、本 ADR の対象外(レビュー文書に残る未着手論点のまま)。

## Decision

### Exception[E] の型パラメータ化

```vibe skip
effect Exception[E] { Throw(E) -> Nothing }

type IoError    { NotFound(String), PermissionDenied(String) }
type ParseError { UnexpectedToken(String, Int), Eof }

fn read_config() -> Bytes with { Exception[IoError] } { ... }
fn parse_config(bytes: Bytes) -> Config with { Exception[ParseError] } { ... }

// Java の「複数の例外型をまとめて宣言する」は effectset の union で表現する
effectset ConfigErrors = { Exception[IoError], Exception[ParseError] }

fn load_config() -> Config with { ConfigErrors } {
  let bytes = read_config()      // Exception[IoError] ⊆ ConfigErrors
  parse_config(bytes)            // Exception[ParseError] ⊆ ConfigErrors
}
```

`Exception[IoError]` と `Exception[ParseError]` が別々の `OperationRef`
として扱われるのは、ADR-0071 の generic effect instantiation 正規化
(`State[Int]` と `State[String]` は異なる operation 集合)をそのまま
再利用できるためであり、新規機構は不要である。

### 階層表現: effectset union と exhaustiveness(Option A、推奨)

「階層」は Java のサブクラスではなく effectset の union で表現し、各
`E` は exhaustiveness check が効く閉じた sum type にする。Option A は
閉じた世界(サードパーティがバリアントを後から追加できない)だが、
網羅性チェックの恩恵を受ける。ADR-0071 が effectset に差集合/補集合/
wildcard を禁止している閉じた世界志向と一貫させるため、Option A を
デフォルトにすることを推奨する。

### エスケープハッチ: trait 境界 + downcast(Option B)

真に開いた拡張性が要る場合のみ、`Exception[E: ExceptionKind]` の trait
境界 + `.downcast[T]()`(Rust の `Box<dyn Error>` 相当)をエスケープ
ハッチとして用意する。Option A をデフォルトとしつつ、この代替案は
`Rejected / deferred alternatives` に記録する。

### core ambient effect としての位置づけ

`Exception`(現 `Error`)は resource kind を持たないが、`main` の row を
素通りしてよい(ADR-0073/0075: 「未処理 checked Error は outer handler が
diagnosed failure へ変換する」)。これは capability でも通常の
algebraic(必ず `handle` で discharge)effect でもない、**第三のカテゴリ
= 「言語が予約する core ambient effect」**として扱う——ADR-0084 が提案
する `main` の row 検査規則の (b) 項目そのものである。ユーザーは
`effect Exception { ... }` を再定義できない(予約済み)。

## Rejected / deferred alternatives

- **Option B(trait 境界 + downcast)をデフォルトにする案**: 却下。
  ADR-0071 が effectset に差集合/補集合/wildcard を禁止している閉じた
  世界志向と一貫させるため、Option A(閉じた effectset union)を
  デフォルトとし、Option B は真に開いた拡張性が要る場合のエスケープ
  ハッチとして残す。
- **WASM exception-handling proposal とのセマンティクス整合の詳細検討**:
  #1218 の対応表が「要検証」と明記した通り、リンクされている提案との
  整合はまだ検討していない。本 ADR では踏み込まず、下記 Open Questions
  に回す。

## Open Questions

- **WASM exception-handling proposal とのセマンティクス整合**: 改名の
  動機の一つだが、具体的にどの意味論(tag ベースの例外、try/catch_all
  等)にどう対応させるかは未検討。
- **rename の移行段取りが未設計**: `docs/effect-resource-kind.md`
  (ADR-0084)にあるような Phase 0-5 の段階移行計画が本 ADR には無い。
  `Error`/`throw`/`with { Error }` は `lib/@vibe/compiler/` を含む
  コードベース全域で使われており(ADR-0073 の実装が
  `docs/error-effect-policy.md` に基づき広く適用済み)、破壊的 rename の
  blast radius 調査と段階計画は本 ADR のスコープ外であり、別途必要。
- **ADR-0073 の記述更新要否**: 本 ADR は ADR-0073 を supersede しないが、
  `docs/adr.md` の ADR-0073 行や `error-effect-policy.md` 内の `Error`
  という呼称をどの時点で `Exception` に更新するか(rename 実施と同時か、
  ADR-0085 の accepted 時点か)は未決定。

## 参照した実装箇所

- [error-effect-policy.md](error-effect-policy.md)(ADR-0073 実体、現行
  `Error` の checked effect 実装)。
- `lib/@vibe/compiler/checker/checker_effects.vibe` — 現行の effect row
  checker 本体(`Error`/`Throw` を含む builtin effect の扱い)。
- [effectset.md](effectset.md)(ADR-0071 実体、generic effect
  instantiation 正規化の土台)。
- [effect-resource-kind.md](effect-resource-kind.md)(ADR-0084 実体、
  core ambient effect カテゴリの定義元)。
