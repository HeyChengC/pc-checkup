#!/usr/bin/env bash
# clean.sh - carries out a cleanup the user has confirmed, on macOS.
# Usage:
#   bash scripts/clean.sh -Manifest ~/pc-checkup/scan-....json -Ids "G1;G2;Y3"           # dry run
#   bash scripts/clean.sh -Manifest ~/pc-checkup/scan-....json -Ids "G1;G2;Y3" -Execute
#   bash scripts/clean.sh -Ids "all-green" -Manifest ... -Execute
#   bash scripts/clean.sh -Undo [-Ids "Y3"]
#   bash scripts/clean.sh -Purge
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/common.sh"

MANIFEST=""; IDS=""; EXECUTE=0; PERMANENT=0; UNDO=0; PURGE=0; OUT_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -Manifest|--manifest) MANIFEST="$2"; shift ;;
    -Ids|--ids) IDS="$2"; shift ;;
    -Execute|--execute) EXECUTE=1 ;;
    -Permanent|--permanent) PERMANENT=1 ;;
    -Undo|--undo) UNDO=1 ;;
    -Purge|--purge) PURGE=1 ;;
    -OutDir|--out-dir) OUT_DIR="$2"; shift ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

pc_init_guard
OUT_DIR="${OUT_DIR:-$HOME/pc-checkup}"
mkdir -p "$OUT_DIR"
INDEX="$OUT_DIR/quarantine-index.json"
[[ -f "$INDEX" ]] || echo '[]' >"$INDEX"
QDIR="$OUT_DIR/quarantine"
mkdir -p "$QDIR"

if [[ $UNDO -eq 1 || $PURGE -eq 1 ]]; then
  python3 - "$INDEX" "$UNDO" "$PURGE" "$IDS" "$EXECUTE" <<'PY'
import json, os, sys, shutil
index_path, undo, purge, ids, execute = sys.argv[1:6]
undo = undo == '1'; purge = purge == '1'; execute = execute == '1'
want = {x.strip().upper() for x in ids.replace(',', ';').replace(' ', ';').split(';') if x.strip()} if ids else set()
entries = json.load(open(index_path, encoding='utf-8'))
kept = []; acted = 0
for e in entries:
    if want and e.get('id', '').upper() not in want:
        kept.append(e); continue
    src = e.get('quarantinePath') or ''
    dst = e.get('originalPath') or ''
    if not src or not os.path.exists(src):
        print(f"SKIP: {e.get('id')} missing in quarantine"); continue
    if undo:
        if execute:
            os.makedirs(os.path.dirname(dst) or '/', exist_ok=True)
            if os.path.exists(dst):
                print(f"SKIP: {e.get('id')} original path occupied: {dst}"); kept.append(e); continue
            shutil.move(src, dst)
            print(f"UNDO: {e.get('id')} -> {dst}"); acted += 1
        else:
            print(f"PLAN-UNDO: {e.get('id')} -> {dst}"); acted += 1
    elif purge:
        if execute:
            if os.path.isdir(src) and not os.path.islink(src): shutil.rmtree(src)
            else: os.remove(src)
            print(f"PURGE: {e.get('id')} {src}"); acted += 1
        else:
            print(f"PLAN-PURGE: {e.get('id')} {src}"); acted += 1
        # purged entries leave the index
        continue
    if not execute:
        kept.append(e)
