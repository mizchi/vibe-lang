# xsh eval workflow

`xsh eval` は、式を逐次評価しながらローカル状態を積み上げ、最後に `--export` で `.xsh` として確定するためのコマンド。

## Usage

```bash
xsh eval \
  [--db <path>] \
  [--include <path-or-alias>]... \
  [--inspect-scope] \
  [--assert <name>:<signature>]... \
  [--test-for <symbol>] \
  [--export <path>] \
  <expr...>
```

`<expr...>` を省略できるのは次の場合:

- `--export` を指定したとき
- `--inspect-scope` を指定したとき
- `--assert` を1つ以上指定したとき

`--test-for` は `<expr...>` 必須。

## オプション

- `--db <path>`
  - 評価状態の保存先 DB を明示する。
  - 未指定時は最寄り workspace の scratch namespace DB を使う。
- `--include <path-or-alias>`
  - 評価前に include source をロードして評価する。
  - `xsh/std@0.1.0.xdb` 形式の alias や `bit:` プレフィックスをサポート。
- `--inspect-scope`
  - 現在スコープの symbol/type/hash を JSON で出力する。
- `--assert <name>:<signature>`
  - 現在スコープで `name` の型シグネチャが一致するか検証する。
  - 不一致/未定義なら `eval` はエラー終了。
- `--test-for <symbol>`
  - `<expr...>` を「本体DBではなくテスト sidecar」に追記する。
  - テストコードを DAG 外に保持し、関数単位で積み重ねる用途。
- `--export <path>`
  - 現在の本体DBソースをそのままファイルへ書き出す。

## inspect-scope 出力

`--inspect-scope` は次の JSON を返す。

```json
{
  "ok": true,
  "symbols": [
    {
      "name": "inc",
      "kind": "function",
      "signature": "(x: Int) -> Int",
      "path": "/abs/path/to/tmp1.db",
      "hash": "...",
      "short_hash": "..."
    }
  ]
}
```

## test-for の保存先（DAG外）

`--test-for <symbol>` で渡した `<expr...>` は以下へ追記される。

- DB が `tmp1.db` の場合: `tmp1.tests/<symbol>_test.xsh`
- DB が `/work/tmp1.db` の場合: `/work/tmp1.tests/<symbol>_test.xsh`

この sidecar は本体DB (`tmp1.db`) に混ざらない。
そのため `--export` の出力にも混ざらない。

## 典型フロー

### 1) 通常の積み上げ

```bash
xsh eval --db tmp1.db 'let base = 10'
xsh eval --db tmp1.db 'let inc = (x: Int) -> Int { x + base }'
xsh eval --db tmp1.db 'let answer = inc(2)'
xsh eval --db tmp1.db 'export { answer }'
xsh eval --db tmp1.db --export main.xsh
```

### 2) 型検証しながら進める

```bash
xsh eval --db tmp1.db --assert 'base:Int' --assert 'inc:(x: Int) -> Int'
xsh eval --db tmp1.db --inspect-scope
```

### 3) テストを関数単位で外出し蓄積

```bash
xsh eval --db tmp1.db --test-for add_base \
  'test "add_base/one" { assert(add_base(1) == 11) }'

xsh eval --db tmp1.db --test-for add_base \
  'test "add_base/two" { assert(add_base(2) == 12) }'
```

## 注意点

- `--test-for` は式を評価はするが、本体DBには追記しない。
- 本体DBが空のまま `--export` すると `eval: no source to export` になる。
- `--assert` の構文は `name:signature` 固定（コロン必須）。
