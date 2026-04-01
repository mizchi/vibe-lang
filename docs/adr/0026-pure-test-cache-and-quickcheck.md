# ADR-0026: 純粋テストキャッシュと QuickCheck

- Date: 2026-03-12
- Status: proposed
- Related: ADR-0003 (エフェクトシステム), ADR-0004 (コンテンツアドレスモジュール), ADR-0021 (Effect Handler)

## Context

`vibe test` はテストごとに WASM コンパイル + wasmtime 実行を行うため、モジュール数が増えると実行時間が累積する。一方、vibe のエフェクトシステム (ADR-0003) により関数の純粋性がコンパイル時に判定可能であり、コンテンツアドレスモジュール (ADR-0004) によりソースの同一性がハッシュで保証される。

この 2 つを組み合わせれば、**純粋なテストの実行結果を安全にキャッシュ**できる。

### QuickCheck の位置づけ

`vibe/x/quickcheck` ライブラリは乱数生成 (Rng) を使うが、固定シードの xorshift PRNG であるため**計算は決定的**である。しかし Rng を「純粋」と見なしてキャッシュするか、「副作用」と見なして毎回再実行するかは自明ではない。

## Decision

### 1. 純粋テストキャッシュ

テストブロックの実行結果を以下の条件でキャッシュする:

- テストブロック本体とその推移的依存がすべて**エフェクト宣言なし** (`with { ... }` がない)
- 推移的依存のすべてのソースハッシュ (ADR-0004) が前回実行時と一致
- コンパイラバージョンが一致

キャッシュキー:

```
cache_key = hash(test_name, source_hash, dep_hashes[], compiler_version)
```

キャッシュストア: `.vibe_cache/test/` にキー→結果 (pass/fail + 出力) を保存。

`--no-cache` フラグで強制再実行:

```bash
vibe test                # キャッシュ利用
vibe test --no-cache     # 全テスト再実行
```

### 2. Rng をエフェクトとして扱う

Rng (擬似乱数生成) は `effect Rng` として宣言する:

```
effect Rng {
  next_int(lo: Int, hi: Int) -> Int
  next_bool() -> Bool
}
```

通常の `Rng` エフェクトはテストをキャッシュ不可 (impure) にする。

### 3. QuickCheck + 固定シードの特例

`quickcheck` ブロック (または `qc` 構文) は、**固定シードの決定的 Rng ハンドラ**を暗黙に注入する特殊テスト形式:

```
qc "addition is commutative" {
  (a: Int, b: Int) -> { a + b == b + a }
}
```

コンパイラが生成するコード (概念):

```
test "addition is commutative" {
  handle {
    let result = quickcheck_run((a: Int, b: Int) -> { a + b == b + a })
    assert(is_ok(result))
  } with Rng {
    // 固定シード xorshift ハンドラ — 決定的
    let mut state = 42
    next_int(lo, hi) -> { state = xorshift(state); resume(lo + state % (hi - lo + 1)) }
    next_bool() -> { state = xorshift(state); resume((state & 1) == 0) }
  }
}
```

この形式では:
- `Rng` エフェクトはハンドラ内で消去される
- ハンドラ自体は純粋 (固定シード、決定的)
- **結果としてテスト全体が純粋と判定され、キャッシュ可能**

### 4. 判定ルールまとめ

| テスト形式 | エフェクト | キャッシュ |
|-----------|-----------|-----------|
| `test { pure_fn() }` | なし | **可** |
| `test { perform read_file(...) }` | `Fs` | 不可 |
| `test { check_int(..., prop) }` (ライブラリ版) | なし (現状) | **可** (※注) |
| `qc { (a: Int) -> { ... } }` (組み込み版) | `Rng` → ハンドラで消去 | **可** |
| `test { handle { perform next_int(...) } with Rng { ... } }` | `Rng` → ハンドラで消去 | **可** |

※注: 現在の `vibe/x/quickcheck` ライブラリ版は Rng を関数引数として渡す純粋関数スタイルなので、エフェクト宣言がなく**そのままキャッシュ可能**。

## Edge Cases

### EC-1: ライブラリ版 quickcheck は「偽の純粋」

現在の `check_int("name", 42, 100, prop)` は seed を引数で受け取る純粋関数。エフェクトシステムから見ると純粋なのでキャッシュされるが、**ユーザーが seed を変更したら異なる入力列でテストすべき**。

- キャッシュキーにソースハッシュが含まれるため、seed リテラル変更 → ハッシュ変更 → 再実行される
- **問題なし**: ソースが同一なら seed も同一なので、結果は決定的

### EC-2: 依存モジュールの非純粋関数を間接呼び出し

```
// module_a.vibe
export let greet = (name: String) -> String with { Fs } {
  let template = Fs::read_file("template.txt")
  replace(template, "{name}", name)
}

// test.vibe
test "greet" {
  // greet を呼ぶが、Fs エフェクトを handle していない
  // → コンパイルエラー (エフェクト未消化)
}
```

- エフェクトシステムが推移的に追跡するため、**コンパイル時に検出**される
- handle で消化した場合、ハンドラの実装が純粋かどうかでキャッシュ判定

