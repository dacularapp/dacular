"""Index — chunk + embed the vault into an on-device LanceDB vector store.

Pipeline (`build_index`): walk the manifest, read each file's text (csv -> joined
rows, md -> text, pdf -> extracted text), CHUNK it (~512-char windows on
paragraph/line boundaries), embed each chunk via the local inference-server, and
`Store.add` (chunk_id Int64, 1024-d vector) into a LanceDB table.

Only ids + vectors cross into LanceDB. The chunk text + its file alias live in a
side-table persisted as TSV next to the db, so `search()` can resolve a returned
chunk_id back to its alias + text. Real paths NEVER enter the side-table — only
aliases — so search results are alias-safe.

Layout (under ~/.config/dacular):
  index.db/      — the LanceDB database (table "chunks", dim 1024)
  chunks.tsv     — chunk_id <TAB> file_alias <TAB> escaped_text
"""

from std.os import getenv, makedirs
from std.os.path import exists

from lancedb import Store
from manifest import build_manifest, FileInfo
from readers import csv_rows, md_text, pdf_text
from embed import embed, EMBED_DIM


comptime CHUNK_SIZE = 512
comptime TABLE = "chunks"


@fieldwise_init
struct Chunk(Copyable, Movable):
    """A search hit: which file (by alias), the chunk text, and its score
    (smaller distance = closer; we expose it as `.score` per the tool contract)."""
    var file_alias: String
    var text: String
    var score: Float32


# ── paths ─────────────────────────────────────────────────────────────────────

def _config_dir() raises -> String:
    return getenv("HOME", ".") + "/.config/dacular"


def _db_uri() raises -> String:
    return _config_dir() + "/index.db"


def _sidetable_path() raises -> String:
    return _config_dir() + "/chunks.tsv"


# ── TSV escaping for the side-table ───────────────────────────────────────────

def _replace_all(s: String, old: String, new: String) raises -> String:
    var parts = s.split(old)
    var out = String("")
    for i in range(len(parts)):
        if i > 0:
            out += new
        out += String(parts[i])
    return out^


def _tsv_escape(s: String) raises -> String:
    """Make `s` a single TSV cell: backslash-escape \\, tab, newline, CR."""
    var o = _replace_all(s, String("\\"), String("\\\\"))
    o = _replace_all(o, String("\t"), String("\\t"))
    o = _replace_all(o, String("\n"), String("\\n"))
    o = _replace_all(o, String("\r"), String("\\r"))
    return o^


def _tsv_unescape(s: String) raises -> String:
    """Inverse of `_tsv_escape` — left-to-right scan so escapes don't compound."""
    var out = String("")
    var bytes = s.as_bytes()
    var i = 0
    while i < len(bytes):
        var c = Int(bytes[i])
        if c == 92 and i + 1 < len(bytes):  # backslash
            var n = Int(bytes[i + 1])
            if n == 116:    # 't'
                out += "\t"; i += 2; continue
            elif n == 110:  # 'n'
                out += "\n"; i += 2; continue
            elif n == 114:  # 'r'
                out += "\r"; i += 2; continue
            elif n == 92:   # backslash
                out += "\\"; i += 2; continue
        out += chr(c)
        i += 1
    return out^


# ── chunking ──────────────────────────────────────────────────────────────────

def _file_text(fi: FileInfo) raises -> String:
    """Read a file to plain text per its kind. CSV rows are joined back with
    commas/newlines so semantically-related cells stay together in a chunk."""
    if fi.kind == "csv":
        var rows = csv_rows(fi.path)
        var out = String("")
        for i in range(len(rows)):
            if i > 0:
                out += "\n"
            for j in range(len(rows[i])):
                if j > 0:
                    out += ", "
                out += rows[i][j]
        return out^
    elif fi.kind == "md":
        return md_text(fi.path)
    elif fi.kind == "pdf":
        return pdf_text(fi.path)
    return String("")


def _chunk_text(text: String) raises -> List[String]:
    """Split `text` into ~CHUNK_SIZE-byte chunks on line boundaries (so we don't
    cut mid-line). A single over-long line becomes its own chunk."""
    var chunks = List[String]()
    var lines = text.split("\n")
    var cur = String("")
    for i in range(len(lines)):
        var line = String(lines[i])
        if cur.byte_length() > 0 and cur.byte_length() + line.byte_length() + 1 > CHUNK_SIZE:
            chunks.append(cur^)
            cur = String("")
        if cur.byte_length() > 0:
            cur += "\n"
        cur += line
    if String(cur.strip()).byte_length() > 0:
        chunks.append(cur^)
    return chunks^


