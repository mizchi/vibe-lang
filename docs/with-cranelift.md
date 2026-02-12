# vibe + Cranelift (draft)
# vibe + Cranelift (下書き)

This document captures a proposed direction for integrating Cranelift as an
AOT backend for vibe, while keeping the existing wasm VM sandbox model.
このドキュメントは、既存の wasm VM サンドボックスを維持しつつ、
vibe に Cranelift を AOT バックエンドとして統合する方針をまとめる。

## Goals / 目標

- AOT-first pipeline (JIT is optional and mainly for local dev/debug).
  AOT を主軸にし、JIT はローカル開発/デバッグ用途に限定する。
- Deterministic builds for content-addressed artifacts.
  コンテンツアドレス化に耐える決定的ビルドを実現する。
- Reuse the existing wasm VM sandbox model for safety and portability.
  既存の wasm VM サンドボックスを安全性/可搬性の基盤として流用する。
- Keep the compiler pipeline modular: AST/typed IR stays frontend-owned.
  AST/typed IR はフロントエンド所有のまま、パイプラインを分離する。

## Non-goals (for now) / 非目標 (当面)

- Replacing the wasm backend.
  wasm バックエンドの置き換え。
- Using Wasmtime's internal ABI/VMContext as a hard dependency.
  Wasmtime 内部 ABI/VMContext への強依存化。
- JIT as the primary execution path.
  JIT を主経路にすること。

## High-level design / 全体像

1. Parse/Type-check vibe as today.
   既存のパーサ/型検査を維持。
2. Lower typed IR into a portable internal IR (existing).
   typed IR を既存の内部 IR に落とす。
3. Add a new backend that lowers IR to CLIF.
   新規バックエンドで IR -> CLIF へ変換。
4. Use `cranelift-object` + `cranelift-module` to emit native object files.
   `cranelift-object` + `cranelift-module` で object を生成。
5. Link/load objects inside a sandboxed runtime (reusing wasm VM boundary).
   wasm VM 境界を使い、sandbox 内で link/load する。

The wasm backend remains the default; Cranelift is an additional AOT backend.
wasm バックエンドはデフォルトのまま、Cranelift は追加の AOT ルート。

## Cranelift components to use / 利用する構成要素

- `cranelift-codegen`: CLIF -> machine code (core compiler).
  `cranelift-codegen`: CLIF -> 機械語 (中核コンパイラ)。
- `cranelift-frontend`: builders for CLIF (FunctionBuilder).
  `cranelift-frontend`: CLIF ビルダー (FunctionBuilder)。
- `cranelift-module`: multi-function linkage and data objects.
  `cranelift-module`: 複数関数/データのリンク層。
- `cranelift-object`: AOT object file emission.
  `cranelift-object`: AOT object 出力。
- `cranelift-native`: host ISA detection for local builds.
  `cranelift-native`: ローカル環境の ISA 検出。
- `cranelift-jit`: optional, only for local dev or quick tests.
  `cranelift-jit`: 任意 (ローカル開発/簡易テスト向け)。

## Deterministic/content-addressed builds / 決定的・コンテンツアドレス化

To make outputs content-addressable, define a strict build fingerprint:
出力をコンテンツアドレス化するため、厳密な指紋 (fingerprint) を定義する。

- input sources (vibe files, imported module hashes)
  入力ソース (vibe ファイル、import されたモジュールハッシュ)
- typed IR serialization bytes
  typed IR のシリアライズ結果
- target triple + cpu features
  ターゲット triple と CPU feature
- Cranelift settings (opt_level, regalloc, flags)
  Cranelift 設定 (opt_level, regalloc, flags)
- toolchain versions (Cranelift version, linker version)
  ツールチェーンのバージョン (Cranelift, linker)

The fingerprint should be hashed to produce the artifact key. The AOT output
must be reproducible for identical inputs.
fingerprint をハッシュ化し成果物キーにする。同一入力なら同一出力を保証する。

## ABI and runtime boundary / ABI とランタイム境界

We want to reuse the existing wasm VM sandbox model. This implies:
既存の wasm VM サンドボックスを流用するため、以下を前提とする。

- A stable ABI for host calls (effects) that mirrors the wasm host imports.
  wasm のホスト import を模した安定 ABI。
- A clear memory model: linear-memory-like buffer or a VM-managed heap.
  メモリモデル (linear memory 互換 / VM 管理ヒープ) を明確化。
- Trap and error propagation that can be mapped into the VM boundary.
  trap/エラーを VM 境界へ伝播できる設計。

Decision / 決定:

- **Option A: wasm-compatible ABI (selected)**
  **Option A: wasm 互換 ABI (採用)**
  - Keep the wasm ABI and memory model.
    wasm ABI とメモリモデルを維持する。
  - AOT code calls the same host functions as wasm does.
    AOT 側から wasm と同じホスト関数を呼ぶ。
  - Easier to reuse sandbox implementation.
    sandbox 実装の流用が容易。

## Host import ABI table (Option A) / ホスト import ABI テーブル (Option A)

