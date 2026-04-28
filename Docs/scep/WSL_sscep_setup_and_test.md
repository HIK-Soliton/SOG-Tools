# WSLでのsscepインストールとSCEPテスト手順

## 📋 概要

このドキュメントでは、WSL（Windows Subsystem for Linux）環境でsscepをインストールし、SCEPプロトコルを使用した証明書取得テストを行う手順を説明します。

## ⚠️ 重要な注意事項

**sscepはHTTPSに対応していません:**
sscepは**HTTPプロトコルのみ**をサポートしています。HTTPSのURLを指定すると "illegal URL" エラーが発生します。

**重要なポイント:**
- ✅ 使用可能: `http://サーバー名/scep`
- ❌ 使用不可: `https://サーバー名/scep`
- SCEPサーバー側でHTTPアクセスを許可する必要があります
- HTTPSが必要な環境では、リバースプロキシ（nginx/Apache）でHTTPS→HTTP変換を行う

詳細は「8. トラブルシューティング」を参照してください。

## 🔧 前提条件

- Windows 10/11にWSL2がインストールされていること
- Ubuntu または Debian ディストリビューションがインストールされていること
- インターネット接続が利用可能であること

## 📦 1. WSL環境の準備

### WSLバージョンの確認

PowerShellで以下を実行：

```powershell
wsl --version
wsl --list --verbose
```

### WSLへの接続

```powershell
wsl
```

## 🛠️ 2. 必要なパッケージのインストール

### システムパッケージの更新

```bash
sudo apt update
sudo apt upgrade -y
```

### ビルドツールとライブラリのインストール

```bash
# 基本的なビルドツール
sudo apt install -y build-essential git

# OpenSSL開発ライブラリ
sudo apt install -y libssl-dev

# ネットワーク診断ツール（curlまたはwget）
sudo apt install -y curl wget

# その他の必要なツール
sudo apt install -y cmake autoconf automake libtool pkg-config
```

## 📥 3. sscepのインストール

### 方法A: ソースからビルド（推奨）

```bash
# 作業ディレクトリの作成
mkdir -p ~/tools
cd ~/tools

# sscepのクローン
git clone https://github.com/certnanny/sscep.git
cd sscep

# ビルド
./bootstrap.sh
./configure
make
sudo make install

# インストール確認
sscep --version
which sscep

# 注意: sscepはHTTPプロトコルのみをサポート（HTTPSは非対応）
```

### 方法B: パッケージマネージャー（Ubuntu 20.04以降）

```bash
# 利用可能か確認
apt search sscep

# インストール（利用可能な場合）
sudo apt install -y sscep
```

## 🔐 4. OpenSSLのインストール確認

```bash
# OpenSSLのバージョン確認
openssl version

# インストールされていない場合
sudo apt install -y openssl
```

## 🧪 5. SCEPテストの実行

### テスト用ディレクトリの作成

```bash
mkdir -p ~/scep-test
cd ~/scep-test
```

### ステップ1: CA証明書の取得

```bash
# SCEPサーバーからCA証明書を取得
# ⚠️ 重要: sscepはHTTPのみ対応。HTTPSは使用不可
sscep getca \
    -u http://hiki-test.ids-dev.solitonsys.jp/scep/static \
    -c ca.crt \
    -v

# 証明書の確認
openssl x509 -in ca.crt -text -noout

# ⚠️ "illegal URL" エラーが出る場合：
# - HTTPSのURLを使用していないか確認（sscepはHTTPのみサポート）
# - 「8. トラブルシューティング」の「illegal URLエラー」セクションを参照
```

### ステップ2: 秘密鍵の生成

```bash
# 2048ビットRSA秘密鍵の生成
openssl genrsa -out client.key 4096

# 秘密鍵の確認
openssl rsa -in client.key -check -noout
```

### ステップ3: CSR（証明書署名要求）の生成

```bash
# 設定ファイルの作成（req.cnf）
cat > req.cnf << 'EOF'
[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
attributes         = req_attributes
req_extensions     = v3_req

[ dn ]
C  = JP
ST = Tokyo
L  = Shinjuku
O  = Soliton Systems K.K.
CN = testuser000001@example.com

[ req_attributes ]
challengePassword = 6d805b9b-72ca-6314-5f6d-4b8a90899807

[ v3_req ]
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF

# 設定ファイルを使用してCSRを生成
openssl req -new \
    -key client.key \
    -out client.csr \
    -config req.cnf

# CSRの確認（challengePasswordが含まれていることを確認）
openssl req -in client.csr -text -noout
```

