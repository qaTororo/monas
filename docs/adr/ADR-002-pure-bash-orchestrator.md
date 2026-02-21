# ADR-002: オーケストレーターとして純粋なbashを採用（go-task排除）

- **日付**: 2026-02-22
- **ステータス**: Accepted

## コンテキスト

設計初期段階では、`Task (go-task)` をオーケストレーターとして採用する案があった（仕様書に明記）。go-taskはYAMLでタスク定義でき、`deps` による並列実行、`--` による引数渡しなど、オーケストレーションに便利な機能を持つ。

## 決定

go-taskを排除し、`bin/monas` を純粋なbashスクリプトによるコントローラーとして実装する。プロセス管理はUNIXの `&`（バックグラウンド実行）と `wait`（完了待機）で完結させる。

```bash
# 並列起動
bash member-loop.sh frontend &
bash member-loop.sh backend &

# 全完了を待機
wait $pid1; wait $pid2
```

## 理由

**YAGNI原則（You Aren't Gonna Need It）**:
- プロセス管理（並列実行・待機）はUNIXカーネルが提供する基本機能で完結する
- go-taskが提供する追加機能（YAML定義、タスク依存グラフ等）は、このユースケースでは不要

**UNIX哲学への準拠**:
- ツールチェーンを減らすことは障害点（SPOF）を減らすことに直結する
- 追加の依存（go-taskのインストール）をなくすことで、「`claude jq sed awk` だけあればOK」というシンプルな依存関係を実現

**カスタマイズの自由度**:
- 純粋なbashスクリプトは誰でも理解・改変できる
- go-taskのDSLを学習する必要がない

## 結果

- 依存ツール: `claude`, `jq`, `sed`, `awk`（全て標準UNIX環境に近い）
- `bin/monas` は `case` 文によるシンプルなルーティングスクリプト
- `scripts/run-leader.sh` がLeader全体フロー（3フェーズ）を制御
- `scripts/member-loop.sh` がMemberのRalph Loopを制御
