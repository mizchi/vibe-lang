# Test / Example capability と executable documentation 設計

**Status:** Proposal  
**Related:** #819 (merged doctest compile)

## 目的

テストと API 利用例を通常の Vibe コードとして型検査・実行し、必要な
capability を宣言可能にする。Markdown fence の任意スクリプトを doctest
として実行する方式だけに依存せず、API に紐付く利用例を言語構文として
記述する。

この設計は次を満たす。

- test/example が必要とする capability を source 上で監査できる。
- assertion failure のための `Exception` を test/example の基底 capability
  として明示する。
- よく使う開発用 capability は `DevEnv` bundle で簡潔に記述する。
- example を対象 API に結び付け、API docs と実行可能な利用例を同期する。
- `.vibe.md` の runnable block を一つの wasm module に統合コンパイルする際、
  block 間の名前衝突を起こさない。

## 構文

```vibe
test "test name" {
  // body
}

test "test name" with Exception + Fs {
  // body
}

example "example name" for Array::get with Exception {
  let xs = [10, 20]
  assert_eq(Array::get(xs, 0), 10)
}
```

`for` の対象は最初の版では fully-qualified symbol のみを受け入れる。
曖昧な overload 解決や任意の式を `for` に置くことは許可しない。

## Effect row の規則

### 省略時

`test "…" { … }` および `example "…" for Symbol { … }` の実効 row は
`{ Exception }` である。省略は effect inference ではない。

従って、例えば `Fs` を使う test は省略形では type error になり、必要な
capability を宣言しなければならない。

### 明示時

`with` を書く場合、row は完全に明示する。`Exception` を省略することは
エラーとする。

```vibe
// OK
test "pure" with Exception { assert_eq(1, 1) }

// OK
test "reads fixture" with Exception + Fs { /* ... */ }

// Error: an explicit test/example effect row must include Exception
test "invalid" with () { assert_eq(1, 1) }
```

この規則により、test の failure / early-exit 経路も declaration から読める。
`Exception` は test runtime が assertion failure を報告するための基底
capability である。

`with` は静的な effect contract であり、実行時の host authorization を
単独で与えるものではない。test runner は declaration を要求として扱い、
別途 sandbox / allowlist を適用する。たとえば `Fs` は fixture root に制限
できる。

## `DevEnv` bundle

開発用 fixture や integration test で capability をすべて個別列挙する負担を
下げるため、`DevEnv` を定義済み development capability bundle とする。

```vibe
test "local integration" with Exception + DevEnv {
  // development fixture を使う
}
```

`DevEnv` は checker と runner が同じ定義を共有する bundle である。checker は
これを concrete effect set に展開して通常の effect check を行い、runner は
展開結果を capability policy と照合する。従って `DevEnv` は型検査をすり抜ける
「万能 effect」ではない。

bundle の正確な内容は stable な runner contract として文書化する。少なくとも
network capability (`Http`) は含めない。network は常に `Http` を個別に
宣言・承認する。

`DevEnv` は test、example、doctest の development execution 用である。
production の `vibe run` / `vibe build` では原則として reject し、必要なら
明示的な development-only flag による opt-in を要求する。

## `example` の意味論

`example` は docs 向け metadata を持つ executable case である。

- body は test と同じ型検査・effect check・runner 基盤で実行する。
- `for Symbol` は解決されなければ compile error とする。
- compiler は example の名前、対象 symbol、source span、宣言 row を registry
  metadata に保存する。
- docs generator は registry と source span を使って対象 API の documentation
  に example を掲載できる。
- `vibe test` は通常の test を実行する。example の実行は `vibe test --examples`
  （名称は実装時に確定）および doctest gate で opt-in する。

example は assertion を含んでよい。stdout を documentation output として検証
する形式は将来の拡張とし、初期版は assertion failure と trap を failure とする。

## Merged doctest compilation (#819)

Markdown の `vibe run` fence は任意の script example として引き続き扱える。
一方、API の利用例には `example` declaration を優先する。

merged compilation では各 runnable fence を独立した generated wrapper にする。

```vibe
export let __doctest_a1b2c3 = () -> Unit {
  let x = 1
  ()
}
```

wrapper ID は raw AST hash 単体ではなく、少なくとも次から作る stable identifier
とする。

```text
sha256(relative-document-path + fence-offset + normalized-AST)
```

同一内容の fence が複数あっても衝突しないためである。wrapper は文書内の順序で
実行し、診断は generated identifier ではなく元の `path:line` に戻す。

runnable fence は互いに独立した scope である。ある fence の definition を後続
fence が参照することはできない。逐次依存する literate programming 用の構文が
必要になった場合は、`vibe continue` 等の別機能として設計する。

fence 内の top-level `test` / `example` declaration は wrapper 内に入れず、merged
source の top level に hoist して registry に登録する。`compile_fail` 等、隔離が
必要な fence は merged compilation から opt-out する。

## 実装段階

1. `STest` に optional effect-row metadata を追加し、parser / lowering / checker /
   test registry を更新する。省略時 `{ Exception }`、明示時 `Exception` 必須を
   実装する。
2. test runner の declared-row-to-runtime-policy 照合と fixture sandbox を追加する。
3. checker / runner 共有の `DevEnv` bundle を導入し、network を含まない展開内容を
   runner contract に固定する。
4. `SExample`、`for` target resolution、example registry metadata、`--examples` 実行
   経路を追加する。
5. `scripts/vibe_md.vibex` を wrapper / hoist 方式の merged compile に移行し、
   source map と block 単位の failure report を追加する。

各段階で parser fixture、effect rejection fixture、runner policy fixture、merged
module の同名 block regression を追加する。
