#!/usr/bin/env python3
"""Keep structural lint focused on changes beyond empty ECall metadata.

Only discard file hunks when empty resolution cells or their pattern/forwarding
slots were added and every other token in both Git snapshots, including comments
and strings, is identical. Any other change retains all hunks for that file.
"""

import re
import sys

IDENT = re.compile(r'[A-Za-z_][A-Za-z_0-9]*')


def quoted_end(code, start):
    quote, i = code[start], start + 1
    while i < len(code):
        if code[i] == "\\":
            if quote == '"' and i + 1 < len(code) and code[i + 1] == '{':
                depth, i = 1, i + 2
                while i < len(code) and depth:
                    if code[i] in ('"', "'"):
                        i = quoted_end(code, i)
                    elif code.startswith('//', i):
                        end = code.find('\n', i)
                        i = len(code) if end < 0 else end
                    else:
                        if code[i] == '{': depth += 1
                        if code[i] == '}': depth -= 1
                        i += 1
            else:
                i += 2
        elif code[i] == quote:
            return i + 1
        else:
            i += 1
    raise ValueError('unterminated string')


def tokenize(code):
    tokens, i = [], 0
    while i < len(code):
        if code[i].isspace():
            i += 1
            continue
        start = i
        if code.startswith('//', i):
            end = code.find('\n', i)
            i = len(code) if end < 0 else end
        elif code[i] in ('"', "'"):
            i = quoted_end(code, i)
        else:
            match = IDENT.match(code, i)
            i = match.end() if match else i + 1
        tokens.append(code[start:i])
    return tokens


def normalized(code):
    try:
        tokens = tokenize(code)
    except ValueError:
        return [code], 0
    stack, ends = [], {}
    pairs = {')': '(', ']': '[', '}': '{'}
    for i, token in enumerate(tokens):
        if token in ('(', '[', '{'):
            stack.append(i)
        elif token in pairs:
            if stack and tokens[stack[-1]] == pairs[token]:
                ends[stack.pop()] = i
            elif stack:
                return tokens, 0
    removed, count = set(), 0
    for i, token in enumerate(tokens[:-1]):
        if token != 'ECall' or tokens[i + 1] != '(':
            continue
        opening = i + 1
        closing = ends.get(opening)
        if closing is None:
            continue
        commas, j = [], opening + 1
        while j < closing:
            if tokens[j] == ',':
                commas.append(j)
            j = ends.get(j, j) + 1
        if len(commas) == 3 and tokens[commas[2] + 1:closing] in (['[', ']'], ['callee_resolution'], ['_']):
            removed.update(range(commas[2], closing))
            count += 1
    return [token for i, token in enumerate(tokens) if i not in removed], count


def metadata_only(before, after):
    old, old_count = normalized(before)
    new, new_count = normalized(after)
    return new_count > old_count and old == new


def filter_diff(diff, snapshots):
    # Compare complete files so incomplete hunks cannot hide a scope change.
    output = []
    blocks = re.split(r'(?=^diff --git )', diff, flags=re.M)
    for block in blocks:
        path = re.search(r'^\+\+\+ [^/\n]+/(.+)$', block, re.M)
        snapshot = snapshots.get(path[1]) if path else None
        if snapshot and metadata_only(*snapshot):
            output.append(block.split('@@ ', 1)[0])
        else:
            output.append(block)
    return ''.join(output)


def git_snapshots(diff, root, range_):
    import subprocess
    before, after = 'HEAD', ''
    if range_:
        after = 'HEAD'
        if '...' in range_:
            left, right = range_.split('...', 1)
            before = subprocess.check_output(['git', '-C', root, 'merge-base', left or 'HEAD', right or 'HEAD'], text=True).strip()
        else:
            before = range_.split('..', 1)[0] or 'HEAD'
    snapshots = {}
    for path in re.findall(r'^\+\+\+ [^/\n]+/(.+)$', diff, re.M):
        try:
            snapshots[path] = tuple(subprocess.check_output(['git', '-C', root, 'show', f'{ref}:{path}'], text=True, stderr=subprocess.DEVNULL) for ref in [before, after])
        except subprocess.CalledProcessError:
            pass  # A new/deleted/unreadable file never qualifies.
    return snapshots


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True)
    parser.add_argument('--range', default='')
    args = parser.parse_args()
    diff = sys.stdin.read()
    sys.stdout.write(filter_diff(diff, git_snapshots(diff, args.root, args.range)))
