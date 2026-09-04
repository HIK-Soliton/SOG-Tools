# OneGate API Suite リグレッションテストツール

バージョンアップ前後でAPI動作を確認し、デグレ（機能差異）を検出するPythonスクリプトです。
Windows、Mac、Linux で動作します。

## 特徴

- ✅ クロスプラットフォーム対応（Windows/Mac/Linux）
- ✅ バージョンアップ前後の差異検出
- ✅ 詳細なテスト結果レポート
- ✅ パフォーマンス変化の検出
- ✅ 見やすいカラー出力

## 必要な環境

- Python 3.7 以上
- pip

## インストール

```bash
# 依存パッケージのインストール
pip install -r requirements.txt
```

## 使用方法

### 1. ベースライン取得（バージョンアップ前）

バージョンアップ前に実行して、現在の動作をベースラインとして保存します。

```bash
python api_regression_test.py \
  --api-key YOUR_API_KEY \
  --tenant YOUR_TENANT \
  --password YOUR_PASSWORD \
  --save-baseline
```

### 2. リグレッションテスト（バージョンアップ後）

バージョンアップ後に実行して、ベースラインと比較します。

```bash
python api_regression_test.py \
  --api-key YOUR_API_KEY \
  --tenant YOUR_TENANT \
  --password YOUR_PASSWORD \
  --compare
```

### 3. 通常実行（比較なし）

単純にAPIテストのみを実行する場合：

```bash
python api_regression_test.py \
  --api-key YOUR_API_KEY \
  --tenant YOUR_TENANT \
  --password YOUR_PASSWORD
```

## オプション

- `--api-key`: APIキー（必須）
- `--tenant`: テナント名（必須）
- `--password`: テスト用パスワード（必須）
- `--save-baseline`: ベースラインとして保存
- `--compare`: ベースラインと比較
- `--baseline-file`: ベースラインファイルを指定（デフォルト: results/baseline.json）

## テスト対象API

### 利用者管理
- 利用者登録
- 利用者検索
- 利用者情報取得
- 利用者更新
- 利用者削除

### 利用者インポート・エクスポート
- 利用者
- アプリケーションロール
- Webアプリ
- ICカード割り当て

### PasswordManager
- Webアプリ設定
- Webアプリユーザー設定
- Windowsアプリ設定
- Windowsアプリユーザー設定
- モバイルアプリ設定
- モバイルアプリユーザー設定
- Windowsサインイン設定

## 検出される差異

### ステータス変更
- 成功→失敗、または失敗→成功のテスト結果変更を検出

### レスポンス変更
- APIレスポンスのステータスコード変更を検出

### パフォーマンス変化
- 実行時間が20%以上変化したテストを検出

### テストの追加・削除
- 新規追加されたテスト
- 削除されたテスト

## 出力ファイル

### results/baseline.json
`--save-baseline` オプション使用時に作成されるベースラインファイル

### results/api_test_results_YYYYMMDD_HHMMSS.json
各テスト実行時に作成される結果ファイル

## ファイル構成

```
API-Suite/
├── api_regression_test.py  # メインスクリプト
├── requirements.txt         # 依存パッケージ
├── README.md               # このファイル
├── data/                   # テストデータ
│   ├── OneGateUser_add.json
│   ├── OneGateUser_mod.json
│   ├── OneGateUser.csv
│   ├── OneGateUserCloudServiceRole.csv
│   ├── OneGateUserWebSsoRole.csv
│   ├── OneGateUserIcCard.csv
│   ├── websso.csv
│   ├── userwebsso.csv
│   ├── winappsso.csv
│   ├── userwinappsso.csv
│   ├── mobileappsso.csv
│   ├── usermobileappsso.csv
│   └── windowsSignin.csv
└── results/                # 結果出力ディレクトリ
    └── baseline.json       # ベースラインファイル
```

## トラブルシューティング

### CSVファイルが見つかりません

`data/` ディレクトリに必要なCSVファイルとJSONファイルを配置してください。
PowerShellスクリプト版と同じデータディレクトリを使用できます。

### ベースラインファイルが見つかりません

`--compare` オプション使用前に、`--save-baseline` でベースラインを作成してください。

### 文字化けする（Windows）

PowerShellで実行する場合、文字エンコーディングを確認してください：
```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
```

## 開発者向け

### テストケースの追加

`OneGateAPITester` クラスに新しいテストメソッドを追加し、
`run_all_tests()` メソッドで呼び出してください。

```python
def test_new_feature(self) -> bool:
    """新機能テスト"""
    self._print_header("新機能テスト")
    
    # テストロジック
    
    return True
```

### カスタム比較ロジック

`RegressionComparator.compare()` メソッドをカスタマイズすることで、
独自の差異検出ロジックを追加できます。

## ライセンス

社内利用のみ

## 変更履歴

### 2026-08-06
- 初版リリース
- PowerShellスクリプトからPythonへ移植
- リグレッションテスト機能追加
- クロスプラットフォーム対応
