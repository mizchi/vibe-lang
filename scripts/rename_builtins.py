#!/usr/bin/env python3
"""Rename builtins from snake_case to Type::method namespace.

For .mbt files: only replaces within double-quoted string literals and #| doc comment lines.
For .vibe/.md/.mjs files: replaces everywhere with word-boundary matching.

Usage:
  python3 scripts/rename_builtins.py [--dry-run]
"""

import re
import sys
import subprocess
from pathlib import Path

DRY_RUN = "--dry-run" in sys.argv

# Order matters: longer names first to avoid partial replacement
RENAMES = [
    # MapBuilder (must come before map_builder)
    ("map_builder_freeze", "MapBuilder::freeze"),
    ("map_builder_set", "MapBuilder::set"),
    ("map_builder", "MapBuilder::new"),
    # Map prelude helpers (must come before map_get etc.)
    ("map_get_or", "Map::get_or"),
    ("map_foreach", "Map::foreach"),
    ("map_entries", "Map::entries"),
    ("map_merge", "Map::merge"),
    ("map_filter", "Map::filter"),
    ("map_size", "Map::size"),
    ("map_map", "Map::map"),
    # Map builtins
    ("map_has_key", "Map::has_key"),
    ("map_values", "Map::values"),
    ("map_keys", "Map::keys"),
    ("map_set", "Map::set"),
    ("map_get", "Map::get"),
    # ArrayBuilder (must come before array_builder)
    ("array_builder_freeze", "ArrayBuilder::freeze"),
    ("array_builder_push", "ArrayBuilder::push"),
    ("array_builder", "ArrayBuilder::new"),
    # Array prelude helpers (must come before array_ builtins)
    ("array_foreach", "Array::foreach"),
    ("array_contains", "Array::contains"),
    ("array_reverse", "Array::reverse"),
    ("array_concat", "Array::concat"),
    ("array_filter", "Array::filter"),
    ("array_sort", "Array::sort"),
    ("array_find", "Array::find"),
    ("array_fold", "Array::fold"),
    ("array_join", "Array::join"),
    ("array_map", "Array::map"),
    ("array_any", "Array::any"),
    ("array_all", "Array::all"),
    # Array builtins
    ("array_truncate", "Array::truncate"),
    ("array_length", "Array::length"),
    ("array_slice", "Array::slice"),
    ("array_push", "Array::push"),
    ("array_set", "Array::set"),
    ("array_get", "Array::get"),
    # StringBuilder (must come before string_builder)
    ("string_builder_freeze", "StringBuilder::freeze"),
    ("string_builder_push", "StringBuilder::push"),
    ("string_builder", "StringBuilder::new"),
    # String (longest first)
    ("string_from_char_code", "String::from_char_code"),
    ("string_unicode_length", "String::unicode_length"),
    ("string_utf16_length", "String::utf16_length"),
    ("string_utf8_length", "String::utf8_length"),
    ("string_char_code_at", "String::char_code_at"),
    ("string_last_index_of", "String::last_index_of"),
    ("string_starts_with", "String::starts_with"),
    ("string_ends_with", "String::ends_with"),
    ("string_replace_all", "String::replace_all"),
    ("string_substring", "String::substring"),
    ("string_to_upper", "String::to_upper"),
    ("string_to_lower", "String::to_lower"),
    ("string_trim_start", "String::trim_start"),
    ("string_trim_end", "String::trim_end"),
    ("string_contains", "String::contains"),
    ("string_index_of", "String::index_of"),
    ("string_replace", "String::replace"),
    ("string_concat", "String::concat"),
    ("string_equals", "String::equals"),
    ("string_length", "String::length"),
    ("string_count", "String::count"),
    ("string_split", "String::split"),
    ("string_join", "String::join"),
    ("string_trim", "String::trim"),
    # Bytes
    ("bytes_from_string", "Bytes::from_string"),
    ("bytes_from_array", "Bytes::from_array"),
    ("bytes_to_string", "Bytes::to_string"),
    ("bytes_to_array", "Bytes::to_array"),
    ("bytes_concat", "Bytes::concat"),
    ("bytes_length", "Bytes::length"),
    ("bytes_slice", "Bytes::slice"),
    ("bytes_push", "Bytes::push"),
    ("bytes_new", "Bytes::new"),
    ("bytes_set", "Bytes::set"),
    ("bytes_get", "Bytes::get"),
    # Int
    ("int_to_double", "Int::to_double"),
    ("int_to_float", "Int::to_float"),
    ("int_is_even", "Int::is_even"),
    ("int_is_odd", "Int::is_odd"),
    ("int_signum", "Int::signum"),
    ("int_clamp", "Int::clamp"),
    ("int_abs", "Int::abs"),
    ("int_max", "Int::max"),
    ("int_min", "Int::min"),
    ("parse_int", "Int::parse"),
    # Double
    ("double_to_i64_bits", "Double::to_i64_bits"),
    ("i64_bits_to_double", "Double::from_i64_bits"),
    ("double_to_float", "Double::to_float"),
    ("double_to_int", "Double::to_int"),
    ("double_floor", "Double::floor"),
    ("double_ceil", "Double::ceil"),
    ("double_abs", "Double::abs"),
    ("double_max", "Double::max"),
    ("double_min", "Double::min"),
    ("parse_double", "Double::parse"),
    # Float
    ("float_to_double", "Float::to_double"),
    ("float_to_int", "Float::to_int"),
    # Char
    ("char_from_int", "Char::from_int"),
    ("char_to_int", "Char::to_int"),
    # Json (longest first)
    ("from_jsonl", "Json::parse_lines"),
    ("to_jsonl", "Json::stringify_lines"),
    ("from_json", "Json::parse"),
    ("to_json", "Json::stringify"),
    ("json_is_null", "Json::is_null"),
    ("json_string", "Json::string"),
    ("json_number", "Json::number"),
    ("json_length", "Json::length"),
    ("json_index", "Json::index"),
    ("json_type", "Json::type_of"),
    ("json_keys", "Json::keys"),
    ("json_bool", "Json::bool"),
    ("json_get", "Json::get"),
    # Fs (longest first)
    ("fs_read_string", "Fs::read_string"),
    ("fs_write_string", "Fs::write_string"),
    ("fs_read_bytes", "Fs::read_bytes"),
    ("fs_write_bytes", "Fs::write_bytes"),
    ("fs_read_file", "Fs::read_file"),
    ("fs_write_file", "Fs::write_file"),
    ("fs_is_file", "Fs::is_file"),
    ("fs_is_dir", "Fs::is_dir"),
    ("fs_readdir", "Fs::readdir"),
    ("fs_mkdir_p", "Fs::mkdir_p"),
    ("fs_exists", "Fs::exists"),
    ("fs_getcwd", "Fs::getcwd"),
    ("fs_remove", "Fs::remove"),
    ("fs_rename", "Fs::rename"),
    ("fs_append", "Fs::append"),
    ("fs_mkdir", "Fs::mkdir"),
    ("fs_chdir", "Fs::chdir"),
    ("fs_copy", "Fs::copy"),
    # Path
    ("path_is_absolute", "Path::is_absolute"),
    ("path_to_string", "Path::to_string"),
    ("path_ref", "Path::ref"),
    # Socket
    ("socket_tcp_connect", "Socket::tcp_connect"),
    ("socket_tcp_write", "Socket::tcp_write"),
    ("socket_tcp_read", "Socket::tcp_read"),
    ("socket_tcp_close", "Socket::tcp_close"),
    # Http (longest first)
    ("http_response_status", "Http::response_status"),
    ("http_response_header", "Http::response_header"),
    ("http_response_body", "Http::response_body"),
    ("http_request_method", "Http::request_method"),
    ("http_request_header", "Http::request_header"),
    ("http_request_body", "Http::request_body"),
    ("http_request_url", "Http::request_url"),
    ("http_request", "Http::request"),
    ("http_respond", "Http::respond"),
    ("http_accept", "Http::accept"),
    ("http_listen", "Http::listen"),
    ("http_close", "Http::close"),
    # Stdout/Stdin
    ("stdout_write_stream", "Stdout::write_stream"),
    ("stdout_write_char", "Stdout::write_char"),
    ("stdin_read_stream", "Stdin::read_stream"),
    ("stdin_read_char", "Stdin::read_char"),
    # Lines
    ("from_lines", "Lines::parse"),
    ("to_lines", "Lines::stringify"),
    # Llm
    ("llm_complete", "Llm::complete"),
    ("rlm_finalize", "Rlm::finalize"),
    ("rlm_run", "Rlm::run"),
    # PromptText
    ("prompt_text_to_string", "PromptText::to_string"),
    ("prompt_text", "PromptText::new"),
    # Misc
    ("dynamic_path_resolve", "Path::resolve"),
    ("env_get", "Env::get"),
]

