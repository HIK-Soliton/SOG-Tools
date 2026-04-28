# SCEP証明書発行テストスクリプト

SCEP (Simple Certificate Enrollment Protocol) を使用してクライアント証明書を大量に発行するためのPythonスクリプトです。マルチスレッド並列実行に対応し、負荷テストや証明書の一括発行に利用できます。

## 特徴

- ✅ **OpenSSL + sscep**: challengePassword付きCSRを生成し、標準的なSCEPフローで証明書を取得
- ⚡ **並列実行**: マルチスレッドによる高速な証明書一括発行
- 📝 **詳細ログ**: エラー追跡が容易なログファイル出力機能
- 🔒 **AES256/SHA256**: 強力な暗号化・署名アルゴリズム
- 🧪 **負荷テスト**: ファイル出力なしモードで高速な動作確認

## 必要な環境

### システム要件
- **OS**: WSL (Windows Subsystem for Linux) / Ubuntu / Linux
- **Python**: 3.7以上
- **OpenSSL**: コマンドラインツール
- **sscep**: HTTP対応版

### Pythonライブラリ
```bash
pip install cryptography requests
```

## インストール

### 1. OpenSSLのインストール
```bash
sudo apt update
sudo apt install openssl
```

### 2. sscepのビルドとインストール
```bash
# 必要な開発ツールをインストール
sudo apt install build-essential libssl-dev git

# sscepをビルド
mkdir -p ~/tools && cd ~/tools
git clone https://github.com/certnanny/sscep.git
cd sscep
./bootstrap.sh
./configure
make
sudo make install

# インストール確認
sscep --version
```

### 3. Pythonライブラリのインストール
```bash
pip install cryptography requests
```

## 設定ファイル

スクリプトはJSON形式の設定ファイル（デフォルト: `ChromeOS_SKMSetting_json.txt`）を読み込みます。

### 設定ファイルの例
```json
{
  "server": {
    "Value": "scep.example.com"
  },
  "challenge": {
    "Value": "your-challenge-password"
  }
}
```

## 使用方法

### 基本的な使い方

```bash
# 単一の証明書を発行
python scep_enrollment_multi.py --email test@example.com

# カスタム設定ファイルを使用
python scep_enrollment_multi.py --email user@example.com --config custom_config.json
```

### 複数証明書の発行

```bash
# 10個の証明書を順次発行
python scep_enrollment_multi.py --email test@example.com --count 10

# 100個の証明書を4スレッドで並列発行
python scep_enrollment_multi.py --email test@example.com --count 100 --max-threads 4

# 1000個の証明書を8スレッドで並列発行（推奨）
python scep_enrollment_multi.py --email test@example.com --count 1000 --max-threads 8
```

### ログ出力

```bash
# ログファイルを指定
python scep_enrollment_multi.py --email test@example.com --count 100 --log-file test.log

# 並列実行 + ログファイル（推奨）
python scep_enrollment_multi.py --email test@example.com --count 100 --max-threads 4 --log-file test.log

# 詳細ログ（DEBUGレベル）
python scep_enrollment_multi.py --email test@example.com --count 10 --log-file debug.log --verbose
```

### 負荷テスト

```bash
# ファイル出力なしで動作確認
python scep_enrollment_multi.py --email test@example.com --count 100 --no-output

# 並列実行 + ファイル出力なし + ログ記録
python scep_enrollment_multi.py --email test@example.com --count 1000 --max-threads 8 --no-output --log-file load_test.log
```

## コマンドラインオプション

| オプション | 説明 | デフォルト |
|-----------|------|-----------|
| `--email` | 証明書のCN (Common Name) | `test@example.com` |
| `--config` | SCEP設定ファイル（JSON） | `ChromeOS_SKMSetting_json.txt` |
| `--output-dir` | 証明書と鍵の出力先ディレクトリ | `SCEP_Output` |
| `--key-size` | RSA鍵長（2048/3072/4096） | `2048` |
| `--count` | 証明書発行を繰り返す回数 | `1` |
| `--max-threads` | 並列実行する最大スレッド数 | `1` (順次実行) |
| `--log-file` | ログファイルのパス | なし |
| `--no-output` | ファイル出力を行わない | `False` |
| `-v`, `--verbose` | 詳細ログを表示 | `False` |

## 出力ファイル

証明書発行が成功すると、以下のファイルが生成されます：

```
SCEP_Output/
├── ca_cert_20260428_143000.pem          # CA証明書
├── private_key_20260428_143001.pem      # 秘密鍵
├── cert_request_20260428_143001.pem     # CSR
├── issued_cert_20260428_143001.pem      # 発行された証明書
├── private_key_20260428_143002.pem
├── cert_request_20260428_143002.pem
└── issued_cert_20260428_143002.pem
```

