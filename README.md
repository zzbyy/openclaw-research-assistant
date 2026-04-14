# OpenClaw Wiki Skill

A personal knowledge wiki following [Karpathy's LLM Wiki method](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) with v2 extensions.

Drop papers, articles, and documents into your wiki. An LLM reads them, writes structured wiki pages, cross-references everything, and maintains consistency — all inside your Obsidian vault.

## Features

- **Three-layer architecture**: raw sources (immutable) → wiki pages (LLM-maintained) → schema (conventions)
- **Obsidian-native**: wikilinks, YAML frontmatter, tags, Dataview-compatible
- **Confidence scoring**: each page tracks confidence (high/medium/low) based on sources, recency, contradictions
- **Contradiction detection**: flags when new sources conflict with existing knowledge
- **Typed entities**: concept, method, person, paper, dataset, tool — with semantic relationships (depends_on, used_by, supersedes)
- **Dual backend**: Claude Code (via [cc-bridge](https://github.com/zzbyy/openclaw-cc-bridge)) for heavy lifting, or OpenClaw agent for quick lookups
- **Cron automation**: optional periodic lint and auto-ingest via OpenClaw scheduled jobs

## Quick Install

```bash
curl -sSL https://raw.githubusercontent.com/zzbyy/openclaw-research-assistant/main/remote-install.sh | bash
```

The installer prompts for:
1. **Install scope** — global (all agents) or specific agent workspace
2. **Obsidian vault path** — where your vault lives
3. **Default backend** — Claude Code or OpenClaw agent

## Two Interaction Modes

### Mode A: Claude Code (via cc-bridge)

Heavy lifting — PDF ingestion, complex multi-page updates, full lint.

```
/wiki ingest ~/papers/attention-is-all-you-need.pdf
/wiki lint --backend cc
```

Flow: Feishu → OpenClaw → wiki skill → cc-bridge → Claude Code → Feishu notification

### Mode B: Direct Agent

Quick lookups — queries, search, browse, status.

```
/wiki query "how does self-attention work?"
/wiki search transformer
/wiki status
```

Also works conversationally — just ask the research agent a question in Feishu and it reads the wiki to answer.

## Commands

| Command | Description |
|---------|-------------|
| `/wiki ingest <path>` | Ingest a document (PDF, HTML, EPUB, markdown) |
| `/wiki query <question>` | Query the wiki |
| `/wiki lint` | Health check: contradictions, orphans, staleness, confidence decay |
| `/wiki search <term>` | Search wiki pages by keyword |
| `/wiki status` | Wiki statistics and health overview |
| `/wiki browse <page>` | Read a specific wiki page |
| `/wiki related <page>` | Find related pages via typed relationships |
| `/wiki config [key] [value]` | View or update configuration |
| `/wiki cron <lint\|ingest> [opts]` | Manage scheduled jobs |
| `/wiki catalog` | Scan sources and build a lightweight catalog (no LLM calls) |
| `/wiki init [--auto N]` | Guided first-time initialization — catalog, pick top papers, ingest |
| `/wiki batch [--limit N] [opts]` | Batch ingest pending sources with filters |

All commands accept `--backend cc|agent` to override the default.

### First-Time Initialization

```
/wiki catalog                               # scan all sources, build catalog.md
/wiki init                                  # pick top 15 papers, start ingesting
/wiki init --auto 20                        # pick top 20 instead
/wiki batch --limit 10                      # ingest next 10 pending files
/wiki batch --match "transformer" --limit 5 # filter by filename pattern
/wiki batch --dry-run                       # preview without ingesting
```

### Cron Automation

```
/wiki cron lint --every "sunday 9am"       # weekly lint
/wiki cron ingest --every "daily 6am"      # daily auto-ingest new sources
/wiki cron status                           # show current schedules
/wiki cron lint --disable                   # turn off
```

## Architecture

```
Feishu ←→ OpenClaw Research Agent ←→ Wiki Skill
                                        ├── Claude Code (cc-bridge)
                                        └── Direct agent

Obsidian Vault/
├── sources/          ← Raw documents (immutable)
│   ├── pdfs/
│   ├── html/
│   ├── epub/
│   └── markdown/
├── wiki/             ← LLM-generated pages
│   ├── CLAUDE.md     ← Schema (conventions, operations)
│   ├── index.md      ← Category catalog
│   ├── log.md        ← Operation log
│   └── pages/        ← Wiki articles
└── ...
```

## Wiki Page Format

Every wiki page has structured frontmatter:

```yaml
---
title: "Self-Attention Mechanism"
type: concept
confidence: high
source_count: 3
sources:
  - "[[../sources/pdfs/attention-is-all-you-need.pdf]]"
created: 2026-04-14
updated: 2026-04-14
last_verified: 2026-04-14
status: consolidated
tags:
  - deep-learning/attention
depends_on:
  - "[[dot-product-attention]]"
used_by:
  - "[[transformer-architecture]]"
related:
  - "[[cross-attention]]"
---
```

Use Obsidian Dataview to query typed relationships:

```dataview
TABLE type, confidence, source_count
FROM "wiki/pages"
WHERE depends_on AND contains(depends_on, "[[transformer-architecture]]")
```

## Configuration

Config lives at `~/.openclaw/wiki/config.json`:

```
/wiki config                              # show all
/wiki config vault_path                   # show specific key
/wiki config default_backend agent        # update value
```

## Prerequisites

- **Required**: `jq`
- **Recommended**: `openclaw` (for Feishu integration)
- **Optional**: `claude` CLI + [cc-bridge](https://github.com/zzbyy/openclaw-cc-bridge) (for Claude Code backend)

## File Locations

| What | Where |
|------|-------|
| Skill | `~/.agents/skills/wiki/` or `<agent-workspace>/skills/wiki/` |
| Config | `<skill-dir>/config.json` (lives alongside the skill) |
| Wiki pages | `<vault>/wiki/pages/` |
| Schema | `<vault>/wiki/CLAUDE.md` |
| Sources | `<vault>/sources/` |
| Index | `<vault>/wiki/index.md` |
| Log | `<vault>/wiki/log.md` |
