# selfhost check parity snapshot

`host (vibe check)` と `selfhost checker (vibe_check_wasi)` の診断差分を、
allowlist 付き snapshot として固定する。

## Files

- `cases.txt`: 比較対象ファイル一覧（repo root からの相対パス）
- `allowed_diff_patterns.txt`: 許容差分ルール
  - format: `<scope>:<regex>`
  - scope: `host`, `self`, `meta`
- `cases/*.vibe`: parity の回帰固定用 fixture

## Commands

```bash
# gate 実行（snapshot 一致 + unexpected diff 0）
just test-selfhost-check-parity

# snapshot 更新
VIBE_CHECK_PARITY_UPDATE=1 just test-selfhost-check-parity
```
