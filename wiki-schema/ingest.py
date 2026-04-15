#!/usr/bin/env python3
"""Extract text from source files (PDF, EPUB, MOBI, HTML) into markdown entries.

Two-phase ingest pipeline:
  Phase 1 (this script): mechanical text extraction → entries/
  Phase 2 (Claude Code or agent): synthesize entries into wiki pages

Usage:
  python3 ingest.py                    # extract all new sources
  python3 ingest.py --file paper.pdf   # extract a single file
  python3 ingest.py --format pdfs      # only process PDFs
  python3 ingest.py --reextract        # re-extract already processed files
"""

import os
import re
import sys
import json
import hashlib
import subprocess
import tempfile
import argparse
from pathlib import Path
from datetime import datetime


def find_vault():
    """Find the vault path from wiki config or environment."""
    # Try environment variable
    vault = os.environ.get("WIKI_VAULT_PATH", "")
    if vault:
        return Path(os.path.expanduser(vault))

    # Try config.json relative to this script (installed in wiki/)
    config_candidates = [
        Path(__file__).parent / "config.json",           # if in wiki/
        Path(__file__).parent.parent / "config.json",    # if in wiki-schema/
    ]

    # Try skill config
    skill_config = Path.home() / ".openclaw" / "wiki" / "config.json"
    config_candidates.append(skill_config)

    for config_path in config_candidates:
        if config_path.exists():
            try:
                config = json.loads(config_path.read_text())
                vault = config.get("vault_path", "")
                if vault:
                    return Path(os.path.expanduser(vault))
            except (json.JSONDecodeError, KeyError):
                pass

    print("Error: Cannot find vault path. Set WIKI_VAULT_PATH or run install.sh first.")
    sys.exit(1)


def sanitize_filename(name: str, max_len: int = 80) -> str:
    """Create a filesystem-safe filename from a title."""
    name = re.sub(r"\.(epub|pdf|mobi|html?|txt|md)$", "", name, flags=re.IGNORECASE)
    for sep in [" by ", " BY ", "\uff08", "\u3010", "(z-lib", "_by_", "_Z_Library"]:
        if sep in name:
            name = name[: name.index(sep)]
            break
    name = re.sub(r"[^\w\u4e00-\u9fff\u3400-\u4dbf\-\s]", "", name)
    name = re.sub(r"\s+", "_", name.strip())
    return name[:max_len].rstrip("_")


def detect_language(text: str) -> str:
    """Detect if text is primarily Chinese or English."""
    sample = text[:2000]
    chinese = len(re.findall(r"[\u4e00-\u9fff]", sample))
    ascii_chars = len(re.findall(r"[a-zA-Z]", sample))
    return "zh" if chinese > ascii_chars else "en"


