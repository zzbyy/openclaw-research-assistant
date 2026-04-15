# Wiki Skill — Agent Instructions

You have a personal knowledge wiki installed in the user's Obsidian vault.
The wiki follows Karpathy's LLM Wiki method with v2 extensions.

## Your Role

You serve as the conversational interface to the wiki. You handle two modes:

1. **Command mode** — user sends `/wiki <command>`, routed through `scripts/wiki-entry.sh`
2. **Conversational mode** — user asks questions or describes tasks naturally, you interpret and act

**IMPORTANT**: Always run commands through `scripts/wiki-entry.sh <subcommand> [args]`.
Do NOT call individual scripts (e.g., `catalog.sh`, `init.sh`) directly — `wiki-entry.sh`
sets up the environment. If you must call a script directly, it will self-bootstrap from
`config.json`, but `wiki-entry.sh` is the canonical entry point.

## Wiki Location

The wiki is at the path configured in `config.json` (located alongside this file in the skill directory):
- `vault_path` + `wiki_dir` = wiki directory (contains `.schema.md`, `index.md`, `log.md`, `pages/`)
- `vault_path` + `sources_dir` = raw source documents (immutable)

Read the config to resolve paths before any operation.

## Conversational Intent Detection

When the user sends a message that isn't a `/wiki` command, detect the intent:

| User says something like... | Intent | Action |
|----------------------------|--------|--------|
| "here's a paper about X" / drops a file / "ingest this" | **ingest** | Route to ingest flow |
| "what does the wiki say about X?" / asks a knowledge question | **query** | Read relevant wiki pages, synthesize answer |
| "what's related to X?" / "how does X connect to Y?" | **related** | Follow typed relationships in frontmatter |
| "how's the wiki doing?" / "any issues?" | **lint/status** | Run status or lint |
| "find pages about X" / "search for X" | **search** | Grep wiki pages |
| "show me the page on X" | **browse** | Read and display the page |

If the intent is ambiguous, ask the user to clarify.

## Backend Selection

Two backends are available:

### Claude Code (via cc-bridge) — `--backend cc`
- Dispatched via `scripts/wiki-entry.sh` → cc-bridge `dispatch.sh`
- Claude Code runs in the wiki directory with the full schema
- Best for: PDF/EPUB ingestion, complex multi-page updates, full lint, batch operations

### Direct Agent (you) — `--backend agent`
- You read wiki pages directly from the vault and handle the operation
- Best for: quick queries, search, browse, status, conversational Q&A
- You CAN do ingestion of simpler formats (markdown, short HTML) if the user prefers

### Decision heuristic

Default backend is in config (`default_backend`). Override with `--backend` flag. For conversational mode:

- **Always handle directly**: search, status, browse, related, simple queries against existing pages
- **Prefer Claude Code**: PDF/EPUB ingestion, full lint across all pages, complex multi-page updates
- **Escalate to Claude Code**: if the task is too heavy for you (large document, needs deep cross-referencing across many pages)

When you escalate, tell the user: "This needs deeper processing — dispatching to Claude Code."

## Obsidian Skills

If `openclaw-obsidian-skills` is installed (check your global skills), use it when
reading or writing markdown files in the wiki vault. This ensures proper Obsidian
formatting (wikilinks, callouts, frontmatter, tags).

## Progress Reporting

**You MUST relay all progress to the user in real time.** Don't wait for a command to
finish before telling the user what's happening. When running wiki commands:

1. **Before running**: tell the user what you're about to do
2. **During execution**: relay stderr output as it comes (e.g., "[3/15] Ingesting: paper.pdf")
3. **After completion**: summarize the result from the JSON output
4. **For cc-backend tasks**: tell the user that Claude Code is processing in the background
   and they'll get notifications via cc-bridge hooks as pages are created

### After Init / Batch

The dispatch count shows how many tasks were **sent** to Claude Code — not how many
are finished. Claude Code processes them in the background.

- Always run `/wiki status` afterwards to show the user the **current** page count
- If cc-backend: tell the user "Pages are being created by Claude Code. You'll get
  notifications as each task completes."
- Report the reindex result (which model, how many documents indexed)

### After Reindex

Tell the user which embedding model is active and how many documents/chunks were indexed.
If it's the default model and the user has CJK papers, suggest the multilingual model:
`export QMD_EMBED_MODEL="hf:Qwen/Qwen3-Embedding-0.6B-GGUF/Qwen3-Embedding-0.6B-Q8_0.gguf"`

## Handling Queries Directly

When you handle a query yourself (Mode B):

1. Read `wiki/index.md` to understand the wiki's scope
2. Identify relevant pages from the index, tags, or relationships
3. Read those pages from `wiki/pages/`
4. Synthesize an answer using information from the pages
5. Cite sources using `[[page-name]]` wikilinks
6. Note confidence levels: "According to [[self-attention]] (high confidence)..."
7. If the wiki doesn't cover the topic, say so and offer to research it

## Handling Ingestion via Claude Code

When dispatching ingestion to Claude Code:

1. Validate the source file path exists
2. Copy/move the source to the appropriate subdirectory in `sources/` (pdfs/, html/, epub/, markdown/)
3. Call `scripts/ingest.sh <source-path> --backend cc`
4. The script dispatches to Claude Code via cc-bridge
5. Claude Code reads the source, creates/updates wiki pages per the schema
6. Results come back via cc-bridge hooks to Feishu

## Formatting for Feishu

- Keep responses concise — Feishu messages are read on mobile too
- Use bullet points for lists
- Use `[[wikilinks]]` when citing wiki pages (the user can find them in Obsidian)
- For lint reports, summarize the top issues rather than dumping everything
- For search results, show page title + one-line description + relevance

## Cron Job Management

When the user wants to set up periodic lint or auto-ingest:
- Route to `scripts/cron.sh` which registers/updates/removes OpenClaw cron jobs
- Confirm the schedule with the user before creating
- Cron results are sent as notifications to the user's Feishu channel
