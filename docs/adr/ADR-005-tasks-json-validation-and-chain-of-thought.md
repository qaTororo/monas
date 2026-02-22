# ADR-005: tasks.json検証のモジュール化とChain of Thoughtによるフォーマット崩れ防止

- **日付**: 2026-02-22
- **ステータス**: Accepted

## コンテキスト

Issue #2: LeaderがPhase 1（タスク設計）でLLMの出力テキスト全体を `tasks.json` に書き込んでしまい、無効なJSONになる問題が発覚した。

**症状**:
```
コードベースの調査が完了しました。タスク設計を行います。

```json
{
  "task-name": { ... }
}
```
```

LLMがJSONをMarkdownコードブロック（` ```json ` ）で囲み、かつブロック外に説明テキストを付加して返した場合、`jq -r '.result'` で取り出した文字列が無効なJSONとなる。`monas status` 実行時に `ERROR: tasks.json is not valid JSON` が表示されPhase 2に進めない。

**既存の問題**:
- `jq -e . tasks.json` による構文チェックのみで、スキーマの正当性（必須フィールド・キー形式）を検証していなかった
- 同じバリデーションロジックが `run-leader.sh` と `bin/monas` に分散しており（DRY原則違反）、将来のリトライ処理導入時に保守性が低下する

## 決定

**二層防御アプローチ**を採用する。

### A. プロンプトエンジニアリング層: `_thought` フィールドによるChain of Thought

`prompts/leader-plan.md` の出力スキーマに `_thought` フィールドをJSONの先頭に追加する。

```json
{
  "_thought": "タスク設計の意図：なぜこの分割にしたか、並列実行可能な理由、依存関係の考慮など",
  "task-name": {
    "objective": "...",
    "definition_of_done": ["..."],
    "allowed_tools": ["Read", "Edit"]
  }
}
```

LLMに `{` を先に書かせることで、出力の最初からJSONフォーマットに縛る。説明テキストをJSONブロックの「外側」に置く代わりに `_thought` フィールドとして「内側」に収めることで、フォーマット崩れをプロンプトエンジニアリングのレイヤーで予防する。

### B. 検証コード層: `json_helpers.sh` の新設

副作用のない純粋な検証関数を `scripts/json_helpers.sh` として切り出し、各スクリプトから `source` して再利用する。

```bash
# 構文チェック
verify_json_syntax(file)  # returns: 0=valid, 1=invalid + error message on stdout

# スキーマ検証（_thoughtフィールドを除く各タスクの必須フィールド・キー形式を確認）
verify_tasks_schema(file) # returns: 0=valid, 1=invalid + error message on stdout
```

**設計上の制約（YAGNI原則の適用）**:
- 関数はファイル書き込み・`exit` 呼び出しを行わない（副作用なし）
- 終了ステータス（0/1）とエラーメッセージ（stdout）のみを返す
- LLMへのエラーフィードバックと自動リトライ（自己修復ループ）は現段階では含めない

### C. `_thought` フィールドを考慮したコード修正

`_thought` を導入したことで、既存コードの2箇所を修正する：

```bash
# run-leader.sh: Memberを起動するキー列挙から_thoughtを除外
jq -r '[keys[] | select(. != "_thought")] | .[]' tasks.json

# bin/monas: 全タスク完了判定から_thoughtを除外
jq '[to_entries[] | select(.key != "_thought") | .value.status] | all(. == "done" or . == "error")' tasks.json
```

## 理由

**なぜリトライ処理を含めないか（YAGNI）**:
- Bashにおける関数の副作用管理は複雑（グローバル変数汚染、`set -e` との競合）
- 純粋な検証関数として実装することで、`bin/monas` と `run-leader.sh` の両方から安全に `source` して再利用できる
- リトライ処理は将来の独立した実装項目として `future-work.md` に記録済み

**なぜMarkdownコードブロック抽出（sedによる回復処理）を含めないか**:
- `_thought` フィールドによるプロンプトエンジニアリングで根本原因に対処する
- 回復処理（フォールバック）は「フォーマット崩れを許容する」という暗黙の合意を生み出し、プロンプト品質の劣化を招く
- 将来リトライ処理を実装する際の責務の明確化のため、今は「検出して即終了」を維持する

**なぜYAMLへの移行ではないか**:
- ADR-002の依存ツール最小化方針（`claude`, `jq`, `sed`, `awk`のみ）を維持する
- `yq` 等の追加依存を避けることで環境構築の障壁と障害点（SPOF）を増やさない
- JSONの厳格な構造はスキーマ検証において優れており、LLMの微妙なフォーマット崩れを確実に検知できる

## 結果

- **Phase 1失敗の早期検出**: 構文エラーに加えスキーマ違反（キー形式・必須フィールド欠落）も検出可能になった
- **DRY化**: `jq -e . file` によるバリデーションが `json_helpers.sh` に集約され、将来のリトライ処理実装時の改修箇所が1箇所になった
- **既知の制限**: `_thought` フィールドはプロンプトへの追加制約であり、LLMが指示を無視する場合は根本的な解決にならない。その場合のフォールバックはリトライ処理（未実装）に委ねる
- **`_thought` の波及**: `tasks.json` を参照する全コード（Phase 2のMember起動・`monas status` の完了判定）で `_thought` キーを除外する処理が必要になった
