# basic/01_string_utils — 変更

`fn longest_word(s: String) -> String` を追加する。`s` は空白区切りの単語列
(区切りは半角スペース1個のみでよい)。最長の単語を返す。同じ長さの単語が
複数ある場合は最初に出現したものを返す。空文字列の場合は空文字列を返す。

既存の `is_palindrome` とその test は変更しない。`longest_word` 用に
最低 3 ケース (通常、同長タイ、空文字列) の test を追加すること。