**req.cnf の設定項目説明:**
- `challengePassword`: SCEPサーバーが要求するチャレンジパスワード
- `keyUsage`: 鍵の使用目的
- `extendedKeyUsage`: 拡張鍵使用目的（クライアント認証用）

### ステップ4: SCEP経由で証明書を取得

#### 基本的な証明書取得

```bash
# 証明書の取得（enroll）
# ⚠️ 重要: HTTPのURLを使用（sscepはHTTPSに非対応）

# オプション説明:
# -u : SCEP サーバーURL（HTTPのみ）
# -c : CA証明書
# -k : 秘密鍵
# -r : CSR
# -l : 取得した証明書の保存先
# -v : 詳細出力
```

#### AES256暗号化とSHA256署名を使用する場合（推奨）

より強力な暗号化とハッシュアルゴリズムを使用する場合：

```bash
# AES256暗号化とSHA256署名を指定
sscep enroll \
    -u http://hiki-test.ids-dev.solitonsys.jp/scep/static \
    -c ca.crt \
    -k client.key \
    -r client.csr \
    -l client.crt \
    -E aes256 \
    -S sha256 \
    -v

# 追加オプション説明:
# -E aes256 : AES256暗号化アルゴリズムを使用
# -S sha256 : SHA256署名アルゴリズムを使用
```

**暗号化オプションの選択肢:**
- `-E des3` : 3DES暗号化（互換性重視）
- `-E aes128` : AES128暗号化
- `-E aes256` : AES256暗号化（推奨）

**署名アルゴリズムの選択肢:**
- `-S md5` : MD5（非推奨）
- `-S sha1` : SHA1
- `-S sha256` : SHA256（推奨）
- `-S sha512` : SHA512

### ステップ5: 取得した証明書の確認

```bash
# 証明書の内容確認
openssl x509 -in client.crt -text -noout

# 証明書の検証
openssl verify -CAfile ca.crt client.crt

# 証明書と秘密鍵の対応確認
diff <(openssl x509 -in client.crt -pubkey -noout) \
     <(openssl rsa -in client.key -pubout)
```

## 📜 7. 完全な自動化スクリプト

便利なワンライナースクリプト：

```bash
#!/bin/bash
# scep-enroll-test.sh

# 設定
# ⚠️ 重要: sscepはHTTPのみサポート（HTTPSは使用不可）
SCEP_URL="http://hiki-test.ids-dev.solitonsys.jp/scep/static"
COMMON_NAME="testuser000001@example.com"
CHALLENGE_PASS="6d805b9b-72ca-6314-5f6d-4b8a90899807"  # チャレンジパスワード

# 暗号化オプション
USE_AES256=true  # AES256暗号化を使用する場合はtrue
USE_CONFIG_FILE=true  # req.cnfを使用する場合はtrue

# プロキシ設定をクリア
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY

# クリーンアップ
rm -f ca.crt client.key client.csr client.crt req.cnf

# URLプロトコルの確認
echo "=== 0. SCEP URL確認 ==="
if [[ "$SCEP_URL" == https://* ]]; then
    echo "❌ エラー: HTTPSのURLが指定されています"
    echo "   sscepはHTTPのみサポートしています"
    echo "   現在のURL: $SCEP_URL"
    exit 1
else
    echo "✅ URL形式: OK (HTTP)"
fi

echo "=== 1. CA証明書の取得 ==="
sscep getca -u "$SCEP_URL" -c ca.crt -v
if [ $? -ne 0 ]; then
    echo "❌ エラー: CA証明書の取得に失敗しました"
    echo "   URLを確認してください: $SCEP_URL"
    exit 1
fi

echo "=== 2. 秘密鍵の生成 ==="
openssl genrsa -out client.key 4096

echo "=== 3. CSRの生成 ==="
if [ "$USE_CONFIG_FILE" = true ]; then
    # 設定ファイルを使用してCSRを生成（challengePassword含む）
    cat > req.cnf << EOF
[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
attributes         = req_attributes
req_extensions     = v3_req

[ dn ]
C  = JP
ST = Tokyo
L  = Shinjuku
O  = Soliton Systems K.K.
CN = $COMMON_NAME

[ req_attributes ]
challengePassword = $CHALLENGE_PASS

[ v3_req ]
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF

    openssl req -new -key client.key -out client.csr -config req.cnf
    echo "✅ CSRを設定ファイル（req.cnf）で生成しました"
else
    # コマンドラインでCSRを生成
    openssl req -new \
        -key client.key \
        -out client.csr \
        -subj "/C=JP/ST=Tokyo/L=Shinjuku/O=Soliton Systems K.K./CN=$COMMON_NAME"
    echo "✅ CSRをコマンドラインで生成しました"
fi

echo "=== 4. 証明書の取得 ==="
# enrollコマンドの構築
ENROLL_CMD="sscep enroll -u \"$SCEP_URL\" -c ca.crt -k client.key -r client.csr -l client.crt"

# AES256/SHA256オプションの追加
if [ "$USE_AES256" = true ]; then
    ENROLL_CMD="$ENROLL_CMD -E aes256 -S sha256"
    echo "   暗号化: AES256, 署名: SHA256"
fi

# チャレンジパスワードの追加（-wオプション）
if [ -n "$CHALLENGE_PASS" ] && [ "$USE_CONFIG_FILE" != true ]; then
    ENROLL_CMD="$ENROLL_CMD -w \"$CHALLENGE_PASS\""
fi

# 詳細出力を追加
ENROLL_CMD="$ENROLL_CMD -v"

# コマンドを実行
eval $ENROLL_CMD

if [ $? -eq 0 ]; then
    echo "=== 5. 証明書の確認 ==="
    openssl x509 -in client.crt -text -noout | head -20
    echo ""
    echo "✅ 証明書の取得に成功しました！"
else
    echo "❌ 証明書の取得に失敗しました"
    exit 1
fi
```

