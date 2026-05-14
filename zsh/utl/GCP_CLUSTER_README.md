# GCP Cluster Connection Functions for zsh

PowerShellの`Connect-SolitonGCPCluster`関数をzsh用に移植した関数セットです。

## 前提条件

以下のツールがインストールされている必要があります：

```bash
# gcloud CLI
brew install --cask google-cloud-sdk

# kubectl
brew install kubectl

# gke-gcloud-auth-plugin
gcloud components install gke-gcloud-auth-plugin

# jq (JSON parser)
brew install jq
```

## クラスタ情報の管理

このスクリプトは `ClusterData.json` ファイルからクラスタ情報を動的に読み込みます。

### ClusterData.json の配置

デフォルトでは `$HOME/ClusterData.json` を参照します。別の場所にある場合は環境変数で指定できます：

```bash
# .zshrc に追加
export SOLITON_CLUSTER_DATA_JSON="/path/to/ClusterData.json"
```

### ClusterData.json の形式

```json
{
  "project-name": {
    "cluster-name": {
      "region": "asia-northeast1",
      "zone": null,
      ...
    }
  }
}
```

スクリプトは以下の情報を使用します：
- プロジェクト名（第1階層のキー）
- クラスタ名（第2階層のキー）
- `region` または `zone`（どちらか一方が設定されていること）

## インストール

### 方法1: .zshrcに直接ロード

```bash
# .zshrcに以下を追加
source /path/to/gcp_cluster_functions.zsh
```

### 方法2: 必要な時だけロード

```bash
# 使用する時に実行
source /path/to/gcp_cluster_functions.zsh
```

## 設定のカスタマイズ

### ClusterData.json の場所を変更

```bash
# .zshrc に追加
export SOLITON_CLUSTER_DATA_JSON="/path/to/your/ClusterData.json"
source /path/to/gcp_cluster_functions.zsh
```

### 利用可能なプロジェクトの確認

```bash
# プロジェクト一覧を表示（引数なしで実行）
list-soliton-gcp-clusters

# または直接JSONファイルを確認
jq 'keys' ~/ClusterData.json
```

### 特定プロジェクトのクラスタ一覧

```bash
# idaas-dev プロジェクトのクラスタ一覧
list-soliton-gcp-clusters idaas-dev

# 短縮形
lsgcp idaas-dev
```

## 使用方法

### 基本的な使い方

```bash
# デフォルトクラスタに接続
connect-soliton-gcp-cluster -p idaas-dev

# 特定のクラスタに接続
connect-soliton-gcp-cluster -p idaas-dev -c cluster-idaas-dev-02

# zone/regionを明示的に指定
connect-soliton-gcp-cluster -p idaas-232202 -c cluster-idaas-232202-01 -z asia-northeast1-b
```

### エイリアスを使った短縮形

```bash
# 短縮形（cgcp = connect-gcp）
cgcp -p idaas-dev

# プロジェクト別エイリアス
cgcp-dev              # idaas-dev に接続
cgcp-prod             # idaas-232202 に接続
cgcp-feature          # idaas-feature に接続
cgcp-lab              # gyutan-lab に接続

# 特定のクラスタを指定
cgcp-dev -c cluster-idaas-dev-02
```

### クラスタ一覧の確認

```bash
# プロジェクトのクラスタ一覧を表示
list-soliton-gcp-clusters idaas-dev

# 短縮形
lsgcp idaas-dev
```

### ヘルプの表示

```bash
connect-soliton-gcp-cluster --help
```

## 機能

### 実装済み機能

- ✅ プロジェクトとクラスタの指定
- ✅ デフォルトクラスタの自動選択
- ✅ zone/region の自動判定と手動指定
- ✅ gcloud configuration の自動作成と切り替え
- ✅ staging環境での本番project警告
- ✅ GKE v1.25+ 対応（gke-gcloud-auth-plugin）
- ✅ クラスタ一覧表示機能
- ✅ 接続成功時の確認表示
- ✅ エイリアス（短縮コマンド）

### PowerShell版との主な違い

1. **クラスタ情報の管理**
   - PowerShell版: `utl_onegate.ps1`の関数から動的に取得
   - zsh版: `ClusterData.json` から動的に読み込み

2. **引数補完**
   - PowerShell版: ArgumentCompleter による動的補完
   - zsh版: JSONファイルから動的に取得（将来的に補完機能拡張可能）

3. **依存関係**
   - PowerShell版: 複数の外部スクリプトファイルに依存
   - zsh版: 単一ファイル + ClusterData.json で完結

## トラブルシューティング

### エラー: "ClusterData.json が見つかりません"

ClusterData.json が指定された場所に存在しません。

**解決方法：**
1. ファイルの存在を確認
```bash
ls -la ~/ClusterData.json
```

2. 別の場所にある場合は環境変数を設定
```bash
export SOLITON_CLUSTER_DATA_JSON="/actual/path/to/ClusterData.json"
```

3. .zshrc に追加して永続化
```bash
echo 'export SOLITON_CLUSTER_DATA_JSON="/path/to/ClusterData.json"' >> ~/.zshrc
```

### エラー: "jq コマンドがインストールされていません"

JSONパース用の `jq` コマンドが必要です。

**解決方法：**
```bash
brew install jq
```

### エラー: "Project 'xxx' not found in ClusterData.json"

指定したプロジェクトがClusterData.jsonに存在しません。

**解決方法：**
1. 利用可能なプロジェクトを確認
```bash
list-soliton-gcp-clusters
# または
jq 'keys' ~/ClusterData.json
```

2. ClusterData.jsonに該当プロジェクトが含まれているか確認

### 接続は成功するが kubectl が動かない

gke-gcloud-auth-plugin がインストールされていない可能性があります：

```bash
# インストール
gcloud components install gke-gcloud-auth-plugin

# 確認
gcloud components list --filter=gke-gcloud-auth-plugin
```

## 高度な使い方

### 複数プロジェクトの素早い切り替え

```bash
# 開発環境に接続
cgcp-dev

# 本番環境に接続
cgcp-prod

# feature環境に接続
cgcp-feature
```

### 現在の接続先を確認

```bash
# 現在のコンテキスト
kubectl config current-context

# クラスタ情報
kubectl cluster-info
```

### クラスタを切り替えた後の確認

関数は自動的に以下の情報を表示します：

- 現在のコンテキスト
- クラスタ情報（API server のURLなど）

## カスタマイズ例

### 独自のエイリアスを追加

`.zshrc` に追加：

```bash
# 頻繁に使うクラスタへのエイリアス
alias cgcp-test='connect-soliton-gcp-cluster -p idaas-dev -c cluster-idaas-dev-03'
alias cgcp-prod-main='connect-soliton-gcp-cluster -p idaas-232202 -c cluster-idaas-232202-01'
```

### 接続後に自動実行するコマンドを追加

関数の最後に追加したいコマンドを記述できます：

```zsh
# 例: 接続後にnamespace一覧を表示
if [[ $? -eq 0 ]]; then
    echo ""
    echo "Available namespaces:"
    kubectl get ns --no-headers | head -n 10
fi
```

## ライセンス

社内ツールとして使用してください。

## 更新履歴

- 2026-04-30: 初版作成（PowerShell版から移植）
