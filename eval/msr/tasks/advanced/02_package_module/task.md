# advanced/02_package_module — 初期実装 (複数ファイル)

2ファイル構成にすること: `store.vibe` (キーバリューストアの実装、
`export` する) と `entry.vibe` (`import ./store.vibe { ... }` で使う側 +
`test { ... }` ブロック)。

`store.vibe` に以下を実装して export する:

- `struct Store` (内部表現は自由 — `Map[String, Int]` 推奨)
- `Store::new() -> Store`
- `set(s: Store, k: String, v: Int) -> Store` (不変更新)
- `get(s: Store, k: String) -> Option[Int]`
- `delete(s: Store, k: String) -> Store`

`entry.vibe` の `test { ... }` で set/get/delete の組み合わせを最低4ケース
`assert` すること (未設定キーの get が `None` になることを含む)。
