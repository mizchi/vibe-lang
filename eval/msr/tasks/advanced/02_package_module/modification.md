# advanced/02_package_module — 変更 (複数ファイル)

`store.vibe` に `keys(s: Store) -> Array[String]` (格納されている全キーを
順不同で返す) を追加する。**同時に `Store` の内部表現を変更すること**
(`Map` を使っていたなら `Array[(String, Int)]` に、あるいはその逆に —
「実装を変えても公開 API が安定していれば動き続けるか」を見る変更なので、
表現を変えずに `keys` だけ足すのは仕様の意図から外れる)。`set`/`get`/
`delete` のシグネチャ・挙動は変えない。

`entry.vibe` の既存 test は書き換えずに残す (内部表現の変更に既存 test が
追随を要求されないことを確認する)。`keys` 用の test を最低2ケース
(複数キー・delete 後にキーが減ること) 追加すること。
