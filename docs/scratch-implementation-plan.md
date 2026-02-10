# Scratch Workflow Implementation Plan

`docs/scratch-workflow.md` の具体実装計画。

## スコープ

- default eval/repl を scratch namespace に寄せる
- symbol 一覧と index inclusion 判定を CLI で確認可能にする
- scratch 履歴の reset を CLI で提供する

## Phase 1 (実装中)

### 1. default sink を scratch に変更

- [x] `xsh eval`:
  - `--db` 未指定時に最寄り workspace の scratch db を使う
  - `--export` は `--db` なしでも許可
- [x] `xsh repl` / `xsh repl-stdin` / `xsh repl-wasi`:
  - 起動時に scratch db を復元
  - 成功した入力を scratch db に追記
- [x] `index.xdb`:
  - `active_namespace`
  - `namespaces.<name>.db_path`
  - `namespaces.<name>.updated_at`
  を最低限維持

実装メモ:

- `XSH_SCRATCH_DB_PATH` をテスト/開発向け override として受け付ける。

### 2. symbol 一覧 CLI

- [x] `xsh symbols [--json] <entry>`
  - `managed` / `scratch-only` を表示
  - `kind/name/path#short-hash` を表示

現在の判定:

- `managed`: `index.lock` の `module_refs` に `<path>#<name>` がある
- それ以外: `scratch-only`

### 3. history reset CLI

- [x] `xsh history reset`
  - scratch db ファイル削除
- [x] `xsh history reset --hard`
  - 追加で `index.xdb` 内 namespace head 系を空文字にリセット

## Phase 2 (次)

### 1. write_file selector

- [x] `xsh write_file [--entry file] [--no-deps] [--dry-run] [--json] <selector> <out-file>`
  - `name`, `name#hash`, `#hash` に対応
  - `name` は `scratch -> index` 優先で解決
  - 既定は module source を materialize、`--no-deps` で selector span のみ書き出し
  - `--dry-run` で selector 解決結果のみ確認可能（出力ファイルは書かない）
  - `--json` で解決結果を JSON で出力

### 2. symbol status 強化

- [x] `shadowed` 判定
- [x] `--json` 出力
- [x] origin（`index` / `scratch`）表示

## Phase 3 (将来)

- [ ] namespace head の merge/rebase
- [ ] distributed refs に namespace head 同期を追加
- [ ] lock を `index.xdb` 主体に一本化（`index.lock` 廃止）
