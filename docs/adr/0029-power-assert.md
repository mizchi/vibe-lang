# ADR-0029: Power Assert とインラインスナップショット

- Date: 2026-03-13
- Status: proposed
- Related: ADR-0003 (エフェクトシステム), ADR-0026 (純粋テストキャッシュ)
- Reference: [wado-lang/wado](https://github.com/wado-lang/wado) の power-assert 実装、MoonBit の `inspect()` パターン

## Context

vibe のテストには 2 つの問題がある。

### 問題 1: assert の情報不足

現在 vibe の `assert` は単一の `Bool` 引数を取る builtin 関数で、失敗時は WASM unreachable trap を発行するだけである。どの式が失敗したのか、各部分式の値がいくつだったのかは一切報告されない。

```vibe
test "example" {
  let x = 3
  let y = 4
  assert(x + y > 10)  // trap: 何も情報なし
}
```

wado 言語は **power-assert** を実装しており、assert 失敗時に以下のような出力を得られる:

```
Assertion failed in run at test.wado:6
condition: x + y > 10
x: 3
y: 4
x + y: 7
```

wado の実装は **コンパイル時 AST desugaring** であり、ランタイムオーバーヘッドはパス時にゼロ、失敗時のみメッセージ構築コストが発生する。

### 問題 2: スナップショットテストの欠如

現在 vibe のテストは `assert(String::equals(result, "expected"))` のような手動文字列比較で書かれている。期待値が長い場合や構造化データの場合、テストの作成・更新が困難になる。

MoonBit は `inspect(expr, content="expected")` というインラインスナップショットを持ち、`moon test --update` で `content=` の値を自動更新できる。これにより:

- 期待値を手で書く必要がない
- 出力が変わったとき `--update` で一括更新
- テストコード内に期待値がインラインで残るため、外部ファイルへの依存がない

```moonbit
// MoonBit の inspect パターン
test "example" {
  inspect(parse("1 + 2"), content="Add(Int(1), Int(2))")
}
```

vibe でも同様の仕組みを導入する。

## Decision

### assert を desugar パスで power-assert に変換する

`assert(expr)` 呼出を検出し、以下の変換を行う:

#### 変換例

```vibe
// 変換前
assert(x + y > 10)

// 変換後 (desugar)
let __v0 = x
let __v1 = y
let __v2 = __v0 + __v1
let __cond = __v2 > 10
if not(__cond) {
  __assert_fail("test.vibe", 6, "x + y > 10", [
    ["x", __show(__v0)],
    ["y", __show(__v1)],
    ["x + y", __show(__v2)]
  ])
}
```

#### 中間値の収集対象 (collect_intermediates)

wado の実装に倣い、以下の部分式を収集する:

| 式の種類 | 例 | 収集する |
|---|---|---|
| 変数参照 | `x`, `y` | Yes |
| 関数呼出 | `f(x)`, `len(s)` | Yes |
| 二項演算 (ルート以外) | `x + y` | Yes |
| 単項演算 | `not(x)` | Yes |
| フィールドアクセス | `r.field` | Yes (将来) |
| 配列インデックス | `a[i]` | Yes (将来) |
| リテラル | `10`, `"hello"`, `true` | No |
| ルート比較 | `> 10` (最外の比較) | No (condition として表示) |

#### 副作用安全性

wado と同様に、すべての部分式を **一度だけ評価** して `let __vN` にキャッシュする。これにより副作用のある関数呼出が二重実行されない:

```vibe
// 変換前
assert(get_count() > 0)

// 変換後
let __v0 = get_count()    // 1回だけ呼ばれる
let __cond = __v0 > 0
if not(__cond) {
  __assert_fail("test.vibe", 5, "get_count() > 0", [
    ["get_count()", __show(__v0)]
  ])
}
```

### 段階的実装

#### Phase 1: ソーステキスト表示 (最小実装)

assert 失敗時にソーステキストとファイル位置を表示する。中間値なし。

```
Assertion failed at test.vibe:6
condition: x + y > 10
```

必要な変更:
- desugar パスで `assert(expr)` を検出
- `expr` の span からソーステキストを抽出
- `__assert_fail(file, line, condition_source)` builtin を追加
- `__assert_fail` は `println` → `unreachable` (または panic 相当)

#### Phase 2: 中間値の表示 (power-assert 本体)

`collect_intermediates` + `__show` による値の表示。

```
Assertion failed at test.vibe:6
condition: x + y > 10
x: 3
y: 4
x + y: 7
```

必要な変更:
- `collect_intermediates()` — 部分式の再帰的収集
- `reconstruct_with_intermediates()` — 条件式の変数参照置換
- `__show(value) -> String` — 型に応じた値表示

#### Phase 3: 汎用 inspect (struct/enum 対応)

`__show` を全型に対応させる。型チェッカーの結果を使い、desugar を checker 後に配置するか、`__show` を trait ディスパッチにする。

### `__show` の型ごとの実装

| 型 | 表示 | Phase |
|---|---|---|
| Int | `42` | Phase 2 |
| String | `"hello"` | Phase 2 |
| Bool | `true` / `false` | Phase 2 |
| Float / Double | `3.14` | Phase 2 |
| Array[T] | `[1, 2, 3]` | Phase 3 |
| enum | `Some(42)` | Phase 3 |
| struct / record | `{x: 1, y: 2}` | Phase 3 |

Phase 2 では Int / String / Bool のみ対応し、他の型は `<opaque>` と表示する。

### desugar の配置

```
parse → desugar(method calls) → desugar(power-assert) → check → codegen
```

power-assert desugar は型チェック前に行う。`__show` は checker の builtins に追加し、引数型に応じたコード生成を codegen 側で行う（Phase 2 では Int/String/Bool の 3 分岐）。

### テストランナーとの統合

現在のテストランナーは wasmtime の exit code で pass/fail を判定し、stderr を `wasmtime_failure_detail()` で取得している。power-assert のメッセージは stderr に出力すればそのまま表示される。

---

### インラインスナップショットテスト

#### 構文

`assert` と `__show` を組み合わせた `snapshot` 関数を導入する:

```vibe
test "parse expression" {
  let result = parse("1 + 2")
  snapshot(result, "Add(Int(1), Int(2))")
}
```

`snapshot(expr, expected)` は以下と等価:

```vibe
let __actual = __show(expr)
if not(String::equals(__actual, expected)) {
  __snapshot_fail("test.vibe", 3, __actual, expected)
}
```

#### 自動更新

`vibe test --update` 実行時、snapshot の失敗箇所について **ソースファイルの第 2 引数を実際の値で書き換える**:

```vibe
// 更新前 (初回は空文字列で書く)
snapshot(result, "")

// vibe test --update 後
snapshot(result, "Add(Int(1), Int(2))")
```

#### 更新の仕組み

1. **コンパイル時**: `snapshot(expr, expected)` の呼出を検出し、第 2 引数の文字列リテラルの **span (ファイル位置)** を記録
2. **実行時**: actual と expected が不一致のとき、`__snapshot_mismatch(file, offset_start, offset_end, actual)` を stderr に構造化出力
3. **テストランナー**: `--update` モードのとき stderr のミスマッチ情報を収集し、ソースファイルを書き換え

構造化出力フォーマット:

```
__SNAPSHOT_MISMATCH__
file: test.vibe
offset: 120-135
actual: Add(Int(1), Int(2))
__END__
```

#### 初回スナップショット

第 2 引数を省略可能にする設計も検討する:

```vibe
// 第2引数省略 → 常に失敗し、--update で埋まる
snapshot(result)

// --update 後
snapshot(result, "Add(Int(1), Int(2))")
```

この場合、`snapshot` は 1 引数のとき暗黙に `""` を期待値とする。ただし、引数省略と空文字列期待を区別する必要がある。

#### 複数行スナップショット

長い出力の場合、複数行文字列リテラルが必要になる。vibe が `"""` (triple-quote) をサポートする場合:

```vibe
snapshot(ast, """
  Module {
    stmts: [
      Let { name: "x", value: Int(1) }
    ]
  }
""")
```

triple-quote 未サポートの場合は `\n` エスケープで対応するが、可読性が下がるため triple-quote の導入を推奨する。

#### __show との関係

`snapshot` は `__show` に依存する。`__show` の実装段階に応じて snapshot の表示精度も変わる:

- Phase 2: Int / String / Bool のみ `__show` 対応 → snapshot もスカラー値のみ有用
- Phase 3: enum / struct 対応 → AST ノードなどの構造化データに snapshot が使える

Phase 3 の `__show` が揃って初めてスナップショットテストの真価が発揮される。

#### power-assert との使い分け

| ユースケース | 推奨 |
|---|---|
| 条件の真偽を検証 | `assert(x > 0)` (power-assert) |
| 値の等値を検証 | `assert(x == 42)` (power-assert) |
| 文字列表現を検証 | `snapshot(expr, "expected")` |
| 構造化データの回帰テスト | `snapshot(ast, "...")` |
| 出力が頻繁に変わる開発中のテスト | `snapshot(result)` + `--update` |

原則: **条件が書ける場合は `assert`、値全体の文字列表現を固定したい場合は `snapshot`**。

## Consequences

### Positive

- assert 失敗時の情報量が劇的に改善
- `assert_eq`, `assert_ne` 等の専用関数が不要 — `assert(a == b)` で十分
- テストの書き方がシンプルなまま、デバッグ体験が向上
- パス時はゼロオーバーヘッド (desugaring は let + if のみ)
- wado と設計思想を共有でき、エコシステムの知見を活用できる
- インラインスナップショットにより、構造化データの回帰テストが容易
- `--update` による期待値の自動更新で、テスト作成・保守のコストが下がる
- 外部スナップショットファイル不要 — テストコード内で完結

### Negative

- desugar パスの複雑化（中間値収集 + 式の再構築）
- `__show` の型ごと実装が必要（Phase 3 で trait 化するまでは限定的）
- assert 内の式が複雑な場合、生成コードが大きくなる
- source span → テキスト復元に元ソース文字列へのアクセスが desugar 時に必要
- snapshot の `--update` はソースファイル書き換えを伴うため、テストランナーにファイル I/O 権限が必要
- 複数行スナップショットには triple-quote (`"""`) の言語サポートが前提

### assert 以外の assertion は不要

power-assert があれば、以下の専用関数は **不要** になる:

- `assert_eq(a, b)` → `assert(a == b)` で `a` と `b` の値が両方表示される
- `assert_ne(a, b)` → `assert(a != b)` で同様
- `assert_gt(a, b)` → `assert(a > b)` で同様
- `assert_contains(s, sub)` → `assert(String::contains(s, sub))` で `s` と `sub` が表示される

### テスト API まとめ

vibe のテストは以下の 2 関数のみで構成される:

| 関数 | 用途 | 失敗時の情報 |
|---|---|---|
| `assert(expr)` | 条件検証 (power-assert) | 条件式 + 中間値 |
| `snapshot(expr, "expected")` | 値の文字列表現検証 | actual vs expected diff |

## Open Questions

### Power Assert

1. **desugar の段階**: 型チェック前 (Phase 1-2) と後 (Phase 3) のどちらに配置するか。Phase 2 までは型チェック前で十分だが、Phase 3 の汎用 inspect は型情報が必要。二段階 desugar にするか、`__show` を codegen 時に解決するか
2. **`__show` の命名と公開**: ユーザーが直接呼べる `show()` 関数にするか、`__` prefix の内部関数にするか。公開する場合 trait 化との関係
3. **ネストした assert**: `assert(assert(x > 0) == ())` のようなケースの扱い（禁止 or 外側のみ変換）
4. **`not(cond)` の表示**: `assert(not(x))` のとき `not(x)` をルート条件として表示するか、`x` の値を中間値として表示するか
5. **ソーステキスト復元の方法**: span から元ソースを引くか、`unparse()` で AST から再構築するか。前者は正確だが desugar 時にソース文字列のスレッディングが必要。後者はフォーマットが変わりうる
6. **release ビルドでの挙動**: `--release` 時に power-assert を無効化して単純な trap に戻すか。コード量削減 vs デバッグ容易性のトレードオフ
7. **ADR-0026 (テストキャッシュ) との関係**: power-assert の `__show` が副作用を持たない限り純粋性は保たれるが、stderr 出力する `__assert_fail` は IO エフェクト。失敗パスのみなので「パスしたテストのキャッシュ」には影響しないが、明示的に規定すべきか
8. **custom message**: `assert(expr, "msg")` のような追加メッセージ構文を許可するか。wado は対応している

### インラインスナップショット

9. **引数省略の扱い**: `snapshot(expr)` (1 引数) を許可するか。許可する場合、空文字列期待 `snapshot(expr, "")` との区別をどうするか。案: 1 引数は「常に失敗 + --update で埋める」、2 引数の空文字列は「空文字列を期待」
10. **エスケープの扱い**: actual 値に `"` や `\n` が含まれる場合、ソースファイル書き換え時のエスケープ処理。triple-quote ならエスケープ不要だが、通常文字列リテラルでは必要
11. **triple-quote の導入**: 複数行スナップショットのために `"""..."""` を言語に追加するか。snapshot 以外でもテンプレート文字列として有用だが、lexer/parser の変更が必要
12. **並列テスト時のファイル書き換え競合**: 同じファイル内の複数テストが同時に失敗した場合、`--update` の書き換えが競合する。対策: ミスマッチ情報を全て収集後にまとめて書き換え
13. **diff 表示**: snapshot 不一致時に unified diff を表示するか。長い文字列の場合に有用だが、diff ライブラリの実装が必要
14. **snapshot の名前**: `snapshot` / `inspect` / `expect` のどれにするか。MoonBit は `inspect`、Jest は `expect().toMatchInlineSnapshot()`。vibe としてどの名前が最適か
15. **snapshot は test ブロック内限定か**: `snapshot` を test ブロック外で使えるか。`--update` はテスト実行時のみ意味があるため、test 外での使用は警告または禁止が妥当
