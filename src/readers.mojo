"""Readers — turn a vault file into text the indexer/tools can use.

Three readers, one per vault kind:
  - `csv_rows(path)` -> rows of trimmed string fields (header row included; the
    caller decides whether to skip it).
  - `md_text(path)`  -> the file's text, verbatim.
  - `pdf_text(path)` -> extracted text via pdftotext.mojo (+ zlib for FlateDecode).

These take REAL paths and live on the trusted side. The alias->path resolution
happens in `vault.mojo`; nothing here knows about aliases.
"""

from pdf import read_file, extract_text


def csv_rows(path: String) raises -> List[List[String]]:
    """Parse a CSV into rows of trimmed string fields.

    Simple split: newline -> rows, comma -> fields, each field `.strip()`ed. No
    quote/embedded-comma handling (good enough for the vault's flat tables).
    Returns ALL rows including the header; the caller decides whether to skip it.
    Empty trailing lines are dropped.
    """
    var rows = List[List[String]]()
    var text: String
    with open(path, "r") as f:
        text = f.read()
    if text.byte_length() == 0:
        return rows^
    var lines = text.split("\n")
    for i in range(len(lines)):
        var line = String(String(lines[i]).strip())
        if line.byte_length() == 0:
            continue
        var fields = line.split(",")
        var row = List[String]()
        for j in range(len(fields)):
            row.append(String(String(fields[j]).strip()))
        rows.append(row^)
    return rows^


def md_text(path: String) raises -> String:
    """Read a markdown (or any text) file's contents verbatim."""
    var text: String
    with open(path, "r") as f:
        text = f.read()
    return text^


def pdf_text(path: String) raises -> String:
    """Extract text from a PDF via pdftotext.mojo.

    Reads the raw bytes and runs the extractor (which uses the zlib shim for
    /FlateDecode streams). Returns the raw extracted text — unlike the pdftotext
    CLI we do NOT escape control characters, since this feeds embedding/ask_local
    rather than a terminal.
    """
    var data = read_file(path)
    return extract_text(data)
