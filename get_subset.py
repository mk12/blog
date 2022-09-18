#!/usr/bin/env python3

from pathlib import Path


ASCII = """\
0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ!"#$%&\'()*+,-./:\
;<=>?@[\\]^_`{|}~ \
"""

nonascii = set()

for path in Path("public").rglob("*"):
    if path.suffix in (".html", ".xml", ".svg"):
        with open(path) as f:
            for line in f:
                for c in line:
                    if ord(c) >= 128:
                        nonascii.add(c)

print(ASCII + "".join(nonascii))