スクリプトの実行：

```bash
# スクリプトに実行権限を付与
chmod +x scep-enroll-test.sh

# 実行
./scep-enroll-test.sh
```

## 🔍 8. トラブルシューティング

### sscepコマンドが見つからない

```bash
# パスの確認
echo $PATH
which sscep

# 手動でパスを追加（必要に応じて）
export PATH=$PATH:/usr/local/bin

# .bashrc に追加して永続化
echo 'export PATH=$PATH:/usr/local/bin' >> ~/.bashrc
source ~/.bashrc
```

### ビルドエラー: OpenSSLが見つからない

```bash
# OpenSSL開発パッケージの再インストール
sudo apt remove libssl-dev
sudo apt install -y libssl-dev

# OpenSSLのパスを確認
pkg-config --cflags --libs openssl
```

### "illegal URL" エラーが出る場合（パケットが送信されない）

**最も重要な原因: sscepはHTTPSに対応していません**

```bash
# エラー例:
# sscep: illegal URL https://hiki-test.ids-dev.solitonsys.jp/scep/static

# 原因: HTTPSのURLを指定している
# sscepはHTTPプロトコルのみをサポートしています

# ✅ 解決方法: HTTPのURLを使用
sscep getca -u http://hiki-test.ids-dev.solitonsys.jp/scep/static -c ca.crt -v

# URLプロトコルの確認
echo "http://hiki-test.ids-dev.solitonsys.jp/scep/static" | grep -q "^http://" && echo "OK: HTTP" || echo "NG: HTTPS使用不可"
```

**SCEPサーバー側の設定が必要:**

```bash
# SCEPサーバーがHTTPアクセスを許可しているか確認
curl -v http://hiki-test.ids-dev.solitonsys.jp/scep/static

# HTTPSでしかアクセスできない場合の対策:
# 1. リバースプロキシ（nginx/Apache）でHTTPS→HTTP変換
# 2. ローカルで stunnel や socat を使用してHTTPS→HTTP変換
```

**stunnelを使ったHTTPS→HTTP変換（ローカル）:**

```bash
# stunnelのインストール
sudo apt install -y stunnel4

# stunnel設定ファイル作成
cat > stunnel.conf << 'EOF'
client = yes

[scep]
accept = 127.0.0.1:8080
connect = hiki-test.ids-dev.solitonsys.jp:443
EOF

# stunnel起動
stunnel stunnel.conf

# sscepでローカルのHTTPポートを使用
sscep getca -u http://127.0.0.1:8080/scep/static -c ca.crt -v
```

**URL形式の問題:**

一部のSCEPサーバーは、特定のクエリパラメータを必要とします：

```bash
# CGIパラメータなしの場合（シンプルなパス）
# ⚠️ HTTPを使用
sscep enroll \
    -u "http://hiki-test.ids-dev.solitonsys.jp/scep/static" \
    -c ca.crt \
    -k client.key \
    -r client.csr \
    -l client.crt \
    -v

# クエリパラメータが必要な場合
sscep enroll \
    -u "http://hiki-test.ids-dev.solitonsys.jp/scep?operation=PKIOperation" \
    -c ca.crt \
    -k client.key \
    -r client.csr \
    -l client.crt \
    -v
```

**HTTPプロキシの問題**

