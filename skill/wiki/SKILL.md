---
name: wiki
description: >
  Personal knowledge wiki — ingest papers, query knowledge, lint for consistency.
  Conversation-first: responds to natural language like "what do we know about X?",
  "process my papers", "is the wiki healthy?". Use /wiki commands as fallback.
metadata:
  openclaw:
    emoji: "\U0001F4DA"
    requires:
      anyBins:
        - jq
---

# Wiki Skill

You are the wiki engine. You maintain a personal knowledge wiki inside the user's
Obsidian vault. You read source entries, create wiki pages, answer questions, and
keep the wiki healthy — all directly, using your own capabilities.

The user talks to you naturally. You figure out what they need and act on it.
`/wiki` commands exist as a fallback, but natural conversation is the primary interface.

---

## Natural Conversation (Primary)

Listen for intent and act directly. Don't wait for `/wiki` commands.

| User says... | What you do |
|-------------|------------|
| "I added some new papers" / "process my sources" | Run extraction + absorb entries |
| "what do we know about X?" / asks a knowledge question | Search wiki + read pages + answer |
| "how does X relate to Y?" | Follow relationships, read pages, explain connections |
| "is the wiki healthy?" / "any issues?" | Run lint check |
| "search for X" / "find papers about X" | Search wiki pages |
| "show me the page on X" | Read and present the page |
| "ingest this paper" / shares a file | Run `/wiki ingest <path>` (single file, uses Claude Code) |

When in doubt about intent, ask. Don't guess wrong and burn resources.

---

## Wiki Location

Read `config.json` (alongside this file) to resolve paths:
- `vault_path` + `wiki_dir` = wiki directory (`.schema.md`, `index.md`, `log.md`, type subdirectories)
- `vault_path` + `sources_dir` = raw source documents (immutable)

The full wiki schema is at `<wiki_dir>/.schema.md` — read it for page format,
frontmatter conventions, and directory layout.

---

## Core Workflows

### 1. Absorb Entries → Wiki Pages

When the user wants to process sources, run extraction first:
```
exec scripts/wiki-entry.sh batch [--limit N | --auto]
```

The script handles extraction + dedup and returns a JSON list of pending entries.
**YOU then process the entries** — reading each one and creating wiki pages.

**For each entry:**
1. Read the entry file (from `.entries/<name>.md` or `sources/markdown/<name>.md`)
2. Understand the content: what concepts, methods, people, techniques does it cover?
3. Create wiki pages in type subdirectories — **you decide** what directories are needed
   based on the content. Create a directory when you first need it. Don't pre-create
   empty directories. Examples from past wikis: `concepts/`, `methods/`, `books/`,
   `papers/`, `people/`, `domains/`, `techniques/`, `protocols/`, `cell-lines/` —
   but use whatever makes sense for the source material.
4. Write proper frontmatter:
   ```yaml
   ---
   title: "Page Title"
   type: concept
   confidence: high              # high | medium | low
   source_count: 1
   sources: ["<file_id from entry frontmatter>"]
   created: 2026-04-15
   last_updated: 2026-04-15
   status: draft                 # draft | consolidated | stale
   tags: [topic/subtopic]
   depends_on: ["[[prereq]]"]   # if applicable
   used_by: []
   supersedes: []
   related: ["[[other-page]]"]
   authored_by: []               # for papers/books
   ---
   ```
   Not all fields required — use what's relevant. See `.schema.md` for full rules.
5. Cross-reference: link to existing related pages, use typed relationships
   (`depends_on`, `used_by`, `supersedes`) when the relationship is clear
6. Check for contradictions against existing pages. If found:
   - Add `> [!warning] Contradiction` callout with both sources cited
   - Lower confidence if warranted
   - Don't auto-resolve — surface for the user
7. Update `index.md` — add new pages under the right categories
8. Append to `log.md` — record what was absorbed
9. After processing, mark each entry by appending its filename to the `absorbed_file` path from the batch output

If Obsidian skills are available (`openclaw-obsidian-skills`), use them for creating
and editing markdown files.

### Parallel Processing for Batch

When absorbing multiple entries, you can spawn subagents to process them in parallel.
You decide whether to use subagents and how many based on the workload.

Each subagent should:
- Get a subset of entries to process
- Read `index.md` first to avoid creating duplicate pages
- Create wiki pages and append to the absorbed manifest

After all subagents finish, consolidate `index.md`, run reindex, and report results.

### 2. Answer Queries

When the user asks a question:

1. **Search for relevant pages**:
   - If QMD is installed: `exec qmd query "<question>" -n 10 --format json`
   - Otherwise: search `index.md` and grep wiki pages
2. **Read the matched pages** from the type subdirectories
3. **Synthesize an answer** with `[[wikilinks]]` as citations
4. **Note gaps** — what the wiki doesn't cover yet
5. **Append to `log.md`**: date, "query", question, pages referenced

### 3. Lint — Health Check

When asked to check wiki health:

1. Read all pages across all type subdirectories
2. Check for:
   - Contradictions between pages
   - Orphan pages (not in `index.md` or linked from other pages)
   - Broken `[[wikilinks]]` pointing to non-existent pages
   - Missing cross-references (pages on same topics not linked)
   - `index.md` completeness (all pages listed)
3. Produce a structured report
4. Append to `log.md`

### 4. Single File Ingest (Claude Code)

When the user shares a single file or runs `/wiki ingest <path>`:
- The script handles extraction + dispatch to Claude Code for deep analysis
- Claude Code creates the wiki pages (not you)
- After CC finishes, run `/wiki status` to show results

---

## `/wiki` Commands (Fallback)

When the user sends `/wiki <subcommand> [args]`, run:
```bash
scripts/wiki-entry.sh <subcommand> [args]
```
Pass all arguments through. Do not interpret or modify them.

| Command | Script does | You do |
|---------|------------|--------|
| `/wiki batch [--limit N] [--auto]` | Extract → dedup → list entries | Absorb entries (with subagents if many) |
| `/wiki init` | Same as batch | Same as batch |
| `/wiki query <q>` | — | Search + read + answer |
| `/wiki lint` | — | Read all pages + health check |
| `/wiki ingest <path>` | Extract → dispatch to CC | Report result |
| `/wiki search <term>` | QMD/grep search | Present results |
| `/wiki status` | Count pages/sources | Present stats |
| `/wiki browse <page>` | Read page | Present content |
| `/wiki related <page>` | Follow relationships | Present connections |
| `/wiki catalog [--quick]` | Scan sources | Present summary |
| `/wiki reindex [--full]` | Update QMD index | Report result |
| `/wiki config [key] [val]` | Read/write config | Present config |
| `/wiki cron <type> [opts]` | Manage cron jobs | Confirm schedule |
| `/wiki upgrade` | Pull latest | Report changes |

---

## Progress Reporting

**Always tell the user what's happening:**
1. Before work: "Extracting and checking for new entries..."
2. During absorb: "Processing 15 entries with 3 subagents..."
3. Subagent progress: "Subagent 1 finished: 5 entries → 12 pages created"
4. After completion: "Done. 15 entries → 38 pages across concepts/, methods/, papers/"
5. After reindex: "Search index updated."

---

## Formatting for Feishu

- Keep responses concise — Feishu messages are read on mobile too
- Use bullet points for lists
- Use `[[wikilinks]]` when citing wiki pages
- For lint reports, summarize top issues
- For search results: page title + one-line description
