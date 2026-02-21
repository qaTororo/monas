# ADR-004: 外部bash判定型Ralph Loopによる完了検知

- **日付**: 2026-02-22
- **ステータス**: Accepted

## コンテキスト

Memberエージェントが「タスクを完了した」と判断する仕組みの設計。主な選択肢：

1. **LLM自己評価型**: LLM（`claude -p`）がBashツール（`jq`）を使って自分で `tasks.json` の `status` を `"done"` に更新する
2. **外部bash判定型（Ralph Loop本来）**: LLMが特定のトークン（`<DONE>`）を出力したら外部bashスクリプトが検知してファイルを更新する

仕様書の初期設計はLLM自己評価型だったが、Ralph Loopの原典（[github.com/snarktank/ralph](https://github.com/snarktank/ralph)）では外部bash判定型が採用されている。

## 決定

外部bash判定型を採用する。

**Ralph Loopの実装**:
```bash
for i in $(seq 1 $MAX_ITER); do
  OUTPUT=$(claude -p "タスク実行。完了なら<DONE>1行サマリー</DONE>を出力" \
    --allowedTools "Read,Edit,Bash")

  # 出力をコンテキストファイルに蓄積（次回イテレーションに注入）
  printf "=== Iteration %s ===\n%s\n\n" "$i" "$OUTPUT" >> context.txt

  if echo "$OUTPUT" | grep -q "<DONE>"; then
    REPORT=$(echo "$OUTPUT" | sed -n 's/.*<DONE>\(.*\)<\/DONE>.*/\1/p')
    # mkdirスピンロックで排他的にtasks.jsonを更新
    update_task_status "done" "$REPORT"
    exit 0
  fi
done
# サーキットブレーカー: 最大イテレーション超過
update_task_status "error" "Circuit breaker triggered"
exit 1
```

**Completion Promiseの定義**:
- LLMが `<DONE>サマリー（1行）</DONE>` を出力 → 外部bashが検知 → `tasks.json` を更新
- LLMはツール不要でCompletion Promiseを出力するだけでよい

**排他制御（mkdirスピンロック）**:
```bash
acquire_lock() {
  # mkdirはPOSIX規格でアトミック性が保証されている
  while ! mkdir "${TASKS_JSON}.lock.d" 2>/dev/null; do
    sleep 0.5
  done
}
```

## 理由

**LLM自己評価の信頼性問題**:
- LLMはタスクが完了していないにもかかわらず「完了した」と誤判断することがある
- LLMにjqコマンドを正しく実行させることへの依存（ツール使用の不確実性）
- 外部bashが判定することで「完了の定義を機械的に検証可能な条件」として扱える

**排他制御の選択（mkdirアトミック操作）**:
- `flock`（ファイルロック）はLinuxとmacOSで挙動が異なる場合がある
- POSIX規格で `mkdir(2)` システムコールのアトミック性が保証されている
- 複数のMemberが同時に `tasks.json` を更新しようとしても、必ず1つだけが成功する

**macOS互換性（sedの使用）**:
- `grep -oP`（Perl互換正規表現）はGNU grep拡張であり、macOSのBSD grepでは動作しない
- `sed -n 's/.*<DONE>\(.*\)<\/DONE>.*/\1/p'` はPOSIX準拠でmacOS互換

**コンテキスト記憶**:
- 各イテレーションの出力を `context-{member}.txt` に蓄積し、次回のプロンプトに注入
- 「前回何をやったか」を引き継ぐことで、同じ失敗を繰り返すリスクを低減

## 結果

- `tasks.json` の更新はbashスクリプトが管理し、LLMは出力テキストのみに責任を持つ
- サーキットブレーカー（MAX_ITER=15）で無限ループを防止
- `context-{member}.txt` はイテレーション数に比例して肥大化する（既知の制限）
- `<DONE>` タグは1行で出力することをpromptで強制（sedの抽出を確実にするため）
