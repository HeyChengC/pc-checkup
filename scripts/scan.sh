#!/usr/bin/env bash
# scan.sh - read-only checkup for macOS. Deletes nothing. Writes ~/pc-checkup/scan-<id>.json
# then builds and opens the HTML report. Usage:
#   bash scripts/scan.sh
#   bash scripts/scan.sh --quick
#   bash scripts/scan.sh --project-roots "/Users/me/work;/Users/me/video"
#   bash scripts/scan.sh --protect "/Users/me/photos"
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/common.sh"

QUICK=0; NO_OPEN=0; PROJECT_ROOTS=""; PROTECT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick|-Quick) QUICK=1 ;;
    --no-open|-NoOpen) NO_OPEN=1 ;;
    --project-roots|-ProjectRoots) PROJECT_ROOTS="$2"; shift ;;
    --protect|-Protect) PROTECT="$2"; shift ;;
    --out-dir|-OutDir) OUT_DIR="$2"; shift ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

pc_init_guard
OUT_DIR="${OUT_DIR:-$HOME/pc-checkup}"
mkdir -p "$OUT_DIR"
SCAN_ID="$(date +%Y%m%d-%H%M%S)"
MANIFEST="$OUT_DIR/scan-$SCAN_ID.json"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pc-checkup.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

ITEMS="$TMP/items.jsonl"; : >"$ITEMS"
DROPPED="$TMP/dropped.jsonl"; : >"$DROPPED"

add_item() {
  # level category label method path1 [path2...]  [--note text] [--min bytes]
  local level="$1" cat="$2" label="$3" method="$4"; shift 4
  local note="" min=0 paths=() p size=0 files=0 newest="" why keep=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --note) note="$2"; shift 2 ;;
      --min) min="$2"; shift 2 ;;
      *) paths+=("$1"); shift ;;
    esac
  done
  for p in "${paths[@]}"; do
    [[ -e "$p" ]] || continue
    why="$(pc_protected "$p")"
    if [[ -n "$why" && "$method" != "info" ]]; then
      printf '{"path":%s,"category":%s,"reason":%s}\n' "$(pc_json_str "$p")" "$(pc_json_str "$cat")" "$(pc_json_str "$why")" >>"$DROPPED"
      continue
    fi
    keep+=("$p")
  done
  [[ ${#keep[@]} -gt 0 ]] || return 0
  local m sz fl nw
  for p in "${keep[@]}"; do
    m="$(pc_measure "$p")"
    sz="${m%%|*}"; rest="${m#*|}"; fl="${rest%%|*}"; nw="${rest##*|}"
    size=$((size + sz)); files=$((files + fl))
    [[ -n "$nw" && ( -z "$newest" || "$nw" > "$newest" ) ]] && newest="$nw"
  done
  [[ $size -ge $min && $size -gt 0 ]] || return 0
  local group=basic
  case "$cat" in model-cache|browser-runtime|other-cache|node-modules|venv|frames|duplicate) group=creator ;; esac
  local path_json="" first=1
  for p in "${keep[@]}"; do
    [[ $first -eq 1 ]] || path_json+=","
    path_json+=$(pc_json_str "$p"); first=0
  done
  printf '{"level":%s,"group":%s,"category":%s,"label":%s,"paths":[%s],"sizeBytes":%s,"files":%s,"newest":%s,"method":%s,"note":%s,"extra":{}}\n' \
    "$(pc_json_str "$level")" "$(pc_json_str "$group")" "$(pc_json_str "$cat")" "$(pc_json_str "$label")" \
    "$path_json" "$size" "$files" "$(pc_json_str "$newest")" "$(pc_json_str "$method")" "$(pc_json_str "$note")" >>"$ITEMS"
}

# ---------------------------------------------------------------- caches
[[ -d "$HOME/Library/Caches" ]] && while IFS= read -r -d '' d; do
  name="$(basename "$d")"
  case "$name" in
    com.apple.*|CloudKit|FamilyCircle|GameKit|HomeKit|PassKit-*|*Metadata) continue ;;
  esac
  add_item green app-cache "${name} cache" delete-contents "$d" --min $((20*1024*1024)) --note "settings-and-data-untouched"
