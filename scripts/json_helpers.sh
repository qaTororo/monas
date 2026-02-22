#!/bin/bash
# json_helpers.sh - JSON検証の純粋関数群
# 副作用なし（ファイル書き込みなし・exit呼び出しなし）
# 終了ステータス（0=成功 / 1=失敗）とエラーメッセージ（stdout）のみを返す

# verify_json_syntax: JSONファイルの構文チェック
# Usage: if ! err=$(verify_json_syntax <file>); then echo "$err"; fi
# Returns: 0=valid, 1=invalid (error message on stdout)
# NOTE: set -e 環境下では必ず `if !` の中で呼ぶこと（return 1 でスクリプトが即終了するため）
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
# NOTE: set -e 環境下では必ず `if !` の中で呼ぶこと（return 1 でスクリプトが即終了するため）
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

  # 各タスクのキー形式と必須フィールドを検証（不正なキーを特定してエラーに含める）
  local invalid_keys
  invalid_keys=$(jq -r '
    [to_entries[] | select(.key != "_thought") |
      select(
        (.key | test("^[a-z0-9-]+$") | not) or
        (.value | type != "object") or
        (.value | has("objective") | not) or
        (.value | has("definition_of_done") | not) or
        (.value | has("allowed_tools") | not) or
        (.value | has("status") | not)
      ) | .key
    ] | join(", ")
  ' "$file" 2>/dev/null)
  if [ -n "$invalid_keys" ]; then
    echo "Invalid task schema for keys: [$invalid_keys]. Each task must have a lowercase-hyphen key and fields: objective, definition_of_done, allowed_tools, status"
    return 1
  fi

  return 0
}
