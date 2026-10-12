#!/usr/bin/env python3
"""Reference token ids for the Gemma SentencePiece differential test.

Writes what Google's SentencePiece (the Python `sentencepiece` package, 0.2.1)
returns for a fixed corpus, so `test/sentencepiece_reference_test.dart` can
assert that this package's Gemma tokenization produces exactly the same ids.
The corpus is built here and stored in the fixture next to the ids: the Dart
test reads both, so the two can never drift apart.

The corpus: the 40 W1 strings (read from the example's W1 golden, the one
list of them), HTML / markdown / code with Gemma's user-defined tag pieces at
the start, the end, in the middle, nested and next to spaces, newlines and
tabs, tag-like strings that are NOT pieces, the special-looking pieces and the
control ones, whitespace runs, CJK, emoji and combining marks — each without a
prefix, and a subset under all nine TaskType prefixes (read from the same W1
golden, which writes them from core's `TaskType.prefix`).

Regenerate (from the repository root, Python with sentencepiece 0.2.1):

  python3 -I packages/flutter_edge_ai_embeddings/tool/generate_sentencepiece_reference.py

That writes test/fixtures/eg1_sentencepiece_reference.json from the example's
committed EmbeddingGemma 1 `sentencepiece.model`. With
`--onnx-dir DIR`, where DIR holds onnx-community/embeddinggemma-300m-ONNX's
`tokenizer.model` (ungated), it also writes
test/fixtures/eg1_onnx_sentencepiece_reference.json, the reference for the
same corpus under that repository's tokenizer — which is what the opt-in
`tokenizer.json` leg of the Dart test compares that repository's
`tokenizer.json` against. `--check` regenerates in memory and fails when a
committed fixture differs.
"""

import argparse
import hashlib
import json
import os
import sys

import sentencepiece

EXPECTED_SENTENCEPIECE = '0.2.1'

PACKAGE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(os.path.dirname(PACKAGE))
EG1_MODEL = os.path.join(
    REPO, 'packages', 'flutter_edge_ai', 'example', 'assets', 'models',
    'sentencepiece.model')
W1_GOLDEN = os.path.join(
    REPO, 'packages', 'flutter_edge_ai', 'example', 'integration_test',
    'goldens', 'w1_eg1_native_token_ids.dart')
FIXTURES = os.path.join(PACKAGE, 'test', 'fixtures')

EG1_FIXTURE = 'eg1_sentencepiece_reference.json'
ONNX_FIXTURE = 'eg1_onnx_sentencepiece_reference.json'

# What each fixture's tokenizer is, for the Dart test's messages and for
# whoever regenerates. The EG1 file is the catalog's EmbeddingGemma 1
# tokenizer; the ONNX pair is the ungated Hugging Face export of the same model.
EG1_SOURCE = (
    'packages/flutter_edge_ai/example/assets/models/sentencepiece.model = '
    'litert-community/embeddinggemma-300m@'
    '29888fcee3216acadc7e844906e5fe0d79a61875/sentencepiece.model')
ONNX_REVISION = '5090578d9565bb06545b4552f76e6bc2c93e4a66'
ONNX_SOURCE = (
    'onnx-community/embeddinggemma-300m-ONNX@' + ONNX_REVISION +
    '/tokenizer.model (its tokenizer.json is the HF form of the same vocab)')


def read_w1():
    """The W1 strings and the nine TaskType prefixes, from the W1 golden."""
    with open(W1_GOLDEN, encoding='utf-8') as f:
        source = f.read()
    start = source.index("r'''") + 4
    end = source.rindex("'''")
    golden = json.loads(source[start:end])
    return golden['strings'], golden['prefixes']


