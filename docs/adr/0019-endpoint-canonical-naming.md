# ADR-0019: endpoint 横断シンボル衝突を避ける canonical naming

- Date: 2026-02-25
- Status: accepted

## Context

`vibe/io`, `vibe/socket`, `vibe/http`, `vibe/process`, `vibe/compiler`,
`vibe/json`, `vibe/base64`, `vibe/sha1`, `vibe/shell`, `vibe/fs` を同時 import すると、以下のような
同名シンボル衝突が発生しやすい。

- `read` (`io.read` / `socket.read`)
- `close` (`socket.close` / `http.close`)
- `run` (`process.run` / parser runtime helpers)
- `parse` (`compiler.parse` / `json.parse`)
- `print` / `println` (`io` / `shell`)
- `exists` (`fs` / `shell`)

現状は `import ... { read as io_read }` など `as` で回避できるが、呼び出し側に
毎回 rename を強制すると API 利用体験が不安定になる。

## Decision

endpoint 直下の `index.vibe` は、衝突しやすい名前に対して prefix 付き canonical 名を
常に公開する。

命名ルール:

1. 形式は `domain_verb` または `domain_verb_qualifier`
2. `domain` は endpoint 名（`io`, `socket`, `http`, `process`, `compiler`, `json`, `fs`, `shell`）
3. 旧名（短名）は互換のため維持し、段階的移行対象とする
4. 新規 endpoint で衝突しやすい verb を公開する場合も同ルールを適用する

`Type::method` 形式の member API（例: `String::starts_with`）は本 ADR の対象外。
そちらは型名で namespace が分離されるため、既存規約を維持する。

## Initial rollout (2026-02-25)

以下の canonical alias を `index.vibe` に追加した。

| Endpoint | Added canonical names |
|---|---|
| `vibe/io` | `io_read`, `io_print`, `io_println`, `io_read_char`, `io_read_line`, `io_write_char` |
| `vibe/socket` | `socket_connect`, `socket_read`, `socket_write`, `socket_close` |
| `vibe/http` | `http_close`, `http_accept`, `http_listen`, `http_request`, `http_respond`, `http_request_*`, `http_response_*`, `http_request_with`, `http_respond_with` |
| `vibe/process` | `process_run`, `process_run_lines`, `process_run_line`, `process_run_text` |
| `vibe/compiler` | `compiler_lex`, `compiler_parse*`, `compiler_print_*` |
| `vibe/json` | `json_parse`, `json_parse_ok`, `json_parse_err`, `json_stringify` |
| `vibe/base64` | `base64_encode`, `base64_decode` |
| `vibe/sha1` | `sha1_hash` |
| `vibe/fs` | `fs_exists`, `fs_read_file`, `fs_write_file` |
| `vibe/shell` | `shell_print`, `shell_println`, `shell_read_line`, `shell_exists`, `shell_is_dir`, `shell_is_file`, `shell_write_file` |

## Consequences

- 良い影響:
  - `as` なしでも衝突を回避した import が可能になる
  - endpoint を跨ぐ合成（`process_run |> json_parse` など）が読みやすくなる
  - 新規 API 追加時の命名判断が一貫する
- トレードオフ:
  - 同機能に短名と canonical 名が併存する期間が生まれる
  - `index.vibe` の公開シンボル数が増える

## Follow-up

- alias 利用率を見て短名の deprecate 方針を決める（互換期間は別 ADR で定義）
- `normalize` に短名 -> canonical 名変換候補を追加するかを検討する
