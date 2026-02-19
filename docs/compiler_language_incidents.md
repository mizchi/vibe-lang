# Compiler / Language Incident Log

このドキュメントは、実際に遭遇した不具合を

- コンパイラ実装側の問題
- `.vibe` 記法運用側の問題

に分けて、再発防止の参照先をまとめる。

## 2026-02 incidents

### C-001: `value_type_name` の非網羅で `build-wasm-vibe` が失敗

- 分類: コンパイラ実装側
- 症状:
  - `just build-wasm-vibe` で `src/lib/lib.mbt` の `partial_match` エラー
  - `@core.Value::PromptText(_)` 追加後に `value_type_name` が未更新
- 対応:
  - `src/lib/lib.mbt` に `PromptText` 分岐を追加
  - `src/lib/lib_wbtest.mbt` に `eval_report_json` の `value_type=PromptText` 回帰テストを追加
- 関連 TODO:
  - `TODO.md` の `Compiler / Language Incident Follow-up (2026-02)`

### L-001: 旧 `import { ... } from ...` 記法の混入

- 分類: `.vibe` 記法運用側
- 症状:
  - parser が `UnexpectedToken(... got=\"import\")` で停止
  - エラーメッセージは `use <module-ref> { ... }` 形式への移行を示す
- 対応:
  - `docs/module-system.md` に移行例を明記
  - `scripts/test_codegen_unsupported.sh` に旧記法 parse error の回帰テストを追加
- 関連 TODO:
  - bundle-size の `unsupported` baseline と現行構文 case の分離

### L-002: bundle-size と syntax 回帰の責務混在

- 分類: `.vibe` 記法運用側 / ベンチ運用
- 症状:
  - `unsupported` baseline を含む case と通常 size regression が同じ `bench/importers` で評価される
  - syntax 変更が size regression と同じ失敗として見える
- 対応方針:
  - `cases.txt` と budget を「syntax unsupported 検証」と「size budget 検証」に分離
  - `bench/bundle_size/README.md` に運用ルールを明文化
- 関連 TODO:
  - `TODO.md` の未完了項目を参照
