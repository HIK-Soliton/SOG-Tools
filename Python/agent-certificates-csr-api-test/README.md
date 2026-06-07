# CSR署名APIテストツール

エージェント用API－証明書発行(CSR署名)をテストするためのPythonスクリプトです。

## 機能

- CSRファイル（PKCS#10形式）を使用してサーバー証明書またはクライアント証明書を発行
- PEM/DER形式での証明書出力
- 証明書有効期限の指定
- コマンドラインまたは環境変数による設定

## 必要な環境

- Python 3.7以上
- 必要なライブラリ:
  - requests
  - python-dotenv

## セットアップ

### 1. ライブラリのインストール

```bash
pip install requests python-dotenv
```

### 2. 環境変数の設定

`.env.example`をコピーして`.env`ファイルを作成し、必要な情報を設定します。

```bash
cp .env.example .env
```

`.env`ファイルを編集:

```bash
API_BASE_URL=https://your-server.example.com
API_USERNAME=admin
API_PASSWORD=your-password
```

**注意**: `.env`ファイルには認証情報が含まれるため、Gitにコミットしないでください。

## 使用方法

### 基本的な使い方

```bash
# サーバー証明書（PEM形式）を発行
python test_csr_sign_api.py -c server.csr -t server -f pem -o server.crt

# クライアント証明書（DER形式）を発行
python test_csr_sign_api.py -c client.csr -t client -f der -o client.crt
```

### オプション

```
-c, --csr CSR_FILE          CSRファイルのパス（必須）
-t, --type {server,client}  証明書タイプ（デフォルト: server）
-f, --format {pem,der}      出力形式（デフォルト: pem）
-e, --encoding {PEM,DER}    CSRファイルのエンコード方式（省略可）
-v, --valid-days DAYS       証明書の有効期限（日数）
                            - サーバー証明書: 1-825（デフォルト: 365）
                            - クライアント証明書: 1-3650（デフォルト: 1825）
-o, --output OUTPUT_FILE    出力ファイルパス（必須）
-u, --url URL               APIベースURL（環境変数で設定可）
--username USERNAME         ユーザー名（環境変数で設定可）
--password PASSWORD         パスワード（環境変数で設定可）
```

### 使用例

#### 例1: サーバー証明書（PEM形式、デフォルト有効期限）

```bash
python test_csr_sign_api.py \
  -c server.csr \
  -t server \
  -f pem \
  -o server.pem
```

#### 例2: クライアント証明書（DER形式、有効期限1825日）

```bash
python test_csr_sign_api.py \
  -c client.csr \
  -t client \
  -f der \
  -v 1825 \
  -o client.der
```

#### 例3: 環境変数を使わずにコマンドラインで全て指定

```bash
python test_csr_sign_api.py \
  -c server.csr \
  -o server.crt \
  -u https://idm.example.com \
  --username admin \
  --password mypassword
```

## CSRファイルの作成方法

### OpenSSLを使用してCSRを作成する例

#### サーバー証明書用CSR

```bash
# 秘密鍵の生成
openssl genrsa -out server.key 2048

# CSRの生成
openssl req -new -key server.key -out server.csr \
  -subj "/C=JP/ST=Tokyo/L=Chiyoda/O=Example Corp/CN=server.example.com"
```

#### クライアント証明書用CSR

```bash
# 秘密鍵の生成
openssl genrsa -out client.key 2048

# CSRの生成
openssl req -new -key client.key -out client.csr \
  -subj "/C=JP/ST=Tokyo/L=Chiyoda/O=Example Corp/CN=client001"
```

## APIエンドポイント

### サーバー証明書

- `/icon/services/seap/onpre/agent/certificates/csr/server/sign` （デフォルト形式）
- `/icon/services/seap/onpre/agent/certificates/csr/server/sign.pem` （PEM形式）
- `/icon/services/seap/onpre/agent/certificates/csr/server/sign.der` （DER形式）

### クライアント証明書

- `/icon/services/seap/onpre/agent/certificates/csr/client/sign` （デフォルト形式）
- `/icon/services/seap/onpre/agent/certificates/csr/client/sign.pem` （PEM形式）
- `/icon/services/seap/onpre/agent/certificates/csr/client/sign.der` （DER形式）

## エラーコード

| エラーコード | 説明 |
|------------|------|
| SP-722-E-043001 | CSRファイル不正 |
| SP-722-E-043002 | 署名時エラー |

## トラブルシューティング

### SSL証明書エラー

テスト環境で自己署名証明書を使用している場合、SSL証明書の検証エラーが発生することがあります。
このスクリプトではテスト目的で証明書検証を無効化していますが、本番環境では適切な証明書を使用してください。

### 認証エラー

API呼び出しには**サイト管理者権限**が必要です。ユーザー名とパスワードが正しいか確認してください。

### ファイルが見つからないエラー

CSRファイルのパスが正しいか確認してください。相対パスまたは絶対パスで指定できます。

## ライセンス

このツールは社内用テストツールです。

## 参考

- エージェント用API－証明書発行(CSR署名) - ID Manager - IDM Team Redmine