if execute:
    json.dump(kept, open(index_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print(f"RESULT: acted={acted} remaining={len(kept)}")
PY
  exit 0
fi

[[ -n "$MANIFEST" && -f "$MANIFEST" ]] || { echo "ERROR: report not found: $MANIFEST" >&2; exit 2; }

python3 - "$MANIFEST" "$IDS" "$EXECUTE" "$PERMANENT" "$INDEX" "$QDIR" "$ROOT/scripts/common.sh" <<'PY'
import json, os, sys, shutil, time, subprocess, datetime

manifest, ids, execute, permanent, index_path, qdir, common = sys.argv[1:8]
execute = execute == '1'; permanent = permanent == '1'
report = json.load(open(manifest, encoding='utf-8'))
if report.get('schema') != 1:
    raise SystemExit('ERROR: this report was not written by scan.sh/scan.ps1')
# refuse reports older than 24h
try:
    gen = datetime.datetime.strptime(report['generatedAt'], '%Y-%m-%d %H:%M:%S')
    if (datetime.datetime.now() - gen).total_seconds() > 24 * 3600:
        raise SystemExit('ERROR: report is older than 24 hours; scan again')
except ValueError:
    pass

items = {it['id'].upper(): it for it in report.get('items') or []}
raw = [x.strip().upper() for x in ids.replace(',', ';').replace('|', ';').replace(' ', ';').split(';') if x.strip()]
chosen = []
if raw == ['ALL-GREEN'] or (len(raw) == 1 and raw[0] == 'ALL-GREEN'):
    chosen = [it for it in report['items'] if it.get('level') == 'green']
else:
    for i in raw:
        if i not in items:
            print(f"ERROR: unknown id {i}"); raise SystemExit(2)
        chosen.append(items[i])

# re-check protection via bash helper
def protected(path):
    env = os.environ.copy()
    # source common.sh and call pc_protected
    script = f'source "{common}"; pc_init_guard; pc_protected "{path}"'
    out = subprocess.check_output(['bash', '-lc', script], text=True).strip()
    return out

index = json.load(open(index_path, encoding='utf-8')) if os.path.exists(index_path) else []
results = []

def delete_tree(path):
    if os.path.islink(path) or os.path.isfile(path):
        os.remove(path); return
    # delete contents for caches, keep the folder
    for name in os.listdir(path):
        fp = os.path.join(path, name)
        try:
            if os.path.isdir(fp) and not os.path.islink(fp):
                shutil.rmtree(fp)
            else:
                os.remove(fp)
        except OSError as e:
            print(f"  keep-in-use: {fp} ({e})")

def quarantine(path, item_id):
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    dest = os.path.join(qdir, f"{item_id}-{stamp}-{os.path.basename(path.rstrip('/'))}")
    if execute:
        os.makedirs(qdir, exist_ok=True)
        shutil.move(path, dest)
    return dest

for it in chosen:
    iid = it['id']
    method = it.get('method') or ''
    paths = it.get('paths') or []
    print(f"ITEM: {iid} {it.get('label')} ({method})")
    status = 'done'; kept = 0
    for path in paths:
        why = protected(path)
        # Trash empty is allowed even though home-adjacent
        if why and not (method == 'empty-recycle-bin' and path.endswith('.Trash')):
            # allow Library/Caches even if a broader rule fires
            if not (path.startswith(os.path.expanduser('~/Library/Caches')) or path.startswith(os.path.expanduser('~/.cache'))
                    or path.startswith(os.path.expanduser('~/.npm')) or path.startswith('/tmp')
                    or 'Trash' in path):
                print(f"  skipped protected:{why} {path}")
                status = 'skipped'; continue
        if not os.path.exists(path):
            print(f"  skipped missing {path}"); status = 'skipped'; continue
        if method in ('delete-contents', 'delete-old'):
            if execute:
                try:
                    if os.path.isdir(path) and method == 'delete-contents':
                        delete_tree(path)
                    elif os.path.isdir(path) and method == 'delete-old':
                        # only remove entries older than 24h
                        cutoff = time.time() - 86400
                        for name in os.listdir(path):
                            fp = os.path.join(path, name)
                            try:
                                if os.lstat(fp).st_mtime >= cutoff: continue
                                if os.path.isdir(fp) and not os.path.islink(fp): shutil.rmtree(fp)
                                else: os.remove(fp)
                            except OSError:
                                kept += 1
                    else:
                        os.remove(path)
                    print(f"  deleted {path}")
                except OSError as e:
                    print(f"  failed {path}: {e}"); status = 'partial'
            else:
                print(f"  PLAN delete {path}")
        elif method == 'quarantine':
            if permanent:
                if execute:
                    try:
                        if os.path.isdir(path) and not os.path.islink(path): shutil.rmtree(path)
                        else: os.remove(path)
                        print(f"  permanent-delete {path}")
                    except OSError as e:
                        print(f"  failed {path}: {e}"); status = 'partial'
                else:
                    print(f"  PLAN permanent-delete {path}")
            else:
                dest = quarantine(path, iid)
                entry = {'id': iid, 'originalPath': path, 'quarantinePath': dest, 'label': it.get('label'), 'at': datetime.datetime.now().isoformat(timespec='seconds')}
                if execute:
                    index.append(entry)
                    print(f"  quarantine {path} -> {dest}")
                else:
                    print(f"  PLAN quarantine {path} -> {dest}")
        elif method == 'empty-recycle-bin':
            if execute:
                try:
                    for name in os.listdir(path):
                        fp = os.path.join(path, name)
                        try:
                            if os.path.isdir(fp) and not os.path.islink(fp): shutil.rmtree(fp)
                            else: os.remove(fp)
                        except OSError:
                            kept += 1
                    print(f"  emptied {path}")
                except OSError as e:
                    print(f"  failed {path}: {e}"); status = 'partial'
            else:
                print(f"  PLAN empty {path}")
        else:
            print(f"  skipped unsupported-method:{method}"); status = 'skipped'
    if kept and status == 'done': status = 'partial'
    results.append({'id': iid, 'status': status, 'keptInUse': kept})

if execute:
    json.dump(index, open(index_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)

result_path = os.path.join(os.path.dirname(index_path), f"clean-{datetime.datetime.now().strftime('%Y%m%d-%H%M%S')}.json")
json.dump({'acted': results, 'execute': execute}, open(result_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print(f"RESULT: {result_path}")
PY
