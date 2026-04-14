# Wiki Skill — Step-by-Step Walkthrough

Your personal knowledge wiki, powered by LLMs. Drop papers in, ask questions, get structured knowledge out — all from Feishu.

---

## 1. Install

```bash
curl -sSL https://raw.githubusercontent.com/zzbyy/openclaw-research-assistant/main/remote-install.sh | bash
```

The installer asks two questions:
- **Where to install**: globally or into a specific agent's workspace
- **Obsidian vault path**: where your wiki and source files will live

It then sets up the vault structure, installs the skill, writes the config, and optionally installs Claude Code and cc-bridge if missing.

---

## 2. Verify

Check the skill is installed and the vault structure looks right:

```bash
# Should show wiki skill info
openclaw skills info wiki

# Your vault should have this structure:
ls <your-vault>/wiki/          # CLAUDE.md, index.md, log.md, pages/
ls <your-vault>/sources/       # pdfs/, html/, epub/, markdown/
```

Quick smoke test from Feishu:
```
/wiki status
```

You should get back a JSON summary showing 0 pages, 0 sources — an empty wiki ready to go.

---

## 3. Ingest Your First Paper

Drop a PDF into the wiki:

```
/wiki ingest ~/papers/attention-is-all-you-need.pdf
```

What happens behind the scenes:
1. The PDF is copied to `<vault>/sources/pdfs/`
2. Claude Code (or the research agent) reads the full paper
3. Wiki pages are created in `<vault>/wiki/pages/` with structured frontmatter:
   - Entity type (concept, method, paper, person)
   - Confidence scoring
   - Typed relationships (depends_on, used_by, related)
   - Source citations
4. `index.md` is updated with new entries
5. `log.md` gets an append-only record
6. You get a notification in Feishu when done

Open Obsidian — you should see new pages in `wiki/pages/`, linked in the graph view.

### Supported formats

| Format | Extension | Notes |
|--------|-----------|-------|
| PDF | `.pdf` | Academic papers, reports — Claude reads them natively |
| HTML | `.html`, `.htm` | Saved web articles |
| EPUB | `.epub` | Books, long-form content |
| Markdown | `.md`, `.txt` | Clipped articles, notes |

### Backend choice

Add `--backend cc` or `--backend agent` to any command:

```
/wiki ingest paper.pdf --backend cc       # Claude Code (heavy lifting)
/wiki ingest article.md --backend agent   # Research agent (lighter)
```

**When to use which:**

| Backend | Best for |
|---------|----------|
| `cc` (Claude Code) | PDFs, EPUBs, complex papers, batch ingestion, full lint |
| `agent` (OpenClaw) | Quick queries, search, browse, conversational Q&A |

---

## 4. Query the Wiki

Ask questions about what you've ingested:

```
/wiki query "what is the key innovation in transformer architecture?"
```

The answer comes back with:
- `[[wikilinks]]` citing the relevant wiki pages
- Confidence levels noted (e.g., "self-attention (high confidence) enables...")
- Gaps identified if the wiki doesn't cover something yet

### Conversational mode

You don't need `/wiki query` for everything. Just talk naturally to the research agent in Feishu:

> "How does self-attention differ from cross-attention?"

The agent reads the relevant wiki pages and synthesizes an answer. No command needed.

---

## 5. Search & Browse

Find pages by keyword:
```
/wiki search attention
```

Returns matching pages with titles, types, confidence levels, and content snippets.

Read a specific page:
```
/wiki browse self-attention
```

Returns the full page content including frontmatter.

Explore connections:
```
/wiki related transformer-architecture
```

Shows all typed relationships: what it depends on, what uses it, what it supersedes, what's related — plus backlinks (pages that link to it).

---

## 6. Lint — Keep the Wiki Healthy

Run a health check:
```
/wiki lint
```

