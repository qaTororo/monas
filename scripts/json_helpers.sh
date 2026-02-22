#!/bin/bash
# json_helpers.sh - JSON検証の純粋関数群
# 副作用なし（ファイル書き込みなし・exit呼び出しなし）
# 終了ステータス（0=成功 / 1=失敗）とエラーメッセージ（stdout）のみを返す

# verify_json_syntax: JSONファイルの構文チェック
# Usage: if ! err=$(verify_json_syntax <file>); then echo "$err"; fi
# Returns: 0=valid, 1=invalid (error message on stdout)
verify_json_syntax() {
  local file="$1"
  if ! jq -e . "$file" >/dev/null 2>&1; then
    echo "Invalid JSON syntax in $file"
    return 1
  fi
  return 0
}

# verify_tasks_schema: tasks.jsonのスキーマ検証
# Usage: if ! err=$(verify_tasks_schema <file>); then echo "$err"; fi
# Returns: 0=valid, 1=invalid (error message on stdout)
# 注: _thoughtフィールドはChain of Thought用のため検証対象外
verify_tasks_schema() {
  local file="$1"

  # トップレベルはオブジェクトであること
  if ! jq -e 'type == "object"' "$file" >/dev/null 2>&1; then
    echo "tasks.json must be a JSON object"
    return 1
  fi

  # タスクが1件以上存在すること（_thoughtを除く）
  local task_count
  task_count=$(jq '[to_entries[] | select(.key != "_thought")] | length' "$file" 2>/dev/null)
  if [ "${task_count:-0}" -eq 0 ]; then
    echo "tasks.json must contain at least one task (excluding _thought)"
    return 1
  fi

  # 各タスクのキー形式と必須フィールドを検証
  if ! jq -e '
    [to_entries[] | select(.key != "_thought")] |
    map(
      (.key | test("^[a-z0-9-]+$")) and
      (.value | type == "object") and
      (.value | has("objective")) and
      (.value | has("definition_of_done")) and
      (.value | has("allowed_tools")) and
      (.value | has("status"))
    ) | all
  ' "$file" >/dev/null 2>&1; then
    echo "Invalid task schema: each task must have a lowercase-hyphen key and fields: objective, definition_of_done, allowed_tools, status"
    return 1
  fi

  return 0
}
