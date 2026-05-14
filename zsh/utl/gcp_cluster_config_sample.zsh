#!/bin/zsh
# GCP Cluster Configuration Sample
# 
# 【重要】このファイルは古い形式です
# 
# 現在のバージョンでは ClusterData.json から動的にクラスタ情報を読み込みます。
# このファイルは参考用として残していますが、使用する必要はありません。
#
# ClusterData.json の設定方法:
# 1. ClusterData.json を $HOME/ にコピー
# 2. または環境変数で指定: export SOLITON_CLUSTER_DATA_JSON="/path/to/ClusterData.json"

# ================================================================================
# ClusterData.json の形式（参考）
# ================================================================================
#
# {
#   "project-name": {
#     "cluster-name": {
#       "region": "asia-northeast1",
#       "zone": null,
#       ...
#     },
#     "another-cluster": {
#       "region": null,
#       "zone": "asia-northeast1-b",
#       ...
#     }
#   }
# }

# ================================================================================
# （旧形式）クラスタ情報の定義 - 参考用
# ================================================================================
# 以下は古い静的定義の方法です。参考として残しています。

# クラスタ情報を連想配列で定義
# キー形式: "project:cluster"
# 値形式: "zone:ZONE_NAME" または "region:REGION_NAME"

typeset -A CLUSTER_INFO

# ----------------------------------------
# idaas-dev プロジェクト
# ----------------------------------------
CLUSTER_INFO[idaas-dev:cluster-idaas-dev-01]="zone:asia-northeast1-b"
CLUSTER_INFO[idaas-dev:cluster-idaas-dev-02]="zone:asia-northeast1-b"
CLUSTER_INFO[idaas-dev:cluster-idaas-dev-03]="zone:asia-northeast1-b"
CLUSTER_INFO[idaas-dev:cluster-idaas-dev-04]="zone:asia-northeast1-b"
CLUSTER_INFO[idaas-dev:cluster-idaas-dev-05]="zone:asia-northeast1-b"

# Regional クラスタの例
# CLUSTER_INFO[idaas-dev:cluster-idaas-dev-regional]="region:asia-northeast1"

# ----------------------------------------
# idaas-232202 プロジェクト（本番）
# ----------------------------------------
CLUSTER_INFO[idaas-232202:cluster-idaas-232202-01]="zone:asia-northeast1-b"
CLUSTER_INFO[idaas-232202:cluster-idaas-232202-02]="zone:asia-northeast1-b"
CLUSTER_INFO[idaas-232202:cluster-idaas-232202-03]="zone:asia-northeast1-b"

# ----------------------------------------
# idaas-feature プロジェクト
# ----------------------------------------
CLUSTER_INFO[idaas-feature:cluster-idaas-feature-01]="zone:asia-northeast1-b"

# ----------------------------------------
# gyutan-lab プロジェクト
# ----------------------------------------
CLUSTER_INFO[gyutan-lab:cluster-gyutan-lab-01]="zone:asia-northeast1-b"

# ----------------------------------------
# 他のプロジェクトを追加する場合
# ----------------------------------------
# CLUSTER_INFO[your-project:your-cluster-01]="zone:asia-northeast1-a"
# CLUSTER_INFO[your-project:your-cluster-02]="region:us-central1"

# ================================================================================
# デフォルトクラスタの定義
# ================================================================================

# 各プロジェクトでクラスタ名を省略した場合に使用されるクラスタ
typeset -A DEFAULT_CLUSTER

DEFAULT_CLUSTER[idaas-dev]="cluster-idaas-dev-01"
DEFAULT_CLUSTER[idaas-232202]="cluster-idaas-232202-01"
DEFAULT_CLUSTER[idaas-feature]="cluster-idaas-feature-01"
DEFAULT_CLUSTER[gyutan-lab]="cluster-gyutan-lab-01"

# 他のプロジェクトを追加する場合
# DEFAULT_CLUSTER[your-project]="your-cluster-01"

# ================================================================================
# 実際のクラスタ情報を確認するコマンド
# ================================================================================
# 
# プロジェクトのクラスタ一覧を取得:
#   gcloud container clusters list --project=idaas-dev
#
# 特定クラスタの詳細情報:
#   gcloud container clusters describe CLUSTER_NAME --project=PROJECT --zone=ZONE
#   gcloud container clusters describe CLUSTER_NAME --project=PROJECT --region=REGION
#
# 例:
#   gcloud container clusters list --project=idaas-dev --format="table(name,location,status)"
#
# この情報をもとに上記の CLUSTER_INFO を編集してください

# ================================================================================
# 使用方法
# ================================================================================
#
# 1. このファイルをコピーして編集:
#    cp gcp_cluster_config_sample.zsh gcp_cluster_config_custom.zsh
#
# 2. gcp_cluster_functions.zsh を編集して、設定ファイルを読み込むように変更:
#    source /path/to/gcp_cluster_config_custom.zsh
#
# または、メインの関数スクリプトに直接書き込む
