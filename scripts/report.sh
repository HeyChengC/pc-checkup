#!/usr/bin/env bash
# report.sh - fill assets/report-template.html with a scan JSON and open it.
# Usage: bash scripts/report.sh -Manifest ~/pc-checkup/scan-....json [-NoOpen]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST=""; NO_OPEN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -Manifest|--manifest) MANIFEST="$2"; shift ;;
    -NoOpen|--no-open) NO_OPEN=1 ;;
    -Template|--template) TEMPLATE="$2"; shift ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$MANIFEST" && -f "$MANIFEST" ]] || { echo "ERROR: report not found: $MANIFEST" >&2; exit 2; }
TEMPLATE="${TEMPLATE:-$ROOT/assets/report-template.html}"
[[ -f "$TEMPLATE" ]] || { echo "ERROR: template not found: $TEMPLATE" >&2; exit 2; }

OUT="$(dirname "$MANIFEST")/report-$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8"))["scanId"])' "$MANIFEST").html"

python3 - "$MANIFEST" "$TEMPLATE" "$OUT" <<'PY'
import json, sys, re
manifest, template, out = sys.argv[1:4]
r = json.load(open(manifest, encoding='utf-8'))
items = []
for it in r.get('items') or []:
    paths = it.get('paths') or []
    first = paths[0] if paths else ''
    extra = {}
    if it.get('extra'):
        if it['extra'].get('byDrive') is not None: extra['byDrive'] = it['extra']['byDrive']
        if it['extra'].get('frames') is not None: extra['frames'] = it['extra']['frames']
    items.append({
        'id': it.get('id'), 'level': it.get('level'), 'group': it.get('group'),
        'category': it.get('category'), 'label': it.get('label'),
        'paths': [first], 'sizeBytes': int(it.get('sizeBytes') or 0),
        'files': it.get('files'), 'newest': it.get('newest'),
        'method': it.get('method'), 'extra': extra,
    })
prot = []
for p in (r.get('notTouched') or {}).get('protectedFolders') or []:
    prot.append({'reason': p.get('reason'), 'sizeBytes': int(p.get('sizeBytes') or 0), 'byDrive': p.get('byDrive') or {}})
apps = []
for a in (r.get('notTouched') or {}).get('personalApps') or []:
    apps.append({'key': a.get('key'), 'sizeBytes': int(a.get('sizeBytes') or 0)})
facts = r.get('facts') or {}
slim = {
    'schema': r.get('schema'), 'scanId': r.get('scanId'), 'generatedAt': r.get('generatedAt'),
    'mode': r.get('mode'), 'platform': r.get('platform') or 'mac',
    'systemDrive': r.get('systemDrive') or '/',
    'drives': r.get('drives') or [], 'items': items,
    'notTouched': {
        'protectedFolders': prot, 'personalApps': apps,
        'tempInUseBytes': (r.get('notTouched') or {}).get('tempInUseBytes') or 0,
    },
    'quarantinePendingBytes': r.get('quarantinePendingBytes') or 0,
    'facts': {'ramTotalBytes': facts.get('ramTotalBytes') or 0, 'ramFreeBytes': facts.get('ramFreeBytes') or 0},
}
json_text = json.dumps(slim, ensure_ascii=False, separators=(',', ':')).replace('</', '<\\/')
html = open(template, encoding='utf-8').read()
marker = '/*__REPORT_JSON__*/null'
if marker not in html:
    raise SystemExit('the template has no data slot')
html = html.replace(marker, json_text, 1)
open(out, 'w', encoding='utf-8').write(html)
print(f'HTML: {out}')
PY

echo "HTML: $OUT"
if [[ $NO_OPEN -eq 0 ]]; then
  if open "$OUT" 2>/dev/null; then echo "HTML-OPENED: yes"; else echo "HTML-OPENED: no (open the file above by hand)"; fi
fi
