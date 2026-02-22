# ADR-006: Owner への進捗可視性は monas status のリッチ化で対応する

- **日付**: 2026-02-23
- **ステータス**: Accepted

## コンテキスト

Leader をステートレス化（ADR-002）した結果、Member の実行状態を Owner が把握する手段が `monas status` の手動実行のみになった。Owner もユーザーも「進捗どう？」と能動的に確認しなければ完了を知る方法がなく、UX 上の課題となっている。

また、現在の `monas status` は `tasks.json` の `status` フィールド（`in_progress` / `done` / `error`）を表示するだけであり、**止まっているのか動いているのか**が区別できない。

## 決定

`monas status` の出力をリッチ化する。具体的には以下の情報を追加表示する。

- 最終更新からの経過時間（Member ログのタイムスタンプ差分）
- 現在のイテレーション数（ログから抽出）
- 最後に実行したアクション（ログ末尾）

```
=== Run: 20260223-020605 ===

[⚡ implementation]  in_progress  iter 3/15
  Last activity: 42 sec ago
  → "Read scripts/member-loop.sh"

[✓ docs-update]  done
  → "「実装済み」ブロックを追記完了"

[⚠ stuck-task]  stuck
  → "Stuck detected: identical output at iter 7"
```

プッシュ型の自動通知は導入しない。

## 理由

**プッシュ型通知を採用しなかった理由：**

以下の案を検討したが、いずれもアーキテクチャ上の矛盾または実用上の限界があり棄却した。

| 案 | 棄却理由 |
|---|---|
| A. 監視デーモン常駐 | 常駐プロセスのSIGKILLリスクは Leader ステートレス化の動機と同型。ADR-002 の設計思想と矛盾する |
| B. Leader に wait を戻す | SIGKILLで孤児プロセスが発生する問題が再発。ADR-002 で解決済みの問題に逆戻り |
| C. monas watch コマンド | Owner（Claude Code）がフォアグラウンドでビジー状態になり、ユーザーとの会話が不可能になる |
| D. IPC（Unix domain socket 等） | Claude Code はリアクティブなモデルであり外部プロセスから割り込まれるリスナーインターフェースを持たない。「誰かがlistenしていなければならない」問題からデーモンと同じ問題が残る |
| E. PS1 プロンプト表示 | Enter を押して更新が必要なため、手動で `monas status` を叩くのと体験上大差ない |

**monas status リッチ化を選んだ理由：**

- 「止まっているのか動いているのか」という最大の不確実性を経過時間表示で解消できる
- 常駐プロセス不要。ステートレス設計を維持できる
- `tasks.json` とメンバーログの `tail` + タイムスタンプ差分計算のみで実装できる。追加の依存なし

## 結果

- `monas status` を叩けば実行状態の詳細が把握できるようになる
- **既知の制限**: 完了の自動通知はない。ユーザーは能動的に `monas status` を確認する必要がある
- 常駐プロセスが増えないため、障害の局所性（KILL されても状態は `tasks.json` に残る）が維持される
