#!/usr/bin/env python3
"""Collect GitHub-style heading IDs and explicit HTML anchors using vendored Mistune."""
import html
from html.parser import HTMLParser
from pathlib import Path
import sys
import unicodedata

if sys.version_info < (3, 11):
    sys.exit('anchor parsing requires Python 3.11 or newer')

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent / 'vendor'))
import mistune  # noqa: E402


class AnchorHTML(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.anchors = set()
        self.text = []
        self.code_depth = 0

    def handle_starttag(self, tag, attrs):
        if tag in ('pre', 'code'):
            self.code_depth += 1
        if tag == 'a' and not self.code_depth:
            self.anchors.update(value for key, value in attrs
                                if key in ('id', 'name') and value is not None)

    def handle_endtag(self, tag):
        if tag in ('pre', 'code') and self.code_depth:
            self.code_depth -= 1

    def handle_data(self, data):
        self.text.append(data)


def anchors(source):
    tokens = mistune.create_markdown(renderer='ast', plugins=['strikethrough'])(source)
    found = set()
    used = set()
    parser = AnchorHTML()

    def text_content(nodes):
        out = ''
        for node in nodes:
            kind = node['type']
            if kind in ('inline_html', 'block_html'):
                fragment = AnchorHTML()
                fragment.feed(node['raw'])
                out += ''.join(fragment.text)
            elif 'children' in node:
                out += text_content(node['children'])
            elif kind in ('text', 'codespan'):
                out += html.unescape(node.get('raw', '')) if kind == 'text' else node.get('raw', '')
            elif kind in ('softbreak', 'linebreak'):
                out += '\n'
        return out

    def walk(nodes):
        for node in nodes:
            kind = node['type']
            if kind == 'heading':
                text = text_content(node['children']).strip().lower()
                slug = ''.join(c for c in text if c in ' _-' or unicodedata.category(c)[0] in 'LMN').replace(' ', '-')
                candidate = slug
                suffix = 0
                while candidate in used:
                    suffix += 1
                    candidate = f'{slug}-{suffix}'
                used.add(candidate)
                found.add(candidate)
            if kind in ('inline_html', 'block_html'):
                parser.feed(node['raw'])
            if 'children' in node:
                walk(node['children'])
    walk(tokens)
    parser.close()
    return found | parser.anchors


if __name__ == '__main__':
    try:
        for anchor in sorted(anchors(Path(sys.argv[1]).read_text(encoding='utf-8'))):
            print(anchor)
    except Exception as error:
        print(f'anchor parsing failed: {sys.argv[1]}: {error}', file=sys.stderr)
        sys.exit(2)
