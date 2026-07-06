# 0.1.0 Usability Sign-off

## Goal

CI gate を最終確認に回す前に、0.1.0 の primary supported surface を人間が実際に触って
「とりあえず動く」だけでなく「安定して使える」ことを確認する。

primary supported surface は [ADR-0033](../adr.md) に従う。

- canonical artifact: `_build/dist/selfhost_compiler.wasm`
- canonical build path: `just build-selfhost-dist`
- canonical entry: `vibe/cli/selfhost_entry.vibe`
- primary supported surface:
  - `vibe shell`
  - `vibe check`
  - `vibe run`
  - `vibe build`
  - selfhost dist の sample compile/run

GC backend, advanced effect/WIT mapping, 大型 `wasm_opt` workload は 0.1.0 sign-off の主対象に含めない。

## Rule

不満点を見つけたら、その場で次の順に処理する。

1. 現象を 1 行で記録する
2. `cli_e2e_wbtest` / smoke script / targeted test のどれかに Red を追加する
3. 修正する
4. 同じ手順をもう一度手で触る

CI gate は発見の場ではなく、手元で詰めた導線の再現確認として使う。

## Scenarios

### 1. shell

目的:

- fresh start が既定である
- prompt と出力が混ざらない
- `let` / `import` / function / `Array` / `Map` が素直に使える
- エラーメッセージが次の入力を妨げない

手順:

1. `vibe shell --no-prompt`
2. `let x = 1 + 1`
3. `let inc = (n: Int) -> Int { n + x }`
4. `inc(40)`
5. `["a", "b"]`
6. `map { a: 1, b: 2 }`
7. `import ./helper.vibe { inc }` のような late import
8. 型エラー 1 件

合格条件:

- 各 step が 1 回の入力で完了する
- `duplicate declaration` など前回 session 汚染がない
- `last:` 行と prompt が混ざらない
- recover 不能な session 崩壊がない

### 2. check

目的:

- 単一 file と import 付き file の check が自然に使える
- 失敗時の span / message が修正に使える

手順:

1. 小さい success case を `vibe check`
2. import 付き success case を `vibe check`
3. 小さい failure case を `vibe check`

合格条件:

- success/failure が即座に判断できる
- failure case に path と span が出る

### 3. run

目的:

- 小さい script が cold/hot ともに現実的な待ち時間で動く
- import 付きでも普通に動く

手順:

1. 単一 file の `vibe run`
2. 同じ file の hot run
3. import 付き file の `vibe run`
4. 同じ file の hot run

合格条件:

- cold/hot の差が体感できる
- 出力/終了コードが期待通り
- one-shot 既定経路が安定し、session worker opt-in でも不安定にならない

### 4. build

目的:

- release/debug build が primary workflow として成立する
- 生成 wasm をそのまま実行できる

手順:

1. 単一 file を `vibe build`
2. 生成 wasm を `wasmtime` で実行
3. 同じ source を `vibe build --debug`
4. linked build 生成物を `wasmtime` で実行

合格条件:

- build path が迷わない
- release/debug ともに artifact が壊れていない

### 5. selfhost dist

目的:

- 配布 selfhost compiler wasm が最小ユースケースを処理できる

手順:

1. `just build-selfhost-dist`
2. dist wasm で sample compile
3. 生成 wasm を実行

合格条件:

- cold build が通る
- sample compile/run が 1 コマンド列で再現できる

## Exit Criteria

次に `just release-selfhost-gates` へ進んでよい条件は次の通り。

- 上の 5 scenario が少なくとも 1 周 pass
- 見つかった defect が TODO / test / fix に落ちている
- 0.1.0 の supported surface 外の課題を sign-off blocker に混ぜていない

## Current Focus

最初の 1 周では、広い examples 網羅ではなく次の観点を優先する。

- shell の対話 UX
- check/run/build の最小成功導線
- selfhost dist の cold build 再現

## Pass 1 Findings (2026-03-26)

### Confirmed Good

- `shell` の基本導線
  - `let`
  - 関数束縛
  - 関数呼び出し
  - `Array`
  - `Map`
- `check` の success/failure 表示
  - failure 時に path / span / expected / actual が出る
- `run/build` の primary path
  - `vibe run` は final top-level pure expression を返す
  - `vibe build` / `vibe build --debug` の生成 wasm は実行できる
- selfhost dist sample compile/run
  - `scripts/build_selfhost_dist.sh` は raw fallback つきで通る

### Found Defects

1. compiled shell の late import が実使用で失敗した
   - 再現:
     - `cd /tmp/...`
     - `import ./helper.vibe { inc }`
   - 原因:
     compiled REPL の temp source が workspace root 直下ではなく別ディレクトリに置かれ、
     relative import が user source ではなく temp file 基準で解決された
   - 対応:
     temp source を workspace root 直下の hidden file に戻し、late import を修正した
   - 現状:
     fix 済み。`import ./helper.vibe { inc }` -> `inc(41)` は compiled shell で通る。

2. latest source から native `cmd/vibe` を再 build できなかった
   - `moon build --target native src/cmd/vibe`
   - cleanup 後の wrapper/API 参照ずれで native path が壊れている
   - 対応:
     native-only path が参照する thin wrapper を必要最小限だけ復旧した
   - 現状:
     fix 済み。`moon build --target native src/cmd/vibe` は通る。

3. `run/build` の entrypoint 契約が docs 上で揺れている
   - source-level は final top-level pure expression
   - generated wasm ABI は `_start`
   - 対応:
     `docs/language-tour/*` を source-level contract に合わせて更新した
   - 現状:
     docs fix 済み。`vibe run` は final top-level pure expression、`vibe build` の wasm は `_start` を export する。

4. stale な `index.lock` が残っている workspace では `run/build` が invalid JSON で落ちる
   - fresh workspace では再現しない
   - 旧壊れた `index.lock` の migration/recovery として扱う
   - 対応:
     自動回復ではなく、壊れた lock path と `vibe update-lock <entry>` を含む actionable error を返す
   - 現状:
     fix 済み。stale lock でも原因と対処は即分かる。

5. selfhost dist は `wasm-opt` parse failure で止まっていた
   - raw wasm は `wasm-tools validate` を通る
   - 問題は optimizer 側だけだった
   - 対応:
     `scripts/build_selfhost_dist.sh` は `wasm-opt` failure 時に raw output へフォールバックする
   - 現状:
     fix 済み。default path で sample compile/run まで通る。

## 0.1.0 Migration Note: Result-first error surface

0.1.0 では、library / package API の canonical なエラー表現は `Result[T, E]` とする。
`throw` / `handle { ... } with Error { ... }` / `?` は廃止しないが、adapter boundary
（CLI / HTTP / FFI / test helper）で使う構文として扱う。

移行方針:

- pipeline core は `Result::and_then` / `Result::map_ok` / `Result::map_err` で組む
- boundary でだけ `throw` / `handle ... with Error` / project-local unwrap を使う
- `?` は 0.1.0 では boundary sugar のまま維持する
- package facade では `Result` を返す API を優先し、`parse_throw` のような throw-style helper は public surface に含めない

JSON package の基準:

- canonical: `parse(String) -> Result[(Json, Int), String]`
- non-canonical: `parse_throw`, `parse_ok`, `parse_err`

利用者向けの書き換え目安:

1. `parse_ok(src)` / `parse_err(src)` を見つけたら `match parse(src) { ... }` へ寄せる
2. `throw` を返していた public helper は `Result::Err(...)` を返す形へ変える
3. `handle { ... } with Error { ... }` は module core ではなく adapter edge に寄せる
