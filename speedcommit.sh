#!/bin/bash
# speedcommit.sh - 50 parallel bots, each commits every 50ms and pushes every 15s

REPO_NAME="${REPO_NAME:-speed-commit}"
GITHUB_USER="${GITHUB_USER}"
GITHUB_TOKEN="${GITHUB_TOKEN}"
NUM_BOTS="${NUM_BOTS:-50}"

if [ -z "$GITHUB_USER" ] || [ -z "$GITHUB_TOKEN" ]; then
  echo "ERROR: GITHUB_USER and GITHUB_TOKEN must be set as environment variables."
  exit 1
fi

CLONE_URL="https://$GITHUB_TOKEN@github.com/$GITHUB_USER/$REPO_NAME.git"

# --- Create repo if it doesn't exist -----------------------------------------
echo "Ensuring GitHub repo '$REPO_NAME' exists..."
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "https://api.github.com/user/repos" \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -d "{\"name\":\"$REPO_NAME\",\"private\":false,\"auto_init\":false}")

if [ "$RESPONSE" == "201" ]; then
  echo "Repo created."
elif [ "$RESPONSE" == "422" ]; then
  echo "Repo already exists -- continuing."
else
  echo "Failed to create repo (HTTP $RESPONSE)"
  exit 1
fi

# --- Bootstrap: clone once and make initial commit if repo is empty -----------
BOOTSTRAP_DIR="/tmp/cb_bootstrap"
rm -rf "$BOOTSTRAP_DIR"
git clone "$CLONE_URL" "$BOOTSTRAP_DIR"
cd "$BOOTSTRAP_DIR"
git config user.email "$GITHUB_USER@users.noreply.github.com"
git config user.name  "CommitBlast"

if ! git log --oneline > /dev/null 2>&1; then
  echo "# $REPO_NAME" > README.md
  git add README.md
  git commit -m "Initial commit"
  git push origin HEAD
  echo "Initial commit pushed."
fi
cd /

# --- Worker function ----------------------------------------------------------
# Each bot gets its own clone dir and its own file (bot_N.txt)
# It commits every 50ms and pushes every 15 seconds.
# On push rejection it pull-rebases and retries up to 10 times.

worker() {
  local BOT_ID="$1"
  local LOCAL="/tmp/cb_bot${BOT_ID}"
  local MYFILE="bot_${BOT_ID}.txt"
  local COUNTER=1
  local COMMITS=0
  local PUSHES=0

  rm -rf "$LOCAL"
  git clone "$CLONE_URL" "$LOCAL" 2>&1 | tail -1
  cd "$LOCAL"
  git config user.email "bot${BOT_ID}@commitblast.local"
  git config user.name  "CommitBlast-Bot${BOT_ID}"
  git config pull.rebase true
  git config rerere.enabled false

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
      # Rejected because remote is ahead → rebase and retry
      if echo "$PUSH_OUT" | grep -qiE "rejected|non-fast-forward|fetch first"; then
        echo "[BOT $BOT_ID] Push rejected (attempt $((ATTEMPTS+1))) - rebasing..."
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

# --- Cleanup on exit ----------------------------------------------------------
cleanup() {
  echo ""
  echo "Shutting down - sending final pushes..."
  # Kill all background workers
  kill $(jobs -p) 2>/dev/null
  # Final push from each bot dir
  for i in $(seq 1 $NUM_BOTS); do
    LOCAL="/tmp/cb_bot${i}"
    if [ -d "$LOCAL" ]; then
      cd "$LOCAL"
      git push origin HEAD 2>/dev/null &
    fi
  done
  wait
  echo "All bots stopped."
  exit 0
}
trap cleanup SIGINT SIGTERM

# --- Launch all bots ----------------------------------------------------------
echo ""
echo "Launching $NUM_BOTS bots... (commit every 50ms, push every 15s each)"
echo ""

for i in $(seq 1 $NUM_BOTS); do
  worker "$i" &
  sleep 0.1   # stagger starts slightly to avoid clone stampede
done

echo "All $NUM_BOTS bots running! Press Ctrl+C to stop."
wait
