# monas

**M**odern **O**rchestration of **N**ode-based **A**gent **S**ystem

Claude エージェント3段構造（Owner / Leader / Member）をローカルCLI環境で実現するオーケストレーションツール。

## 概要

従来のtmuxペイン分割方式が引き起こすキーバインド衝突を解決するため、Owner以外をヘッドレス（`claude -p`）で実行し、全通信をファイルシステム経由で行います。

| 役割 | 動作方式 | 責務 |
|---|---|---|
| **Owner** | UIつきの通常Claude（インタラクティブ） | ユーザーとの唯一の窓口 |
| **Leader** | `claude -p` バックグラウンド実行 | tasks.json生成 → Members並列起動 → 完了サマリー出力 |
| **Member** | `claude -p` Ralph Loop実行 | タスク実行・`<DONE>`出力で完了通知 |

## インストール

```bash
# 1. Clone
git clone https://github.com/qaTororo/monas ~/tools/monas
chmod +x ~/tools/monas/bin/monas ~/tools/monas/scripts/*.sh

# 2. PATH追加（~/.bashrc または ~/.zshrc）
echo 'export PATH="$PATH:$HOME/tools/monas/bin"' >> ~/.zshrc
source ~/.zshrc

# 3. 依存ツールの確認（標準UNIXツールのみ）
which claude jq sed awk  # これだけあればOK

# 4. 動作確認
monas
```

## 使い方

### 基本フロー

ユーザーは **Owner**（インタラクティブなClaude）に指示を出すだけで、LeaderとMemberが自律的に動きます。

```bash
# 1. 作業プロジェクトのルートでOwnerを起動
cd ~/my-project
claude  # Ownerセッション開始
```

```
[ユーザー]  「ログイン機能を実装して。フロントとバックを並列で」

[Owner]     要件を分析してLeaderを起動します...
              Bashツールで実行 →
              monas leader -- "ログイン機能の実装。..." > /dev/null 2>&1 &

[Leader]    tasks.json生成 → member-frontend & member-backend 並列起動

[Member×2]  Ralph Loop で実装 → <DONE> → tasks.json 更新 → 完了

[ユーザー]  「進捗どう？」

[Owner]     monas status を確認して報告...
```

### 進捗確認コマンド

```bash
# 最新ランの状態確認（tasks.jsonをjqで整形表示）
monas status

# Leaderのログをリアルタイムで確認
monas logs

# 特定Memberのログを確認
monas logs frontend
```

### Ownerなしで直接起動する場合

デバッグや簡易実行では直接呼び出しも可能です：

```bash
monas leader -- "README.mdに今日の日付を追記して"
```

## ワークスペース構成

実行すると作業プロジェクト内に以下が生成されます：

```
~/my-project/
└── .monas/
    ├── latest -> 20240222-143022/   # 最新ランへのシンボリックリンク
    └── 20240222-143022/
        ├── tasks.json               # タスク定義・進捗
        ├── context-frontend.txt     # Member毎のイテレーション記憶
        ├── context-backend.txt
        └── logs/
            ├── leader.log
            ├── member-frontend.log
            └── member-backend.log
```

> **注意**: 作業プロジェクトの `.gitignore` に `.monas/` を追加してください。

## tasks.json スキーマ

```json
{
  "frontend": {
    "objective": "ログインボタンのコンポーネントを修正する",
    "definition_of_done": [
      "Button.tsxのonClickハンドラが正しくバインドされていること",
      "npm run lintでエラーが出ないこと"
    ],
    "allowed_tools": ["Read", "Edit"],
    "status": "in_progress",
    "final_report": ""
  }
}
```

## アーキテクチャ

```
bin/monas                  # メインコントローラー（case文ルーティング）
scripts/
  run-leader.sh            # Leader全体フロー制御（3フェーズ）
  member-loop.sh           # Member Ralph Loop（コンテキスト記憶付き）
prompts/
  leader-plan.md           # Leader Phase1: tasks.json生成プロンプト
  leader-summary.md        # Leader Phase3: 完了サマリープロンプト
  member.md                # Member: Ralph Loopプロンプト
```

### Ralph Loop（Member動作）

```
for i in 1..MAX_ITER(15):
  claude -p（前回コンテキスト注入）→ 出力をcontext.txtに追記
  <DONE>検知 → mkdirスピンロック → tasks.json更新 → 完了
サーキットブレーカー → status:error → 終了
```

### 設計上のポイント

- **オーケストレーター**: 純粋なbash（YAGNI原則）
- **排他制御**: mkdirアトミック操作（POSIX準拠、macOS互換）
- **文字列抽出**: sed（macOS互換、grep -P不使用）
- **完了判定**: 外部bashが`<DONE>`を検知してtasks.jsonを更新（LLMに任せない）

## 既知の制限（v1）

- `context-{member}.txt` は全イテレーション分を蓄積するため、MAX_ITER=15の場合にLLMのコンテキストウィンドウを圧迫する可能性があります。v2でスライディングウィンドウを検討予定。
