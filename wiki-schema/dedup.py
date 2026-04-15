#!/usr/bin/env python3
"""Deduplicate PDF files based on content.

Two modes:
  1. Exact dedup (default): identical file content → keep one, move rest to dupes/
  2. Near-dedup (--fuzzy): extract text, compare similarity → flag near-matches

Usage:
  python3 dedup.py /path/to/pdfs                    # exact dedup, preview only
  python3 dedup.py /path/to/pdfs --apply             # actually move duplicates
  python3 dedup.py /path/to/pdfs --fuzzy             # also detect near-duplicates
  python3 dedup.py /path/to/pdfs --fuzzy --threshold 0.85  # similarity threshold
"""

import os
import sys
import hashlib
import argparse
import shutil
import subprocess
import re
from pathlib import Path
from collections import defaultdict
from datetime import datetime


def content_hash(filepath: Path) -> str:
    """MD5 hash of file content."""
    h = hashlib.md5()
    with open(filepath, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def file_size_human(size: int) -> str:
    if size >= 1048576:
        return f"{size / 1048576:.1f}MB"
    elif size >= 1024:
        return f"{size / 1024:.0f}KB"
    return f"{size}B"


def extract_text_preview(filepath: Path, max_chars: int = 2000) -> str:
    """Extract first N chars of text from PDF for similarity comparison."""
    # Try pdftotext
    try:
        result = subprocess.run(
            ["pdftotext", "-l", "3", str(filepath), "-"],  # first 3 pages
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout[:max_chars]
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass

    # Fallback to PyPDF2
    try:
        import PyPDF2
        with open(filepath, "rb") as f:
            reader = PyPDF2.PdfReader(f)
            texts = []
            for page in reader.pages[:3]:  # first 3 pages
                text = page.extract_text()
                if text:
                    texts.append(text)
                if sum(len(t) for t in texts) >= max_chars:
                    break
        return "\n".join(texts)[:max_chars]
    except Exception:
        return ""


def text_similarity(text_a: str, text_b: str) -> float:
    """Simple word-overlap similarity (Jaccard)."""
    if not text_a or not text_b:
        return 0.0
    words_a = set(re.findall(r'\w+', text_a.lower()))
    words_b = set(re.findall(r'\w+', text_b.lower()))
    if not words_a or not words_b:
        return 0.0
    intersection = words_a & words_b
    union = words_a | words_b
    return len(intersection) / len(union)


def find_exact_dupes(folder: Path) -> dict:
    """Group files by content hash. Returns {hash: [file_paths]}."""
    hash_groups = defaultdict(list)
    files = sorted(f for f in folder.iterdir() if f.is_file() and f.suffix.lower() == ".pdf")

    print(f"Scanning {len(files)} PDFs...")
    for i, f in enumerate(files, 1):
        if i % 100 == 0:
            print(f"  {i}/{len(files)} scanned...")
        h = content_hash(f)
        hash_groups[h].append(f)

    # Only keep groups with duplicates
    return {h: paths for h, paths in hash_groups.items() if len(paths) > 1}


def find_near_dupes(folder: Path, threshold: float = 0.80) -> list:
    """Find PDFs with similar text content. Returns [(file_a, file_b, similarity)]."""
    files = sorted(f for f in folder.iterdir() if f.is_file() and f.suffix.lower() == ".pdf")

    # Extract text previews
    print(f"Extracting text from {len(files)} PDFs for comparison...")
    texts = {}
    for i, f in enumerate(files, 1):
        if i % 50 == 0:
            print(f"  {i}/{len(files)} extracted...")
        texts[f] = extract_text_preview(f)

    # Compare all pairs (skip files with no text)
    files_with_text = [f for f in files if texts.get(f, "").strip()]
    print(f"Comparing {len(files_with_text)} files with extractable text...")

    near_dupes = []
    for i, fa in enumerate(files_with_text):
        for fb in files_with_text[i + 1:]:
            sim = text_similarity(texts[fa], texts[fb])
            if sim >= threshold:
                near_dupes.append((fa, fb, sim))

    return near_dupes


def pick_keeper(paths: list) -> Path:
    """Pick the best file to keep from a group of duplicates.
    Prefer: longer filename (more descriptive) > newer modification date > first."""
    return max(paths, key=lambda p: (len(p.stem), p.stat().st_mtime))


def main():
    parser = argparse.ArgumentParser(description="Deduplicate PDF files by content")
    parser.add_argument("folder", help="Folder containing PDF files")
    parser.add_argument("--apply", action="store_true", help="Actually move duplicates (default: preview only)")
    parser.add_argument("--fuzzy", action="store_true", help="Also detect near-duplicates via text similarity")
    parser.add_argument("--threshold", type=float, default=0.80, help="Similarity threshold for near-dedup (default: 0.80)")
    parser.add_argument("--dupes-dir", default=None, help="Where to move duplicates (default: <folder>/dupes/)")
    args = parser.parse_args()

    folder = Path(args.folder).resolve()
    if not folder.is_dir():
        print(f"Error: {folder} is not a directory")
        sys.exit(1)

    dupes_dir = Path(args.dupes_dir) if args.dupes_dir else folder / "dupes"

    # ── Exact duplicates ────────────────────────────────────────────────
    print("\n=== Exact Duplicate Scan ===\n")
    exact_groups = find_exact_dupes(folder)

    total_dupes = sum(len(paths) - 1 for paths in exact_groups.values())
    total_size = sum(p.stat().st_size for paths in exact_groups.values() for p in paths[1:])

    if exact_groups:
        print(f"\nFound {total_dupes} exact duplicates in {len(exact_groups)} groups")
        print(f"Space reclaimable: {file_size_human(total_size)}\n")

        for h, paths in sorted(exact_groups.items(), key=lambda x: -len(x[1])):
            keeper = pick_keeper(paths)
            dupes = [p for p in paths if p != keeper]
            print(f"  [{len(paths)} copies] {file_size_human(paths[0].stat().st_size)}")
            print(f"    KEEP: {keeper.name}")
            for d in dupes:
                print(f"    DUPE: {d.name}")
            print()
    else:
        print("No exact duplicates found.\n")

    # ── Near duplicates ─────────────────────────────────────────────────
    near_dupes = []
    if args.fuzzy:
        print("=== Near-Duplicate Scan ===\n")
        near_dupes = find_near_dupes(folder, args.threshold)

        # Filter out pairs that are already exact dupes
        exact_hashes = set()
        for paths in exact_groups.values():
            for p in paths:
                exact_hashes.add(str(p))

        near_dupes = [(a, b, s) for a, b, s in near_dupes
                      if str(a) not in exact_hashes or str(b) not in exact_hashes]

        if near_dupes:
            print(f"\nFound {len(near_dupes)} near-duplicate pairs (>{args.threshold:.0%} similar)\n")
            for fa, fb, sim in sorted(near_dupes, key=lambda x: -x[2]):
                print(f"  {sim:.0%} similar:")
                print(f"    {fa.name}")
                print(f"    {fb.name}")
                print()
        else:
            print("No near-duplicates found.\n")

    # ── Apply ───────────────────────────────────────────────────────────
    if args.apply and total_dupes > 0:
        dupes_dir.mkdir(exist_ok=True)
        moved = 0
        for h, paths in exact_groups.items():
            keeper = pick_keeper(paths)
            for p in paths:
                if p != keeper:
                    dest = dupes_dir / p.name
                    # Handle name collisions in dupes dir
                    if dest.exists():
                        dest = dupes_dir / f"{p.stem}_{h[:8]}{p.suffix}"
                    shutil.move(str(p), str(dest))
                    moved += 1

        print(f"Moved {moved} duplicates to {dupes_dir}/")
        print(f"Reclaimed {file_size_human(total_size)}")
    elif not args.apply and total_dupes > 0:
        print("This was a preview. Run with --apply to move duplicates.")

    # ── Summary ─────────────────────────────────────────────────────────
    print(f"\n=== Summary ===")
    all_pdfs = len([f for f in folder.iterdir() if f.is_file() and f.suffix.lower() == ".pdf"])
    print(f"Total PDFs: {all_pdfs}")
    print(f"Exact duplicates: {total_dupes}")
    if args.fuzzy:
        print(f"Near-duplicates: {len(near_dupes)}")
    print(f"Unique files: {all_pdfs - total_dupes}")


if __name__ == "__main__":
    main()
