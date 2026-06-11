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


def _row_all_empty(row: List[String]) -> Bool:
    for i in range(len(row)):
        if row[i].byte_length() > 0:
            return False
    return True


def csv_rows(path: String) raises -> List[List[String]]:
    """Parse a CSV into rows of string fields, RFC-4180 style.

    A proper state machine (UTF-8-safe, over codepoints): handles `"`-quoted
    fields, embedded commas, embedded newlines inside quotes, and `""` escaped
    quotes. Unquoted fields are trimmed; quoted fields are kept verbatim (so
    `"1,234.56"` survives intact — the case the old naive split broke). Fully
    empty rows (blank lines) are dropped. Returns ALL rows incl. the header.
    """
    var rows = List[List[String]]()
    var text: String
    with open(path, "r") as f:
        text = f.read()
    if text.byte_length() == 0:
        return rows^

    var row = List[String]()
    var field = String("")
    var field_quoted = False     # was the current field opened with a quote?
    var in_quotes = False
    var pending_quote = False    # saw a `"` inside quotes — escape or close?

    for cp in text.codepoint_slices():
        var ch = String(cp)
        if pending_quote:
            pending_quote = False
            if ch == '"':
                field += '"'      # "" -> literal quote, stay in the quoted field
                continue
            in_quotes = False     # the quote closed the field; fall through to ch
        if in_quotes:
            if ch == '"':
                pending_quote = True
            else:
                field += ch       # includes newlines inside quotes
            continue
        # ── unquoted ──
        if ch == '"':
            in_quotes = True
            field_quoted = True
        elif ch == ",":
            row.append(field if field_quoted else String(field.strip()))
            field = String(""); field_quoted = False
        elif ch == "\n":
            row.append(field if field_quoted else String(field.strip()))
            if not _row_all_empty(row):
                rows.append(row.copy())
            row = List[String](); field = String(""); field_quoted = False
        elif ch == "\r":
            pass                  # skip CR (CRLF handled by the LF case)
        else:
            field += ch

    # flush a trailing field/row with no terminating newline
    if field.byte_length() > 0 or len(row) > 0:
        row.append(field if field_quoted else String(field.strip()))
        if not _row_all_empty(row):
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