The lint checks for:
- **Contradictions** — pages with conflicting claims
- **Orphan pages** — not linked from index or other pages
- **Broken wikilinks** — `[[links]]` pointing to non-existent pages
- **Stale pages** — not verified in 90+ days, confidence gets lowered
- **Missing cross-references** — pages discussing same topics without linking
- **Entity relationship integrity** — typed links are valid and bidirectional

### Contradiction handling

When you ingest a new paper that contradicts existing knowledge, the wiki doesn't silently overwrite. Instead:

1. A `> [!warning] Contradiction` callout is added to affected pages
2. The contradiction is flagged in the ingest output
3. Confidence is lowered if warranted
4. You decide how to resolve it

---

## 7. Obsidian Integration

Your wiki is native Obsidian markdown. Everything works out of the box:

- **Graph view** — see connections between concepts, methods, papers, people
- **Wikilinks** — `[[page-name]]` links work throughout
- **Tags** — `#topic/subtopic` tags are browsable
- **Frontmatter** — visible in reading view and properties panel

### Dataview queries

Install the [Dataview](https://github.com/blacksmithgu/obsidian-dataview) plugin for powerful queries:

```dataview
TABLE type, confidence, source_count
FROM "wiki/pages"
WHERE type = "method"
SORT confidence DESC
```

```dataview
LIST
FROM "wiki/pages"
WHERE contains(depends_on, "[[transformer-architecture]]")
```

```dataview
TABLE status, last_verified
FROM "wiki/pages"
WHERE status = "stale"
```

---

## 8. Scheduled Automation (Optional)

Set up periodic jobs via OpenClaw cron:

### Weekly lint
```
/wiki cron lint --every "sunday 9am"
```

### Daily auto-ingest
Automatically picks up new files dropped into `sources/`:
```
/wiki cron ingest --every "daily 6am"
```

### Manage schedules
```
/wiki cron status                    # show current schedules
/wiki cron lint --disable            # turn off weekly lint
/wiki cron ingest --disable          # turn off auto-ingest
```

Results are sent to your Feishu channel as notifications.

---

## 9. Configuration

View or update settings:
```
/wiki config                                  # show all
/wiki config vault_path                       # show specific key
/wiki config default_backend agent            # change default backend
/wiki config confidence.stale_after_days 60   # stricter staleness
```

Config lives alongside the skill in the agent's workspace (`config.json`).

---

## 10. Building Your Wiki — Tips

### Start with a handful of foundational papers
Don't ingest everything at once. Start with 5-10 core papers in your area. Let the wiki build a strong foundation of cross-referenced concepts, then add more incrementally.

### Review the first few ingestions in Obsidian
After your first few ingests, open the wiki in Obsidian. Check that:
- Page titles make sense
- Cross-references are meaningful
- The index is organized well
- The graph view shows useful connections

### Use queries to find gaps
Ask questions you care about. When the wiki can't answer, that tells you what to ingest next.

### Run lint periodically
Even without cron, run `/wiki lint` weekly. It catches:
- Pages that drifted out of sync
- Concepts that should be linked but aren't
- Stale information that needs re-verification

### Let contradictions accumulate, then resolve
Don't resolve every contradiction immediately. Let them build up, then review them in batch — you'll often see patterns that make the right resolution obvious.

---

## 11. Troubleshooting

**No response from `/wiki` commands?**
```bash
openclaw skills info wiki
openclaw gateway restart
```

**Ingest seems stuck?**
If using `--backend cc`, check cc-bridge task status:
```
/cc-status
```

**Config issues?**
```
/wiki config
```
Verify vault_path points to your actual Obsidian vault.

**Pages not showing in Obsidian?**
Make sure your Obsidian vault path matches the `vault_path` in config. The wiki pages live at `<vault>/wiki/pages/`.

---

## 12. Updating

Re-run the installer — it's idempotent:
```bash
curl -sSL https://raw.githubusercontent.com/zzbyy/openclaw-research-assistant/main/remote-install.sh | bash
```

Existing wiki pages, sources, and config are preserved. Only the skill scripts and schema are updated.
