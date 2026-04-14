# Wiki Schema

You are maintaining a personal knowledge wiki inside an Obsidian vault.
This file defines the structure, conventions, and operations you must follow.

---

## Directory Layout

```
wiki/                     ← You operate here (working directory)
├── CLAUDE.md             ← This file (schema — read on every session)
├── index.md              ← Category-organized catalog of all wiki pages
├── log.md                ← Chronological append-only record of operations
├── .ingested             ← Manifest of processed source files (do not edit manually)
└── pages/                ← Wiki article files (you create and maintain these)
    ├── concept-name.md
    ├── method-name.md
    └── ...

../sources/               ← Raw documents (READ ONLY — never modify)
├── pdfs/
├── html/
├── epub/
└── markdown/
```

---

## Page Format

Every wiki page lives in `pages/` and uses this structure:

### Frontmatter (YAML)

```yaml
---
title: "Human-Readable Title"
type: concept                    # see Entity Types below
confidence: high                 # high | medium | low
source_count: 2
sources:
  - "[[../sources/pdfs/paper-name.pdf]]"
  - "[[../sources/markdown/article-name.md]]"
created: 2026-04-14
updated: 2026-04-14
last_verified: 2026-04-14
status: draft                    # draft | consolidated | stale
tags:
  - topic/subtopic
  - another-tag
depends_on:
  - "[[prerequisite-concept]]"
used_by:
  - "[[downstream-concept]]"
supersedes:
  - "[[older-concept]]"
related:
  - "[[similar-concept]]"
authored_by:                     # for type: paper or method
  - "[[person-name]]"
---
```

### Body

- Use Obsidian wikilinks `[[page-name]]` for all cross-references (not markdown links)
- Use `#topic/subtopic` tags inline where relevant
- Use Obsidian callouts for special blocks:
  - `> [!info]` for key definitions
  - `> [!warning] Contradiction` for flagged contradictions (see below)
  - `> [!tip]` for practical implications
  - `> [!example]` for concrete examples
- Keep pages focused on one concept/entity — split if a page grows beyond ~500 lines
- Use `##` headings for major sections, `###` for subsections

### File Naming

- kebab-case: `self-attention.md`, `transformer-architecture.md`
- Descriptive and unique — the filename is the wikilink target
- No prefixes or numbering — organization is via index.md and relationships

---

## Entity Types

Each page has a `type` field. Use the appropriate type:

| Type | Use for | Expected relationships |
|------|---------|----------------------|
| `concept` | Ideas, principles, techniques | `depends_on`, `used_by`, `related` |
| `method` | Algorithms, architectures, approaches | `depends_on`, `used_by`, `supersedes`, `authored_by` |
| `person` | Researchers, authors | `related` (to their work) |
| `paper` | Specific publications | `authored_by`, `depends_on` (prior work), `related` |
| `dataset` | Datasets, benchmarks | `used_by`, `related` |
| `tool` | Software, libraries, frameworks | `depends_on`, `used_by`, `related` |

---

## Confidence Rules

### Scoring

Assign confidence based on:

| Confidence | Criteria |
|-----------|---------|
| `high` | 3+ supporting sources, no contradictions, sources from last 3 years |
| `medium` | 1-2 sources, or minor contradictions exist, or sources are 3-5 years old |
| `low` | Single source, or unresolved contradictions, or sources older than 5 years |

### Status Lifecycle

- `draft` — newly created from a single source, not yet cross-referenced thoroughly
- `consolidated` — reviewed against multiple sources, cross-references verified
- `stale` — `last_verified` is older than 90 days (configurable), needs re-verification

### Decay

During lint, if a page's `last_verified` date exceeds the stale threshold:
1. Set `status: stale`
2. If confidence was `high`, lower to `medium`
3. Add a note in the lint report

---

## Operations

### Ingest

When asked to ingest a source document:

