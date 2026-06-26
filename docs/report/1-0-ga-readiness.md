# 1.0 GA Readiness Sign-off

> 作成: 2026-06-25 / 対象: `docs/release-roadmap.md` の 4 テーマ
> (install / module / debugger / LSP) と M1–M4 マイルストーン。
> 仕様凍結は [spec/1.0-freeze.md](../spec/1.0-freeze.md) (ADR-0057)。

## Goal

0.1.0 の言語コア sign-off ([0-1-0-usability-signoff.md](0-1-0-usability-signoff.md))
の上に積んだ「リリース体験」4 テーマが、外部ユーザーが install → 開発 →
配布まで一通り回せる水準に達したかを確認し、1.0 GA タグの判断材料にする。

GA の content gate は (1) 4 テーマの実装、(2) 言語仕様 freeze、(3) docs 完備。
本ドキュメントはその達成状況を一覧化する。残る outward-facing アクション
(1.0 タグ / version bump / main への land) は本ドキュメントの対象外。

## マイルストーン達成状況

| M | 内容 | 状態 |
| --- | --- | --- |
| M1 | install + module 配布凍結 | ✅ 達成 |
| M2 | LSP MVP + debugger P0 | ✅ 達成 |
| M3 | LSP 補完/リファクタ + DAP step | ✅ 達成 |
| M4 | 統合 + 仕様 freeze + docs 完備 | ✅ content gate 達成（sign-off タグ待ち） |

## テーマ別の達成と検証

### テーマ1: install 配布

- canonical: 独自 wasmtime runner (`moonrun_wt`) + portable compiler wasm
  (`vibe-cli.wasm`)、install 時に host 固有 `.cwasm` AOT (ADR-0056)。
- `vibe self update --cli-wasm` で compiler を runner と独立更新。
- 検証: `scripts/test_vibe_cli_install.sh`(smoke)、`scripts/install.sh`、
  CI `cli-install.yml`(ubuntu/macos、wasmtime CLI pinned v45.0.2)。
- docs: [install.md](../install.md)。

### テーマ2: module 配布

- git/URL 分散 (Deno/Go 風)、中央 registry なし、content hash で lock。
- `vibe add` / `fetch [--frozen]` / `verify`、transitive 解決、semver 制約
  (`^`/`~`/`>=`/`x`/`*`)。
- docs: [module-system.md](../module-system.md)。

### テーマ3: debugger（P0–P4 + 3-D 完了）

| フェーズ | 内容 | 検証 |
| --- | --- | --- |
| P0 | trap → source-line (name section + funcmap) | `test_name_section.sh`, `test_vibe_trace.sh` |
| P1 | function breakpoint (`--break <fn>`) | `test_vibe_break.sh` 5/5 |
| P2 | 引数検査 | `test_vibe_break_args.sh` 6/6 |
| P3 | step 実行 (s/n/o/c/q) | `test_vibe_step.sh` 14/14 |
| P4 | 名前付きローカル検査 (`vibe.dbgnames`) | `test_vibe_break_args.sh`（`args: [x=20]`） |
| 行 | `--break <file>:<line>`（関数宣言行） | `test_vibe_break_line.sh` 9/9 |
| 任意行 | `--break <file>:<line>`（関数内任意行 + 行 step、`vibe::dbg_line`） | `test_vibe_break_interior.sh` 6/6 |
| 3-D | VS Code DAP adapter | `test_vibe_dap.js` 25/25 |

- docs: [editor-and-debugging.md](../editor-and-debugging.md)。
- 関数内**任意行** breakpoint / 行 step は着地（break-mode codegen の
  `vibe::dbg_line` 計装、既定 codegen は byte-identical で fixpoint 維持）。
  v1 scope = 単一ファイル entry。**post-GA**: multi-file entry の関数内行 break
  （文単位の source provenance が前提）。

### テーマ4: LSP

- diagnostics（parser error-recovery で全 top-level 構文エラー + located 型
  エラー）、typed hover（識別子 + **call-site / field-access** ノード）、
  symbols、definition、scope 精度の references / rename、completion、
  signatureHelp、error-recovery。
- span foundation: `EIdent`/`ECall`/`EDot` に source offset、per-node 型テーブル。
- 検証: `test_vibe_lsp.js` 14/14、`test_vibe_type_at.sh` 7/7、
  `test_located_diagnostics.sh` 10/10、`test_vibe_binding_at.sh`、
  `test_vibe_diagnostics.sh`。
- docs: [install.md](../install.md#editor-support-lsp),
  [editor-and-debugging.md](../editor-and-debugging.md)。
- **残（minor/post-GA）**: シンボル span の JSON 露出、診断 range の AST 化。

## 横断ゲート

- **selfhost fixpoint**: `scripts/selfhost_only_gate.sh` → stage2==stage3、
  bundle/module-source sync、13 regression。本セッションの全 compiler 変更
  (ECall/EDot offset、hover、診断 consumer) で green を維持。
- デバッグ instrumentation は全て **opt-in**（`VIBE_DEBUG_BREAK`/`VIBE_TRACE_OUT`/
  `VIBE_COVERAGE` 等）。既定 self-compile は byte-identical で fixpoint を壊さない。

## 仕様 freeze

[spec/1.0-freeze.md](../spec/1.0-freeze.md) (ADR-0057) で 1.0 の stable surface
(言語コア / prelude / CLI / フォーマット) と SemVer 2.0.0 ポリシー、対象外の
unstable surface (async / component model / capability / SIMD / span-arc 残 /
incremental / wasm-gc gap) を確定。

## 判定

4 テーマの実装・仕様 freeze・docs の **content gate は達成**。残るのは:

1. **1.0 タグ / version bump** — outward-facing、リリース判断（人手）。
2. **branch → main の land** — 本セッションの作業（wasmtime CI 修正、freeze、
   docs、DAP P4、span-arc step2–5）を main へ取り込む PR（明示要求時）。
3. **post-GA**: 関数内任意行 debug、LSP span JSON / 診断 range AST 化。

(1)(2) は実装ゲートではなくリリース運用判断のため、本 readiness では「実装側
GA-ready」と結論する。