### EC-3: `let mut` はキャッシュに影響するか

`let mut` は局所可変状態でありエフェクトではない。外部状態を変更しないため**キャッシュに影響しない**。quickcheck のライブラリ実装が `let mut` で PRNG 状態を管理しているのはこの理由で安全。

### EC-4: ハンドラ内の非決定性

```
test "bad" {
  handle {
    let x = perform next_int(0, 100)
    assert(x > 50)  // 決定的だが、ハンドラ次第
  } with Rng {
    // 外部時刻をシードにする → 非決定的
    next_int(lo, hi) -> { resume(system_time() % (hi - lo + 1) + lo) }
  }
}
```

- `system_time()` は `with { Clock }` エフェクトを要求
- ハンドラ本体にエフェクトが残る → テスト全体が impure → キャッシュ不可
- **エフェクトシステムが正しく機能すれば自動判定される**

### EC-5: qc ブロックの count パラメータ

```
qc(count=1000) "prop" { (n: Int) -> { n + 0 == n } }
```

`count` はソースの一部なのでハッシュに含まれる。count 変更 → ハッシュ変更 → 再実行。問題なし。

### EC-6: コンパイラの最適化変更

コンパイラが新しい最適化パスを追加した場合、同じソースでも異なる WASM が生成される可能性がある。純粋関数なら結果は同じはずだが、**コンパイラバグで結果が変わるリスク**がある。

- キャッシュキーに `compiler_version` を含めることで対処
- コンパイラ更新時はキャッシュ全体が無効化される

### EC-7: プロパティ関数がクロージャで外部状態を参照

```
let mut counter = 0
test "bad quickcheck" {
  let result = check_int("inc", 42, 100, (n: Int) -> Bool {
    counter = counter + 1  // 外部 mutable を参照
    n + 0 == n
  })
  assert(is_ok(result))
}
```

- `counter` は `let mut` で宣言されたテスト外のトップレベル変数
- テストブロックは独立した環境でクローンされるため、テスト間で `counter` を共有しない
- ただし同一テスト内でクロージャが外部 mut を捕捉する場合は**意味的には純粋ではない** (副作用として観測可能な状態変更がある)
- 現行のエフェクトシステムでは `let mut` の外部参照はエフェクトとして追跡されない → キャッシュの正当性に影響しうる
- ADR-0021 の Effect Handler 導入後、このパターンは `effect Mut` として検出可能になる見込み

### EC-8: テストの実行順序依存

純粋テストは定義上実行順序に依存しないため、キャッシュの有無で順序が変わっても問題ない。ただし:

- impure テスト同士の順序依存 (例: テスト A が DB にデータ挿入、テスト B がそれを読む) はキャッシュ対象外なので影響しない
- pure テストと impure テストが混在するファイルでは、pure テストのみスキップされ impure テストは常に実行される

## Open Questions

以下は今後の設計・実装フェーズで決定する。

1. **キャッシュキーにファイルパスを含めるか**: `test_name` がファイル内で一意とは限らない。別ファイルの同名テストとの衝突回避にファイルパス (またはモジュールハッシュ) が必要か
2. **ビルトイン関数のハッシュ扱い**: `assert`, `Array::push` 等のビルトインは `compiler_version` に含まれるとするか、別途ハッシュを持つか
3. **fail 結果のキャッシュポリシー**: fail もキャッシュするか。CI (変更なければ再実行不要) とローカル開発 (即座に再実行したい) で挙動を分けるか
4. **`qc` 構文の詳細**: 対応する型のジェネレータ一覧、ユーザー定義型のジェネレータ提供方法、`count` / `seed` のデフォルト値と指定構文
5. **ハンドラ本体の純粋性判定ルール**: ハンドラ内で `let mut` を使いつつエフェクトを消化するケース (EC-3 と EC-4 の交差) の判定基準
6. **テストキャッシュと ADR-0004 の `index.vdb` の関係**: `.vibe_cache/test/` は別ストアか、`index.vdb` に統合するか

## Consequences

良い面:
- 大規模プロジェクトでのテスト実行時間を大幅に削減（純粋テストのみキャッシュヒットでスキップ）
- エフェクトシステムとコンテンツアドレスが連携し、キャッシュの正当性が型レベルで保証される
- QuickCheck の固定シード実行がキャッシュ可能 — プロパティテストの再実行コストを抑えつつ信頼性を維持
- `--no-cache` による明示的な全件再実行が常に可能

悪い面/トレードオフ:
- エフェクト追跡が「推移的依存すべて」に及ぶため、深い依存木の解析コストがかかる
- `let mut` の外部参照 (EC-7) はエフェクトシステム v1 では検出できない — ADR-0021 の Effect Handler 導入まで保守的に impure 扱いにするか、既知の制限として文書化する必要がある
- キャッシュストアの管理 (GC、サイズ制限) の実装が必要
- ユーザーが「キャッシュされているからバグを見逃した」と感じるリスク — `--no-cache` の存在を明示すべき
