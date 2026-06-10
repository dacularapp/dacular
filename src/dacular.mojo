"""dacular — CLI entry point for the personal data vault.

For now: `dacular manifest <dir>` prints the aliased, frontier-visible view of a
vault directory — the confidentiality boundary, before any of the heavier
machinery (indexer, vault tools, the headgate-driven ask loop) is wired in.
"""

from std.sys import argv
from std.os import getenv

from manifest import build_manifest


def _print_manifest(data_dir: String) raises:
    var infos = build_manifest(data_dir)
    print("vault:", data_dir)
    print(
        String(len(infos))
        + " indexable file(s) — the frontier model sees only this:"
    )
    for i in range(len(infos)):
        ref fi = infos[i]
        var line = String("  ") + fi.id + "  [" + fi.kind + "]  "
        line += String(fi.size) + " bytes"
        if len(fi.columns) > 0:
            line += "  schema: "
            for j in range(len(fi.columns)):
                if j > 0:
                    line += ", "
                line += fi.columns[j]
        print(line)


def main() raises:
    var args = argv()
    if len(args) < 2 or String(args[1]) != "manifest":
        print("usage: dacular manifest <vault-dir>")
        return
    var data_dir: String
    if len(args) >= 3:
        data_dir = String(args[2])
    else:
        data_dir = getenv("HOME", ".") + "/dacular"
    _print_manifest(data_dir)