done < <(find "$HOME/Library/Caches" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

# browsers
for pair in \
  "Chrome|$HOME/Library/Caches/Google/Chrome" \
  "Edge|$HOME/Library/Caches/com.microsoft.edgemac" \
  "Brave|$HOME/Library/Caches/BraveSoftware/Brave-Browser" \
  "Arc|$HOME/Library/Caches/Arc" \
  "Firefox|$HOME/Library/Caches/Firefox"; do
  name="${pair%%|*}"; path="${pair#*|}"
  [[ -d "$path" ]] && add_item green browser-cache "${name} cache" delete-contents "$path" --min $((20*1024*1024)) --note "logins-history-bookmarks-untouched"
done
[[ -d "$HOME/Library/Caches/com.apple.Safari" ]] && add_item green browser-cache "Safari cache" delete-contents \
  "$HOME/Library/Caches/com.apple.Safari" --min $((20*1024*1024)) --note "logins-history-bookmarks-untouched"

# temp: only the current user''s TMPDIR (never the shared /tmp)
if [[ -n "${TMPDIR:-}" && -d "$TMPDIR" ]]; then
  add_item green temp "Temporary files" delete-old "$TMPDIR" --min $((50*1024*1024)) --note "programs-recreate-what-they-need"
fi

# package managers
[[ -d "$HOME/Library/Caches/Homebrew" ]] && add_item green dev-cache "Homebrew cache" delete-contents \
  "$HOME/Library/Caches/Homebrew" --min $((20*1024*1024)) --note "packages-download-again-when-needed"
[[ -d "$HOME/Library/Caches/pip" ]] && add_item green dev-cache "pip download cache" delete-contents \
  "$HOME/Library/Caches/pip" --min $((20*1024*1024)) --note "packages-download-again-when-needed"
[[ -d "$HOME/.npm/_cacache" ]] && add_item green dev-cache "npm download cache" delete-contents \
  "$HOME/.npm/_cacache" --min $((20*1024*1024)) --note "packages-download-again-when-needed"
[[ -d "$HOME/Library/Caches/Yarn" ]] && add_item green dev-cache "yarn download cache" delete-contents \
  "$HOME/Library/Caches/Yarn" --min $((20*1024*1024)) --note "packages-download-again-when-needed"
[[ -d "$HOME/.cache/uv" ]] && add_item green dev-cache "uv download cache" delete-contents \
  "$HOME/.cache/uv" --min $((20*1024*1024)) --note "packages-download-again-when-needed"
[[ -d "$HOME/Library/Caches/Cargo" ]] && add_item green dev-cache "Cargo cache" delete-contents \
  "$HOME/Library/Caches/Cargo" --min $((20*1024*1024)) --note "packages-download-again-when-needed"

# AI models and headless browsers
hub="${HF_HUB_CACHE:-${HF_HOME:+$HF_HOME/hub}}"
hub="${hub:-$HOME/.cache/huggingface/hub}"
if [[ -d "$hub" ]]; then
  while IFS= read -r -d '' d; do
    name="$(basename "$d")"
    [[ "$name" == models--* || "$name" == datasets--* || "$name" == spaces--* ]] || continue
    kind="${name%%--*}"; rest="${name#*--}"; rest="${rest//--//}"
    add_item yellow model-cache "HuggingFace ${kind%s}: $rest" quarantine "$d" --min $((50*1024*1024)) --note "downloads-again-on-next-use"
  done < <(find "$hub" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
fi
for pair in \
  "PyTorch hub models|$HOME/.cache/torch" \
  "Whisper models|$HOME/.cache/whisper" \
  "ModelScope models|$HOME/.cache/modelscope" \
  "rembg / U2Net matting models|$HOME/.u2net" \
  "Ollama models|${OLLAMA_MODELS:-$HOME/.ollama/models}" \
  "LM Studio models|$HOME/.cache/lm-studio/models" \
  "LM Studio models|$HOME/.lmstudio/models"; do
  name="${pair%%|*}"; path="${pair#*|}"
  [[ -d "$path" ]] && add_item yellow model-cache "$name" quarantine "$path" --min $((50*1024*1024)) --note "downloads-again-on-next-use"
done
[[ -d "$HOME/.cache/puppeteer" ]] && add_item yellow browser-runtime "Puppeteer browsers" quarantine \
  "$HOME/.cache/puppeteer" --min $((50*1024*1024)) --note "downloads-again-on-next-use"
[[ -d "$HOME/Library/Caches/ms-playwright" ]] && add_item yellow browser-runtime "Playwright browsers" quarantine \
  "$HOME/Library/Caches/ms-playwright" --min $((50*1024*1024)) --note "downloads-again-on-next-use"

# unknown large folders under ~/.cache
if [[ -d "$HOME/.cache" ]]; then
  while IFS= read -r -d '' d; do
    name="$(basename "$d")"
    case "$name" in huggingface|torch|whisper|modelscope|uv|pip|puppeteer|lm-studio) continue ;; esac
    add_item yellow other-cache "~/.cache/$name" quarantine "$d" --min $((200*1024*1024)) --note "cache-of-an-unknown-tool"
  done < <(find "$HOME/.cache" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
fi

# Trash
[[ -d "$HOME/.Trash" ]] && add_item yellow recycle-bin "Trash" empty-recycle-bin "$HOME/.Trash" --min 1 --note "cannot-be-undone"

# old installers in Downloads
if [[ -d "$HOME/Downloads" ]]; then
  while IFS= read -r -d '' f; do
    age_days=$(( ($(date +%s) - $(stat -f %m "$f")) / 86400 ))
    [[ $age_days -ge 30 ]] || continue
    add_item yellow installer "$(basename "$f")" quarantine "$f" --min $((1024*1024)) --note "installed-software-does-not-need-its-installer"
  done < <(find "$HOME/Downloads" -maxdepth 2 \( -iname '*.dmg' -o -iname '*.pkg' -o -iname '*.zip' \) -type f -print0 2>/dev/null)
fi

# stale node_modules / venvs (skip in --quick)
if [[ $QUICK -eq 0 ]]; then
  search_roots=("$HOME")
  IFS=';' read -ra _pr <<<"$PROJECT_ROOTS"
  for r in "${_pr[@]}"; do
    r="$(echo "$r" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$r" && -d "$r" ]] && search_roots+=("$r")
  done
  python3 "$ROOT/scripts/mac_scan_projects.py" "$ITEMS" "${search_roots[@]}"
