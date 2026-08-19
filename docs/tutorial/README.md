# The vibe tutorial has moved

The runnable language tour now lives in **[The Vibe Book](../../book/README.md)**
(`book/en/`). Every chapter is still a `*.vibe.md`; `scripts/vibe_md.sh`
checks the code and the recorded output.

| Old path | Book chapter |
| --- | --- |
| `01_values_functions.vibe.md` | [Values and functions](../../book/en/01_values_functions.vibe.md) |
| `02_control_flow.vibe.md` | [Control flow](../../book/en/02_control_flow.vibe.md) |
| `03_data.vibe.md` | [Data](../../book/en/03_data.vibe.md) |
| `04_option.vibe.md` | [Option](../../book/en/04_option.vibe.md) |
| `05_effects.vibe.md` | [Effects](../../book/en/05_effects.vibe.md) |
| `06_tests.vibe.md` | [Tests](../../book/en/06_tests.vibe.md) |
| `07_modules_packages.vibe.md` | [Modules](../../book/en/07_modules_packages.vibe.md) |

日本語: [book/ja/](../../book/ja/) and [README-ja.md](README-ja.md).

```bash
bash scripts/vibe_md.sh check book/en/*.vibe.md
pkf run vibe-md-tutorial
```