プロキシ環境変数が設定されている場合、クリアしてみる：

```bash
# プロキシ設定を一時的に無効化
unset http_proxy
unset https_proxy
unset HTTP_PROXY
unset HTTPS_PROXY

# 再実行
sscep enroll -u https://... -c ca.crt -k client.key -r client.csr -l client.crt -v
```

**動作確認方法**

```bash
# ステップ1: サーバーへの基本的な接続確認（HTTP）
# curlがない場合: sudo apt install -y curl
curl -v http://hiki-test.ids-dev.solitonsys.jp/scep/static

# curlがインストールされていない場合はwgetを使用
wget --spider -v http://hiki-test.ids-dev.solitonsys.jp/scep/static

# ステップ2: SCEPのGetCACert操作を手動で確認（HTTP）
curl -v "http://hiki-test.ids-dev.solitonsys.jp/scep/static?operation=GetCACert"
# または
wget -O- "http://hiki-test.ids-dev.solitonsys.jp/scep/static?operation=GetCACert"

# ステップ3: sscepのgetcaコマンドでサーバー接続を確認
# ⚠️ 重要: HTTPのURLを使用（HTTPSは不可）
sscep getca -u http://hiki-test.ids-dev.solitonsys.jp/scep/static -c ca.crt -v

# getcaが成功すれば、URLは正しい
# getcaも失敗する場合は、URLまたはサーバー設定に問題がある
```

**診断チェックリスト:**
- [ ] curl または wget がインストールされている
- [ ] HTTPのURLを使用している（HTTPSではない）
- [ ] curlまたはwgetでサーバーに接続できる（HTTPで）
- [ ] `sscep getca` コマンドが成功する
- [ ] プロキシ環境変数が設定されていない

### curlコマンドが見つからない

診断コマンドでcurlが必要な場合：

```bash
# エラー: -bash: curl: command not found

# 対処法: curlをインストール
sudo apt update
sudo apt install -y curl

# 確認
curl --version

# 代替手段: wgetを使用
sudo apt install -y wget
wget --version

# curlの代わりにwgetを使用する例:
# curl -v https://example.com  →  wget --spider -v https://example.com
# curl -O https://example.com  →  wget https://example.com
```

### 証明書取得時のSSL/TLSエラー

```bash
# より詳細なデバッグ出力を有効にする
# ⚠️ HTTPのURLを使用
sscep enroll \
    -u http://hiki-test.ids-dev.solitonsys.jp/scep \
    -c ca.crt \
    -k client.key \
    -r client.csr \
    -l client.crt \
    -d -v

# または、curlでSCEPサーバーへの接続を確認（curlがない場合: sudo apt install -y curl）
curl -v http://hiki-test.ids-dev.solitonsys.jp/scep/static
# wgetの場合:
wget --spider -v http://hiki-test.ids-dev.solitonsys.jp/scep/static
```

### 証明書が pending 状態になる

一部のSCEPサーバーは手動承認が必要です：

```bash
# pending状態の確認
# ⚠️ HTTPのURLを使用
sscep getcert \
    -u http://hiki-test.ids-dev.solitonsys.jp/scep/static \
    -c ca.crt \
    -k client.key \
    -r client.csr \
    -l client.crt \
    -v

# 管理者による承認後、再度実行
```

### WSLからWindowsのファイルにアクセス

```bash
# Windowsのファイルシステムは /mnt/ にマウントされています
cd /mnt/c/Users/hiki.FOURSEASONS/

# 結果をWindows側にコピー
cp ~/scep-test/*.crt /mnt/c/Users/hiki.FOURSEASONS/Downloads/
```

## 📚 9. 参考情報

### sscepの主要オプション

| オプション | 説明 |
|-----------|------|
| `-u URL` | SCEP サーバーのURL（HTTPのみ対応） |
| `-c FILE` | CA証明書ファイル |
| `-k FILE` | 秘密鍵ファイル |
| `-r FILE` | CSRファイル |
| `-l FILE` | 取得した証明書の保存先 |
| `-w PASS` | チャレンジパスワード |
| `-E ALGO` | 暗号化アルゴリズム（des3, aes128, aes256） |
| `-S ALGO` | 署名アルゴリズム（md5, sha1, sha256, sha512） |
| `-v` | 詳細出力 |
| `-d` | デバッグモード |

**推奨オプション組み合わせ:**
```bash
# セキュアな設定（推奨）
sscep enroll -u <URL> -c ca.crt -k client.key -r client.csr -l client.crt \
  -E aes256 -S sha256 -v

# 互換性重視
sscep enroll -u <URL> -c ca.crt -k client.key -r client.csr -l client.crt \
  -E des3 -S sha1 -v
```

