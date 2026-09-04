# クイックスタートガイド

## セットアップ（初回のみ）

### Windows

```powershell
# ディレクトリに移動
cd c:\Users\hiki.FOURSEASONS\src\SOG\Python\API-TEST\API-Suite

# 依存パッケージをインストール
pip install -r requirements.txt
```

### Mac/Linux

```bash
# ディレクトリに移動
cd /path/to/SOG/Python/API-TEST/API-Suite

# 依存パッケージをインストール
pip3 install -r requirements.txt

# 実行スクリプトに権限付与
chmod +x run_test.sh
```

## 典型的な使用フロー

### 1. バージョンアップ前にベースライン取得

**Windows:**
```powershell
.\run_test.ps1 -ApiKey "your-api-key" -Tenant "your-tenant" -Password "your-password" -Mode baseline
```

**Mac/Linux:**
```bash
./run_test.sh your-api-key your-tenant your-password baseline
```

### 2. バージョンアップ実施

（システムのバージョンアップを実施）

### 3. バージョンアップ後にリグレッションテスト

**Windows:**
```powershell
.\run_test.ps1 -ApiKey "your-api-key" -Tenant "your-tenant" -Password "your-password" -Mode compare
```

**Mac/Linux:**
```bash
./run_test.sh your-api-key your-tenant your-password compare
```

### 4. 結果確認

結果は `results/` ディレクトリに保存されます：
- `baseline.json`: ベースライン（バージョンアップ前の状態）
- `api_test_results_YYYYMMDD_HHMMSS.json`: 各実行の結果

デグレが検出された場合、画面に詳細が表示されます：
- ❌ ステータス変更（成功→失敗など）
- ⚠️  レスポンス変更
- ℹ️  パフォーマンス変化（20%以上）

## 直接Pythonスクリプトを実行する場合

```bash
# ベースライン保存
python api_regression_test.py --api-key YOUR_KEY --tenant YOUR_TENANT --password YOUR_PASS --save-baseline

# リグレッションテスト
python api_regression_test.py --api-key YOUR_KEY --tenant YOUR_TENANT --password YOUR_PASS --compare

# 通常実行（比較なし）
python api_regression_test.py --api-key YOUR_KEY --tenant YOUR_TENANT --password YOUR_PASS
```

## トラブルシューティング

### Q: "CSVファイルが見つかりません"と表示される

A: `data/` ディレクトリに必要なCSVファイルとJSONファイルを配置してください。
   元のPowerShellスクリプト版と同じdataディレクトリを使用できます。

### Q: "ベースラインファイルが見つかりません"と表示される

A: `--compare` を使う前に、`--save-baseline` でベースラインを作成してください。

### Q: 文字化けする（Windows）

A: PowerShellで以下を実行してください：
```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
python api_regression_test.py ...
```

### Q: Macで"Permission denied"エラーが出る

A: 実行権限を付与してください：
```bash
chmod +x run_test.sh
```

## テストデータの準備

以下のファイルが `data/` ディレクトリに必要です：

### JSON形式
- `OneGateUser_add.json` - 利用者追加用
- `OneGateUser_mod.json` - 利用者更新用

### CSV形式
- `OneGateUser.csv`
- `OneGateUserCloudServiceRole.csv`
- `OneGateUserWebSsoRole.csv`
- `OneGateUserIcCard.csv`
- `websso.csv`
- `userwebsso.csv`
- `winappsso.csv`
- `userwinappsso.csv`
- `mobileappsso.csv`
- `usermobileappsso.csv`
- `windowsSignin.csv`

これらのファイルは既存のPowerShellスクリプト版のものをそのまま使用できます。

## 継続的な使用

定期的なテストには以下のようなスケジュールを推奨：

1. **週次**: 通常テストを実行して動作確認
2. **バージョンアップ前**: 必ずベースライン取得
3. **バージョンアップ後**: リグレッションテスト実行
4. **月次**: ベースラインの更新（大きな変更がない場合）

## サポート

問題が発生した場合は、以下の情報と共に報告してください：
- エラーメッセージの全文
- 使用したコマンド
- Python バージョン (`python --version`)
- OS とバージョン
- `results/` ディレクトリの最新結果ファイル
