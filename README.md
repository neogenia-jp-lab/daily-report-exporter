# Mattermost Daily Report Exporter

Mattermost の times チャンネルから、ユーザーごとの業務日報投稿を取得して Markdown ファイルとして保存する Ruby 3.3 スクリプトです。

## 仕様

- 対象チーム: Neogenia（デフォルト）
- 対象チャンネル: times（デフォルト）
- ユーザー指定: username
- 期間指定: from/to（JST, 両端含む）
- 日報判定: スレッド内投稿の本文が正規表現に一致
- 保存形式: output_root/username/YYYY-MM-DD.md
- 既存ファイル: デフォルトはスキップ、`-w` で上書き

## 前提

- Ruby 3.3
- Mattermost パーソナルアクセストークン

## 環境変数

- MATTERMOST_TOKEN: 必須
- MATTERMOST_BASE_URL: 任意（既定: https://chat.neogenia.co.jp/）
- MATTERMOST_TEAM: 任意（既定: Neogenia）
- MATTERMOST_CHANNEL: 任意（既定: times）

例:

export MATTERMOST_TOKEN="your_token"

## 使い方

```rb
ruby ./export_daily_reports.rb \
  --member lobin.z0x50 \
  --from 2026-04-01 \
  --to 2026-04-22 \
  --out ./times/ \
  -v
```

### コマンドラインオプション

- `--member` 取得対象の Mattermost ユーザ名
- `--from`   取得対象期間 FROM
- `--to`     取得対象期間 TO
- `--out`    出力先ディレクトリ
- `-v`       詳細ログ出力
- `-w`       既存ファイルを上書き:

## 抽出ルール調整

抽出判定は `./export_daily_reports.rb` の `REPORT_PATTERNS` を編集してください。

初期値:

- /#+\s*(業務)?日報/
- /#+\s*感じたこと/
- /#+\s*所感/

## 補足

- 日報が見つからない日はファイルを作成しません。
- 候補が複数ある場合、最後の投稿を保存します。
- スクリプトは Mattermost API で root 投稿を取得し、各スレッドを辿って日報投稿を判定します。

## AIに分析させる方法

### 日報をダウンロード

- `--member` で自分の Mattermost ユーザ名を指定
- `--from` `--to` で対象期間を指定

```rb
ruby ./export_daily_reports.rb \
  --member lobin.z0x50 \
  --from 2026-04-01 \
  --to 2026-04-22 \
  --out ./times/ \
  -v
```

### VSCode で開く

```sh
code .
```

### Copilot にプロンプトを投げる

プロンプト例:
```
times/lobin.z0x50/ ディレクトリには、
個人ごとの業務日報が日付ごとのファイル名で保存されています。
これを解析してください。
辛口で。傾向と課題を出してください。できていないことや苦手分野など。
```