This section defines a minimal, stable host-call ABI that mirrors the wasm
imports used by the existing backend.
この節は、既存の wasm バックエンドの import と一致する最小限の
ホスト呼び出し ABI を定義する。

### Naming / 名前解決

- Use wasm import names as external symbols (module `xsh`).
  wasm の import 名を外部シンボル名として使う (module `xsh`)。
- Example symbols: `xsh.sh`, `xsh.path`.
  例: `xsh.sh`, `xsh.path`。
- The sandbox loader resolves symbol -> host function pointer.
  sandbox ローダがシンボルからホスト関数へ解決する。

### Calling convention / 呼び出し規約

- C ABI, fixed across targets.
  C ABI を採用し、ターゲット間で固定。
- All values are 32-bit tagged values, matching the wasm backend.
  すべての値は wasm バックエンドと同じ 32-bit タグ付き値。
- The first argument is an opaque context pointer (`*mut VmContext`).
  第1引数は不透明なコンテキストポインタ (`*mut VmContext`)。
- Linear memory is accessed via the context (base/len), offsets are `u32`.
  linear memory はコンテキスト経由で参照し、オフセットは `u32`。

### Initial import set (draft) / 初期 import セット (案)

The exact signatures should match the wasm backend and be finalized later.
シグネチャは wasm バックエンドと一致させ、後で確定する。

- `xsh.sh`: effectful shell execution (used only inside `do {}`).
  `xsh.sh`: 副作用付きのシェル実行 (`do {}` 内のみ)。
- `xsh.path`: constructs a Path value.
  `xsh.path`: Path 値を構築する。

### Versioning / バージョニング

- The host ABI version must be included in the content hash.
  ホスト ABI のバージョンはコンテンツハッシュに含める。
- Any change to signatures or value representation bumps the ABI version.
  シグネチャや値表現の変更は ABI バージョンの更新が必要。

## Object format and linker (what this means) / object 形式とリンカの意味

Object format = the binary container for native code emitted by Cranelift.
object 形式とは、Cranelift が出力するネイティブコードの格納形式。

Typical formats by platform:
プラットフォームごとの代表例:

- Linux: ELF
  Linux: ELF
- macOS: Mach-O
  macOS: Mach-O
- Windows: COFF/PE
  Windows: COFF/PE

Linker = the tool or loader that resolves symbols/relocations and produces a
loadable image.
リンカとは、シンボル/リロケーションを解決し、ロード可能な形にするもの。

Possible strategies:
想定しうる戦略:

1) **External linker (LLD or system linker)**
   **外部リンカ (LLD またはシステムリンカ)**
   - Emit object(s) and link into a shared library/executable.
     object を出力し、共有ライブラリ/実行ファイルにリンク。
   - Good for local dev, less ideal for sandbox isolation.
     ローカル開発には有利だが、sandbox 分離には不利。

2) **Custom in-sandbox loader**
   **sandbox 内のカスタムローダ**
   - Parse object files and apply relocations in-process.
     object を解析してプロセス内でリロケーションを適用。
   - Keeps the wasm VM boundary but requires loader work.
     wasm VM 境界を維持できるがローダ実装が必要。

3) **Hybrid**
   **ハイブリッド**
   - Use external linker for distribution builds, custom loader for sandboxed
     execution.
     配布ビルドは外部リンカ、実行は sandbox ローダで分岐。

The choice affects determinism, portability, and runtime isolation.
選択によって決定性/可搬性/隔離性が大きく変わる。

## Minimal sandbox loader requirements (draft) / sandbox ローダの最小要件 (案)

This section lists the smallest feature set to load Cranelift AOT objects
inside a sandbox runtime. It is intentionally minimal and can be expanded later.
この節は、sandbox 内で Cranelift AOT object をロードするための
最小機能セットを列挙する。意図的に最小限で、後から拡張する。

### 1) Object parsing / object 解析
- Parse sections and symbols for the target format (ELF/Mach-O/COFF).
  対象形式のセクション/シンボルを解析 (ELF/Mach-O/COFF)。
- Read code section(s) and data section(s).
  コード/データセクションを読み取る。

### 2) Relocations / リロケーション
- Apply absolute and PC-relative relocations used by Cranelift.
  Cranelift が生成する absolute/PC-relative リロケーションを適用。
- Support at least function calls and data references.
  最低限、関数呼び出しとデータ参照に対応。

#### x86_64 minimal set (ELF/Mach-O/COFF) / x86_64 の最小セット

If we avoid TLS and minimize GOT/PLT usage:
TLS を使わず、GOT/PLT の利用を最小化する前提なら、必要最小限は以下。

- `Abs4`, `Abs8` (absolute data addresses)
  `Abs4`, `Abs8` (絶対アドレス参照)
- `X86PCRel4` (PC-relative data/code reference)
  `X86PCRel4` (PC 相対参照)
- `X86CallPCRel4` (direct call)
  `X86CallPCRel4` (直接 call)
- `X86SecRel` (COFF only; section-relative)
  `X86SecRel` (COFF 専用; セクション相対)