def get_file_id(filepath: Path) -> str:
    """Generate a stable ID from file content hash."""
    h = hashlib.md5()
    with open(filepath, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()[:12]


# ── Extractors ──────────────────────────────────────────────────────────────


def extract_epub(filepath: Path) -> tuple:
    """Extract text and metadata from EPUB."""
    try:
        import ebooklib
        from ebooklib import epub
        from bs4 import BeautifulSoup
    except ImportError:
        print("  [!!] Install: pip install ebooklib beautifulsoup4 lxml")
        return "", {}

    book = epub.read_epub(str(filepath), options={"ignore_ncx": True})
    meta = {}
    title = book.get_metadata("DC", "title")
    if title:
        meta["title"] = title[0][0]
    creator = book.get_metadata("DC", "creator")
    if creator:
        meta["author"] = creator[0][0]

    texts = []
    for item in book.get_items():
        if item.get_type() == ebooklib.ITEM_DOCUMENT:
            soup = BeautifulSoup(item.get_content(), "lxml")
            text = soup.get_text(separator="\n", strip=True)
            if text.strip():
                texts.append(text)

    return "\n\n---\n\n".join(texts), meta


def extract_pdf(filepath: Path) -> tuple:
    """Extract text from PDF using pdftotext, fallback to PyPDF2."""
    meta = {}

    # Try pdftotext first (better quality)
    try:
        result = subprocess.run(
            ["pdftotext", "-layout", str(filepath), "-"],
            capture_output=True,
            text=True,
            timeout=120,
        )
        if result.returncode == 0 and result.stdout.strip():
            text = result.stdout
            for line in text.split("\n"):
                line = line.strip()
                if line and len(line) > 3:
                    meta["title"] = line[:100]
                    break
            return text, meta
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass

    # Fallback to PyPDF2
    try:
        import PyPDF2

        texts = []
        with open(filepath, "rb") as f:
            reader = PyPDF2.PdfReader(f)
            if reader.metadata:
                if reader.metadata.title:
                    meta["title"] = reader.metadata.title
                if reader.metadata.author:
                    meta["author"] = reader.metadata.author
            for page in reader.pages:
                text = page.extract_text()
                if text:
                    texts.append(text)
        return "\n\n".join(texts), meta
    except ImportError:
        print("  [!!] Install: pip install PyPDF2")
        return "", {}


def extract_mobi(filepath: Path) -> tuple:
    """Convert MOBI to EPUB using calibre, then extract."""
    with tempfile.TemporaryDirectory() as tmpdir:
        epub_path = Path(tmpdir) / "converted.epub"
        result = subprocess.run(
            ["ebook-convert", str(filepath), str(epub_path)],
            capture_output=True,
            text=True,
            timeout=300,
        )
        if result.returncode != 0:
            raise RuntimeError(f"ebook-convert failed: {result.stderr[:200]}")
        return extract_epub(epub_path)


def extract_html(filepath: Path) -> tuple:
    """Extract text from HTML file."""
    try:
        from bs4 import BeautifulSoup
    except ImportError:
        # Plain text fallback
        return filepath.read_text(encoding="utf-8", errors="ignore"), {}

    content = filepath.read_text(encoding="utf-8", errors="ignore")
    soup = BeautifulSoup(content, "lxml")
    meta = {}
    title_tag = soup.find("title")
    if title_tag:
        meta["title"] = title_tag.get_text(strip=True)
    return soup.get_text(separator="\n", strip=True), meta


def extract_markdown(filepath: Path) -> tuple:
    """Read markdown/text file directly."""
    text = filepath.read_text(encoding="utf-8", errors="ignore")
    meta = {}
    # Try to extract title from first heading
    for line in text.split("\n"):
        line = line.strip()
        if line.startswith("# "):
            meta["title"] = line[2:].strip()
            break
    return text, meta


# ── Main ────────────────────────────────────────────────────────────────────

# Only extract binary/complex formats that need text extraction.
# Markdown, text, and HTML files are already readable — they go directly
# into .entries/ as-is (or are read directly by the LLM).
EXTRACTORS = {
    ".epub": ("epub", extract_epub),
    ".pdf": ("pdf", extract_pdf),
    ".mobi": ("mobi", extract_mobi),
}

FORMAT_DIRS = {
    "epub": "epub",
    "pdf": "pdfs",
    "mobi": "epub",  # treated same as epub
}


def write_entry(entries_dir: Path, filepath: Path, text: str, meta: dict, fmt: str):
    """Write extracted content as a markdown entry."""
    file_id = get_file_id(filepath)
    title = meta.get("title", sanitize_filename(filepath.stem))
    author = meta.get("author", "Unknown")
    language = detect_language(text)
    safe_name = sanitize_filename(filepath.stem)
    entry_path = entries_dir / f"{fmt}_{safe_name}.md"

    mtime = datetime.fromtimestamp(filepath.stat().st_mtime)

    frontmatter = f"""---
id: {file_id}
title: "{title}"
author: "{author}"
date: {mtime.strftime('%Y-%m-%d')}
source_type: {'paper' if fmt == 'pdf' else 'book'}
format: {fmt}
language: {language}
source_file: "{filepath.name}"
tags: []
---

"""
    entry_path.write_text(frontmatter + text, encoding="utf-8")
    return entry_path


def ingest(vault_path: Path, single_file: str = None, format_filter: str = None, reextract: bool = False):
    """Extract text from source files into entries."""
    sources_dir = vault_path / "sources"
    entries_dir = vault_path / "wiki" / ".entries"
    entries_dir.mkdir(parents=True, exist_ok=True)

    # Build list of already-extracted file IDs
    existing_ids = set()
    if not reextract:
        for entry in entries_dir.glob("*.md"):
            try:
                content = entry.read_text(encoding="utf-8")
                match = re.search(r"^id: (\w+)", content, re.MULTILINE)
                if match:
                    existing_ids.add(match.group(1))
            except Exception:
                pass

    # Find source files
    source_files = []
    if single_file:
        fp = Path(single_file).expanduser().resolve()
        if fp.exists():
            source_files.append(fp)
        else:
            print(f"Error: File not found: {fp}")
            sys.exit(1)
    else:
        for subdir in sorted(sources_dir.iterdir()):
            if not subdir.is_dir():
                continue
            if format_filter and subdir.name != format_filter:
                continue
            for f in sorted(subdir.iterdir()):
                if f.is_file() and f.suffix.lower() in EXTRACTORS and not f.name.startswith("."):
                    source_files.append(f)

    print(f"Found {len(source_files)} source files to process")

    results = {"success": [], "skipped": [], "failed": []}

    for i, filepath in enumerate(source_files, 1):
        file_id = get_file_id(filepath)
        suffix = filepath.suffix.lower()

        if suffix not in EXTRACTORS:
            continue

        fmt, extractor = EXTRACTORS[suffix]

        if file_id in existing_ids:
            results["skipped"].append(filepath.name)
            print(f"  [{i}/{len(source_files)}] SKIP: {filepath.name[:60]}")
            continue

        print(f"  [{i}/{len(source_files)}] Extracting ({fmt}): {filepath.name[:60]}...")
        try:
            text, meta = extractor(filepath)
            if not text.strip():
                raise ValueError("No text extracted (possibly scanned/image PDF)")
            entry_path = write_entry(entries_dir, filepath, text, meta, fmt)
            results["success"].append(filepath.name)
            print(f"    -> {entry_path.name} ({len(text):,} chars)")
        except Exception as e:
            results["failed"].append((filepath.name, str(e)))
            print(f"    FAILED: {e}")

    # Summary
    print(f"\n=== Extraction Summary ===")
    print(f"Success: {len(results['success'])}")
    print(f"Skipped: {len(results['skipped'])} (already extracted)")
    print(f"Failed:  {len(results['failed'])}")
    if results["failed"]:
        print("\nFailed files:")
        for name, err in results["failed"]:
            print(f"  - {name[:60]}: {err[:80]}")

    # Write summary JSON
    summary = {
        "timestamp": datetime.now().isoformat(),
        "total": len(source_files),
        "success": len(results["success"]),
        "skipped": len(results["skipped"]),
        "failed": len(results["failed"]),
        "failed_files": [{"name": n, "error": e} for n, e in results["failed"]],
    }
    (entries_dir / ".extract_log.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False))

    return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Extract text from source documents")
    parser.add_argument("--file", help="Extract a single file")
    parser.add_argument("--format", help="Only process this format (pdfs, epub, html, markdown)")
    parser.add_argument("--reextract", action="store_true", help="Re-extract already processed files")
    args = parser.parse_args()

    vault = find_vault()
    print(f"Vault: {vault}")
    ingest(vault, single_file=args.file, format_filter=args.format, reextract=args.reextract)
