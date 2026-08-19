# ADR-0083: 関数/メソッド識別子の命名規約を snake_case から lowerCamelCase へ

Status: proposed(骨子段階、規模調査のみ完了、Phase 0 未着手)

Date: 2026-07-29

Related: ADR-0081(`Type::method` canonical on-disk form)、#1189(Type::method
naming ratchet lint)、[docs/spec/stable-surface.md](spec/stable-surface.md)(型命名
CamelCase の凍結)、[docs/effect-taxonomy-review.md](effect-taxonomy-review.md)
(本 ADR の発端になった議論)

## Context

現状、vibe は関数/メソッド識別子に一貫して snake_case を使っている
(`CLAUDE.md`: 「variables/functions は snake_case (lowercase only)」)。
`Type::method(recv, args)` 形式の qualified call も例外ではなく、method
部分は snake_case のままである(ADR-0081 が定める canonical on-disk
form、#1189 の ratchet lint(`scripts/lint_method_style_naming.sh`)が
CI で強制)。一方 `docs/spec/stable-surface.md` は型命名だけを明示的に
1.0 の SemVer 保証対象として凍結している(「ユーザー型は CamelCase」)。
関数/メソッドの snake_case 自体はこの凍結リストに明記されていない。

`docs/effect-taxonomy-review.md` の議論で `perform Fs::read_file(...)`
のような effect operation の呼び出し例を書いていたところ、関数名を
lowerCamelCase に統一したいという要望が出た。検討の結果、対象範囲は
effect operation に限らず **vibe 全体の関数/メソッド命名規約**に及ぶ。

pre-1.0 の今のうちに変更する方が、1.0 freeze 後に同じ変更をする(=
SemVer 上の破壊的変更として扱う必要が生じる)よりコストが低い、という
「やるなら今」という時間的制約がある。

### 規模(2026-07-29 時点の概算)

- `lib/` 配下の `fn` 宣言: 7629 件(うち snake_case 複合語 7003 件)
- `Type::method(...)` 形式の呼び出し箇所: 概算 93,000 箇所
- 対象ファイル数: 770 ファイル(コンパイラ自身のソースを含む)

## Decision

命名規約の変更を、性質の異なる**2つの独立した軸**に分解して扱う。

### 軸1: casing(機械的変換)

関数宣言(`fn`)と `Type::method` の method 部分の綴りを、意味を変えず
snake_case → lowerCamelCase へ変換する。

- 対象: 関数宣言、`Type::method` の method 名
- 対象外(現状維持): 型名(CamelCase、`docs/spec/stable-surface.md` で
  既に凍結済み)、enum variant 名(既に CamelCase の慣習)

**未決定として残す論点**: local 変数・`let` 束縛も対象に含めるか。
`CLAUDE.md` は「variables/functions」をひとまとめに snake_case として
おり、関数だけを camelCase にすると変数側との不整合(`let read_file =
...` と `fn readFile()` が混在)が残る可能性がある。この ADR の
Decision セクションを確定させる前に、変数を含めるかどうかの結論を
別途出す必要がある。

### 軸2: 短縮(意味判断・人手のキュレーション)

`read_file` → `read` のような名前の短縮は、casing とは独立した別の
決定である。同じ effect/型の中で別の operation と衝突しないかを名前
ごとに人手で判断する必要があり、機械的に導出できない。

**叩き台の例**(既存 builtin の一部、Fs/Env/Stdout/Socket から):

| 現行(snake_case) | casing のみ | casing + 短縮 | 備考 |
| --- | --- | --- | --- |
| `Env::args_len` | `Env::argsLen` | — | 短縮の必要なし |
| `Env::args_get` | `Env::argsGet` | — | 短縮の必要なし |
| `Stdout::write_stream` | `Stdout::writeStream` | — | 短縮の必要なし |
| `Fs::read_file` | `Fs::readFile` | `Fs::read` | `Fs::readdir` と別語なので衝突しない |
| `Socket::tcp_connect` | `Socket::tcpConnect` | `Socket::connect` | 将来 `Socket::` に udp 系が増えると再衝突しうる — 短縮は慎重に判断する例 |

この表は網羅的ではなく、Phase 0 で全 builtin を対象に監査してから
確定する。

## 移行機構

正規表現によるテキスト置換ではなく、既存の LSP rename 基盤
(`vibe binding-at` が返す binding の全出現箇所、#36 で実装済みの
references/rename handler)を再利用したバッチリネームツールを新規に
作る。

renaming は他の意味論変更と異なり、**コンパイルが通ること自体が正しさの
検証**になる(取りこぼしがあれば `unbound identifier` としてコンパイル
エラーになる)。この性質を活かし、casing 変換は大部分を自動化できる。

## 段階計画

- **Phase 0**: バッチリネームツールの構築。casing 変換ルールの自動生成
  (snake_case → lowerCamelCase は機械的に導出可能)。短縮対象の命名
  テーブルを builtin から着手して人手でキュレーション。
- **Phase 1**: `lib/@vibe/compiler/` 自身を含む `lib/` 全体を一括
  リネーム。renaming は新しい構文を導入するものではないため
  bootstrap bump は不要。ただし通常の compiler-source 変更と同様、
  `stage2 == stage3` fixpoint の確認は必須。
- **Phase 2**: `docs/cheatsheet.md`、`docs/tutorial/*.vibe.md`、
  `docs/adr.md` 内のコード片、generated bundle の再生成。
- **Phase 3**: `scripts/lint_method_style_naming.sh` /
  `scripts/method_style_naming_allowlist.txt` の再検証。この lint は
  casing 非依存の構造チェック(free fn と `Type::method` のペアリング
  存在を見るだけ)なので、変換後も pairing が保たれているかどうかの
  回帰確認としてそのまま使える。

## Rejected / deferred alternatives

- **現状維持**: ユーザーの明示的な意向により却下。
- **effect operation 名だけを camelCase にする(全体規約は変えない)**:
  当初検討した小さい scope。ユーザーが「vibe 全体」を選んだため不採用
  だが、影響範囲を絞った代替案として記録しておく。
- **snake_case/camelCase の両対応による緩やかな移行期間**(parser が
  両方を受理し、新規コードだけ camelCase を推奨する): renaming が
  コンパイラ検証可能な機械的変換であることを踏まえると、この複雑さに
  見合わないと判断し、一括カットオーバーを推奨する。

## Open Questions

- local 変数・`let` 束縛を対象に含めるか(軸1参照)。
- 短縮の命名テーブルを誰が/どの基準でキュレーションするか。
- 一括カットオーバーのタイミング(1.0 freeze 前に完了させるべき、という
  前提を確認する必要がある)。
- 外部消費者(vibe の stdlib/API に依存する既存コード)への影響範囲
  — pre-1.0 のため許容範囲内という前提だが、確認が必要。

## 参照した実装箇所

- `CLAUDE.md` — 現行の snake_case 命名規約の記述。
- `scripts/lint_method_style_naming.sh`,
  `scripts/method_style_naming_allowlist.txt` — #1189 の ratchet lint。
- `docs/spec/stable-surface.md`, `docs/spec/decisions.md` — 型命名の凍結
  ポリシー。
- `lib/@vibe/compiler/checker/builtins_fs.vibe`,
  `builtins_system.vibe`, `builtins_net.vibe` — 短縮テーブル叩き台の
  出典。
- `vibe binding-at` / LSP references・rename handler — 移行機構の
  再利用対象。
