# monas

**M**odern **O**rchestration of **N**ode-based **A**gent **S**ystem

Claude エージェント3段構造（Owner / Leader / Member）をローカルCLI環境で実現するオーケストレーションツール。

## 概要

従来のtmuxペイン分割方式が引き起こすキーバインド衝突を解決するため、Owner以外をヘッドレス（`claude -p`）で実行し、全通信をファイルシステム経由で行います。

| 役割 | 動作方式 | 責務 |
|---|---|---|
| **Owner** | UIつきの通常Claude（インタラクティブ） | ユーザーとの唯一の窓口 |
| **Leader** | `claude -p` ステートレス実行 | tasks.json生成 → Members独立起動して即終了（サマリーは `monas status` で遅延生成） |
| **Member** | `claude -p` Ralph Loop実行 | タスク実行・`<DONE>`出力で完了通知 |

## 使用適性

monas は **3 階層（Owner / Leader / Member）が全て必要な場合**に初めて価値を発揮します。
2 階層で完結するユースケースでは、monas は余分なオーバーヘッドを生むだけです。

### 使うべきでないケース（非推奨）

**Claude Code の Task ツール（組み込みサブエージェント）で代替できる場合は monas を使わないでください。**

```
[あなた] ─── claude（インタラクティブ） ─── Task ツール ─── Sub-Agent
```

この 2 階層パターンで十分なケースに monas を使うと、以下のオーバーヘッドが発生するだけです。

| オーバーヘッド | 内容 |
|---|---|
| **Token 効率の低下** | Member は各イテレーションでシステムプロンプト・コンテキストファイルを毎回再注入する |
| **プロセスオーバーヘッド** | 別プロセス起動・`tasks.json` ファイル I/O・完了のポーリングが発生する |
| **サブエージェント制限** | monas の Member（`claude -p`）内部から Task ツールは使用不可（`CLAUDECODE` ガード）。Member はさらなるサブエージェントを生成できない |

> **目安**: タスクが 1〜3 件で、各タスクが 1 回の LLM 呼び出しで完結するなら Task ツールで十分です。

### 使うべきケース

| ケース | 理由 |
|---|---|
| **長期並列タスク** | 1 タスクが複数イテレーション（数分〜数十分）にわたり、Task ツールの同期待機では親セッションのコンテキストを圧迫する |
| **Member 間の完全分離** | 各 Member に異なる `allowed_tools` を与え、互いのコンテキストを見せたくない |
| **Leader の耐障害性** | ネットワーク断・プロセス kill でも Member が継続実行される必要がある |
| **CI/CD・ヘッドレス環境** | インタラクティブな Claude セッションが使えない環境での並列タスク実行 |

## インストール

```bash
# 1. Clone
git clone https://github.com/qaTororo/monas ~/tools/monas

# 2. PATH追加（~/.bashrc または ~/.zshrc）
echo 'export PATH="$PATH:$HOME/tools/monas/bin"' >> ~/.zshrc
source ~/.zshrc

# 3. 依存ツールの確認（標準UNIXツールのみ）
which claude jq sed awk  # これだけあればOK

# 4. 動作確認
monas
```

## 更新

```bash
git -C ~/tools/monas pull
```

## 使い方

### 基本フロー

ユーザーは **Owner**（インタラクティブなClaude）に指示を出すだけで、LeaderとMemberが自律的に動きます。

```bash
# 1. 作業プロジェクトのルートでOwnerを起動
cd ~/my-project
monas owner  # Owner として振る舞う Claude セッションを開始
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

# ストリーミング表示（デフォルト3秒間隔でポーリング）
monas stream

# 全Runのステータスを一覧表示
monas status --all

# 全Runをポーリング表示（interval秒間隔、デフォルト3秒）
monas stream --all [interval]
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
        ├── summary.txt              # 完了サマリー（monas status で自動生成・冪等）
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
  "_thought": "タスク設計の意図：なぜこの分割にしたか、並列実行可能な理由、依存関係の考慮など",
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
  run-leader.sh            # Leader全体フロー制御（Phase 1: tasks.json生成、Phase 2: Members独立起動して即終了）
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

## リーダーの耐障害性

Leader プロセスは **ステートレス** に設計されています。

- Member を `setsid`（macOS では `nohup + disown`）で **独立セッション** として起動
- Member 起動直後に Leader プロセス自身は終了（`wait` なし）
- Leader が途中で SIGKILL されても Member は継続実行される
- サマリー生成は `monas status` を叩いたタイミングで遅延実行（`summary.txt` に保存、冪等）
