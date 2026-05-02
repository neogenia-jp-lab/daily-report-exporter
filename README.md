# Mattermost Report Exporter

Mattermost から投稿を取得して Markdown ファイルとして保存する Ruby 3.3 スクリプト群です。

## スクリプト一覧

| ファイル | 対象チャンネル | 概要 |
|---|---|---|
| `export_daily_reports.rb` | times | ユーザーごとの業務日報を取得・保存 |
| `export_work-rule_refrections.rb` | チーム改善 (team) | `#ワークルールMTG` タグの投稿を取得・保存 |

詳細な仕様・コマンドラインオプション・環境変数は各 `.rb` ファイルの冒頭コメントを参照してください。

## 前提

- Ruby 3.3
- Mattermost パーソナルアクセストークン

## 環境変数（共通）

| 変数名 | 必須 | 既定値 |
|---|---|---|
| `MATTERMOST_TOKEN` | 必須 | — |
| `MATTERMOST_BASE_URL` | 任意 | `https://chat.neogenia.co.jp/` |
| `MATTERMOST_TEAM` | 任意 | `Neogenia` |
| `MATTERMOST_CHANNEL` | 任意 | スクリプトごとに異なる |

```sh
export MATTERMOST_TOKEN="your_token"
```

## 使い方

### 業務日報を取得する

```sh
ruby ./export_daily_reports.rb \
  --member lobin.z0x50 \
  --from 2026-04-01 \
  --to 2026-04-30 \
  --out ./times/ \
  -v
```

### ワークルールMTG 振り返り投稿を取得する

```sh
ruby ./export_work-rule_refrections.rb \
  --member lobin.z0x50 \
  --from 2025-01-01 \
  --to 2026-04-30 \
  --out ./work-rule-mtg/ \
  -v
```

`--member` を省略するとメンバーを絞り込まずに投稿を取得します。

## 保存形式

どちらのスクリプトも以下の形式でファイルを保存します。

```
{out_dir}/{username}/YYYY-MM-DD.md
```

既存ファイルはデフォルトでスキップされます。`-w` を指定すると上書きします。

## 日報パターンの調整

`export_daily_reports.rb` の抽出判定は `REPORT_PATTERNS` 定数を編集してください。

初期値:

- `/#+\s*(業務)?日報/`
- `/#+\s*感じたこと/`
- `/#+\s*所感/`

## AIに分析させる方法

### ダウンロード後に VSCode で開く

```sh
code .
```

### Copilot にプロンプトを投げる

**業務日報の分析例:**

```
times/lobin.z0x50/ ディレクトリには、
個人ごとの業務日報が日付ごとのファイル名で保存されています。
これを解析してください。
辛口で。傾向と課題を出してください。できていないことや苦手分野など。
```

**ワークルールMTG 振り返りの分析例:**

```
work-rule-mtg/lobin.z0x50/  ディレクトリには、
ワークルールMTG の振り返り投稿が日付ごとのファイルで保存されています。
傾向と課題を分析してください。
繰り返し挙がっている問題や、改善が進んでいないテーマを特定してください。
```