def corpus(w1_strings):
    """(name, text) pairs. Names are unique; they key the test's messages."""
    rows = [('w1/' + name, text) for name, text in w1_strings]

    def add(group, texts):
        for i, text in enumerate(texts):
            rows.append(('%s/%d' % (group, i), text))

    # Gemma user-defined tag pieces, wherever they can sit.
    add('tags', [
        '</div>', '<div>', '<div></div>', '<p>Hello</p>',
        '<b>bold</b> and <i>italic</i>',
        '<div><span>x</span></div>',
        '<div><div><div>deep</div></div></div>',
        '<ul>\n  <li>one</li>\n  <li>two</li>\n</ul>',
        '<table><tr><td>1</td><td>2</td></tr></table>',
        'start <div>', '<div> end', 'mid<div>dle', 'a<br>b', 'a <br> b',
        ' <div>', '<div> ', '  <div>  ', '\n<div>\n', '\n\n<p>\n\n',
        '\t<td>\t', '\t\t<td>\t\t', ' \n\t<li> \n\t', '<li>\n</li>',
        'text</p>', '</p>text', '</p></p>', '<p><p>', '<br/>', '<br />',
        '<hr>', '<img src="x.png" alt="y">', '<a href="https://x.y">link</a>',
        '<!DOCTYPE html>', '<!-- comment -->',
        '<html><head><title>T</title></head><body>B</body></html>',
        '<h1>Title</h1>\n<h2>Sub</h2>\n<p>Body text.</p>',
        '<script>var a = 1 < 2;</script>', '<style>p { color: red; }</style>',
        '<code>x</code>', '<pre>  indented\n    more</pre>',
        '<strong>S</strong><em>E</em><u>U</u>', '<tr>\n<td>\n</td>\n</tr>',
        '<?xml version="1.0"?><root><item/></root>',
        '<Button onClick={f}>OK</Button>',
        '<DIV>', '<Div>', '</DIV>', '<P>upper</P>',
        '&lt;div&gt; &amp; &quot;',
        '<div class="note">Hi &amp; bye</div>',
    ])
    # Tag-like strings that are NOT user-defined pieces.
    add('not-pieces', [
        '<foo>', '< div>', '<div ', '<div', 'div>', '</ div>', '<<div>>',
        '<div>>', '<</div>', '</div</div>', '<div class>', '<xyz123>',
        '<', '>', '</', '/>', '<>', '< >', '<-->', 'a<b', 'a > b',
        'if (a<b && c>d) {}', 'List<String>', 'Map<String, int>',
        'Vec<Option<T>>', 'x <= y >= z', '<<<', '>>>',
    ])
    # Gemma's special-looking user-defined pieces, and its control ones (which
    # SentencePiece never produces from text).
    add('special', [
        '<mask>', '<ctrl1>', '<ctrl99>', '[multimodal]', '[toxicity=0]',
        '<mask><mask>', 'x<mask>y', ' <mask> ', '<mask> and <ctrl1>',
        '<ctrl1><ctrl2>', '<ctrl', 'ctrl1>', '[multimodal', 'multimodal]',
        '[multimodal] image', '<unused0>', '<unused99>',
        '<start_of_turn>user\nhi<end_of_turn>', '<start_of_image>',
        '<end_of_image>', '<image_soft_token>',
        '<bos>', '<eos>', '<pad>', '<unk>', '<bos>text<eos>', ' <eos> ',
        '<0x41>', '<0xFF>',
    ])
    # Whitespace runs: Gemma has user-defined pieces for runs of spaces,
    # newlines and tabs.
    ws = []
    for n in (1, 2, 3, 5, 8, 16, 31, 32, 33, 40):
        ws.append(' ' * n)
        ws.append('\n' * n)
        ws.append('\t' * n)
        ws.append('a' + ' ' * n + 'b')
    ws += [
        'a\n\n\nb', 'a\t\t\tb', ' \n \t ', '\n \n', '\r\n', 'a\r\nb',
        'line\n\n\n\nnext', 'indent\n    code\n        deeper',
        '\u00a0nbsp\u00a0', 'ideographic\u3000space', 'thin\u2009space',
        '\u2581already\u2581escaped\u2581\u2581', '\u2581',
        ' \u2581 \u2581 ',
    ]
    add('whitespace', ws)
    # Scripts and characters away from ASCII.
    add('unicode', [
        '\u4e2d\u6587\u6587\u672c\u5d4c\u5165\u6d4b\u8bd5', '\u7e41\u9ad4\u4e2d\u6587', '\u3072\u3089\u304c\u306a \u30ab\u30bf\u30ab\u30ca \u6f22\u5b57',
        '\ud55c\uad6d\uc5b4', '\u0395\u03bb\u03bb\u03b7\u03bd\u03b9\u03ba\u03ac', '\u05e2\u05d1\u05e8\u05d9\u05ea', '\u0e44\u0e17\u0e22', '\u0939\u093f\u0928\u094d\u0926\u0940', '\u0ba4\u0bae\u0bbf\u0bb4\u0bcd',
        '\U0001f600\U0001f601\U0001f602', '\U0001f44b\U0001f3fb hi',
        '\U0001f3f3\ufe0f\u200d\U0001f308', 'e\u0301\u0302\u0303',
        'Z\u0351\u0352\u0353a\u0354lgo', '\ufb01 ligature', '\u2163 roman',
        '\u00bd \u2153', '\u212b angstrom sign', 'x\u200by zero width',
        '\ufeffbom', '\U00010348 gothic', 'mixed \u4e2d <div>\u6587</div> \u672c',
    ])
    # Code and markup outside HTML.
    add('code', [
        '# Title\n\n- item\n- item', '```python\nprint("hi")\n```',
        '**bold** _it_ `code`', '[link](https://x.y)',
        '| a | b |\n|---|---|\n| 1 | 2 |',
        '{"key": [1, 2, {"nested": null}]}',
        'const f = (x) => x * 2; // arrow',
        'SELECT a, b FROM t WHERE c <> 1;',
        'fn main() {\n\tprintln!("{}", 1);\n}',
        '#include <stdio.h>\nint main(void) { return 0; }',
        '    four-space indented\n\tand a tab',
    ])
    # Gemma's chat and image markers and its CONTROL pieces as literal text.
    # In the Gemma 3 vocabularies <start_of_turn>, <end_of_turn>,
    # <start_of_image> and <end_of_image> are USER_DEFINED — a tokenizer.json
    # marks them `special`, yet SentencePiece keeps them whole in text — while
    # <pad>, <eos>, <bos> are CONTROL and <unk> UNKNOWN, which SentencePiece
    # never produces from text. Both loaders must agree with it on each.
    add('turns', [
        '<start_of_turn>', '<end_of_turn>', '<start_of_turn>user',
        '<start_of_turn>model\nHello!<end_of_turn>\n',
        '<start_of_turn>user\nWhat is RAG?<end_of_turn>\n<start_of_turn>model\n',
        ' <start_of_turn> ', 'x<end_of_turn>y', '<start_of_turn><end_of_turn>',
        '<end_of_turn><eos>', '<bos><start_of_turn>user\nhi<end_of_turn><eos>',
        '<start_of_image><image_soft_token><end_of_image>',
        '<pad><pad>', '<eos><eos>', '<bos> <bos>', '<unk><unk>',
        '<start_of_turn', 'start_of_turn>', '<START_OF_TURN>',
        '<mask><start_of_turn><bos>',
    ])
    return rows


