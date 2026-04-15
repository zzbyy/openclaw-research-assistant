# Wiki Skill — Step-by-Step Walkthrough

Your personal knowledge wiki, powered by LLMs. Drop papers in, ask questions, get structured knowledge out — all from Feishu.

---

## 1. Install

```bash
curl -sSL https://raw.githubusercontent.com/zzbyy/openclaw-research-assistant/main/remote-install.sh | bash
```

The installer asks two questions:
- **Where to install**: globally or into a specific agent's workspace (lists agents from `openclaw.json`)
- **Obsidian vault path**: where your wiki and source files will live

It then sets up the vault structure, installs the skill + Python extraction pipeline, and optionally installs Claude Code, cc-bridge, and QMD.

---

## 2. Verify

```bash
ls <your-vault>/wiki/          # index.md, log.md, ingest.py (.schema.md is hidden)
ls <your-vault>/sources/       # pdfs/, html/, epub/, markdown/
```

Quick smoke test from Feishu:
```
/wiki status
```

You should see 0 pages, 0 sources — an empty wiki ready to go.

---

## 3. Set Up Semantic Search (Optional but Recommended)

Install [QMD](https://github.com/tobi/qmd) for hybrid search (BM25 + vector + LLM reranker). Fully local, no API keys.

```bash
npm install -g qmd
```

For CJK + English papers, set a multilingual embedding model:
```bash
echo 'export QMD_EMBED_MODEL="hf:Qwen/Qwen3-Embedding-0.6B-GGUF/Qwen3-Embedding-0.6B-Q8_0.gguf"' >> ~/.zshrc
source ~/.zshrc
```

Models auto-download on first use (~2GB total). Without QMD, search falls back to keyword grep.

---

## 4. Add Your Sources

Copy your files into the vault's `sources/` directory:

```bash
cp ~/papers/*.pdf <vault>/sources/pdfs/
cp ~/articles/*.md <vault>/sources/markdown/
cp ~/books/*.epub <vault>/sources/epub/
```

---

## 5. Build the Wiki

### What happens behind the scenes

When you run `/wiki batch`, two things happen automatically:

**Phase 1 — Python text extraction** (fast, free, no LLM)
- Scans `sources/pdfs/`, `sources/epub/` for unextracted files
- Extracts text + metadata from each PDF/EPUB/MOBI
- Writes clean markdown entries to `wiki/.entries/`
- Markdown and HTML source files skip this step — they're already readable

**Phase 2 — LLM absorption** (creates wiki pages)
- Reads each entry from `.entries/` (or markdown/HTML sources directly)
- Identifies key concepts, methods, people, techniques
- Creates wiki pages in type subdirectories (e.g., `concepts/`, `methods/`, `books/`)
- Subdirectories are created dynamically based on content — not predefined
- Cross-references between pages via `[[wikilinks]]`
- Updates `index.md` and `log.md`

### Commands

**Process a single batch:**
```
/wiki batch                     # extract all pending → absorb next 10
/wiki batch --limit 30          # absorb next 30
```

**Process everything automatically:**
```
/wiki batch --auto              # extract all → absorb all, loop until done
```

**Preview first:**
```
/wiki batch --dry-run           # show what would be processed
```

**Filter:**
```
/wiki batch --match "CAR-T"     # only matching entries
```

**Backend choice:**
```
/wiki batch --auto                        # uses OpenClaw agent (default, cheaper)
/wiki batch --auto --backend cc           # uses Claude Code (heavier, more capable)
```

### First-time with 1600+ papers

```
/wiki batch --auto
```

This extracts all PDFs first (takes minutes, free), then feeds entries to the agent batch by batch. Progress notifications arrive in Feishu:

```
[Wiki] Step 1: Extracting text from sources...
[Wiki] Extracted 1688 new entries (3 failed)
[Wiki] Auto batch: 1688 entries to process (batches of 10)
[Wiki] Absorbing batch 1 (10 entries)...
[Wiki] Batch 1: 10/10 absorbed...
[Wiki] Absorbing batch 2 (10 entries)...
...
[Wiki] Complete: 1688 absorbed, 3 failed, 0 remaining.
```

You can also use `/wiki ingest <path>` to add a single file — it copies it to the right subdirectory automatically.

### After ingestion

Open Obsidian — you'll see:
- Type subdirectories: `concepts/`, `methods/`, `books/`, `people/`, etc.
- Wiki pages with structured frontmatter and `[[wikilinks]]`
- Graph view showing connections between concepts
- `index.md` with a categorized master index

---

## 6. Query the Wiki

Ask questions about what you've ingested:

```
/wiki query "what is the key innovation in CAR-T therapy?"
```

The answer comes back with:
- `[[wikilinks]]` citing relevant wiki pages
- Gaps identified if the wiki doesn't cover something yet

When QMD is installed, queries use hybrid semantic search to find relevant pages — even when exact keywords don't match.

### Conversational mode

Just talk naturally to the research agent in Feishu:

> "How do dendritic cell vaccines compare to CAR-T?"

The agent reads relevant wiki pages and synthesizes an answer. No command needed.

---

## 7. Search & Browse

**Keyword search:**
```
/wiki search attention
```

**Semantic search** (finds conceptual matches):
```
/wiki search "manufacturing challenges" --semantic
```

**Read a page:**
```
/wiki browse self-attention
```

**Explore connections:**
```
/wiki related transformer-architecture
```

Shows typed relationships: depends_on, used_by, supersedes, related — plus backlinks.

---

## 8. Lint — Keep the Wiki Healthy

```
/wiki lint
```

Checks for:
- **Contradictions** — pages with conflicting claims
- **Orphan pages** — not linked from index or other pages
- **Broken wikilinks** — `[[links]]` pointing to non-existent pages
- **Missing cross-references** — pages discussing same topics without linking
- **Index completeness** — pages missing from `index.md`

When contradictions are found, a `> [!warning] Contradiction` callout is added — the wiki doesn't silently overwrite.

---

## 9. Obsidian Integration

Your wiki is native Obsidian markdown. Everything works:

- **Graph view** — connections between concepts, methods, papers, people
- **Wikilinks** — `[[page-name]]` links work throughout
- **Tags** — `#topic/subtopic` tags are browsable
- **Frontmatter** — visible in reading view and properties panel

If Obsidian skills are installed, the wiki uses them for proper formatting.

### Dataview queries

```dataview
TABLE type, sources
FROM "wiki/concepts"
SORT title ASC
```

```dataview
LIST
FROM "wiki/methods"
WHERE contains(related, "[[CAR-T]]")
```

---

## 10. Scheduled Automation (Optional)

```
/wiki cron lint --every "sunday 9am"        # weekly health check
/wiki cron ingest --every "daily 6am"       # daily auto-ingest new sources
/wiki cron status                           # show schedules
/wiki cron lint --disable                   # turn off
```

---

## 11. Configuration

```
/wiki config                                  # show all
/wiki config default_backend cc               # switch to Claude Code
/wiki config batch.default_limit 20           # change batch size
/wiki config notifications.progress_interval 5  # progress every 5 files
```

Config lives alongside the skill (`config.json`).

---

## 12. Troubleshooting

**No response from `/wiki` commands?**
```bash
openclaw skills info wiki
openclaw gateway restart
```

**Extraction failed for some PDFs?**
Install better extractors:
```bash
brew install poppler                         # pdftotext
pip install PyPDF2 ebooklib beautifulsoup4 lxml  # Python fallbacks
```

**Search not finding pages?**
```
/wiki reindex
```

**Want to start over?**
Delete wiki content (keep sources):
```bash
rm -rf <vault>/wiki/concepts <vault>/wiki/books <vault>/wiki/methods ...
rm -f <vault>/wiki/.entries/.absorbed
rm -f <vault>/wiki/index.md <vault>/wiki/log.md
# Re-run install to restore index.md and log.md templates
```

---

## 13. Upgrading

From Feishu:
```
/wiki upgrade
```

From terminal:
```bash
curl -sSL https://raw.githubusercontent.com/zzbyy/openclaw-research-assistant/main/remote-install.sh | bash
```

Both are idempotent — config, wiki pages, sources, and search index are preserved.
