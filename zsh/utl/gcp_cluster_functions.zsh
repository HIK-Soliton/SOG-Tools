#!/bin/zsh
# GCP Cluster接続用のzsh関数
# 
# 使用方法:
#   source gcp_cluster_functions.zsh
#   connect-soliton-gcp-cluster -p idaas-dev -c cluster-idaas-dev-01
#
# 必要な設定:
#   - gcloud CLI がインストールされていること
#   - kubectl がインストールされていること
#   - gke-gcloud-auth-plugin がインストールされていること
#     インストール: gcloud components install gke-gcloud-auth-plugin
#   - jq がインストールされていること（JSONパース用）
#     インストール: brew install jq

# ================================================================================
# 設定
# ================================================================================

# staging環境のホスト名プレフィックス
STAGING_HOSTNAME_PREFIX="staging"

# ClusterData.json のパス（環境変数で上書き可能）
# 例: export SOLITON_CLUSTER_DATA_JSON="/path/to/ClusterData.json"
CLUSTER_DATA_JSON="${SOLITON_CLUSTER_DATA_JSON:-$HOME/ClusterData.json}"

# クラスタ情報キャッシュ（JSONから動的に読み込み）
typeset -A CLUSTER_INFO
typeset -A DEFAULT_CLUSTER
typeset -A CLUSTER_DATA_LOADED

# ================================================================================
# JSON読み込み関数
# ================================================================================

# JSONファイルが存在するか確認
check-cluster-data-json() {
    if [[ ! -f "$CLUSTER_DATA_JSON" ]]; then
        echo "\033[31mError: ClusterData.json が見つかりません: $CLUSTER_DATA_JSON\033[0m" >&2
        echo "環境変数 SOLITON_CLUSTER_DATA_JSON でパスを指定できます" >&2
        return 1
    fi
    
    if ! command -v jq &> /dev/null; then
        echo "\033[31mError: jq コマンドがインストールされていません\033[0m" >&2
        echo "インストール方法: brew install jq" >&2
        return 1
    fi
    
    return 0
}

# JSONファイルからクラスタ情報を読み込む
load-cluster-data-from-json() {
    local project=$1
    
    # 既に読み込み済みの場合はスキップ
    if [[ -n "${CLUSTER_DATA_LOADED[$project]}" ]]; then
        return 0
    fi
    
    if ! check-cluster-data-json; then
        return 1
    fi
    
    # プロジェクトが存在するか確認
    local project_exists=$(jq -r "has(\"$project\")" "$CLUSTER_DATA_JSON" 2>/dev/null)
    if [[ "$project_exists" != "true" ]]; then
        echo "\033[33mWarning: プロジェクト '$project' が ClusterData.json に存在しません\033[0m" >&2
        return 1
    fi
    
    # クラスタ一覧を取得してCLUSTER_INFOに格納
    local clusters=$(jq -r ".\"$project\" | keys[]" "$CLUSTER_DATA_JSON" 2>/dev/null)
    local first_cluster=""
    
    while IFS= read -r cluster; do
        [[ -z "$cluster" ]] && continue
        
        # 最初のクラスタをデフォルトとして記録
        if [[ -z "$first_cluster" ]]; then
            first_cluster="$cluster"
        fi
        
        local region=$(jq -r ".\"$project\".\"$cluster\".region // empty" "$CLUSTER_DATA_JSON" 2>/dev/null)
        local zone=$(jq -r ".\"$project\".\"$cluster\".zone // empty" "$CLUSTER_DATA_JSON" 2>/dev/null)
        
        local location_info=""
        if [[ -n "$region" && "$region" != "null" ]]; then
            location_info="region:$region"
        elif [[ -n "$zone" && "$zone" != "null" ]]; then
            location_info="zone:$zone"
        fi
        
        if [[ -n "$location_info" ]]; then
            CLUSTER_INFO["${project}:${cluster}"]="$location_info"
        fi
    done <<< "$clusters"
    
    # デフォルトクラスタを設定（最初に見つかったクラスタ）
    if [[ -n "$first_cluster" ]]; then
        DEFAULT_CLUSTER[$project]="$first_cluster"
    fi
    
    # 読み込み済みマーク
    CLUSTER_DATA_LOADED[$project]=1
    
    return 0
}

# ================================================================================
# ヘルパー関数
# ================================================================================

# クラスタ情報を取得する関数
get-sog-cluster-info() {
    local project=$1
    local cluster=$2
    local key="${project}:${cluster}"
    
    # まずキャッシュを確認
    if [[ -n "${CLUSTER_INFO[$key]}" ]]; then
        echo "${CLUSTER_INFO[$key]}"
        return 0
    fi
    
    # JSONから読み込み
    load-cluster-data-from-json "$project"
    
    # 再度キャッシュを確認
    if [[ -n "${CLUSTER_INFO[$key]}" ]]; then
        echo "${CLUSTER_INFO[$key]}"
        return 0
    else
        return 1
    fi
}

