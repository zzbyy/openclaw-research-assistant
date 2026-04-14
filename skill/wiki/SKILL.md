---
name: wiki
description: LLM-maintained knowledge wiki — ingest papers, query knowledge, lint for consistency
metadata:
  openclaw:
    emoji: "\U0001F4DA"
    requires:
      anyBins:
        - jq
---

# Wiki Skill

Personal knowledge wiki following Karpathy's LLM Wiki method with v2 extensions
(confidence scoring, contradiction detection, typed entities, cron automation).

## Commands

| Command | Script | Description |
|---------|--------|-------------|
| `/wiki ingest <path>` | `scripts/wiki-entry.sh ingest` | Ingest a document into the wiki |
| `/wiki query <question>` | `scripts/wiki-entry.sh query` | Query the wiki with a question |
| `/wiki lint` | `scripts/wiki-entry.sh lint` | Health check: contradictions, orphans, staleness |
| `/wiki search <term>` | `scripts/wiki-entry.sh search` | Search wiki pages by keyword |
| `/wiki status` | `scripts/wiki-entry.sh status` | Wiki statistics and health overview |
| `/wiki browse <topic>` | `scripts/wiki-entry.sh browse` | Browse a specific topic or page |
| `/wiki related <page>` | `scripts/wiki-entry.sh related` | Find related pages via typed relationships |
| `/wiki config <key> [value]` | `scripts/wiki-entry.sh config` | View or update wiki configuration |
| `/wiki cron <lint\|ingest> [opts]` | `scripts/wiki-entry.sh cron` | Manage scheduled lint and auto-ingest jobs |
| `/wiki catalog [--format <type>]` | `scripts/wiki-entry.sh catalog` | Scan sources and build a lightweight catalog |
| `/wiki init [--auto <count>]` | `scripts/wiki-entry.sh init` | Guided first-time wiki initialization |
| `/wiki batch [--limit N] [opts]` | `scripts/wiki-entry.sh batch` | Batch ingest pending sources |

## Global Flags

All commands accept:
- `--backend cc|agent` — override default backend (Claude Code via cc-bridge, or direct agent)

## Routing

All `/wiki` commands route through `scripts/wiki-entry.sh` which parses the subcommand
and dispatches to the appropriate script.

### MANDATORY — command dispatch

When the user sends `/wiki <subcommand> [args]`, run:

```bash
scripts/wiki-entry.sh <subcommand> [args]
```

Pass all arguments through. Do not interpret or modify them.
