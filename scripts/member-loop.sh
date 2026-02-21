#!/bin/bash
set -euo pipefail

MEMBER_NAME="$1"
WORKSPACE="$2"
MONAS_DIR="$3"
PROJECT_DIR="$4"
TASKS_JSON="$WORKSPACE/tasks.json"
CONTEXT_FILE="$WORKSPACE/context-${MEMBER_NAME}.txt"
MAX_ITER=15

log() { echo "[$(date '+%H:%M:%S')] [member-${MEMBER_NAME}] $1"; }

# POSIX準拠の排他制御（mkdirのアトミック性を利用したスピンロック）
acquire_lock() {
  local lock_dir="${TASKS_JSON}.lock.d"
  local retries=20  # 0.5s × 20 = 10秒タイムアウト
  while [ $retries -gt 0 ]; do
    if mkdir "$lock_dir" 2>/dev/null; then
      return 0
    fi
    sleep 0.5
    retries=$((retries - 1))
  done
  return 1
}

release_lock() {
  rmdir "${TASKS_JSON}.lock.d" 2>/dev/null || true
}

update_task_status() {
  local status="$1"
  local report="$2"
  if acquire_lock; then
    # trap EXIT でロック解放を保証（RETURN は set -e による強制終了時に実行されないため）
    trap release_lock EXIT
    jq --arg m "$MEMBER_NAME" --arg s "$status" --arg r "$report" \
      '.[$m].status = $s | .[$m].final_report = $r' \
      "$TASKS_JSON" > "${TASKS_JSON}.tmp" && mv "${TASKS_JSON}.tmp" "$TASKS_JSON"
    release_lock
    trap - EXIT
  else
    log "CRITICAL: Could not update tasks.json due to lock contention."
    exit 1
  fi
}

# タスク情報取得
OBJECTIVE=$(jq -r ".\"${MEMBER_NAME}\".objective" "$TASKS_JSON")
DOD=$(jq -r ".\"${MEMBER_NAME}\".definition_of_done[]" "$TASKS_JSON" | awk '{print NR". "$0}')
ALLOWED_TOOLS=$(jq -r ".\"${MEMBER_NAME}\".allowed_tools // [] | join(\",\")" "$TASKS_JSON")

log "Starting. Objective: $OBJECTIVE"
touch "$CONTEXT_FILE"

for i in $(seq 1 $MAX_ITER); do
  log "Iteration $i/$MAX_ITER"

  STATUS=$(jq -r ".\"${MEMBER_NAME}\".status" "$TASKS_JSON")
  [ "$STATUS" = "done" ] && { log "Already done."; exit 0; }

  SYSTEM_PROMPT="$(cat "$MONAS_DIR/prompts/member.md")"
  USER_PROMPT="$(cat <<EOF
## Your Task
**Objective**: $OBJECTIVE

## Definition of Done
$DOD

## Context
- Working directory: $PROJECT_DIR
- Iteration: $i / $MAX_ITER

## Previous Iterations History
$(cat "$CONTEXT_FILE")
EOF
)"

  OUTPUT=$(cd "$PROJECT_DIR" && claude -p "$USER_PROMPT" \
    --append-system-prompt "$SYSTEM_PROMPT" \
    --allowedTools "$ALLOWED_TOOLS" \
    2>&1)

  log "Output received."

  # 次回イテレーションのためにコンテキストを保存
  printf "=== Iteration %s ===\n%s\n\n" "$i" "$OUTPUT" >> "$CONTEXT_FILE"

  if echo "$OUTPUT" | grep -q "<DONE>"; then
    log "DONE detected!"
    # macOS互換: grep -P ではなく sed で抽出（sed は不一致でも 0 を返すため変数で判定）
    REPORT=$(echo "$OUTPUT" | sed -n 's/.*<DONE>\(.*\)<\/DONE>.*/\1/p')
    REPORT="${REPORT:-Completed without summary.}"
    update_task_status "done" "$REPORT"
    log "tasks.json updated: done"
    exit 0
  fi

  log "Not done yet. Continuing..."
done

# サーキットブレーカー
log "CIRCUIT BREAKER: Max iterations ($MAX_ITER) reached."
update_task_status "error" "Circuit breaker triggered"
exit 1
