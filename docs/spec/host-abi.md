# vibe 生成物のホスト ABI 契約 (host-abi)

> 目的: `vibe build` が出力する `.wasm` を「どんなホストが・何を満たせば実行できるか」
> を確定させる。実測（素の `wasmtime` + import セクションのダンプ）で裏取りした内容。

## TL;DR（確定事項）

- 生成物は **core wasm（linear memory）**。**exception-handling proposal が必須**。
- ホストが満たすべき import 面 =
  **`wasi_snapshot_preview1::fd_write`（常時）＋ プログラムが使ったエフェクトに対応する `vibe::*`**。
- **pure / compute なプログラムは、任意の WASI Preview1 ホスト（＋exceptions）で動く** —
  実測: 素の `wasmtime run -W exceptions=y pure.wasm` が `5` を出力。
- **エフェクトを使う生成物は `vibe::*` host ABI を実装したホストが必要**（現状は `viberun`）。
  標準 WASI だけのホストでは `unknown import: vibe::fs_read_file` で instantiate に失敗する（実測）。
- したがって **「IO は wasip3 前提」はデフォルトの linear path には当てはまらない**。
  デフォルトは *Preview1 fd_write ＋ 独自 `vibe::*`*。wasip3 は別系統（component path）の到達目標。

## 1. 生成物の形（artifact shape）

| 項目 | 値 |
|---|---|
| module 種別 | core wasm、linear memory（component ではない）|
| 必須 proposal | **exception-handling**（tag section ＋ try/throw）|
| exports | `_start`（WASI command entry）, `main`, `memory`, `__heap_ptr`(global i32 mut), `error`(exception **tag**) |

`_start` は結果を `fd_write` で stdout に出すため、**出力の有無に関わらず全プログラムが `fd_write` を import する**。

## 2. import 契約（ホストが提供すべき面）

### 2.1 常時必要

- `wasi_snapshot_preview1::fd_write` — stdout/stderr（結果出力・panic）。標準 WASI Preview1。

### 2.2 エフェクト別 `vibe::*`（独自 host module）

値表現は **vibe tagged i64**。packed string / bytes は引数 i64 が linear memory 上の領域を指し、
ホストは export された `memory` 経由で読み書きする（エンコードは runtime / `vibe_read_packed_str` 参照）。

| effect | import | signature | 意味 |
|---|---|---|---|
| `Fs` | `vibe::fs_read_file` | `(path: i64) -> i64` | ファイル読込（戻り値は packed string）|
| `Fs` | `vibe::fs_write_file` | `(path: i64, content: i64) -> ()` | テキスト書込 |
| `Fs` | `vibe::fs_publish_immutable_text` | `(path: i64, content: i64) -> i64` | immutable text publication（tagged Bool） |
| `Fs` | `vibe::fs_write_bytes` | `(path: i64, bytes: i64) -> ()` | バイト書込 |
| `Fs` | `vibe::fs_exists` | `(path: i64) -> i64` | 真偽（tagged）|
| `Fs` | `vibe::fs_stat_token` | `(path: i64) -> i64` | stat トークン |
| debug | `vibe::dbg_line` | `(file_id: i32, line: i32) -> ()` | `--break` ビルドのみ |
| debug | `vibe::dbg_break` | `() -> ()` | `--break` ビルドのみ |

注:
- **Process / Shell / Http エフェクトは現行 runner の `vibe::*` には未実装**。これらを使う
  プログラムを動かすには ABI 拡張（`vibe::proc_*` 等）か component path が要る。
- `Fs::publish_immutable_text(path, content) -> Bool with Fs` は final path が
  不在のときだけ exact UTF-8 bytes を atomically publish する。既存 regular file の
  raw bytes が同じなら `true`、異なれば `false`。losing writer は overwrite せず、
  I/O・unsupported filesystem・symlink/nonregular target は fail closed。official
  Node/Rust runners use an exclusive same-directory temp followed by atomic hard-link
  (no-replace); temp cleanup is best effort.
- `__moonbit_fs_unstable::*` / `__moonbit_sys_unstable::*` / `spectest::*` は
  **コンパイラ wasm（`vibe-cli.wasm`）専用**の externref ベース runtime であり、
  **ユーザ生成物の import には現れない**。混同しないこと。

## 3. 移植性ティア（いずれも実測済み）

- **Tier 0 — pure / compute**: import は `fd_write` のみ。
  任意の WASI Preview1 ＋ exceptions ホストで動く（wasmtime / wasmer / Node `node:wasi` /
  ブラウザの WASI shim 等）。
  実測: `wasmtime run -W exceptions=y pure.wasm` → `5`（`add(2,3)`）。
- **Tier 1 — effectful**: 上記に加え `vibe::*` が必要。vibe ABI を実装したホストに限る。
  実測: 素の wasmtime で `unknown import: vibe::fs_read_file`。

つまり **claim「生成物は任意の環境で動く .wasm」は Tier 0 では真**、
**Tier 1 では「vibe host ABI を満たすホスト」という条件付きで真**。

## 4. wasip3 との関係（前提の整理）

- **デフォルト linear path**（`vibe build` / `viberun`）: Preview1 `fd_write` ＋ 独自 `vibe::*`。
  **wasip3 ではない**。
- **component path**（`lib/@vibe/compiler/component_codegen.vibe`）: canonical ABI（`cabi_realloc`）＋
  preview1 adapter で WASI component 化。標準 I/O を `wasi:io`（preview2）→ p3 async に寄せるのが
  到達目標（[wasi-p3-async.md](./wasi-p3-async.md), [decisions.md](./decisions.md)）。
- よって「IO を wasip3 前提にする」のは **component path の方針**であり、
  core path のエフェクトを wasip3 に載せ替えるには `vibe::fs_*` →
  `wasi:filesystem`/`wasi:cli` へのマッピング adapter が別途必要。

## 5. 任意ホストで動かす実装ガイド

エフェクト付き生成物を任意環境（JS / Rust / Go / …）で動かす最小手順:

1. wasm 実行時に **exceptions proposal を有効化**する。
2. `wasi_snapshot_preview1::fd_write` を提供（最低限 stdout を書ければよい）。
3. プログラムが使う **`vibe::*`（§2.2）だけ**を実装する。
   値は tagged-i64 ＋ export された `memory` から packed string/bytes を読む。
4. `_start` を呼ぶ（または `main` を直接 invoke）。

この 4 点が「契約」。これを満たすホストは viberun と等価に生成物を実行できる。

## CI enforcement

この契約は `scripts/test_host_abi.js`（cli-install ワークフロー）が **スナップショットとして固定**する:
pure 生成物の import が `wasi_snapshot_preview1::fd_write` のみであること、exceptions タグを
export すること、Fs エフェクトが `vibe::fs_*` に落ちること（`wasi:*` / `__moonbit_*` でないこと）を
ビルドして検証する。ホストに要求する面が変わるとここで落ちる。

## 付録: 契約の再現手順

```bash
vibe build pure.vibe -o pure.wasm        # Tier 0
vibe build fs_prog.vibe -o fs.wasm       # Tier 1 (Fs effect)

# import 面の確認（module::field を列挙する任意のツールで）
wasm-tools print pure.wasm | grep '(import'   # => wasi_snapshot_preview1 "fd_write"
wasm-tools print fs.wasm   | grep '(import'   # => + vibe "fs_read_file" 等

# Tier 0 は素の wasmtime で動く
wasmtime run -W exceptions=y pure.wasm        # => 5

# Tier 1 は vibe host ABI が無いと落ちる
wasmtime run -W exceptions=y fs.wasm          # => unknown import: vibe::fs_read_file
```
