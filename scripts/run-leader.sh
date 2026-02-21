#!/bin/bash
set -euo pipefail

MONAS_DIR="$1"
INSTRUCTION="$2"
RUNID="$(date '+%Y%m%d-%H%M%S')"
PROJECT_DIR="$(pwd)"
WORKSPACE="$PROJECT_DIR/.monas/$RUNID"

mkdir -p "$WORKSPACE/logs"
ln -sfn "$WORKSPACE" "$PROJECT_DIR/.monas/latest"

log() { echo "[$(date '+%H:%M:%S')] [leader] $1" | tee -a "$WORKSPACE/logs/leader.log"; }

log "Run ID: $RUNID"
log "Instruction: $INSTRUCTION"

# Phase 1: tasks.json 生成
log "Phase 1: Generating tasks.json..."
if ! claude -p "$INSTRUCTION" \
  --output-format json \
  --append-system-prompt "$(cat "$MONAS_DIR/prompts/leader-plan.md")" \
  --allowedTools "Read" \
  2>> "$WORKSPACE/logs/leader.log" \
  | jq -r '.result' > "$WORKSPACE/tasks.json"; then
  log "FATAL: Claude failed to generate output or jq failed to parse."
  exit 1
fi

# 生成されたJSONの厳密なバリデーション
if ! jq -e . "$WORKSPACE/tasks.json" >/dev/null 2>&1; then
  log "FATAL: tasks.json is not valid JSON."
  cat "$WORKSPACE/tasks.json" >> "$WORKSPACE/logs/leader.log"
  exit 1
fi
log "tasks.json generated successfully."

# Phase 2: Members 並列起動
log "Phase 2: Spawning members..."
declare -a PIDS=()
while IFS= read -r member; do
  log "Spawning member: $member"
  bash "$MONAS_DIR/scripts/member-loop.sh" \
    "$member" "$WORKSPACE" "$MONAS_DIR" "$PROJECT_DIR" \
    > "$WORKSPACE/logs/member-${member}.log" 2>&1 &
  PIDS+=($!)
done < <(jq -r 'keys[]' "$WORKSPACE/tasks.json")

# 全 Member 完了を待機
FAILED=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || FAILED=$((FAILED + 1))
done
log "All members finished. Failed: $FAILED"

# Phase 3: 完了サマリー出力（Ownerが受け取るstdout）
log "Phase 3: Generating summary..."
SUMMARY=$(claude -p "全タスクが完了しました。tasks.jsonの内容を基に、達成内容を簡潔にまとめてください。" \
  --append-system-prompt "$(cat "$MONAS_DIR/prompts/leader-summary.md")" \
  --allowedTools "Read" < "$WORKSPACE/tasks.json")
echo "$SUMMARY" | tee -a "$WORKSPACE/logs/leader.log"
log "COMPLETED: $RUNID"
