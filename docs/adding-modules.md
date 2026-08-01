# 新しいモジュールを足す・直す — メンテナンスの手引き

> Status: 2026-07-04, #741/#742/#745 の作業で確立した運用の成文化
> (境界の綴りを `index.vpkg` に更新: 2026-08-01, #1269)。
> 境界・可視性・pin の規則は [module-system-oracle.md の「現行モデル」節](module-system-oracle.md#現行モデル-canonical--ここが唯一の現行記述)
> が正本。設計の経緯は [module-system-v2.md](module-system-v2.md) (ADR-0063/0064)。
> selfhost-only 前提 ([archive/moonbit-retirement.md](archive/moonbit-retirement.md))。

このリポジトリのライブラリは「テストが allowlist に載っていて、battery が
回っている」ものだけが生きている。allowlist の外にあるコードはコンパイラで
一度もコンパイルされず、host 時代の腐敗が溜まる (#742 で json / base64 /
fmt から発掘された rot がその実例)。**新しいモジュールは必ずテストと
allowlist をセットで足す。**

## 1. どこに置くか

| 置き場所 | 用途 | 例 |
| --- | --- | --- |
| `lib/@vibe/<pkg>/` | 契約パッケージ。`index.vpkg` が境界かつ公開 API (legacy `index.vibei` は境界ではない、ADR-0070)。**境界強制 (#729)**: `index.vpkg` を持つディレクトリの内部ファイルは外部の owner から直接 import できず、契約 (ディレクトリ import) 経由のみ。compiler 本体からも `import ../../../lib/@vibe/<pkg> { ... }` で消費できる (#741, #766) | `lib/@vibe/core` (sha1 / leb128 / list / set / maps, #766), `lib/@vibe/ast` (AST 透明型), `lib/@vibe/parser` (lexer/parser/printer, #753) |
| `lib/@vibe/<domain>/` | 標準ライブラリ層。directory import (`import ../json { ... }`) は `index.vpkg` 契約経由 | `lib/@vibe/json`, `lib/@vibe/module` |
| `lib/@vibex/<pkg>/` | 実験・拡張層 (ADR-0065: @vibex = 仮想実験ユーザー scope)。安定したら `lib/@vibe/` へ昇格 | `lib/@vibex/fmt`, `lib/@vibex/regexp` |
| `lib/@<user>/<pkg>/` | コンパイラ非関連の実ユーザー scope パッケージ (in-repo に置けるのは repo owner が支配する scope のみ) | `lib/@mizchi/markdown` |
| `lib/@vibe/compiler/` | compiler 本体のみ。ライブラリを置かない (共有したいものは `lib/@vibe/` に切り出して契約 import する) | — |

新規の再利用可能なデータ構造・アルゴリズムは **`lib/@vibe/core` への追加を
第一候補**にする (moonbitlang/core 方式のドメイン別ファイル + index.vpkg
契約)。

`@scope/name` import の解決順 (ADR-0065, #751): `.vibe/store/` (pin 検証済み)
→ workspace `lib/` → **`VIBE_LIB`** の各 root (`:` 区切りリスト。未設定時は
`$VIBE_HOME/lib`、それも無ければ `~/.vibe/lib`)。lib/ / VIBE_LIB 解決は
dev-mode の便宜で、pin があれば置き場所によらず hash 照合される。
**`VIBE_REQUIRE_PINS=1`** (release/publish の freeze スイッチ; 将来の
`vibe run --freeze` はこれに対応する) では pin なしの lib 解決はエラー。

## 2. 追加の手順

1. **実装**: `<pkg>/foo.vibe` を書く。公開 API は `export`。
   - 文字列添字 `s[i]` は Int (char code)。文字比較は `String::char_code_at`
     + char literal (`'x'`) で書く (#742 の base64/fmt rot の教訓)
   - `r#` raw identifier は printer で再エスケープされるが (#741)、keyword
     名 binding は避けるのが無難
2. **契約 (lib/@vibe の場合)**: `index.vpkg` の先頭に `import ./foo.vibe {}`
   を足し、公開 fn を bodyless 宣言で列挙する。conformance は checker が
   照合する (#729)
3. **テスト**: `<pkg>/foo_test.vibe` を書く。`vibe test` は production
   default (RC) でコンパイルされることに注意 — float / 所有権の RC 特有
   経路も踏まれる (#745 はこれで発見された)。`scripts/unit_test_runner.sh`
   は `examples/`・`lib/`・`fixtures/` 配下の `*_test.vibe` を discover()
   で無条件に全部拾って battery を回す — allowlist ファイルは無い(#1231
   で撤廃)ので、追加の登録手順は不要。generic harness で回せない特殊な
   ファイル(gate 専用の `__DATA__` フィクスチャ、gc-only fixture 等)だけ
   `scripts/unit_test_runner.sh` の `EXCLUDE_PATTERNS` に理由付きで載せる
4. **compiler から消費する場合のみ**: `lib/@vibe/compiler/compiler_sources_manifest.tsv`
   に `vibe_core` group で `../../../lib/@vibe/<pkg>/...` の行を足す。bundle
   への inline / codegen fingerprint への波及は generate_bundle.sh
   が面倒を見る (#741, #766)

## 3. 検証 (commit 前に必ず)

```bash
# 個別テストの素振り (compile + run)
env VIBE_PREOPEN_DIR="$PWD" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  <stage2.wasm> path/to/foo_test.vibe /tmp/t.wasm __no_entry__
env VIBE_PREOPEN_DIR="$PWD" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start /tmp/t.wasm

# 一式 (compiler を触った場合は bundle regen + fixpoint も)
bash scripts/compiler_gate.sh
bash scripts/unit_test_runner.sh
```

compiler 本体 (`lib/@vibe/compiler/`, `lib/@vibe/` の compiler 消費分) を触った
場合は必ず:

```bash
VIBE_REGEN_MODULE_SOURCE=1 \
  VIBE_ADAPTER_MODULE_SOURCE_OUT=lib/@vibe/compiler/_cli_adapter_module_source.vibe \
  bash scripts/generate_bundle.sh
bash scripts/generations.sh build --stage3 --out-dir _build/gen
cmp _build/gen/stage2.wasm _build/gen/stage3.wasm   # fixpoint
```

## 4. よく踏む言語・checker の罠 (2026-07 時点)

- **`Ok`/`Err` は enum ctor**: bare で使うにも `import ../prelude/result.vibe { Result }`
  が要る (型 import が ctor を随伴させる)
- **qualified ctor パターン** `Result::Ok(v) =>` は #742 で対応済み
- **`Type::method` を使うなら import 列に明示する** (`Json::get` など —
  host 時代の暗黙随伴 import は無い)
- **Double の文字列化**: `"\{x}"` は静的に floatish と分かる形 (リテラル /
  float 追跡 local / float 算術 / annotated param) のみ正しい (#744)。素の
  user 関数呼び出し結果は一度 annotated param に通すか `* 1.0` を挟む
- **facade の bare export 禁止**: `export ./file { A }` の後に bare
  `export { A }` を並置しない (FS merge で garbage facade になる、#726/#742)
- **effect handler 越しの深い再帰 perform** は #737 が未解決 — ライブラリは
  builtin 直呼び (Fs::read_file 等) を使う

## 5. 既知の残ギャップ (issue 追跡)

- #737: 深い再帰内 perform + 外側 handler の resume 破壊
- #739: 契約の bodyless type 宣言が型 arity を保持しない
- #740: seed の cold-cache 全体 FS-compile OOB (module_source lane で回避中)
- #534: vibe/types / vibe/parser の compiler からの切り出し (レイアウト整理)
- #415: builtin の 2 backend 共有 registry 化 (新 builtin 追加を 1 箇所に)