If you link against external symbols via PLT/GOT, add:
外部シンボルを PLT/GOT 経由で解決する場合は以下も必要。

- `X86CallPLTRel4` (PLT call)
  `X86CallPLTRel4` (PLT call)
- `X86GOTPCRel4` (GOT load)
  `X86GOTPCRel4` (GOT 参照)

TLS-related (only if TLS is used):
TLS を使う場合のみ必要。

- `ElfX86_64TlsGd` (ELF)
  `ElfX86_64TlsGd` (ELF)
- `MachOX86_64Tlv` (Mach-O)
  `MachOX86_64Tlv` (Mach-O)

#### aarch64 minimal set (ELF/Mach-O) / aarch64 の最小セット

If we avoid TLS and minimize GOT usage:
TLS を使わず、GOT の利用を最小化する前提なら、必要最小限は以下。

- `Arm64Call` (direct call)
  `Arm64Call` (直接 call)
- `Aarch64AdrPrelPgHi21` + `Aarch64AddAbsLo12Nc`
  (page+offset pair for absolute address)
  `Aarch64AdrPrelPgHi21` + `Aarch64AddAbsLo12Nc`
  (ページ+オフセットの絶対参照)

If GOT is used for external references:
外部参照に GOT を使う場合は以下も必要。

- `Aarch64AdrGotPage21`
  `Aarch64AdrGotPage21`
- `Aarch64Ld64GotLo12Nc`
  `Aarch64Ld64GotLo12Nc`

TLS-related (only if TLS is used):
TLS を使う場合のみ必要。

- `Aarch64TlsDesc*` (ELF TLS desc)
  `Aarch64TlsDesc*` (ELF TLS desc)
- `MachOAarch64TlsAdrPage21`, `MachOAarch64TlsAdrPageOff12` (Mach-O TLS)
  `MachOAarch64TlsAdrPage21`, `MachOAarch64TlsAdrPageOff12` (Mach-O TLS)

Notes:
補足:

- The actual object relocation types are format-specific; Cranelift's
  `Reloc` kinds are mapped in `cranelift/object/src/backend.rs`.
  実際の object リロケーション型は形式依存。Cranelift の `Reloc` との
  マッピングは `cranelift/object/src/backend.rs` を参照。

### 3) Symbol resolution / シンボル解決
- Resolve internal symbols (within the object).
  object 内のシンボルを解決。
- Resolve external symbols to sandbox imports (host functions).
  外部シンボルを sandbox の import (ホスト関数) に解決。
- Provide a stable ABI table for host calls (Option A).
  Option A の ABI に沿ったホスト関数テーブルを提供。

### 4) Memory placement / メモリ配置
- Allocate R/W for data, R/X for code.
  データは R/W、コードは R/X で配置。
- Align sections as required by the object headers.
  セクションのアラインメントを遵守。

### 5) Entry points / エントリポイント
- Expose a well-known exported symbol (e.g. `run`).
  既知のエクスポート (例: `run`) を公開。
- Optional: expose metadata symbols for runtime introspection.
  任意: ランタイム参照用のメタデータシンボル。

### 6) Determinism / 決定性
- Ensure deterministic layout or include layout in the content hash.
  位置配置の決定性を担保するか、配置もハッシュ対象に含める。

Notes:
補足:
- The exact relocation set depends on target ISA and object format.
  リロケーションの種類は ISA と形式に依存する。
- A minimal loader can start with one platform/format and grow.
  最小ローダは 1 プラットフォームから始めて拡張可能。

## Phased milestones / フェーズ計画

1. Minimal AOT proof (no effects)
   最小 AOT 実証 (副作用なし)
   - Simple expressions -> CLIF -> object -> run.
     単純式 -> CLIF -> object -> 実行。
2. Host call bridge
   ホスト呼び出しの橋渡し
   - Map effectful operations to sandbox imports.
     副作用を sandbox import に対応付け。
3. Memory model alignment
   メモリモデルの統一
   - Decide on linear-memory-like buffer or direct native heap.
     linear memory 互換 or ネイティブヒープの選定。
4. Deterministic build pipeline
   決定的ビルドパイプライン
   - Stable hashing and reproducible artifacts.
     安定ハッシュと再現可能成果物。
5. Optimization and profiling
   最適化とプロファイリング
   - Benchmark vs wasm backend; tune opt_level and codegen flags.
     wasm バックエンドと比較し、最適化設定を調整。

## Open questions / 未決事項

- Object format choice per target and how to enforce determinism.
  ターゲットごとの object 形式と決定性担保の方法。
- Link strategy for sandbox execution (external linker vs custom loader).
  sandbox 実行時のリンク戦略 (外部リンカ vs カスタムローダ)。
- How much of Wasmtime's ABI/VMContext can or should be reused.
  Wasmtime の ABI/VMContext をどこまで再利用するか。
- Value representation compatibility with the wasm backend.
  wasm バックエンドと値表現を合わせるか。

## References in this repo (for orientation) / 参考

- `docs/vibe.md`: current language design and wasm backend notes.
  `docs/vibe.md`: 現在の言語設計と wasm バックエンドのメモ。