# Build a single regex pattern from all old names (longest first, already sorted)
# Use custom boundaries instead of \b to handle escape sequences like \n before names
# The lookbehind allows: non-word chars, OR backslash+letter (escape sequences like \n, \t)
old_names_pattern = re.compile(
    r'(?:(?<![a-zA-Z_0-9])|(?<=\\[a-zA-Z]))'
    r'(' + '|'.join(re.escape(old) for old, _ in RENAMES) + r')'
    r'(?![a-zA-Z_0-9])'
)

# Build lookup dict
rename_map = dict(RENAMES)

def replace_match(m):
    return rename_map[m.group(0)]


def process_mbt_line(line):
    """For .mbt files: only replace within double-quoted strings and #| doc comment lines."""
    # #| lines contain vibe source code - replace everywhere
    stripped = line.lstrip()
    if stripped.startswith('#|'):
        return old_names_pattern.sub(replace_match, line)

    # For other lines, only replace within double-quoted strings
    # Find all string literals and replace within them
    def replace_in_string(m):
        s = m.group(0)
        return old_names_pattern.sub(replace_match, s)

    # Match double-quoted strings (handling escaped quotes)
    return re.sub(r'"(?:[^"\\]|\\.)*"', replace_in_string, line)


def process_other_content(content):
    """For .vibe/.md/.mjs files: replace everywhere with word boundaries."""
    return old_names_pattern.sub(replace_match, content)