# Strings that get all nine TaskType prefixes (by name).
PREFIXED = [
    'w1/ascii word', 'w1/paragraph', 'w1/html', 'w1/python code',
    'w1/leading space', 'w1/empty', 'w1/whitespace only', 'w1/chinese',
    'w1/emoji zwj', 'w1/combining acute',
    'tags/0', 'tags/1', 'tags/10', 'tags/14', 'tags/17', 'tags/36',
    'not-pieces/1', 'not-pieces/22',
    'special/0', 'special/3', 'special/8', 'special/21',
    'whitespace/1', 'whitespace/31', 'whitespace/2',
    'unicode/21', 'code/1', 'code/10',
    'turns/2', 'turns/9', 'turns/12',
]


def build(model_path, source, w1_strings, prefixes):
    with open(model_path, 'rb') as f:
        data = f.read()
    sp = sentencepiece.SentencePieceProcessor(model_proto=data)
    texts = corpus(w1_strings)
    names = [name for name, _ in texts]
    if len(set(names)) != len(names):
        raise SystemExit('duplicate corpus names')
    by_name = dict(texts)
    missing = [n for n in PREFIXED if n not in by_name]
    if missing:
        raise SystemExit('PREFIXED names not in the corpus: %s' % missing)

    rows = []
    for name, text in texts:
        rows.append({'name': name, 'prefix': 'none', 'text': text,
                     'ids': sp.encode(text)})
    for name in PREFIXED:
        for task, prefix in prefixes.items():
            if task == 'none':
                continue  # already above
            rows.append({'name': name, 'prefix': task,
                         'text': by_name[name],
                         'ids': sp.encode(prefix + by_name[name])})

    return {
        'generator': 'tool/generate_sentencepiece_reference.py',
        'sentencepiece': sentencepiece.__version__,
        'tokenizer': {
            'source': source,
            'sha256': hashlib.sha256(data).hexdigest(),
            'pieces': sp.get_piece_size(),
            'userDefinedPieces': _user_defined_count(data),
        },
        'ids': 'sentencepiece.SentencePieceProcessor.encode(prefix + text): '
               'no BOS, no EOS',
        'prefixes': prefixes,
        'rows': rows,
    }


