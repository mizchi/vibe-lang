# ADR-0027: Capability-Based Dead Code Elimination

- Date: 2026-03-12
- Status: proposed
- Related: ADR-0003 (エフェクトシステム), ADR-0008 (unstable feature flags), ADR-0010 (Component Model), ADR-0021 (Effect Handler + `#import`), ADR-0022 (ディレクティブ構文)

## Context

WASI の capability (名前空間) はランタイムごとにサポート範囲が異なる:

| Capability | wasmtime (Linux) | wasmtime (macOS) | Browsers | Edge Workers |
|---|---|---|---|---|
| `wasi:cli/stdio` | Yes | Yes | Polyfill | No |
| `wasi:filesystem` | Yes | Yes | No | No |
| `wasi:http/outgoing` | Yes | Yes | fetch polyfill | Yes |
| `wasi:threads` | >=4.4, Linux only | No | SharedArrayBuffer | No |
| `wasi:sockets` | Yes | Yes | No | No |
| `wasi:clocks/wall` | Yes | Yes | Date polyfill | Yes |

現状、vibe は利用可能な capability を実行時にしか判定できない。コードがどの capability を要求するかは `#import` ディレクティブ (ADR-0021/0022) で宣言されるが、**ビルド時にターゲット環境の capability セットが確定していれば、到達不能なコードパスとその推移的依存を DCE (Dead Code Elimination) できる**。

### 動機

1. **バイナリサイズ削減**: Edge Workers 向けビルドで `wasi:filesystem` や `wasi:threads` に依存するコードパスをすべて除去
2. **ビルド時安全性**: ターゲットが提供しない capability を使うコードパスがあればコンパイルエラー (または警告) にできる
3. **最適化の可視化**: ユーザーがビルドプロファイルを選ぶことで、何が除去されるかを事前に把握できる

## Decision

### 1. ビルドプロファイルで capability セットを宣言

ビルド時に `--capabilities` フラグまたはプロファイルで利用可能な WASI capability を指定する:

```bash
# 明示的に capability を列挙
vibe compile --capabilities wasi:cli,wasi:filesystem,wasi:http app.vibe

# プロファイル名で指定
vibe compile --profile edge app.vibe
vibe compile --profile server-linux app.vibe
```

プロファイル定義 (`vibe.profiles.toml` またはモジュール設定):

```toml
[profile.edge]
capabilities = ["wasi:http/outgoing", "wasi:clocks/wall"]

[profile.server-linux]
capabilities = [
  "wasi:cli", "wasi:filesystem", "wasi:http",
  "wasi:sockets", "wasi:threads", "wasi:clocks"
]

[profile.browser]
capabilities = ["wasi:http/outgoing", "wasi:clocks/wall"]
# polyfill 対応の capability のみ
```

### 2. `#import` ディレクティブと capability の照合

ADR-0021/0022 の `#import` ディレクティブが宣言する名前空間を、ビルドプロファイルの capability セットと照合する:

```
#import("wasi:filesystem/read@0.2.0")
effect Fs {
  read_file(path: String) -> String
}

#import("wasi:threads/spawn@0.1.0")
effect Threads {
  spawn(f: () -> Unit) -> ThreadId
}
```

`--profile edge` でビルドした場合:
- `wasi:filesystem` は capability セットに含まれない → `Fs` エフェクトは**利用不可**
- `wasi:threads` も含まれない → `Threads` エフェクトも**利用不可**

### 3. DCE のメカニズム

capability 照合の結果に基づき、以下の DCE パスを実行する:

```
Source → Parse → Check → Capability Resolution → Effect Reachability → DCE → Codegen
```

**Phase 1: Capability Resolution**

```
available_caps = profile.capabilities
for each #import(ns) + effect E:
  if ns ∉ available_caps:
    mark E as unavailable
```

**Phase 2: Effect Reachability**

```
for each function f with { E1, E2, ... }:
  if any Ei is unavailable AND not handled within f:
    mark f as unreachable
```

**Phase 3: DCE**

```
for each unreachable function f:
  remove f from codegen
  for each function g called only by f:
    if g has no other callers:
      mark g as unreachable (transitively)
```

### 4. `#cfg` ディレクティブとの連携

capability の有無を `#cfg` で分岐する:

```
#cfg(cap = "wasi:threads")
let parallel_map = (arr: Array[Int], f: (Int) -> Int) -> Array[Int] with { Threads } {
  // スレッド使用の並列実装
  ...
}

#cfg(not(cap = "wasi:threads"))
let parallel_map = (arr: Array[Int], f: (Int) -> Int) -> Array[Int] {
  // シングルスレッド fallback
  map(arr, f)
}
```

`--profile edge` でビルド:
- `#cfg(cap = "wasi:threads")` → false → 並列実装は DCE
- `#cfg(not(cap = "wasi:threads"))` → true → fallback が採用

### 5. エラーレベルの制御

利用不可な capability へのコードパスが存在する場合の挙動:

```bash
# デフォルト: 到達不能コードを DCE、到達必須なら error
vibe compile --profile edge app.vibe

# 厳格モード: 利用不可 capability への参照がソース中にあれば error
vibe compile --profile edge --strict-capabilities app.vibe

# 寛容モード: 利用不可 capability を warning にして stub 生成
vibe compile --profile edge --warn-capabilities app.vibe
```

stub モード (`--warn-capabilities`) では、利用不可な capability の import 関数を `unreachable` trap で置換する:

