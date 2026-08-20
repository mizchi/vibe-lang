# The vibe tutorial has moved

The runnable language tour now lives in **[The Vibe Book](../../book/README.md)**
(`book/en/`). Every chapter is still a `*.vibe.md`; `scripts/vibe_md.sh`
checks the code and the recorded output.

| Old path | Book chapter |
| --- | --- |
| `03_values_functions.vibe.md` | [Values and functions](../../book/en/03_values_functions.vibe.md) |
| `04_control_flow.vibe.md` | [Control flow](../../book/en/04_control_flow.vibe.md) |
| `07_data.vibe.md` | [Data](../../book/en/07_data.vibe.md) |
| `08_option.vibe.md` | [Option](../../book/en/08_option.vibe.md) |
| `13_effects.vibe.md` | [Effects](../../book/en/13_effects.vibe.md) |
| `10_tests.vibe.md` | [Tests](../../book/en/10_tests.vibe.md) |
| `09_modules_packages.vibe.md` | [Modules](../../book/en/09_modules_packages.vibe.md) |

日本語: [book/ja/](../../book/ja/) and [README-ja.md](README-ja.md).

```bash
bash scripts/vibe_md.sh check book/en/*.vibe.md
pkf run vibe-md-tutorial
```