def _user_defined_count(model_bytes):
    # SentencePieceProcessor has no is_user_defined; the proto's type is 4.
    from sentencepiece import sentencepiece_model_pb2 as pb
    proto = pb.ModelProto()
    proto.ParseFromString(model_bytes)
    return sum(1 for piece in proto.pieces if piece.type == 4)


def render(fixture):
    # ASCII only — every other code point is a \\u escape, so NFC and NFD forms
    # stay visibly distinct in review — and one row per line.
    lines = ['{']
    head = {k: v for k, v in fixture.items() if k != 'rows'}
    for key, value in head.items():
        lines.append('  %s: %s,' % (json.dumps(key), json.dumps(value)))
    lines.append('  "rows": [')
    for i, row in enumerate(fixture['rows']):
        comma = ',' if i < len(fixture['rows']) - 1 else ''
        lines.append('    ' + json.dumps(row) + comma)
    lines.append('  ]')
    lines.append('}')
    text = '\n'.join(lines) + '\n'
    assert json.loads(text) == fixture
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--onnx-dir', help='directory holding '
                        'onnx-community/embeddinggemma-300m-ONNX tokenizer.model')
    parser.add_argument('--check', action='store_true',
                        help='fail when a committed fixture differs')
    args = parser.parse_args()

    if sentencepiece.__version__ != EXPECTED_SENTENCEPIECE:
        raise SystemExit('sentencepiece %s, expected %s' %
                         (sentencepiece.__version__, EXPECTED_SENTENCEPIECE))
    w1_strings, prefixes = read_w1()

    jobs = [(EG1_FIXTURE, EG1_MODEL, EG1_SOURCE)]
    if args.onnx_dir:
        jobs.append((ONNX_FIXTURE,
                     os.path.join(args.onnx_dir, 'tokenizer.model'),
                     ONNX_SOURCE))

    stale = []
    for name, model_path, source in jobs:
        text = render(build(model_path, source, w1_strings, prefixes))
        path = os.path.join(FIXTURES, name)
        if args.check:
            with open(path, encoding='utf-8') as f:
                if f.read() != text:
                    stale.append(path)
            continue
        os.makedirs(FIXTURES, exist_ok=True)
        with open(path, 'w', encoding='utf-8') as f:
            f.write(text)
        print('wrote %s (%d rows)' % (path, text.count('"name"')))
    if stale:
        raise SystemExit('stale: %s' % ', '.join(stale))


if __name__ == '__main__':
    sys.exit(main())
