#!/usr/bin/env python3
"""
Qwiklabs markdown lint — catches the two failure modes that only show up once
the lab is rendered, and which no amount of proofreading finds.

  1. Indented prose OUTSIDE a numbered list.  Four leading spaces means "code
     block" in Markdown, so the paragraph renders monospace with a copy button.

  2. A block element at column zero INSIDE a numbered list — a table, an
     infobox, a fenced code block. It terminates the list, so step numbering
     restarts at 1 and every indented paragraph after it becomes a code block.

Usage:  python3 lint_md.py en.md
"""
import re, sys

def lint(path):
    L = open(path).read().split('\n')
    in_list = False
    fence = False
    sec = None
    problems = []

    for i, l in enumerate(L):
        n = i + 1
        if re.match(r'^#{1,6} ', l.lstrip()) and not l.startswith('    '):
            sec = l.strip('# ').strip()
            in_list = False
        if re.match(r'^\s*```', l):
            fence = not fence
            continue
        if fence:
            continue
        if re.match(r'^\d+\. ', l):
            in_list = True
            continue
        if not l.strip():
            continue

        col0 = bool(re.match(r'^\S', l))

        if in_list and col0:
            if l.startswith('|'):
                problems.append((n, sec, 'TABLE at column 0 inside a numbered list', l[:60]))
            elif l.startswith('<'):
                problems.append((n, sec, 'HTML BLOCK at column 0 inside a numbered list', l[:60]))
            else:
                in_list = False          # ordinary prose legitimately ends the list
        elif not in_list and l.startswith('    '):
            problems.append((n, sec, 'INDENTED PROSE outside a list (renders as code)', l.strip()[:60]))

    return problems

if __name__ == '__main__':
    path = sys.argv[1] if len(sys.argv) > 1 else 'en.md'
    p = lint(path)
    if not p:
        print(f'{path}: clean')
    else:
        print(f'{path}: {len(p)} problem(s)\n')
        for n, sec, kind, txt in p:
            print(f'  L{n:<6} {str(sec)[:34]:36} {kind}\n           {txt}')
    sys.exit(1 if p else 0)
