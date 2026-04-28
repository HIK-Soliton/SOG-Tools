# MacでのsscepインストールとSCEPテスト手順

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

## 🛠️ 2. 必要なパッケージのインストール

### ビルドツールとライブラリのインストール

```zsh
# Python
brew install python

## エイリアスを作成
echo 'alias python="python3"' >> ~/.zshrc
echo 'alias pip="pip3"' >> ~/.zshrc

## エイリアスの設定を反映
source ~/.zshrc

## 確認
python --version
pip --version

```

## 📥 3. sscepのインストール

### 方法A: ソースからビルド（推奨）

```zsh
# 開発ツールの準備
xcode-select --install

# GitHubからソースを取得してビルド
git clone https://github.com/certnanny/sscep.git
cd sscep

# ツール（autoconfなど）の準備（入っていなければ）
brew install autoconf automake libtool openssl

# 手動ビルド

# 0. フォルダの準備
mkdir -p build-aux m4

# 1. libtoolの準備（Mac用のglibtoolizeを使用）
glibtoolize --force --copy

# 2. マクロの収集
aclocal

# 3. Makefileのテンプレート作成
# --add-missing で必要な補助ファイルを build-aux にコピーさせます
automake --add-missing --copy --foreign

# 4. configureスクリプトの生成
autoconf

# 5. コンパイルの実行
./configure LDFLAGS="-L$(brew --prefix openssl)/lib" CPPFLAGS="-I$(brew --prefix openssl)/include"
make

# インストール確認
./sscep

# インストール（どこからでも使えるようにする）
sudo make install

# 注意: sscepはHTTPプロトコルのみをサポート（HTTPSは非対応）
```

## 🧪 5. SCEPテストの実行

# ライブラリのインストール

## 仮想環境（venv）を作成
mkdir ~/my_project
cd ~/my_project

python -m venv .venv
source .venv/bin/activate

## インストール
pip install cryptography requests

### テスト用ディレクトリの作成

```zsh
mkdir -p ~/scep-test
cd ~/scep-test
```

### 作成したディレクトリにPythonスクリプトとコンフィグファイルを配置
scep_enrollment_multi.py
ChromeOS_SKMSetting_json.txt

### スクリプトの実行

```zsh
python scep_enrollment_multi.py --no-output --key-size 4096 --count 10 --max-threads 10 --log-file ./scep-test.log
```
[--email EMAIL] [--config CONFIG] [--output-dir OUTPUT_DIR]
                                [--key-size {2048,3072,4096}] [-v] [--count COUNT]
                                [--no-output] [--max-threads MAX_THREADS] [--log-file LOG_FILE]