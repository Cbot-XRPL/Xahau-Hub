#!/usr/bin/env python3
"""
render.py — strict {{ var }} renderer. No dependencies.

The template uses variable interpolation only, so this produces byte-identical
output to jinja2 while needing nothing installed on the host or guest.

  render.py TEMPLATE KEY=VALUE ...          # values on argv
  render.py TEMPLATE --env-prefix V_        # values from the environment
An unresolved {{ var }} is a hard error — a config silently rendered with a
missing node_seed or a missing online_delete is worse than no config.
"""
import os
import re
import sys

VAR = re.compile(r"\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}")


def render(text, values):
    missing = []

    def sub(m):
        k = m.group(1)
        if k not in values or values[k] in (None, ""):
            missing.append(k)
            return m.group(0)
        return str(values[k])

    out = VAR.sub(sub, text)
    if missing:
        uniq = sorted(set(missing))
        sys.stderr.write("render: unresolved template variable(s): %s\n" % ", ".join(uniq))
        sys.exit(3)
    left = VAR.findall(out)
    if left:
        sys.stderr.write("render: template still contains %s after rendering\n" % left)
        sys.exit(3)
    return out


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    tpl = argv[1]
    values = {}
    prefix = None
    args = argv[2:]
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--env-prefix":
            prefix = args[i + 1]
            i += 2
            continue
        if "=" in a:
            k, v = a.split("=", 1)
            values[k] = v
        i += 1
    if prefix:
        for k, v in os.environ.items():
            if k.startswith(prefix):
                values.setdefault(k[len(prefix):].lower(), v)
    with open(tpl, "r", encoding="utf-8") as fh:
        sys.stdout.write(render(fh.read(), values))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
