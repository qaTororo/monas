#!/bin/bash
set -euo pipefail

# Claude Code の nested session ガードを回避する。
# CLAUDECODE 変数が存在すると子プロセスの claude 起動がブロックされるため除去する。
unset CLAUDECODE

MONAS_DIR="$1"
INSTRUCTION="$2"
RUNID="$(date '+%Y%m%d-%H%M%S')"
PROJECT_DIR="$(pwd)"
WORKSPACE="$PROJECT_DIR/.monas/$RUNID"

mkdir -p "$WORKSPACE/logs"
ln -sfn "$WORKSPACE" "$PROJECT_DIR/.monas/latest"

log() { echo "[$(date '+%H:%M:%S')] [leader] $1" | tee -a "$WORKSPACE/logs/leader.log"; }

# shellcheck source=scripts/json_helpers.sh
source "$MONAS_DIR/scripts/json_helpers.sh"

log "Run ID: $RUNID"
log "Instruction: $INSTRUCTION"

# Phase 1: tasks.json 生成
log "Phase 1: Generating tasks.json..."
CLAUDE_RAW="$WORKSPACE/logs/leader-phase1-raw.json"
if ! claude -p "$INSTRUCTION" \
  --output-format json \
  --append-system-prompt "$(cat "$MONAS_DIR/prompts/leader-plan.md")" \
  --allowedTools "Read" \
  2>> "$WORKSPACE/logs/leader.log" \
  > "$CLAUDE_RAW"; then
  log "FATAL: Claude failed to generate output."
  log "--- Claude raw output ---"
  cat "$CLAUDE_RAW" >> "$WORKSPACE/logs/leader.log"
  log "--- end of raw output ---"
  exit 1
fi

log "--- Claude raw output ---"
cat "$CLAUDE_RAW" >> "$WORKSPACE/logs/leader.log"
log "--- end of raw output ---"

RESULT_TEXT=$(jq -r '.result' "$CLAUDE_RAW" 2>> "$WORKSPACE/logs/leader.log") || {
  log "FATAL: Failed to extract .result from Claude output."
  exit 1
}
# コードフェンス（```json ... ``` または ``` ... ```）が含まれる場合は中身のみ抽出する
if echo "$RESULT_TEXT" | grep -q '```'; then
  echo "$RESULT_TEXT" | sed -n '/^```\(json\)\?$/,/^```$/{ /^```\(json\)\?$/d; /^```$/d; p }' > "$WORKSPACE/tasks.json"
else
  echo "$RESULT_TEXT" > "$WORKSPACE/tasks.json"
fi

# 生成されたJSONの構文・スキーマ検証
if ! err=$(verify_json_syntax "$WORKSPACE/tasks.json"); then
  log "FATAL: tasks.json is not valid JSON. $err"
  log "--- tasks.json content ---"
  cat "$WORKSPACE/tasks.json" >> "$WORKSPACE/logs/leader.log"
  log "--- end of tasks.json ---"
  exit 1
fi
if ! err=$(verify_tasks_schema "$WORKSPACE/tasks.json"); then
  log "FATAL: tasks.json schema is invalid. $err"
  log "--- tasks.json content ---"
  cat "$WORKSPACE/tasks.json" >> "$WORKSPACE/logs/leader.log"
  log "--- end of tasks.json ---"
  exit 1
fi
log "tasks.json generated and validated successfully."

# Phase 2: Members 並列起動
log "Phase 2: Spawning members..."
while IFS= read -r member; do
  log "Spawning member: $member"
  if command -v setsid >/dev/null 2>&1; then
    setsid bash "$MONAS_DIR/scripts/member-loop.sh" "$member" "$WORKSPACE" "$MONAS_DIR" "$PROJECT_DIR" > "$WORKSPACE/logs/member-${member}.log" 2>&1 &
  else
    nohup bash "$MONAS_DIR/scripts/member-loop.sh" "$member" "$WORKSPACE" "$MONAS_DIR" "$PROJECT_DIR" > "$WORKSPACE/logs/member-${member}.log" 2>&1 & disown
  fi
done < <(jq -r '[keys[] | select(. != "_thought")] | .[]' "$WORKSPACE/tasks.json")

log "All members spawned (stateless). Leader exiting."
