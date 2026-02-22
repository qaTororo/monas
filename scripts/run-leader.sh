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
while IFS= read -r member; do
  log "Spawning member: $member"
  if command -v setsid >/dev/null 2>&1; then
    setsid bash "$MONAS_DIR/scripts/member-loop.sh" "$member" "$WORKSPACE" "$MONAS_DIR" "$PROJECT_DIR" > "$WORKSPACE/logs/member-${member}.log" 2>&1 &
  else
    nohup bash "$MONAS_DIR/scripts/member-loop.sh" "$member" "$WORKSPACE" "$MONAS_DIR" "$PROJECT_DIR" > "$WORKSPACE/logs/member-${member}.log" 2>&1 & disown
  fi
done < <(jq -r 'keys[]' "$WORKSPACE/tasks.json")

log "All members spawned (stateless). Leader exiting."
