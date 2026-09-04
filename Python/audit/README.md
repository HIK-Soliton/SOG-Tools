# Google Cloud IAM × SharePoint 権限一覧 突合棚卸手順書

本書は、Google Cloud からエクスポートした最新の IAM 権限データと、SharePoint の申請データ（CSV）を突合し、自動で監査・棚卸しレポート（Excel）を生成するための手順書です。

Python の安全な実行環境（仮想環境）の構築から、データの抽出、スクリプトの実行、レポートの確認方法までを網羅しています。

---

## 1. Google Cloud からのデータエクスポート

まず、作業を行う任意のフォルダ（例：`gcp_iam_audit`）をローカル PC に作成し、ターミナル（Windows の場合は PowerShell）を開いてそのフォルダに移動します。

移動後、以下の `gcloud` コマンドを実行して、プロジェクトの最新の IAM 権限一覧を CSV としてエクスポートします。

```bash
# プロジェクト名「idaas-dev」からメンバーごとにロールを1行ずつバラしたCSVを抽出
gcloud projects get-iam-policy idaas-dev \
    --flatten="bindings[].members" \
    --format="csv(bindings.members:label=member, bindings.role:label=role)" \
    > ~/Downloads/iam_list_detailed.csv

```powershell
# プロジェクト名「idaas-dev」からメンバーごとにロールを1行ずつバラしたCSVを抽出
gcloud projects get-iam-policy idaas-dev `
    --flatten="bindings[].members" `
    --format="csv(bindings.members:label=member, bindings.role:label=role)" `
    > ~/Downloads/iam_list_detailed.csv

💡 注意：コマンド実行前に `gcloud auth login` および `gcloud config set project idaas-dev` で対象プロジェクトへのアクセス権がある状態にしてください。

## 2. 対象ファイルの配置確認

`~/Downloads/` 内に、以下の **2つの CSV ファイル** が揃っていることを確認します。

- `iam_list_detailed.csv` （ステップ1 で抽出したファイル）
- `Sharepoint_GoogleCloud権限一覧.csv` （SharePoint からエクスポートしたアカウント一覧の CSV）

## 3. Python 仮想環境（venv）の構築とライブラリ導入
OS のシステム環境を汚さず、安全にスクリプトを実行するために、独立した仮想環境を構築します。

### 3.1 仮想環境の作成と有効化

作業フォルダ内で、OS に合わせて以下のコマンドを実行します。

**Mac / Linux の場合:**

```bash
# 仮想環境（フォルダ名: venv）を作成
python3 -m venv venv

# 仮想環境を有効化（アクティベート）
source venv/bin/activate
```

**Windows（PowerShell）の場合:**

```powershell
# 仮想環境（フォルダ名: venv）を作成
python -m venv venv

# 仮想環境を有効化（アクティベート）
.\venv\Scripts\Activate.ps1
```

💡 確認ポイント：有効化に成功すると、ターミナルの左端に `(venv)` と表示されます。

### 3.2 必要ライブラリのインストール

有効化された状態で、データ処理と Excel 装飾に必要なパッケージをインストールします。

```bash
pip install pandas openpyxl
```

(※仮想環境内であるため、externally-managed-environment のエラーは発生しません)

## 4. 突合スクリプトの確認

`~/Downloads/` 内のデータを読み込む `audit.py` が存在することを確認します。このスクリプトは以下の処理を自動で実行します：

- Google Cloud IAM データと SharePoint 申請データの読み込み（`~/Downloads/` から）
- アカウント種別の識別（user / serviceAccount / group / deleted）
- メールアドレスの正規化と突合処理
- 監査判定ロジックの適用
- Excel レポート（2シート構成）の生成

## 5. スクリプトの実行

仮想環境が有効化された状態で（ターミナルに `(venv)` と表示されている）、以下のコマンドでスクリプトを実行します。

```bash
python audit.py
```

💡 実行に成功すると、以下のメッセージが表示されます：

```
突合完了！「~/Downloads/GoogleCloud_SharePoint_突合棚卸結果.xlsx」を出力しました。
```

`~/Downloads/` 内に `GoogleCloud_SharePoint_突合棚卸結果.xlsx` ファイルが生成されます。

## 6. レポート（Excel）の見方と対応方針

出力されたExcelには2つのタブが含まれています。

タブ①: 「棚卸サマリー」
全体のサマリーと対応の緊急度が自動で集計されています。

🟥 要確認 (SharePointに申請がないアカウント)
👉 最優先対応。Google Cloud 上に存在するが、SharePoint に正式な申請履歴が確認できない人間のアカウント（user:）です。不正アクセスのリスクがあるため、利用者に確認のうえ、不要な場合は IAM から削除します。

🟥 要削除 (削除済みアカウントの残骸)
👉 過去に Google アカウント自体は消されたが、Google Cloud 側の IAM 設定にゴミ（deleted:serviceAccount:...）として残っているものです。セキュリティ上のリスクはありませんが、ポリシー清掃のため削除してください。

🟨 要レビュー (特権保有者)
👉 roles/owner（オーナー）や roles/editor（編集者）などの強い権限を持っているアカウントです。開発環境であっても必要性を再評価し、最小権限ロールへの格下げを検討します。

🟩 問題なし / 対象外
👉 正式な承認が得られているアカウント、およびシステム動作用のアカウント（サービスアカウント、Googleグループ）です。通常の人事棚卸からはスキップして問題ありません。

タブ②: 「突合詳細データ」
すべてのアクセス権定義が1行ずつ並んでおり、上記サマリーで引っかかったレコードが色別（赤・黄・緑）にハイライトされています。オートフィルターが設定されているため、「赤（要確認）」だけを絞り込んでリスト化することが可能です。

## 7. 後片付け（仮想環境の解除）
棚卸作業がすべて完了し、仮想環境を閉じたい場合は以下のコマンドを実行します。

```bash
deactivate
```

---

以上で、Google Cloud IAM × SharePoint 権限一覧の突合棚卸作業は完了です。
💡 ターミナル左端の (venv) の表示が消え、元のOS環境に戻ります。作成した venv フォルダはそのまま残しておけば、次回以降は source venv/bin/activate を実行するだけで、いつでも突合処理を再開できます。