# ── side-table persistence ────────────────────────────────────────────────────

def _write_sidetable(aliases: List[String], texts: List[String]) raises:
    """Persist chunk_id -> (file_alias, text). chunk_id is the row index."""
    var out = String("")
    for i in range(len(aliases)):
        out += String(i) + "\t" + _tsv_escape(aliases[i]) + "\t" + _tsv_escape(texts[i]) + "\n"
    with open(_sidetable_path(), "w") as f:
        f.write(out)


def _load_sidetable() raises -> Tuple[List[String], List[String]]:
    """Load the side-table -> (aliases, texts) indexed by chunk_id."""
    var aliases = List[String]()
    var texts = List[String]()
    if not exists(_sidetable_path()):
        raise Error("no index side-table at " + _sidetable_path() + " — run `dacular index` first")
    var text: String
    with open(_sidetable_path(), "r") as f:
        text = f.read()
    var lines = text.split("\n")
    for i in range(len(lines)):
        var line = String(lines[i])
        if line.byte_length() == 0:
            continue
        var cols = line.split("\t")
        if len(cols) < 3:
            continue
        # cols[0] is the chunk_id == row index; rows are written in order.
        aliases.append(_tsv_unescape(String(cols[1])))
        texts.append(_tsv_unescape(String(cols[2])))
    return (aliases^, texts^)


# ── build ─────────────────────────────────────────────────────────────────────

def build_index(data_dir: String, base_url: String) raises:
    """Chunk + embed every file in `data_dir`'s manifest into the LanceDB store.

    Requires the inference-server embeddings endpoint to be live at `base_url`
    (e.g. http://127.0.0.1:8000/v1); a failed embed aborts with a clear error.
    """
    makedirs(_config_dir(), exist_ok=True)
    var infos = build_manifest(data_dir)

    var aliases = List[String]()
    var texts = List[String]()
    var ids = List[Int64]()
    var vectors = List[Float32]()

    var next_id = 0
    for i in range(len(infos)):
        ref fi = infos[i]
        var body = _file_text(fi)
        var chunks = _chunk_text(body)
        print("  " + fi.id + " [" + fi.kind + "] -> " + String(len(chunks)) + " chunk(s)")
        for c in range(len(chunks)):
            var vec: List[Float32]
            try:
                vec = embed(base_url, chunks[c])
            except err:
                raise Error(
                    "build_index: embedding " + fi.id + " chunk " + String(c)
                    + " failed (is the inference-server embedding model serving at "
                    + base_url + "?): " + String(err)
                )
            if len(vec) != EMBED_DIM:
                raise Error(
                    "build_index: embedding dim " + String(len(vec))
                    + " != expected " + String(EMBED_DIM)
                )
            ids.append(Int64(next_id))
            for d in range(len(vec)):
                vectors.append(vec[d])
            aliases.append(fi.id.copy())
            texts.append(chunks[c].copy())
            next_id += 1

    var store = Store(_db_uri(), String(TABLE), EMBED_DIM)
    store.add(ids, vectors)
    _write_sidetable(aliases, texts)
    print("indexed " + String(len(ids)) + " chunk(s) into " + _db_uri())


def search(query: String, k: Int, base_url: String) raises -> List[Chunk]:
    """Semantic search: embed `query`, k-NN over the LanceDB store, resolve each
    returned chunk_id back to (file_alias, text) via the side-table. Nearest
    first. Requires the index to exist and the embedding endpoint to be live."""
    var sidetable = _load_sidetable()
    var aliases = sidetable[0].copy()
    var texts = sidetable[1].copy()

    # Qwen3-Embedding is instruction-tuned: QUERIES get an instruction prefix,
    # documents (the indexed chunks) stay raw. This materially improves ranking.
    var q_instructed = String(
        "Instruct: Given a search query, retrieve relevant passages that answer"
        " it.\nQuery: "
    ) + query
    var qvec = embed(base_url, q_instructed)
    var store = Store(_db_uri(), String(TABLE), EMBED_DIM)
    var result = store.search(qvec, k)
    var ids = result[0].copy()
    var dists = result[1].copy()

    var hits = List[Chunk]()
    for i in range(len(ids)):
        var cid = Int(ids[i])
        if cid < 0 or cid >= len(aliases):
            continue
        hits.append(Chunk(aliases[cid].copy(), texts[cid].copy(), dists[i]))
    return hits^
