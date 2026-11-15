#!/usr/bin/env bash
# common.sh - protection rules and helpers for the macOS scripts.
# Source from scan.sh / clean.sh / report.sh. Do not run by itself.

pc_json_str() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"
}

pc_norm() {
  local p="$1"
  [[ -n "$p" ]] || { echo ""; return; }
  p="${p%\"}"; p="${p#\"}"
  if [[ "$p" != /* ]]; then echo ""; return; fi
  # resolve .. and . without requiring the path to exist
  python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]).rstrip("/"))' "$p" 2>/dev/null || echo "$p"
}

pc_under() {
  local path="$1" base="$2"
  [[ -n "$path" && -n "$base" ]] || return 1
  [[ "$path" == "$base" || "$path" == "$base"/* ]]
}

pc_measure() {
  # prints sizeBytes|files|newestYYYY-MM-DD
  python3 - "$1" <<'PY'
import os, sys, datetime
root = sys.argv[1]
size = files = 0
newest = 0
if os.path.isfile(root):
    st = os.lstat(root)
    print(f"{st.st_size}|1|{datetime.datetime.fromtimestamp(st.st_mtime).strftime('%Y-%m-%d')}")
    raise SystemExit
for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
    # skip huge / protected trees if we somehow land in them
    base = os.path.basename(dirpath)
    if base in ('.git', 'node_modules') and dirpath != root:
        # still measure node_modules when it IS the root
        if base == '.git':
            dirnames[:] = []
            continue
    for name in filenames:
        fp = os.path.join(dirpath, name)
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
day = datetime.datetime.fromtimestamp(newest).strftime('%Y-%m-%d') if newest else ''
print(f"{size}|{files}|{day}")
PY
}

pc_init_guard() {
  PC_ZONES=()
  local home="$HOME"
  for p in \
    /System /Library /Applications /usr /bin /sbin /private/var/db /private/var/vm \
    "$home/Library/Mail" "$home/Library/Messages" "$home/Library/Mobile Documents" \
    "$home/Library/Group Containers" "$home/Library/Containers" \
    "$home/Library/Keychains" "$home/Library/Cookies" \
    "$home/Desktop" "$home/Documents" "$home/Pictures" "$home/Movies" "$home/Music" \
    "$home/.ssh" "$home/.gnupg" "$home/.aws" "$home/.config" \
    "$home/.claude" "$home/.codex" "$home/.cursor" "$home/.openclaw"; do
    [[ -e "$p" ]] && PC_ZONES+=("$(pc_norm "$p")|system-or-personal")
  done
  # chat / notes apps
  for p in \
    "$home/Library/Containers/com.tencent.xinWeChat" \
    "$home/Library/Containers/com.tencent.qq" \
    "$home/Library/Application Support/Telegram Desktop" \
    "$home/Library/Application Support/Slack" \
    "$home/Library/Application Support/discord" \
    "$home/Library/Application Support/Feishu" \
    "$home/Library/Application Support/LarkShell"; do
    [[ -e "$p" ]] && PC_ZONES+=("$(pc_norm "$p")|chat")
  done
  # user protect list
  if [[ -n "${PROTECT:-}" ]]; then
    IFS=';' read -ra _pp <<<"$PROTECT"
    for p in "${_pp[@]}"; do
      p="$(echo "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -n "$p" ]] && PC_ZONES+=("$(pc_norm "$p")|user-protected")
    done
  fi
  # granted project roots are recorded but do not expand the deletable surface by themselves
  PC_GRANTED=()
  if [[ -n "${PROJECT_ROOTS:-}" ]]; then
    IFS=';' read -ra _pr <<<"$PROJECT_ROOTS"
    for p in "${_pr[@]}"; do
      p="$(echo "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -n "$p" && -d "$p" ]] && PC_GRANTED+=("$(pc_norm "$p")")
    done
  fi
}

pc_protected() {
  local path norm z base reason
  path="$(pc_norm "$1")"
  [[ -n "$path" ]] || { echo "bad-path"; return; }
  # never allow deleting the home directory itself, or /
  [[ "$path" == "/" || "$path" == "$HOME" ]] && { echo "root-or-home"; return; }
  for z in "${PC_ZONES[@]:-}"; do
    base="${z%%|*}"; reason="${z#*|}"
    if pc_under "$path" "$base"; then
      # caches under Library/Caches are allowed even though Library itself is protected
      if [[ "$path" == "$HOME/Library/Caches" || "$path" == "$HOME/Library/Caches"/* ]]; then
        continue
      fi
      echo "$reason"; return
    fi
  done
  # never touch anything that looks like credentials or source control at the leaf
  case "$(basename "$path")" in
    .git|.ssh|.gnupg|.aws|.env|.env.*) echo "credentials-or-vcs"; return ;;
  esac
  echo ""
}
