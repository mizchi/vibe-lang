# Chapters read under the book-review rubric

The live ledger is `bash eval/book-review/run_loop.sh status`. A row in
`scores/chapters/<id>/` is current only while its blobs match the
English and Japanese files. This table is the r5 partial pass, from
before those files existed. Do not treat it as the list of chapters
still to read.

`last_doc_pass` is the round that read the chapter for this rubric. Rounds
r1–r4 are not rows here: they have findings, and they are not scores.
`—` means a later round still has to read it. A cell that names a section
means the rest of the chapter was not read.

| Chapter | last_doc_pass | Scope note |
| --- | --- | --- |
| 00_introduction | — | |
| 01_getting_started | — | |
| 02_a_small_program | — | |
| 03_values_functions | — | |
| 04_control_flow | — | |
| 05_types_strings | — | |
| 06_mutation | — | |
| 07_data | — | |
| 08_effects | — | |
| 09_capabilities | — | |
| 10_option | — | |
| 11_modules_packages | — | |
| 12_tests | — | |
| 13_collections | — | |
| 14_iteration | — | |
| 15_generics | — | |
| 16_equality | 2026-09-24 r5 | en and ja. Prose corrected in that round. |
| 17_concurrency | — | |
| 18_cli | — | |
| 19_wasm | — | |
| 20_pitfalls | 2026-09-24 r5 | Equality section only, en and ja. Corrected in that round. |
| 99_appendix | 2026-09-24 r5 | Links only. Not scored. |

Cheatsheet sections read in r5, because surface_agreement compares them
with the book: the `==` / `Eq` section through the allow-list, and the
lambda-bound pitfall that used to say a nested bound is ignored. Both were
corrected in that round. The rest of the cheatsheet was not read.
