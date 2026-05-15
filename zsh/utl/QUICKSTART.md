# GCP Cluster Functions - クイックスタートガイド

## 1. 必要なものを準備

```bash
# Homebrew のインストール（未インストールの場合）
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 必要なツールをインストール
brew install --cask google-cloud-sdk
brew install kubectl jq

# GKE plugin をインストール
gcloud components install gke-gcloud-auth-plugin
```

## 2. ClusterData.json を配置

ClusterData.json をホームディレクトリにコピー：

```bash
# ClusterData.json をホームディレクトリにコピー
cp /path/to/ClusterData.json ~/ClusterData.json

# または、別の場所に配置して環境変数で指定
export SOLITON_CLUSTER_DATA_JSON="/path/to/ClusterData.json"
```

## 3. スクリプトを読み込む

### 方法A: 自動セットアップスクリプトを使用（推奨）

```bash
chmod +x setup_mac.sh
./setup_mac.sh
```

### 方法B: 手動セットアップ

```bash
# スクリプトをホームディレクトリの適当な場所にコピー
mkdir -p ~/.soliton-tools
cp gcp_cluster_functions.zsh ~/.soliton-tools/

# .zshrc に追加
echo 'export SOLITON_CLUSTER_DATA_JSON="$HOME/ClusterData.json"' >> ~/.zshrc
echo 'source ~/.soliton-tools/gcp_cluster_functions.zsh' >> ~/.zshrc

# 設定を再読み込み
source ~/.zshrc
```

## 4. 使ってみる

### プロジェクト一覧を確認

```bash
list-soliton-gcp-clusters
```

### 特定プロジェクトのクラスタ一覧を確認

```bash
list-soliton-gcp-clusters idaas-dev
# または短縮形
lsgcp idaas-dev
```

### クラスタに接続

```bash
# デフォルトクラスタに接続
connect-soliton-gcp-cluster -p idaas-dev

# 短縮形
cgcp -p idaas-dev

# 特定のクラスタに接続
cgcp -p idaas-dev -c cluster-idaas-dev-02
```

### プロジェクト別エイリアス（設定されている場合）

```bash
cgcp-dev      # idaas-dev に接続
cgcp-prod     # idaas-232202 に接続
cgcp-feature  # idaas-feature に接続
cgcp-lab      # gyutan-lab に接続
```

## 5. 動作確認

```bash
# 現在の接続先を確認
kubectl config current-context

# クラスタ情報を表示
kubectl cluster-info

# ネームスペース一覧を表示
kubectl get namespaces
```

## よくある使い方

### 開発環境に接続してテナント一覧を確認

```bash
cgcp-dev
kubectl get ns | grep -E '^(tenant-|common-)'
```

### 特定のテナントの Pod 状態を確認

```bash
cgcp-dev
kubectl get pods -n tenant-example
```

### 複数のクラスタを素早く切り替え

```bash
# 開発環境のクラスタ1に接続
cgcp -p idaas-dev -c cluster-idaas-dev-01
kubectl get nodes

# 開発環境のクラスタ2に接続
cgcp -p idaas-dev -c cluster-idaas-dev-02
kubectl get nodes
```

## トラブルシューティング

### ClusterData.json が見つからない

```bash
# 現在の設定を確認
echo $SOLITON_CLUSTER_DATA_JSON

# ファイルの存在を確認
ls -la ~/ClusterData.json

# 環境変数を設定（一時的）
export SOLITON_CLUSTER_DATA_JSON="/path/to/ClusterData.json"

# .zshrc に追加（永続化）
echo 'export SOLITON_CLUSTER_DATA_JSON="/path/to/ClusterData.json"' >> ~/.zshrc
source ~/.zshrc
```

### 利用可能なプロジェクトを確認

```bash
# スクリプト経由で確認
lsgcp

# 直接 JSON を確認
jq 'keys' ~/ClusterData.json

# 特定プロジェクトのクラスタ一覧
jq '.["idaas-dev"] | keys' ~/ClusterData.json
```

### gcloud の認証エラー

```bash
# 再認証
gcloud auth login

# アクティブなアカウントを確認
gcloud auth list

# デフォルトプロジェクトを設定
gcloud config set project idaas-dev
```

### kubectl が動かない

```bash
# gke-gcloud-auth-plugin の確認
gcloud components list --filter=gke-gcloud-auth-plugin

# インストール
gcloud components install gke-gcloud-auth-plugin

# 環境変数の確認（USE_GKE_GCLOUD_AUTH_PLUGIN が True であること）
echo $USE_GKE_GCLOUD_AUTH_PLUGIN
```

## 次のステップ

詳細なドキュメント：[GCP_CLUSTER_README.md](GCP_CLUSTER_README.md)

---

**ヒント：** タブ補完を有効にしたい場合は、zsh の補完機能を追加することができます。詳細は README を参照してください。
