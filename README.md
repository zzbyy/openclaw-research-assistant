# OpenClaw Wiki Skill

A personal knowledge wiki following [Karpathy's LLM Wiki method](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) with v2 extensions.

Drop papers, articles, and documents into your wiki. An LLM reads them, writes structured wiki pages, cross-references everything, and maintains consistency — all inside your Obsidian vault.

## How It Works

Two-phase pipeline:

```
Source files (PDF/EPUB/MOBI)          Markdown/HTML/text files
        │                                      │
        ▼                                      │
  Python extraction                            │
  (text + metadata → .entries/)                │
        │                                      │
        ▼                                      ▼
            LLM absorbs entries into wiki pages
            (creates type subdirectories dynamically)
                        │
                        ▼
              QMD reindexes (if installed)
```

**Phase 1** (Python, fast, free): Extracts text from PDFs/EPUBs/MOBIs into `.entries/` as clean markdown with metadata. Markdown/HTML source files skip this step — they're already readable.

**Phase 2** (LLM): Reads extracted entries, identifies concepts/methods/people/techniques, creates wiki pages in type subdirectories (`concepts/`, `books/`, `methods/`, etc.), cross-references everything, updates index.

## Features

- **Two-phase ingest**: Python extracts text → LLM synthesizes wiki pages (faster, cheaper, more reliable)
- **Obsidian-native**: wikilinks, YAML frontmatter, tags, Dataview-compatible
- **Dynamic type subdirectories**: `concepts/`, `methods/`, `books/`, `people/`, etc. — created as content demands
- **Contradiction detection**: flags when new sources conflict with existing knowledge
- **Dual backend**: OpenClaw agent (default, cheaper) or Claude Code (via [cc-bridge](https://github.com/zzbyy/openclaw-cc-bridge), heavier)
- **Auto-batch mode**: `--auto` processes all sources end-to-end without intervention
- **Semantic search**: [QMD](https://github.com/tobi/qmd) hybrid search (BM25 + vector + LLM reranker), fully local, no API keys
- **Progress notifications**: batch progress sent directly to Feishu during processing
- **Obsidian skills**: uses Obsidian markdown skills when available for proper formatting
- **Cron automation**: optional periodic lint and auto-ingest via OpenClaw scheduled jobs

## Quick Install

```bash
curl -sSL https://raw.githubusercontent.com/zzbyy/openclaw-research-assistant/main/remote-install.sh | bash
```

The installer prompts for:
1. **Install scope** — global or specific agent workspace (reads agents from `openclaw.json`)
2. **Obsidian vault path** — where your vault lives

It also offers to install Claude Code, cc-bridge, and QMD if not already present.

## Commands

| Command | What it does |
|---------|-------------|
| `/wiki batch [--limit N]` | Extract pending sources + absorb entries into wiki pages |
| `/wiki batch --auto` | Extract + absorb everything, loop until done |
| `/wiki init` | Same as batch (alias for first-time use) |
| `/wiki ingest <path>` | Ingest a single file (extract + absorb) |
| `/wiki query <question>` | Query the wiki (semantic search via QMD when available) |
| `/wiki search <term>` | Search wiki pages (keyword or `--semantic` for hybrid) |
| `/wiki lint` | Health check: contradictions, orphans, broken links |
| `/wiki status` | Wiki statistics and health overview |
| `/wiki browse <page>` | Read a specific wiki page |
| `/wiki related <page>` | Find related pages via typed relationships |
| `/wiki catalog [--quick]` | Scan sources, build `.catalog.json` |
| `/wiki reindex [--full]` | Update QMD search index (incremental by default) |
| `/wiki config [key] [value]` | View or update configuration |
| `/wiki cron <lint\|ingest> [opts]` | Manage scheduled jobs |
| `/wiki upgrade` | Pull latest from GitHub and update skill in place |

All commands accept `--backend cc|agent` (default: `agent`).

### Typical Workflow

```bash
# 1. Drop files into sources/
cp ~/papers/*.pdf <vault>/sources/pdfs/

# 2. Process everything
/wiki batch --auto                    # extract all → absorb all

# 3. Ask questions
/wiki query "what is CAR-T therapy?"

# 4. Keep adding
# Drop more files into sources/, run batch again
/wiki batch --limit 20
```

### Batch Options

```
/wiki batch                                 # extract + absorb next 10 (default limit)
/wiki batch --limit 30                      # absorb 30
/wiki batch --auto                          # absorb everything, loop until done
/wiki batch --match "immunology"            # only matching entries
/wiki batch --dry-run                       # preview without absorbing
/wiki batch --auto --backend cc             # use Claude Code instead of agent
/wiki config batch.default_limit 20         # change default limit
```

### Semantic Search (QMD)

```
/wiki search "CAR-T"                        # keyword search (fast)
/wiki search "CAR-T manufacturing" --semantic  # hybrid: BM25 + vector + reranker
/wiki query "what are the challenges?"      # auto-uses QMD when available
/wiki reindex                               # update search index
```

## Architecture

```
Feishu ←→ OpenClaw Research Agent ←→ Wiki Skill
                                        ├── Python (text extraction)
                                        ├── Agent (absorb, default)
                                        ├── Claude Code (absorb, --backend cc)
                                        └── QMD (semantic search, local)

Obsidian Vault/
├── sources/              ← Raw documents (immutable)
│   ├── pdfs/
│   ├── html/
│   ├── epub/
│   └── markdown/
├── wiki/                 ← LLM-generated wiki
│   ├── .schema.md        ← Schema (hidden from Obsidian)
│   ├── .entries/         ← Extracted text from sources (hidden)
│   ├── .catalog.json     ← Source catalog (hidden)
│   ├── index.md          ← Master index of all wiki pages
│   ├── log.md            ← Operation log
│   ├── concepts/         ← Created dynamically
│   ├── methods/          ←   by the LLM
│   ├── books/            ←   based on content
│   ├── people/           ←   (not pre-defined)
│   └── ...
└── ...
```

## Wiki Page Format

Pages are placed in type subdirectories with structured frontmatter:

```yaml
---
title: "Self-Attention Mechanism"
type: concept
created: 2026-04-14
last_updated: 2026-04-14
sources: ["a1b2c3d4e5f6"]
related: ["[[cross-attention]]", "[[transformer-architecture]]"]
---
```

Use Obsidian Dataview to query:

```dataview
TABLE type, sources
FROM "wiki/concepts"
SORT title ASC
```

## Configuration

Config lives alongside the skill (`<skill-dir>/config.json`):

```
/wiki config                                  # show all
/wiki config default_backend cc               # switch to Claude Code
/wiki config batch.default_limit 20           # change batch size
/wiki config notifications.progress_interval 5  # progress every 5 files
```

## Prerequisites

- **Required**: `jq`, `python3`
- **Recommended**: `openclaw` (for Feishu integration)
- **Recommended for PDFs**: `pdftotext` (poppler) — `brew install poppler`
- **Recommended for EPUBs**: `pip install ebooklib beautifulsoup4 lxml`
- **Optional**: `claude` CLI + [cc-bridge](https://github.com/zzbyy/openclaw-cc-bridge) (for `--backend cc`)
- **Optional**: [QMD](https://github.com/tobi/qmd) (for semantic search — `npm install -g qmd`)

## File Locations

| What | Where |
|------|-------|
| Skill | `<agent-workspace>/skills/wiki/` |
| Config | `<skill-dir>/config.json` |
| Wiki pages | `<vault>/wiki/<type>/` (dynamic subdirectories) |
| Schema | `<vault>/wiki/.schema.md` (hidden) |
| Extracted text | `<vault>/wiki/.entries/` (hidden) |
| Catalog | `<vault>/wiki/.catalog.json` (hidden) |
| Sources | `<vault>/sources/` |
| Index | `<vault>/wiki/index.md` |
| Log | `<vault>/wiki/log.md` |
| QMD index | `~/.cache/qmd/` (auto-managed) |
