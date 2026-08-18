# The vibe tutorial has moved

The runnable language tour now lives in **[The Vibe Book](../../book/README.md)**
(`book/src/`). Every chapter is still a `*.vibe.md`; `scripts/vibe_md.sh`
checks the code and the recorded output.

| Old path | Book chapter |
| --- | --- |
| `01_values_functions.vibe.md` | [Values and functions](../../book/src/01_values_functions.vibe.md) |
| `02_control_flow.vibe.md` | [Control flow](../../book/src/02_control_flow.vibe.md) |
| `03_data.vibe.md` | [Data](../../book/src/03_data.vibe.md) |
| `04_option.vibe.md` | [Option](../../book/src/04_option.vibe.md) |
| `05_effects.vibe.md` | [Effects](../../book/src/05_effects.vibe.md) |
| `06_tests.vibe.md` | [Tests](../../book/src/06_tests.vibe.md) |
| `07_modules_packages.vibe.md` | [Modules](../../book/src/07_modules_packages.vibe.md) |

日本語: [book/ja/](../../book/ja/) and [README-ja.md](README-ja.md).

```bash
bash scripts/vibe_md.sh check book/src/*.vibe.md
pkf run vibe-md-tutorial
```
