#!/bin/bash
# speedcommit.sh - N bots, each commits every 50ms and pushes every 15s

REPO_NAME="${REPO_NAME:-speed-commit}"
GITHUB_USER="${GITHUB_USER}"
GITHUB_TOKEN="${GITHUB_TOKEN}"
NUM_BOTS="${NUM_BOTS:-10}"

if [ -z "$GITHUB_USER" ] || [ -z "$GITHUB_TOKEN" ]; then
  echo "ERROR: GITHUB_USER and GITHUB_TOKEN must be set as environment variables."
  exit 1
fi

CLONE_URL="https://$GITHUB_TOKEN@github.com/$GITHUB_USER/$REPO_NAME.git"

echo "=== COMMITBLAST starting ==="
echo "User: $GITHUB_USER | Repo: $REPO_NAME | Bots: $NUM_BOTS"
echo ""

# --- Bootstrap: ensure repo has at least one commit --------------------------
BOOTSTRAP_DIR="/tmp/cb_bootstrap"
rm -rf "$BOOTSTRAP_DIR"
echo "[BOOT] Cloning repo..."
git clone "$CLONE_URL" "$BOOTSTRAP_DIR" 2>&1
if [ ! -d "$BOOTSTRAP_DIR/.git" ]; then
  echo "[BOOT] Clone failed! Check GITHUB_TOKEN and REPO_NAME."
  exit 1
fi
echo "[BOOT] Clone OK"

cd "$BOOTSTRAP_DIR"
git config user.email "$GITHUB_USER@users.noreply.github.com"
git config user.name  "CommitBlast"

if ! git log --oneline > /dev/null 2>&1; then
  echo "# $REPO_NAME" > README.md
  git add README.md
  git commit -m "Initial commit"
  git push origin HEAD
  echo "[BOOT] Initial commit pushed."
fi
cd /

# --- Worker function ----------------------------------------------------------
worker() {
  local BOT_ID="$1"
  local LOCAL="/tmp/cb_bot${BOT_ID}"
  local MYFILE="bot_${BOT_ID}.txt"
  local COUNTER=1
  local COMMITS=0
  local PUSHES=0

  if [ ! -d "$LOCAL/.git" ]; then
    echo "[BOT $BOT_ID] No clone dir - skipping"
    return
  fi

  cd "$LOCAL"

  # Resume if file already exists
  if [ -f "$MYFILE" ]; then
    LAST=$(tail -1 "$MYFILE" 2>/dev/null)
    [[ "$LAST" =~ ^[0-9]+$ ]] && COUNTER=$((LAST + 1))
  fi

  echo "[BOT $BOT_ID] Started from counter $COUNTER"

  LAST_PUSH=$(date +%s)

  push_with_retry() {
    local ATTEMPTS=0
    while [ $ATTEMPTS -lt 10 ]; do
      PUSH_OUT=$(git push origin HEAD 2>&1)
      if [ $? -eq 0 ]; then
        PUSHES=$((PUSHES + 1))
        echo "[BOT $BOT_ID] PUSHED #$PUSHES (commits: $COMMITS)"
        return 0
      fi
      if echo "$PUSH_OUT" | grep -qiE "rejected|non-fast-forward|fetch first"; then
        git pull --rebase --autostash origin HEAD 2>&1 || git rebase --abort 2>/dev/null
      else
        echo "[BOT $BOT_ID] Push error (attempt $((ATTEMPTS+1))): $PUSH_OUT"
        sleep 0.5
      fi
      ATTEMPTS=$((ATTEMPTS + 1))
    done
    echo "[BOT $BOT_ID] Push failed after 10 attempts"
    return 1
  }

  while true; do
    echo "$COUNTER" > "$MYFILE"
    git add "$MYFILE" 2>/dev/null
    if git commit -m "bot${BOT_ID}: $COUNTER" > /dev/null 2>&1; then
      COMMITS=$((COMMITS + 1))
    fi
    COUNTER=$((COUNTER + 1))

    NOW=$(date +%s)
    if [ $((NOW - LAST_PUSH)) -ge 15 ]; then
      push_with_retry
      LAST_PUSH=$(date +%s)
    fi

    sleep 0.05
  done
}

# --- Clone all bots sequentially before launching ----------------------------
echo "Cloning $NUM_BOTS bot repos (one at a time)..."
for i in $(seq 1 $NUM_BOTS); do
  LOCAL="/tmp/cb_bot${i}"
  rm -rf "$LOCAL"
  echo "[BOT $i] Cloning..."
  git clone "$CLONE_URL" "$LOCAL" 2>&1 | tail -1
  if [ ! -d "$LOCAL/.git" ]; then
    echo "[BOT $i] Clone FAILED"
    continue
  fi
  cd "$LOCAL"
  git config user.email "bot${i}@commitblast.local"
  git config user.name  "CommitBlast-Bot${i}"
  git config pull.rebase true
  git config rerere.enabled false
  cd /
  echo "[BOT $i] Ready"
done

# --- Cleanup on exit ----------------------------------------------------------
cleanup() {
  echo "Shutting down..."
  kill $(jobs -p) 2>/dev/null
  for i in $(seq 1 $NUM_BOTS); do
    LOCAL="/tmp/cb_bot${i}"
    [ -d "$LOCAL" ] && cd "$LOCAL" && git push origin HEAD 2>/dev/null &
  done
  wait
  echo "All bots stopped."
  exit 0
}
trap cleanup SIGINT SIGTERM

# --- Launch all bots ----------------------------------------------------------
echo ""
echo "Launching bots!"
echo ""

for i in $(seq 1 $NUM_BOTS); do
  [ -d "/tmp/cb_bot${i}/.git" ] && worker "$i" &
done

echo "All $NUM_BOTS bots running!"
wait
