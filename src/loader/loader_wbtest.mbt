///| Whitebox tests for loader/lib.mbt internal helpers.

///|
test "extract_vibe_from_markdown extracts a single vibe block" {
  let md = "# Title\n```vibe\nlet x = 1\n```\n"
  let extracted = extract_vibe_from_markdown(md)
  assert_eq(extracted, "let x = 1")
}

///|
test "extract_vibe_from_markdown joins multiple vibe blocks with blank line" {
  let md = "```vibe\nlet a = 1\n```\n\n```vibe\nlet b = 2\n```\n"
  let extracted = extract_vibe_from_markdown(md)
  assert_eq(extracted, "let a = 1\n\nlet b = 2")
}

///|
test "extract_vibe_from_markdown skips non-vibe code fences" {
  let md = "```js\nconst hidden = 1\n```\n\n```vibe\nlet visible = 2\n```\n"
  let extracted = extract_vibe_from_markdown(md)
  assert_eq(extracted, "let visible = 2")
}

///|
test "extract_vibe_from_markdown returns empty for markdown without vibe blocks" {
  let md = "# Just prose\n\nNo code here.\n"
  let extracted = extract_vibe_from_markdown(md)
  assert_eq(extracted, "")
}

///|
test "extract_vibe_from_markdown drops an unterminated vibe block" {
  // No closing ``` — the block content is buffered but never flushed.
  // Current behaviour: the unterminated block is silently dropped.
  let md = "```vibe\nlet x = 1\n"
  let extracted = extract_vibe_from_markdown(md)
  assert_eq(extracted, "")
}

///|
test "extract_vibe_from_markdown ignores fence opens inside a non-vibe block" {
  // Opening another fence while in a non-vibe block doesn't switch state;
  // only `\`\`\`` (alone, after trim) closes the block.
  let md = "```js\nconst x = 1\n```\n\n```vibe\nlet y = 2\n```\n"
  let extracted = extract_vibe_from_markdown(md)
  assert_eq(extracted, "let y = 2")
}

///|
test "extract_vibe_from_markdown preserves blank lines inside a vibe block" {
  let md = "```vibe\nlet a = 1\n\nlet b = 2\n```\n"
  let extracted = extract_vibe_from_markdown(md)
  assert_eq(extracted, "let a = 1\n\nlet b = 2")
}
