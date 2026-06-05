# wasmtime prebuilt setup

更新日: 2026-06-06

このメモは、`vibe-lang/deps/wasmtime` に固定した `mizchi/wasmtime` fork の
ローカル build を project-local prebuilt として固定し、thread / Component
Model probe を同じ binary で再現するための手順をまとめる。

現在の known-good:

- submodule gitlink: `623a84d03099ec65d7254000f1e07e70a98883c3`
- wasmtime binary: `wasmtime 46.0.0 (e6ba8b7d8 2026-06-02)`
- archive: `_build/prebuilt/wasmtime-v46.0.0-e6ba8b7d-aarch64-macos.tar.xz`
- install path: `.tools/wasmtime/bin/wasmtime`

`wasmtime --version` の hash は archive 名と `VERSION` file に保存する。
submodule gitlink は `git -C deps/wasmtime rev-parse HEAD` で別に確認する。
remote release asset として配布するまでは、archive はローカル成果物として扱う。

## 1. Repository layout

`ghq` 配下で `vibe-lang` を checkout し、その中の `deps/wasmtime` submodule を
source-build fallback として使う前提:

```bash
~/ghq/github.com/mizchi/vibe-lang
~/ghq/github.com/mizchi/vibe-lang/deps/wasmtime
```

`vibe-lang/scripts/package_wasmtime_prebuilt.sh` は既定で次の順に binary を探す:

1. `WASMTIME_PREBUILT_BIN`
2. `deps/wasmtime/target/release/wasmtime`
3. `deps/wasmtime/target/debug/wasmtime`
4. `../wasmtime/target/release/wasmtime`
5. `../wasmtime/target/debug/wasmtime`

明示したい場合は `WASMTIME_PREBUILT_BIN=/path/to/wasmtime` を使う。

## 2. Build fork wasmtime

`vibe-lang` の submodule 側で release CLI を作る。

```bash
cd ~/ghq/github.com/mizchi/vibe-lang

pkf run wasmtime-submodule-init
pkf run build-wasmtime-submodule

deps/wasmtime/target/release/wasmtime --version
git -C deps/wasmtime rev-parse HEAD
```

期待する形:

```text
wasmtime 46.0.0 (<rev> <date>)
```

この version line は archive 名と `VERSION` file に保存される。probe 結果を
比較するときは、必ずこの出力を記録する。

## 3. Package and install into vibe-lang

`vibe-lang` 側で archive 化し、`.tools/wasmtime` に install する。

```bash
cd ~/ghq/github.com/mizchi/vibe-lang

pkf run package-wasmtime-prebuilt
pkf run install-wasmtime-prebuilt
```

生成物:

- archive: `_build/prebuilt/wasmtime-v<version>-<rev>-<arch>-<os>.tar.xz`
- installed binary: `.tools/wasmtime/bin/wasmtime`
- installed version file: `.tools/wasmtime/VERSION`

`_build/` と `.tools/` は commit しない。必要なのは script と docs だけ。

URL または既存 archive から install する場合:

```bash
pkf run install-wasmtime-prebuilt -- _build/prebuilt/wasmtime-v46.0.0-e6ba8b7d-aarch64-macos.tar.xz
pkf run install-wasmtime-prebuilt -- https://example.invalid/wasmtime-v46.0.0-e6ba8b7d-aarch64-macos.tar.xz
```

script から直接使う場合:

```bash
WASMTIME_PREBUILT_ARCHIVE=_build/prebuilt/wasmtime-v46.0.0-e6ba8b7d-aarch64-macos.tar.xz \
  scripts/install_wasmtime_prebuilt.sh

WASMTIME_PREBUILT_URL=https://example.invalid/wasmtime-v46.0.0-e6ba8b7d-aarch64-macos.tar.xz \
  scripts/install_wasmtime_prebuilt.sh
```

## 4. Resolve wasmtime binary

thread probe では prebuilt を明示的に使う。

```bash
VIBE_USE_WASMTIME_PREBUILT=1 scripts/wasmtime_bin.sh
"$(VIBE_USE_WASMTIME_PREBUILT=1 scripts/wasmtime_bin.sh)" --version
```