fi

# ---------------------------------------------------------------- assemble JSON
python3 - "$MANIFEST" "$ITEMS" "$DROPPED" "$SCAN_ID" "$QUICK" <<'PY'
import json, os, sys, subprocess, datetime
out, items_path, dropped_path, scan_id, quick = sys.argv[1:6]
items_raw = []
with open(items_path, encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if line: items_raw.append(json.loads(line))
# assign ids
g = y = 0
for it in items_raw:
    if it['level'] == 'green':
        g += 1; it['id'] = f'G{g}'
    else:
        y += 1; it['id'] = f'Y{y}'
# drives
drives = []
try:
    df = subprocess.check_output(['df', '-k', '/'], text=True).strip().splitlines()[-1].split()
    # Filesystem 1K-blocks Used Available Capacity iused ifree %iused Mounted
    size = int(df[1]) * 1024; avail = int(df[3]) * 1024
    drives.append({"name": "/", "sizeBytes": size, "freeBytes": avail})
except Exception:
    drives = [{"name": "/", "sizeBytes": 0, "freeBytes": 0}]
# try extra volumes under /Volumes
for name in os.listdir('/Volumes'):
    p = f'/Volumes/{name}'
    if not os.path.isdir(p) or os.path.samefile(p, '/'): continue
    try:
        st = os.statvfs(p)
        size = st.f_blocks * st.f_frsize; free = st.f_bavail * st.f_frsize
        if size > 8 * 1024**3:
            drives.append({"name": p, "sizeBytes": size, "freeBytes": free})
    except Exception:
        pass
dropped = []
with open(dropped_path, encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if line: dropped.append(json.loads(line))
report = {
    "schema": 1,
    "scanId": scan_id,
    "generatedAt": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    "mode": "quick" if quick == "1" else "full",
    "platform": "mac",
    "systemDrive": "/",
    "outDir": os.path.dirname(out),
    "drives": drives,
    "items": items_raw,
    "notTouched": {
        "protectedFolders": [
            {"reason": "personal", "sizeBytes": 0, "byDrive": {}},
            {"reason": "system", "sizeBytes": 0, "byDrive": {}},
        ],
        "personalApps": [],
        "tempInUseBytes": 0,
    },
    "quarantinePendingBytes": 0,
    "facts": {"ramTotalBytes": 0, "ramFreeBytes": 0, "os": "macOS"},
    "droppedByGuard": dropped,
    "grantsRejected": [],
}
# RAM
try:
    mem = subprocess.check_output(['sysctl', '-n', 'hw.memsize'], text=True).strip()
    report["facts"]["ramTotalBytes"] = int(mem)
except Exception:
    pass
with open(out, 'w', encoding='utf-8') as f:
    json.dump(report, f, ensure_ascii=False, separators=(',', ':'))
print(f"REPORT: {out}")
print(f"ITEMS: {len(items_raw)}")
print(f"MODE: {report['mode']}")
PY

args=( -Manifest "$MANIFEST" )
[[ $NO_OPEN -eq 1 ]] && args+=( -NoOpen )
bash "$ROOT/scripts/report.sh" "${args[@]}"
