# vibec.wasm — コンパイラコアのコンポーネント分離 (#1107 Phase 5 / #857)

vibe コンパイラの「純粋な compile 面」だけを component model で切り出した
成果物 `vibec.component.wasm` の設計と現状。#857 の「ランナー非依存の
embedding 形」の実装形にあたる。

## 成果物とビルド

```bash
bash scripts/build_vibec.sh            # _build/vibec/{vibec.core.wasm, vibec.component.wasm, vibec.wit}
bash scripts/vibec_browser_poc.sh      # 上記 + jco transpile + in-memory compile→run PoC
```

- **core**: `lib/@vibe/compiler/cli_direct_component_entry.vibe` を
  `__no_entry__` (library mode) でコンパイルしたもの。表面は
  `compile_cli_request(source, request) -> String` — ソースは
  NUL 区切り (path, source) ペアの hex payload で**インライン**に渡り、
  出力 wasm は hex チャンクで返る。effect row が Env/Fs を含まないため、
  compile 経路は動的にホスト import に到達しない。
- **component 化**: `scripts/vibec_componentize.vibex`(vibe-opt と同じ
  script-tool パターン)が
  `comp_emit_component_wasm_string_handler_stubbed` で canonical ABI の
  `compile: func(source: string, request: string) -> string` に lift する。
  library ビルドの兄弟 export が参照する `vibe.env-get` / `vibe.fs_*`
  import は component 内 stub で吸収する(env-get → 空文字 = 未設定、
  fs_* → `unreachable`。compile 面の row がこれらの動的未到達を保証し、
  違反すれば trap で即座に顕在化する)。serve handler 経路は従来どおり
  strict reject のまま。

## WIT world (compile 面)

`_build/vibec/vibec.wit` として同梱:

```wit
package vibe:vibec@0.1.0;

world vibec {
  export compile: func(source: string, request: string) -> string;
}
```

request プロトコル(`cli_direct_component_entry.vibe` と同一):

| request | 意味 |
|---|---|
| `probe-part-count` | payload のパート数 |
| `probe-main-source-len` | main source の長さ |
| `len-mode:<mode>:<entry>` | コンパイルしてバイト長を返す(結果はキャッシュ) |
| `hex-chunk-mode:<mode>:<entry>:<n>` | n 番目の 1024B hex チャンク |

エラーは一律 `""`(Error は内部で discharge)。

## vfs callback 面(設計のみ、未実装)

FS 依存のホスト(ネイティブ CLI 等)が大きなプロジェクトを inline hex に
せず渡せるようにする第二面。将来 world をこう拡張する:

```wit
world vibec-hosted {
  import vfs: interface {
    read-file: func(path: string) -> result<string, string>;
    exists: func(path: string) -> bool;
    read-dir: func(path: string) -> list<string>;
  }
  export compile-file: func(input-path: string, entry-name: string, mode: string) -> result<list<u8>, string>;
}
```

実装は cli_adapter の `VIBE_FS_COMPILE` 経路(compile_to)の import 解決を
`vfs` interface 経由に差し替える形になる。compile 単発 API が先に実績を
積むまで保留(#1107 Phase 5 チェックボックス残)。

## ブラウザ PoC

`scripts/vibec_browser_poc.sh` が実証する内容:

1. `jco transpile vibec.component.wasm`(WASI shim 不要 — component は
   自己完結)→ ESM + core wasm。
2. driver (`scripts/vibec_poc_driver.mjs`) はブラウザで使える API のみで
   - `compile(hex_payload, "len-mode:mvp:answer")` → バイト長
   - `hex-chunk-mode` でチャンク回収 → `Uint8Array`
   - `WebAssembly.instantiate(bytes, { wasi_snapshot_preview1: { fd_write } })`
   - `answer(0n)` 直接呼び(user 関数は先頭に closure-env i64 を取る)と
     `_start` の stdout キャプチャの両方で 42 を確認。

node はヘッドレス代替として使っているだけで、driver のコードはそのまま
`<script type="module">` で動く(sample の読み込みを fetch に変えるだけ)。

## runtime/vibe の切替判断 (#857 検討事項)

- `vibe` CLI の compile 系は現状 `vibe-cli.wasm`(env-mode adapter)経由。
  **launcher には既に `VIBE_CLI_WASM` / `VIBE_RUNNER` の差し替え seam が
  あり、vibec を compile 面に使う切替はこの seam で足りる**。CLI 全面の
  compose (wac) 移行は、vfs 面の実装と `vibe self update` の artifact
  レイアウト変更(`lib/vibec.component.wasm` の追加配布)とセットで行う。
- **後方互換 alias は不要**と判断: 正式リリース前で互換保証はまだ無く
  (#1107 の前提)、`vibe` のユーザー向けサブコマンド表面は変わらない。
  変わるのは配布物の内部構成のみ。

## サイズとの関係 (#1107 Phase 2-4 との接続)

- component core は export 名 lift 依存のため ADR-0077 の export フィルタは
  `__no_entry__` を対象外にしており、そのまま安全。
- core は library ビルドでは ~4.9MB だが、`build_vibec.sh` が既定で
  `minify_wasm.sh --keep-exports compile_cli_request,memory,__heap_ptr
  --per-pass` により compile 面だけへ DCE し **~3.85MB (-22%)** に縮小する
  (#1109-1)。縮小 component でもブラウザ PoC は全通過。`VIBE_VIBEC_NO_MINIFY=1`
  で skip 可。
- Phase 4 (funcref table 最小化) は elem root を減らすため、この DCE の
  効きをそのまま良くする。