### ファイル名の形式
- `ca_cert_YYYYMMDD_HHMMSS.pem`: CA証明書（1回のみ取得）
- `private_key_YYYYMMDD_HHMMSS_microsec.pem`: 秘密鍵
- `cert_request_YYYYMMDD_HHMMSS_microsec.pem`: CSR（証明書署名要求）
- `issued_cert_YYYYMMDD_HHMMSS_microsec.pem`: 発行された証明書

## ログファイル

`--log-file` オプションを指定すると、詳細なログが記録されます。

### ログレベル
- **INFO**: 主要なイベント（証明書発行開始・完了など）
- **DEBUG**: 詳細な処理情報（`--verbose` 指定時）
- **ERROR**: エラー情報とスタックトレース

### ログの例
```
2026-04-28 10:30:15 [INFO] [Thread-12345] === SCEP証明書発行テスト開始 ===
2026-04-28 10:30:15 [INFO] [Thread-12345] 証明書発行回数: 100
2026-04-28 10:30:15 [INFO] [Thread-12345] 最大スレッド数: 4
2026-04-28 10:30:16 [INFO] [Thread-12345] CA証明書取得成功: Subject=CN=...
2026-04-28 10:30:17 [INFO] [Thread-12347] 証明書発行開始: [1/100] index=0
2026-04-28 10:30:18 [INFO] [Thread-12347] 証明書発行成功: [1/100] Serial=ABC123...
2026-04-28 10:30:19 [ERROR] [Thread-12348] 証明書発行失敗: [2/100] index=1
2026-04-28 10:30:19 [ERROR] [Thread-12348] エラー詳細: Connection timeout
2026-04-28 10:30:19 [ERROR] [Thread-12348] スタックトレース:
...
```

## パフォーマンス最適化

### スレッド数の推奨値
- **CPU性能**: コア数の1〜2倍
- **ネットワークI/O**: 4〜8スレッド
- **大量発行**: 8〜16スレッド

```bash
# CPU 4コアの場合: 4〜8スレッド
python scep_enrollment_multi.py --count 1000 --max-threads 8 --log-file test.log

# 高速なネットワーク環境: 16スレッド
python scep_enrollment_multi.py --count 10000 --max-threads 16 --no-output --log-file load_test.log
```

## トラブルシューティング

### sscepが見つからない
```bash
# sscepのインストール確認
which sscep
sscep --version

# 再インストール
cd ~/tools/sscep
sudo make install
```

### OpenSSLが見つからない
```bash
# OpenSSLのインストール確認
which openssl
openssl version

# インストール
sudo apt install openssl
```

### 証明書発行が失敗する
1. **ログファイルを確認**
   ```bash
   python scep_enrollment_multi.py --count 1 --log-file debug.log --verbose
   cat debug.log
   ```

2. **設定ファイルを確認**
   - サーバーアドレスが正しいか
   - チャレンジパスワードが正しいか

3. **ネットワーク接続を確認**
   ```bash
   ping scep.example.com
   curl -I http://scep.example.com/scep/static
   ```

### HTTPSエラー
⚠️ **注意**: sscepはHTTPのみ対応しています。HTTPSを使用する場合は、別のSCEPクライアントを検討してください。

## 注意事項

- 🚫 **sscepはHTTPSに非対応**: HTTPのみで動作します
- 🔐 **challengePassword**: OpenSSL + sscepの組み合わせで自動的に含まれます
- 💾 **ファイル出力なしモード**: `--no-output` 使用時は一時ディレクトリに保存され、実行後に削除されます
- 🧵 **スレッド数**: サーバー負荷を考慮して適切な値を設定してください
- 📊 **大量発行**: 1000件以上の発行時は `--log-file` の使用を推奨します

## 実行例

### 例1: 開発環境での動作確認
```bash
python scep_enrollment_multi.py --email dev@example.com --count 5 --verbose
```

### 例2: 本番環境での証明書発行（100件）
```bash
python scep_enrollment_multi.py \
  --email prod@example.com \
  --config production_config.json \
  --count 100 \
  --max-threads 4 \
  --log-file production_$(date +%Y%m%d_%H%M%S).log
```

### 例3: 負荷テスト（1000件、ファイル出力なし）
```bash
python scep_enrollment_multi.py \
  --email loadtest@example.com \
  --count 1000 \
  --max-threads 8 \
  --no-output \
  --log-file loadtest_$(date +%Y%m%d_%H%M%S).log
```

### 例4: 大量発行（10000件）
```bash
python scep_enrollment_multi.py \
  --email bulk@example.com \
  --count 10000 \
  --max-threads 16 \
  --output-dir bulk_certificates \
  --log-file bulk_$(date +%Y%m%d_%H%M%S).log
```

## ライセンス

このスクリプトは内部使用を目的としています。

## 関連ドキュメント

- [SCEP Protocol Specification](https://datatracker.ietf.org/doc/html/rfc8894)
- [sscep GitHub Repository](https://github.com/certnanny/sscep)
- [OpenSSL Documentation](https://www.openssl.org/docs/)

## サポート

問題が発生した場合は、`--verbose` と `--log-file` オプションを使用して詳細ログを取得し、エラー内容を確認してください。
