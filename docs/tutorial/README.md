# The vibe tutorial has moved

The runnable language tour now lives in **[The Vibe Book](../../book/README.md)**
(`book/en/`). Every chapter is still a `*.vibe.md`; `scripts/vibe_md.sh`
checks the code and the recorded output.

This table exists to resolve citations of the old `docs/tutorial/` paths, so
the left column holds the **historical** basenames — the files as they were
before [#2075](https://github.com/mizchi/vibe-lang/pull/2075) folded them into
the book. The book has since grown from seven chapters to twenty, so the
numbering on the right is not a renumbering of the left; several book chapters
have no predecessor here.

| Old path (`docs/tutorial/`) | Book chapter |
| --- | --- |
| `01_values_functions.vibe.md` | [Values and functions](../../book/en/03_values_functions.vibe.md) |
| `02_control_flow.vibe.md` | [Control flow](../../book/en/04_control_flow.vibe.md) |
| `03_data.vibe.md` | [Structs, enums, and match](../../book/en/07_data.vibe.md) |
| `04_option.vibe.md` | [Option and the railway](../../book/en/10_option.vibe.md) |
| `05_effects.vibe.md` | [Effects](../../book/en/08_effects.vibe.md) |
| `06_tests.vibe.md` | [Writing tests](../../book/en/12_tests.vibe.md) |
| `07_modules_packages.vibe.md` | [Modules and packages](../../book/en/11_modules_packages.vibe.md) |

Each chapter's `-ja` sibling (`01_values_functions-ja.vibe.md` and so on) maps
to the file under [book/ja/](../../book/ja/) named after its **English
destination** in the table above — so `01_values_functions-ja.vibe.md` is
`book/ja/03_values_functions.vibe.md`, not `book/ja/01_*`. The two languages
share one numbering; only the `-ja` suffix is gone.

日本語: [book/ja/](../../book/ja/) and [README-ja.md](README-ja.md).

```bash
bash scripts/vibe_md.sh check book/en/*.vibe.md
pkf run vibe-md-tutorial
```