期待する path:

```text
.../vibe-lang/.tools/wasmtime/bin/wasmtime
```

優先順位:

1. `WASMTIME_BIN`
2. `VIBE_USE_WASMTIME_PREBUILT=1` のとき `.tools/wasmtime/bin/wasmtime`
3. `VIBE_USE_WASMTIME_SUBMODULE=1` のとき `deps/wasmtime/target/{release,debug}/wasmtime`
4. `.tools/wasmtime/bin/wasmtime`
5. `PATH` 上の `wasmtime`
6. `deps/wasmtime/target/{release,debug}/wasmtime`

`WASMTIME_BIN` は常に最優先。CI や bisect で binary を差し替えるときだけ使う。

## 5. Run validation probes

prebuilt install 後の最小確認:

```bash
pkf run experimental_shared_everything_threads_probe
pkf run experimental_component_model_threading_probe
pkf run experimental_wasi_threads_probe
pkf run experimental_wasi_threads_speedup_probe
moon test src/x/threads
git diff --check
```

`src/x/threads/run_*.sh` は既定で `VIBE_USE_WASMTIME_PREBUILT=1` を設定する。
そのため、prebuilt が未 install の状態では明示的に失敗する。

2026-06-06 の local validation:

- `experimental_shared_everything_threads_probe`: passed
- `experimental_component_model_threading_probe`: passed
- `experimental_wasi_threads_probe`: passed
- `experimental_wasi_threads_speedup_probe`: `3.24x` faster than serial
- `moon test src/x/threads`: 24 passed

`experimental_wasi_threads_*` は WASI Threads baseline。Wasmtime 46 では
`-Sthreads` の Wasmtime 47.0.0 廃止警告が出るため、最終 backend ではなく
speedup 比較用として扱う。

## 6. Source-build fallback

prebuilt がない環境で fork source から build したい場合だけ使う。

```bash
pkf run wasmtime-submodule-init
pkf run build-wasmtime-submodule

VIBE_USE_WASMTIME_SUBMODULE=1 pkf run component-run -- script.vibe
VIBE_USE_WASMTIME_SUBMODULE=1 pkf run bench-wasmtime
```

prebuilt path では `.tools/wasmtime/bin/wasmtime --version` を実行時の binary
固定として扱う。source 側の追跡には `deps/wasmtime` の gitlink を使い、更新時は
両方を記録する。

## 7. Update procedure

fork 側の実装を更新したら、毎回この順で進める。

```bash
cd ~/ghq/github.com/mizchi/vibe-lang
pkf run wasmtime-submodule-init
pkf run build-wasmtime-submodule
deps/wasmtime/target/release/wasmtime --version
git -C deps/wasmtime rev-parse HEAD

pkf run package-wasmtime-prebuilt
pkf run install-wasmtime-prebuilt
"$(VIBE_USE_WASMTIME_PREBUILT=1 scripts/wasmtime_bin.sh)" --version

pkf run experimental_shared_everything_threads_probe
pkf run experimental_component_model_threading_probe
pkf run experimental_wasi_threads_speedup_probe
moon test src/x/threads
git diff --check
```

記録するもの:

- `wasmtime --version`
- `git -C deps/wasmtime rev-parse HEAD`
- archive path
- install path
- probe pass/fail
- speedup probe の倍率
- `-Sthreads` などの runtime warning

## 8. Common pitfalls

- `WASMTIME_BIN` を設定したままだと prebuilt より優先される。
- `.tools/wasmtime/bin/wasmtime` が古い場合、`package` だけでは更新されない。
  必ず `install-wasmtime-prebuilt` も実行する。
- `deps/wasmtime` の gitlink は source fallback 用。prebuilt の revision 確認は
  `.tools/wasmtime/bin/wasmtime --version` を見る。
- `pkf run install-wasmtime-prebuilt` は既定で `_build/prebuilt` 内の lexicographic
  最後の archive を選ぶ。複数 archive があるときは path を明示する。
- remote URL install は script 上は対応済みだが、GitHub Release 等の配布元は
  まだ作っていない。