1. **Read the source** completely — understand its key claims, concepts, methods, and findings
2. **Scan existing pages** — read `index.md` and relevant pages in `pages/` to understand current wiki state
3. **Check for contradictions** — compare the source's claims against existing wiki pages. If contradictions found:
   - Add `> [!warning] Contradiction` callout in the affected page(s) with both sources cited
   - Lower confidence if warranted (e.g., `high` → `medium`)
   - Note the contradiction in your output and in `log.md`
   - Do NOT auto-resolve — surface the conflict for the user to decide
4. **Create or update pages** — for each key concept/entity in the source:
   - If a page exists: update it, add the new source, adjust confidence, update `updated` and `last_verified` dates, add cross-references
   - If no page exists: create a new page with full frontmatter, `status: draft`, appropriate confidence
5. **Update typed relationships** — fill in `depends_on`, `used_by`, `supersedes`, `related`, `authored_by` as appropriate. Update the reverse direction on the linked pages too (e.g., if A `depends_on` B, add A to B's `used_by`)
6. **Update index.md** — add new pages under the appropriate categories
7. **Append to log.md** — record: date, "ingest", source filename, pages created/updated, contradictions flagged

### Query

When asked a question against the wiki:

1. **Search relevant pages** — use the question's concepts to find matching pages via index.md, tags, and wikilinks
2. **Read the pages** — gather information from matched pages
3. **Synthesize an answer** — combine information with:
   - `[[wikilinks]]` as citations to wiki pages
   - Confidence levels noted for claims (e.g., "Self-attention (high confidence) is...")
   - Source references where relevant
4. **If the answer reveals gaps** — note what the wiki doesn't cover yet
5. **Optionally file the answer** — if the query and answer represent valuable knowledge not yet in the wiki, offer to create a new page
6. **Append to log.md** — record: date, "query", the question asked, pages referenced

### Lint

When asked to health-check the wiki:

1. **Contradiction scan** — find pages with conflicting claims, flag with callouts
2. **Orphan detection** — find pages not linked from index.md or any other page
3. **Broken wikilinks** — find `[[links]]` that point to non-existent pages
4. **Missing cross-references** — find pages that discuss the same topics but don't link to each other
5. **Confidence decay** — check `last_verified` dates, mark stale pages, lower confidence where needed
6. **Entity relationship integrity** — verify typed relationship links (depends_on, used_by, etc.) point to valid pages and are bidirectional
7. **Index completeness** — verify all pages in `pages/` appear in `index.md`
8. **Produce a report** with sections for each check, listing issues found and suggested fixes
9. **Append to log.md** — record: date, "lint", summary of findings

---

## index.md Format

```markdown
# Wiki Index

## Concepts
- [[concept-name]] — one-line description
- [[another-concept]] — one-line description

## Methods
- [[method-name]] — one-line description

## Papers
- [[paper-name]] — one-line description

## People
- [[person-name]] — one-line description

## Datasets
- [[dataset-name]] — one-line description

## Tools
- [[tool-name]] — one-line description
```

Categories are added as needed. Alphabetical within each category.

---

## log.md Format

Append-only. Most recent entries at the bottom.

```markdown
# Wiki Log

| Date | Operation | Details | Pages affected | Notes |
|------|-----------|---------|---------------|-------|
| 2026-04-14 | ingest | attention-is-all-you-need.pdf | +3 new, 1 updated | No contradictions |
| 2026-04-14 | query | "how does self-attention work?" | 2 referenced | — |
| 2026-04-15 | lint | full health check | 5 flagged stale | 1 contradiction found |
```

---

## Rules

- Never modify files in `../sources/` — they are immutable raw documents
- Always update `index.md` and `log.md` when making changes
- Always maintain bidirectional relationships (if A depends_on B, B should list A in used_by)
- When updating a page, always update the `updated` and `last_verified` dates
- Prefer updating existing pages over creating near-duplicates
- When in doubt about merging vs. creating a new page, create a new page and add `related` links
- Keep page titles and filenames in sync
- Use the Obsidian `> [!warning] Contradiction` callout format — never silently overwrite conflicting information
