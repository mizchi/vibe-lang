# ADR-0050: `handle` を汎用 effect handler に統一

- Date: 2026-04-08
- Status: proposed

## Context

### 現状の `handle` は構文と意味がずれている

現行の parser は `handle { body } { arms }` を単一の `Handle` 式として受理し、
arm には通常の pattern、or-pattern、guard を許可している。

一方で lowering / rewrite では、arm のうち `Effect::Op(...)` 形式だけを
effect handler として抽出し、それ以外を error/local boundary として別扱いしている。

このため、ユーザーから見た `handle` は 1 構文だが、実装上は次の 2 系統が混在している。

1. `Error(_) => ...` のような local error boundary
2. `Effect::Op(...) => resume(...)` のような generic effect handler

0.1.0 前に surface syntax を固定するなら、この hybrid をそのまま stable にするべきではない。

### 公開前に固定したい要件

- `handle` を error 専用 special case にしない
- `Error` を通常 effect と同じモデルに乗せる
- handler 構文は 1 つに統一する
- 将来の `Mut<T>` / capability effect / host import handler と整合する
- formatter / parser / docs / selfhost source の canonical 形を 1 つに固定する

## Decision

### 1. `handle` は汎用 effect handler とする

`handle` は `Error` 専用ではなく、任意の effect を処理する汎用構文とする。

- `Error` は built-in effect の一種として扱う
- local error boundary は `Error` handler の special case ではなく、通常の
  effect handling と同じ規則に従う

### 2. canonical syntax は `handle { expr } with EffectName { ... }`

canonical surface syntax は次に固定する。

```vibe
handle { expr } with EffectName {
  Op(...) => expr;
  OtherOp(...) if guard => expr;
}
```

規則:

- `handle` の body は任意の式
- body は常に `{ ... }` で囲む
- `with EffectName` は必須
- 1 つの `handle` が消す effect は 1 個だけ
- 複数 effect を処理したい場合は nested `handle` で表現する

### 3. arm の表記は effect 名を省略する

`with EffectName` の内側では arm は `Op(...)` を書く。
`EffectName::Op(...)` は canonical syntax に含めない。

```vibe
handle { risky() } with Error {
  Throw(msg) => -1;
}

handle { greet("world") } with Logger {
  Log(msg) => {
    Stdout::write_stream(msg)
    resume(())
  };
}
```

### 4. arm の matching は `match` と同等にする

arm は `match` と同等の pattern matching 能力を持つ。

- `_` を許可
- or-pattern を正式対応にする
- guard (`if ...`) を正式対応にする
- 選択順は top-to-bottom の first match
- arm 区切りは `;` のみ
- trailing `;` は許可する

### 5. `Error` は built-in effect として一般化する

`throw(e)` は source-level sugar として残すが、意味論上は
`perform Error::Throw(e)` の sugar とする。

handler 側は次を canonical とする。

```vibe
handle { risky() } with Error {
  Throw(msg) => fallback(msg);
}
```

### 6. `resume` は one-shot continuation に制限する

0.1.0 向け stable contract として、`resume` は one-shot continuation に固定する。

規則:

- `resume` は handler arm の lexical scope 内でのみ使用可能
- `resume` は 0 回または 1 回のみ呼び出し可能
- continuation の保存、返却、再束縛、closure capture、複数回呼び出しは禁止
- tail-resumptive form は最適化対象だが、意味論としては non-tail も許可する

### 7. 型規則と effect 消去規則

`handle { body } with E { arms }` の型規則を次で固定する。

- `body` の型を `T` とする
- 各 arm はすべて `T` を返さなければならない
- `resume(v)` の引数 `v` は対応する operation の戻り値型に一致しなければならない
- `handle` 全体の型は `T`
- `handle` 全体の effect set は、`body` が要求する effect set から `E` を除き、
  arm 本体が直接使う effect を加えたもの
- `with E` の arm は exhaustive でなければならない

### 8. ネスト時の解決規則

同一 effect に対する複数の handler がネストしている場合は、
最も近い動的に内側の handler が先に operation を捕捉する。

すなわち handler の解決規則は inner-first とする。

### 9. return clause は導入しない

`handle` に対する `return x => ...` のような追加 clause は 0.1.0 では導入しない。

- `handle` 全体の戻り値型は body と同じ型に固定する
- return path の分岐は将来の拡張に残す

### 10. 旧構文は一括移行で廃止する

旧 `handle { body } { arms }` は移行期間を持たずに廃止する。

- parser は旧構文を受理しない
- diagnostic で `with EffectName` 付き新構文への migration を案内する
- formatter / printer / docs / selfhost source は新構文に統一する

## Implementation Sketch

実装は次の順序で進める。

1. parser / AST
   - `handle { expr } with EffectName { ... }` を parse する
   - `with EffectName` を含む `Handle` AST に拡張する
   - 旧 `handle { ... } { ... }` を parse error にし、migration hint を出す
2. printer / formatter
   - canonical print を新構文に切り替える
   - arm 区切りを `;` に固定する
3. checker
   - `Error` を built-in effect として effect set に統合する
   - `with E` arm の exhaustiveness を検査する
   - `resume` の one-shot / lexical-scope 制約を検査する
4. lowering / rewrite
   - 現在の hybrid 分岐 (`effect arm` vs `error arm`) を廃止する
   - `with EffectName` 前提で generic effect handler rewrite に整理する
5. migration
   - selfhost source、compiler tests、language docs、cheatsheet を一括更新する
   - old syntax を前提にした parser roundtrip / printer snapshot を置き換える
6. release hardening
   - diagnostic 文言を固定する
   - `Error` / `resume` / nested handle の characterization test を追加する

## Consequences

### Good

- **error と generic effect が 1 つの理論に統一される**
- **将来の `Mut<T>` や capability effect と表面構文が整合する**
- **`with` が「この handler が何を消すか」を示すため、可読性が上がる**
- **formatter の canonical form が 1 つに定まる**
- **hybrid 実装を整理しやすくなる**

### Bad

- **旧 `handle { ... } { ... }` を使う既存コードは一括で書き換えが必要**
- **parser / printer / docs / tests / selfhost source に大きな migration が必要**
- **`resume` の one-shot 制約を checker / lowering / diagnostics で明示的に実装する必要がある**
- **`with EffectName` による 1 effect per handle 制約は、複数 effect を一度に扱いたいケースでは冗長に見える**

### Neutral

- `throw` は残すが、表面 sugar に降格する
- tail-resumptive inline 最適化は継続するが、surface semantics そのものではない