```wasm
;; wasi:threads/spawn がない場合
(func $threads_spawn (param i64) (result i64)
  unreachable  ;; runtime trap with message
)
```

### 6. ビルド出力での可視化

ビルド時にどの capability が有効/無効か、何が除去されたかをレポートする:

```
$ vibe compile --profile edge --report app.vibe

Capabilities:
  ✓ wasi:http/outgoing@0.2.0
  ✓ wasi:clocks/wall@0.2.0
  ✗ wasi:filesystem/read@0.2.0   (2 functions removed)
  ✗ wasi:threads/spawn@0.1.0     (5 functions removed)

DCE summary:
  removed 7 functions, 3 types, ~12KB saved
  output: app.component.wasm (48KB, was 60KB without DCE)
```

### 7. ランタイムでの capability 検証

Component Model のリンク時に、component の import が host の export と一致するか検証される。ビルド時の capability セットとランタイムの提供する capability が一致すれば、リンクエラーは発生しない:

```
Build time:  --profile edge → imports = {wasi:http, wasi:clocks}
Runtime:     edge worker     → exports = {wasi:http, wasi:clocks}
             → OK: all imports satisfied

Build time:  --profile server → imports = {wasi:http, wasi:fs, wasi:threads}
Runtime:     wasmtime macOS    → exports = {wasi:http, wasi:fs}
             → LINK ERROR: wasi:threads not available
```

ビルドプロファイルがランタイムの実態と一致することをユーザーが保証する。不一致の場合は Component Model のリンクエラーとして検出される。

## Design Rationale

### なぜビルド時に固定するか

1. **DCE の効果が最大化**: 実行時分岐ではコード自体は残るが、ビルド時固定なら完全に除去
2. **バイナリサイズがターゲットに最適化**: Edge Workers では数十 KB が重要
3. **型安全性**: ビルド時に capability 不足を検出できる。実行時 trap より早い
4. **Component Model との整合**: component の import セクションが capability セットと一致し、リンク時検証が成立する

### `wasi:threads` の具体例

`wasi:threads` は wasmtime 4.4+ かつ Linux でのみ利用可能。これを capability として扱うことで:

- `--profile server-linux`: `wasi:threads` 有効。並列処理コードが含まれる
- `--profile server-macos`: `wasi:threads` 無効。fallback 実装のみ。threads 関連のインポート・型定義・ワーカー管理コードがすべて DCE
- `--profile edge`: `wasi:threads` 無効 + `wasi:filesystem` 無効。さらに大きな DCE

ビルド成果物自体が「この capability セットで動く」ことを保証するため、ユーザーはデプロイ先の制約を明示的に意識してビルドを行う。

## Open Questions

以下は今後の設計・実装フェーズで決定する。

1. **capability 名の粒度とマッチングルール**: プロファイルで `wasi:http` (パッケージ) と `wasi:http/outgoing` (インターフェース) が混在している。`wasi:http` は配下のすべてのインターフェースを含むプレフィックスマッチか、完全一致か
2. **バージョン制約の扱い**: `#import("wasi:filesystem/read@0.2.0")` のバージョンとプロファイルの capability (バージョンなし) の照合ルール。バージョン不一致を capability マッチングで検出するか、Component Model リンク時に委ねるか
3. **`#cfg` と DCE の適用順序**: `#cfg(cap = ...)` はパース時の構文レベル除去、DCE は型チェック後のエフェクト到達性解析。両方が同じコードに適用される場合の明示的な優先順位
4. **プロファイル未指定時のデフォルト**: `vibe compile app.vibe` でプロファイルなしの場合の capability セット (全有効 / ソースの `#import` から自動導出 / エラー)
5. **ライブラリの capability 要件伝播**: ライブラリ内の `#import` はアプリ側のプロファイルと照合されるか、ライブラリのビルド時に固定されるか。Component Model のリンクモデルとの整合
6. **polyfill / adapter の capability 宣言方法**: ブラウザ polyfill 等が capability を「提供」する仕組み。プロファイルでの通常 capability との区別の必要性
7. **stub (`--warn-capabilities`) の位置づけ**: DCE されなかったコードパスに stub が残る場合、型チェックは通るが実行時 trap になる。これを意図的な挙動として許容するか、lint 警告を出すか

## Consequences

良い面:
- ターゲット環境に最適化されたバイナリが生成され、不要な WASI import と依存コードが除去される
- capability 不足がビルド時に検出され、実行時の `unreachable` trap やリンクエラーを事前に防げる
- `#cfg(cap = ...)` による条件コンパイルで、capability ごとの fallback 実装を型安全に切り替えられる
- ADR-0021 の `#import` + エフェクトシステムと自然に統合され、DCE の判定基準がエフェクトの到達性解析に帰着する
- ビルドレポートにより除去されたコード量が可視化され、ユーザーが最適化効果を把握できる

悪い面/トレードオフ:
- ビルドプロファイルの管理が必要 (ターゲットごとにプロファイルを定義・保守)
- `#cfg` による条件分岐が増えるとソースの可読性が低下する可能性
- プロファイルとランタイムの不一致はユーザー責任。誤ったプロファイルでビルドすると実行時にリンクエラーになる (ただしこれは Component Model の標準的な検証で検出される)
- DCE パスの実装コスト: エフェクト到達性解析 + 推移的依存の除去
- polyfill (ブラウザでの `wasi:http` → `fetch` 等) をどう扱うか — polyfill 提供側が capability を export する形で解決可能だが、polyfill の品質保証は別問題
