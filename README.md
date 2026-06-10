# dacular

> Part of [**millrace**](https://millrace.me) — local-first AI on Apple Silicon.
> **Experimental.**

Ask open-ended questions about your own files — *"how much did I spend on travel
last year?"*, *"when do I renew my insurance?"*, *"what's the license plate of my
car?"* — over a private vault of **CSV, PDF, and Markdown** documents, **without
your data ever leaving the machine**.

dacular is the **vault application**. It builds on the
[headgate](https://github.com/millrace/headgate) privacy harness and the millrace
toolbox: [lancedb.mojo](https://github.com/millrace/lancedb.mojo) for the on-device
vector index, [pdftotext.mojo](https://github.com/millrace/pdftotext.mojo) for PDF
extraction, and the local [inference server](https://github.com/millrace/mojo-backend)
as the trusted on-device reader.

## How the privacy model works

There are **two models**, deliberately asymmetric:

- A **frontier model** (untrusted) is the *planner/coder*. It answers your
  question by writing **one Mojo program** that calls a fixed set of vault
  **tools**. It sees only a **sanitized manifest** — file *aliases* (`file_0`),
  kinds, and aliased column schemas (`col_2`) — never the contents, names, or
  paths. The program's results never return to it.
- A **local model** (trusted, on your device) is the *reader*. When the program
  needs to understand content — "is this a travel expense?", "extract the renewal
  date" — it calls `ask_local(instruction, content)`, which runs on the inference
  server and sees the real text.

So the frontier model orchestrates over aliases; the local model reads; the data
and the final answer stay on the machine. This is enforced by headgate's egress
guard and a network-denied sandbox — the generated program runs locally and can
only reach the local model.

## The vault tools

The generated program does `from vault import *` and has:

| tool | purpose |
|---|---|
| `manifest()` | the aliased file list (`.alias`, `.kind`, `.size`, csv `.columns`) |
| `search(query, k)` | semantic search across the indexed vault → ranked chunks |
| `csv_rows(alias)` | a table's rows, columns by alias |
| `pdf_text(alias)` | extracted text of a PDF (via pdftotext.mojo) |
| `md_text(alias)` | a markdown file's text |
| `ask_local(instruction, content)` | the trusted on-device reader |
| `print_answer(s)` | emit the final answer (local only) |

## Pipeline

```
your files ─▶ index: chunk + embed (local) ─▶ LanceDB vector store
                                                      │
question ─▶ headgate: frontier writes a vault program │ (sees only aliases)
                          │                           ▼
                          └─▶ sandbox run ─▶ search / read / ask_local ─▶ answer (local)
```

## Status

Early scaffold. Building outward from the manifest (the confidentiality boundary)
→ readers → indexer (LanceDB) → the `vault` tool library → the headgate-driven
`ask` loop.

## Use (so far)

```sh
pixi run manifest -- ~/dacular            # print the aliased manifest for a vault dir
```