def main():
    # Find files using git grep for all old names
    root = subprocess.check_output(
        ['git', 'rev-parse', '--show-toplevel'], text=True
    ).strip()

    # Collect all files that contain any old name
    extensions = ['*.mbt', '*.vibe', '*.md', '*.mjs']
    all_files = set()
    for ext in extensions:
        try:
            result = subprocess.check_output(
                ['git', 'grep', '-l', '-E',
                 '|'.join(re.escape(old) for old, _ in RENAMES[:20]),  # sample
                 '--', ext],
                text=True, cwd=root, stderr=subprocess.DEVNULL
            )
            all_files.update(result.strip().split('\n'))
        except subprocess.CalledProcessError:
            pass

    # Also search with remaining patterns
    for ext in extensions:
        try:
            result = subprocess.check_output(
                ['git', 'grep', '-l', '-E',
                 '\\b(' + '|'.join(re.escape(old) for old, _ in RENAMES[20:50]) + ')\\b',
                 '--', ext],
                text=True, cwd=root, stderr=subprocess.DEVNULL
            )
            all_files.update(result.strip().split('\n'))
        except subprocess.CalledProcessError:
            pass

    # Excluded directory prefixes
    EXCLUDED_PREFIXES = ('.claude/', '.jj/', '.mooncakes/', '.tmp/', 'node_modules/', '.vibe/', '_build/', 'target/')

    # Find all .mbt, .vibe, .md, .mjs files
    for ext_glob in ['**/*.mbt', '**/*.vibe', '**/*.md', '**/*.mjs']:
        for p in Path(root).glob(ext_glob):
            if not p.is_file():
                continue
            rel = str(p.relative_to(root))
            if any(rel.startswith(prefix) for prefix in EXCLUDED_PREFIXES):
                continue
            all_files.add(rel)

    count = 0
    for rel_path in sorted(all_files):
        if not rel_path:
            continue
        full_path = Path(root) / rel_path
        if not full_path.exists():
            continue

        try:
            content = full_path.read_text()
        except (UnicodeDecodeError, FileNotFoundError):
            continue

        if rel_path.endswith('.mbt'):
            # Process line by line for .mbt files
            lines = content.split('\n')
            new_lines = [process_mbt_line(line) for line in lines]
            new_content = '\n'.join(new_lines)
        else:
            new_content = process_other_content(content)

        if new_content != content:
            if DRY_RUN:
                print(f"WOULD MODIFY: {rel_path}")
                # Show first few changes
                for i, (old_line, new_line) in enumerate(zip(content.split('\n'), new_content.split('\n'))):
                    if old_line != new_line:
                        print(f"  L{i+1}: {old_line.strip()}")
                        print(f"     -> {new_line.strip()}")
                        if i > 5:
                            print(f"  ... and more")
                            break
            else:
                full_path.write_text(new_content)
                print(f"MODIFIED: {rel_path}")
            count += 1

    print(f"\n{'Would modify' if DRY_RUN else 'Modified'} {count} files.")


if __name__ == '__main__':
    main()
