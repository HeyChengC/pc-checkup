#!/usr/bin/env python3
"""Append stale node_modules / venv entries to the scan items JSONL. macOS only."""
import json, os, sys, time

items_path = sys.argv[1]
roots = sys.argv[2:]
now = time.time()
n_nm = n_venv = 0


def emit(level, group, cat, label, method, path, note, min_size=100 * 1024 * 1024):
    size = files = 0
    newest = 0
    for dp, dns, fns in os.walk(path, followlinks=False):
        for fn in fns:
            fp = os.path.join(dp, fn)
            try:
                st = os.lstat(fp)
            except OSError:
                continue
            if not os.path.isfile(fp):
                continue
            size += st.st_size
            files += 1
            if st.st_mtime > newest:
                newest = st.st_mtime
    if size < min_size:
        return
    day = time.strftime("%Y-%m-%d", time.localtime(newest)) if newest else ""
    row = {
        "level": level,
        "group": group,
        "category": cat,
        "label": label,
        "paths": [path],
        "sizeBytes": size,
        "files": files,
        "newest": day,
        "method": method,
        "note": note,
        "extra": {},
    }
    with open(items_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


home_lib = os.path.expanduser("~/Library")
for root in roots:
    if not os.path.isdir(root):
        continue
    for dp, dns, fns in os.walk(root, followlinks=False):
        base = os.path.basename(dp)
        if dp.startswith(home_lib) or dp.startswith("/Library") or dp.startswith("/Applications"):
            dns[:] = []
            continue
        rel = os.path.relpath(dp, root)
        if rel != "." and rel.count(os.sep) > 5:
            dns[:] = []
            continue
        if base in (".git", ".Trash"):
            dns[:] = []
            continue
        if base == "node_modules":
            if n_nm < 60:
                proj = os.path.dirname(dp)
                try:
                    age = (now - os.lstat(proj).st_mtime) / 86400
                except OSError:
                    age = 0
                if age >= 90:
                    emit(
                        "yellow",
                        "creator",
                        "node-modules",
                        "node_modules in " + os.path.basename(proj),
                        "quarantine",
                        dp,
                        "npm-install-brings-it-back",
                    )
                    n_nm += 1
            dns[:] = []
            continue
        if base in (".venv", "venv") and os.path.isfile(os.path.join(dp, "pyvenv.cfg")):
            if n_venv < 30:
                try:
                    age = (now - os.lstat(dp).st_mtime) / 86400
                except OSError:
                    age = 0
                if age >= 90:
                    emit(
                        "yellow",
                        "creator",
                        "venv",
                        "Python env " + base,
                        "quarantine",
                        dp,
                        "rebuild-from-requirements",
                    )
                    n_venv += 1
            dns[:] = []
            continue