# デフォルトクラスタを取得する関数
get-sog-default-cluster() {
    local project=$1
    
    # まずキャッシュを確認
    if [[ -n "${DEFAULT_CLUSTER[$project]}" ]]; then
        echo "${DEFAULT_CLUSTER[$project]}"
        return 0
    fi
    
    # JSONから読み込み
    load-cluster-data-from-json "$project"
    
    # 再度キャッシュを確認
    if [[ -n "${DEFAULT_CLUSTER[$project]}" ]]; then
        echo "${DEFAULT_CLUSTER[$project]}"
        return 0
    else
        return 1
    fi
}

# プロジェクトのクラスタ一覧を取得する関数
get-sog-cluster-list() {
    local project=$1
    
    # JSONから読み込み
    load-cluster-data-from-json "$project"
    
    local clusters=()
    
    for key in ${(k)CLUSTER_INFO}; do
        if [[ $key == ${project}:* ]]; then
            clusters+=(${key#*:})
        fi
    done
    
    if [[ ${#clusters[@]} -gt 0 ]]; then
        printf '%s\n' "${clusters[@]}"
        return 0
    else
        return 1
    fi
}

# zone/region情報を抽出する関数
extract-location-info() {
    local info=$1
    local type=$2  # "zone" or "region"
    
    if [[ $info == *"${type}:"* ]]; then
        echo ${info#*${type}:}
        return 0
    else
        return 1
    fi
}

# ================================================================================
# メイン関数: Connect-SolitonGCPCluster のzsh版
# ================================================================================

connect-soliton-gcp-cluster() {
    # 使用方法を表示
    local usage="Usage: connect-soliton-gcp-cluster -p PROJECT [-c CLUSTER] [-r REGION] [-z ZONE]
    
Options:
    -p, --project PROJECT    GCP project name (idaas-dev, idaas-232202, idaas-feature, gyutan-lab)
    -c, --cluster CLUSTER    Cluster name (optional, uses default if not specified)
    -r, --region REGION      Region name (optional)
    -z, --zone ZONE          Zone name (optional)
    -h, --help               Show this help message

Examples:
    connect-soliton-gcp-cluster -p idaas-dev
    connect-soliton-gcp-cluster -p idaas-dev -c cluster-idaas-dev-02
    connect-soliton-gcp-cluster -p idaas-232202 -c cluster-idaas-232202-01 -z asia-northeast1-b
"
    
    # パラメータ初期化
    local project=""
    local cluster=""
    local region=""
    local zone=""
    
    # 引数解析
    while [[ $# -gt 0 ]]; do
        case $1 in
            -p|--project)
                project="$2"
                shift 2
                ;;
            -c|--cluster)
                cluster="$2"
                shift 2
                ;;
            -r|--region)
                region="$2"
                shift 2
                ;;
            -z|--zone)
                zone="$2"
                shift 2
                ;;
            -h|--help)
                echo "$usage"
                return 0
                ;;
            *)
                echo "Unknown option: $1"
                echo "$usage"
                return 1
                ;;
        esac
    done
    
    # プロジェクトが指定されているかチェック
    if [[ -z "$project" ]]; then
        echo "Error: Project is required."
        echo "$usage"
        return 1
    fi
    
    # ClusterData.json の存在確認
    if ! check-cluster-data-json; then
        return 1
    fi
    
    # プロジェクトの妥当性チェック（JSONファイルに存在するか）
    local project_exists=$(jq -r "has(\"$project\")" "$CLUSTER_DATA_JSON" 2>/dev/null)
    if [[ "$project_exists" != "true" ]]; then
        echo "Error: Project '$project' not found in ClusterData.json"
        echo "Available projects:"
        jq -r 'keys[]' "$CLUSTER_DATA_JSON" 2>/dev/null | sed 's/^/  - /'
        return 1
    fi
    
    # staging環境で本番projectが指定された場合の警告
    local hostname=$(hostname)
    if [[ "$hostname" =~ ^${STAGING_HOSTNAME_PREFIX} ]] && [[ "$project" == "idaas-232202" ]]; then
        echo "\033[31mstaging 環境で本番 project が指定されました. 30秒後に exit 1 します.(Ctrl+Cで停止)\033[0m"
        sleep 30
        return 1
    fi
    
    # GKE v1.25+ 対応
    # https://cloud.google.com/blog/products/containers-kubernetes/kubectl-auth-changes-in-gke
    export USE_GKE_GCLOUD_AUTH_PLUGIN=True
    
    # クラスタが指定されていない場合、デフォルトを使用
    if [[ -z "$cluster" ]]; then
        cluster=$(get-sog-default-cluster "$project")
        if [[ $? -ne 0 ]]; then
            echo "Error: Could not get default cluster for project $project"
            return 1
        fi
        echo "Using default cluster: $cluster"
    fi
    
    # クラスタ情報を取得
    local cluster_info=$(get-sog-cluster-info "$project" "$cluster")
    if [[ $? -ne 0 ]]; then
        echo "Warning: Cluster info not found for $project:$cluster"
        echo "Available clusters for $project:"
        get-sog-cluster-list "$project"
        echo ""
        # クラスタ情報がなくても続行（zone/regionが引数で指定されている場合）
        if [[ -z "$zone" ]] && [[ -z "$region" ]]; then
            echo "Error: Zone or region must be specified for unknown cluster"
            return 1
        fi
    else
        # zone/region情報を抽出
        if [[ -z "$zone" ]]; then
            zone=$(extract-location-info "$cluster_info" "zone")
        fi
        if [[ -z "$region" ]]; then
            region=$(extract-location-info "$cluster_info" "region")
        fi
    fi
    
    # gcloud configuration の確認と作成
    local config_list=$(gcloud config configurations list 2>/dev/null)
    local create_configuration=false
    
    if ! echo "$config_list" | grep -q "^${project}"; then
        create_configuration=true
    fi
    
    if $create_configuration; then
        echo "Creating new gcloud configuration for $project..."
        gcloud config configurations create "$project"
        gcloud config set project "$project"
        gcloud auth login
    fi
    
    # configuration を有効化
    echo "Activating gcloud configuration: $project"
    gcloud config configurations activate "$project"
    
    # クラスタに接続
    if [[ -n "$region" ]]; then
        echo "Connecting to cluster $cluster in region $region..."
        gcloud container clusters get-credentials "$cluster" --region "$region" --project "$project"
    elif [[ -n "$zone" ]]; then
        echo "Connecting to cluster $cluster in zone $zone..."
        gcloud container clusters get-credentials "$cluster" --zone "$zone" --project "$project"
    else
        echo "\033[33mWarning: Could not get clusters region/zone info. Cluster credentials not changed.\033[0m"
        return 1
    fi
    
    # 接続成功を確認
    if [[ $? -eq 0 ]]; then
        echo "\033[32m✓ Successfully connected to $cluster in $project\033[0m"
        echo ""
        echo "Current context:"
        kubectl config current-context
        echo ""
        echo "Cluster info:"
        kubectl cluster-info | head -n 3
    else
        echo "\033[31m✗ Failed to connect to cluster\033[0m"
        return 1
    fi
}

# エイリアス設定（短縮形）
alias cgcp='connect-soliton-gcp-cluster'

# プロジェクト別エイリアスを動的に生成
# 使用可能なプロジェクトのみエイリアスを作成
if check-cluster-data-json 2>/dev/null; then
    # よく使うプロジェクトのエイリアスを定義
    local common_aliases=(
        "idaas-dev:cgcp-dev"
        "idaas-232202:cgcp-prod"
        "idaas-feature:cgcp-feature"
        "gyutan-lab:cgcp-lab"
    )
    
    for alias_def in "${common_aliases[@]}"; do
        local proj="${alias_def%%:*}"
        local alias_name="${alias_def##*:}"
        local exists=$(jq -r "has(\"$proj\")" "$CLUSTER_DATA_JSON" 2>/dev/null)
        if [[ "$exists" == "true" ]]; then
            alias "$alias_name"="connect-soliton-gcp-cluster -p $proj"
        fi
    done
fi

# ================================================================================
# 補助関数: クラスタ一覧表示
# ================================================================================

list-soliton-gcp-clusters() {
    local project=$1
    
    if [[ -z "$project" ]]; then
        if ! check-cluster-data-json; then
            return 1
        fi
        
        echo "Usage: list-soliton-gcp-clusters PROJECT"
        echo ""
        echo "Available projects (from ClusterData.json):"
        jq -r 'keys[]' "$CLUSTER_DATA_JSON" 2>/dev/null | sed 's/^/  - /'
        return 1
    fi
    
    if ! check-cluster-data-json; then
        return 1
    fi
    
    # JSONから読み込み
    load-cluster-data-from-json "$project"
    
    echo "Clusters in $project:"
    get-sog-cluster-list "$project" | while read cluster; do
        local info=$(get-sog-cluster-info "$project" "$cluster")
        local is_default=""
        if [[ "$cluster" == "${DEFAULT_CLUSTER[$project]}" ]]; then
            is_default=" [DEFAULT]"
        fi
        echo "  - $cluster ($info)$is_default"
    done
}

alias lsgcp='list-soliton-gcp-clusters'

# ================================================================================
# 初期化メッセージ
# ================================================================================

echo "Soliton GCP Cluster Functions loaded."
if [[ -f "$CLUSTER_DATA_JSON" ]]; then
    echo "Using ClusterData.json: $CLUSTER_DATA_JSON"
else
    echo "\033[33mWarning: ClusterData.json not found at: $CLUSTER_DATA_JSON\033[0m"
    echo "Set SOLITON_CLUSTER_DATA_JSON environment variable to specify the path"
fi
echo "Use 'connect-soliton-gcp-cluster --help' for usage information."
echo "Short aliases: cgcp, lsgcp"