### SCEP操作の種類

- `getca` : CA証明書の取得
- `enroll` : 証明書の新規取得
- `getcert` : pending状態の証明書の取得
- `getcrl` : CRLの取得

### 環境変数の設定

```bash
# 環境変数でSCEPサーバーを指定
# ⚠️ 重要: HTTPのURLを使用（sscepはHTTPSに非対応）
export SCEP_URL="http://hiki-test.ids-dev.solitonsys.jp/scep/static"

# スクリプト内で使用
sscep getca -u "$SCEP_URL" -c ca.crt
```

## ✅ 10. 動作確認チェックリスト

- [ ] sscepがインストールされている (`sscep --version`)
- [ ] OpenSSLがインストールされている (`openssl version`)
- [ ] CA証明書の取得に成功した
- [ ] 秘密鍵とCSRの生成に成功した
- [ ] SCEP経由での証明書取得に成功した
- [ ] 証明書の検証が成功した (`openssl verify`)
- [ ] 証明書と秘密鍵の対応が確認できた

## 🚑 11. "illegal URL" エラーのクイックリファレンス

### 問題の症状
```
sscep: illegal URL https://hiki-test.ids-dev.solitonsys.jp/scep/static
```
- パケットが全く送信されない
- ネットワーク接続前にエラーが発生

### 🔴 最重要：sscepはHTTPSに対応していません

**sscepはHTTPプロトコルのみをサポートしています。**

### 解決手順

#### 1️⃣ URLをHTTPに変更（最も重要）
```bash
# ❌ 誤り（HTTPSは使用不可）
sscep getca -u https://hiki-test.ids-dev.solitonsys.jp/scep/static -c ca.crt -v

# ✅ 正しい（HTTPを使用）
sscep getca -u http://hiki-test.ids-dev.solitonsys.jp/scep/static -c ca.crt -v
```

#### 2️⃣ サーバーがHTTPアクセスを許可しているか確認
```bash
# curlで接続テスト（HTTP）
curl -v http://hiki-test.ids-dev.solitonsys.jp/scep/static

# HTTPで接続できない場合、サーバー設定を確認
```

#### 3️⃣ HTTPSしか許可されていない場合の対処

サーバーがHTTPSのみの場合、以下の方法でHTTPS→HTTP変換：

**方法A: stunnelでローカル変換（推奨）**
```bash
# stunnelインストール
sudo apt install -y stunnel4

# 設定ファイル作成
cat > ~/stunnel-scep.conf << 'EOF'
client = yes
foreground = yes

[scep]
accept = 127.0.0.1:8080
connect = hiki-test.ids-dev.solitonsys.jp:443
EOF

# stunnel起動（別ターミナル）
stunnel ~/stunnel-scep.conf

# sscepでローカルHTTPポートを使用
sscep getca -u http://127.0.0.1:8080/scep/static -c ca.crt -v
```

**方法B: socatで変換**
```bash
# socatインストール
sudo apt install -y socat

# HTTPS→HTTP変換（バックグラウンド）
socat TCP-LISTEN:8080,fork,reuseaddr \
  OPENSSL:hiki-test.ids-dev.solitonsys.jp:443 &

# sscepで使用
sscep getca -u http://127.0.0.1:8080/scep/static -c ca.crt -v
```

#### 4️⃣ その他の確認
```bash
# プロキシをクリア
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY

# 別のURLパスを試す
sscep getca -u http://hiki-test.ids-dev.solitonsys.jp/scep -c ca.crt -v
```

### よくある原因と対策

| 原因 | 症状 | 対策 |
|------|------|------|
| **HTTPSのURL使用** | illegal URLエラー | **HTTPに変更（最重要）** |
| サーバーがHTTPを許可していない | 接続拒否 | stunnel/socatでHTTPS→HTTP変換 |
| プロキシ設定 | 接続タイムアウト | `unset http_proxy https_proxy` |
| URL形式の問題 | illegal URLエラー | URLパス（/scep か /scep/static）を変更 |

## 🔗 12. 参考リンク

- [sscep GitHub](https://github.com/certnanny/sscep)
- [SCEP Protocol RFC 8894](https://datatracker.ietf.org/doc/html/rfc8894)
- [OpenSSL Documentation](https://www.openssl.org/docs/)
- [WSL Documentation](https://docs.microsoft.com/en-us/windows/wsl/)

---

**作成日**: 2026年4月28日  
**バージョン**: 1.0  
**対象環境**: WSL2 (Ubuntu/Debian)
