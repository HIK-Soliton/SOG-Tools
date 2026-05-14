#!/bin/zsh
# ClusterData.json の内容を確認するユーティリティスクリプト

# ClusterData.json のパス
CLUSTER_DATA_JSON="${SOLITON_CLUSTER_DATA_JSON:-$HOME/ClusterData.json}"

# カラー出力用
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== ClusterData.json 確認ツール ===${NC}\n"

# ファイルの存在確認
if [[ ! -f "$CLUSTER_DATA_JSON" ]]; then
    echo -e "${RED}✗ ClusterData.json が見つかりません: $CLUSTER_DATA_JSON${NC}"
    echo ""
    echo "環境変数 SOLITON_CLUSTER_DATA_JSON でパスを指定できます："
    echo "  export SOLITON_CLUSTER_DATA_JSON=\"/path/to/ClusterData.json\""
    exit 1
fi

echo -e "${GREEN}✓ ClusterData.json: $CLUSTER_DATA_JSON${NC}\n"

# jq の確認
if ! command -v jq &> /dev/null; then
    echo -e "${RED}✗ jq コマンドがインストールされていません${NC}"
    echo "インストール方法: brew install jq"
    exit 1
fi

# ファイル情報
echo -e "${CYAN}[ファイル情報]${NC}"
ls -lh "$CLUSTER_DATA_JSON"
echo ""

# プロジェクト一覧
echo -e "${CYAN}[プロジェクト一覧]${NC}"
jq -r 'keys[]' "$CLUSTER_DATA_JSON" | while read project; do
    echo "  - $project"
done
echo ""

# 詳細表示オプション
if [[ "$1" == "-v" ]] || [[ "$1" == "--verbose" ]]; then
    echo -e "${CYAN}[プロジェクト詳細]${NC}"
    
    jq -r 'keys[]' "$CLUSTER_DATA_JSON" | while read project; do
        echo -e "\n${YELLOW}プロジェクト: $project${NC}"
        
        # クラスタ一覧と location 情報を取得
        jq -r ".\"$project\" | to_entries[] | \"\(.key)\t\(.value.region // \"\")\t\(.value.zone // \"\")\"" "$CLUSTER_DATA_JSON" | \
        while IFS=$'\t' read -r cluster region zone; do
            if [[ -n "$region" && "$region" != "null" ]]; then
                location="region:$region"
            elif [[ -n "$zone" && "$zone" != "null" ]]; then
                location="zone:$zone"
            else
                location="(location not defined)"
            fi
            echo "  - $cluster ($location)"
        done
    done
    echo ""
fi

# 特定プロジェクトの情報表示
if [[ -n "$2" ]]; then
    PROJECT=$2
    echo -e "${CYAN}[プロジェクト '$PROJECT' の詳細]${NC}"
    
    # プロジェクトの存在確認
    exists=$(jq -r "has(\"$PROJECT\")" "$CLUSTER_DATA_JSON")
    if [[ "$exists" != "true" ]]; then
        echo -e "${RED}✗ プロジェクト '$PROJECT' が見つかりません${NC}"
        exit 1
    fi
    
    # クラスタ情報を表示
    jq -r ".\"$PROJECT\" | to_entries[] | \"\(.key)\t\(.value.region // \"\")\t\(.value.zone // \"\")\"" "$CLUSTER_DATA_JSON" | \
    while IFS=$'\t' read -r cluster region zone; do
        if [[ -n "$region" && "$region" != "null" ]]; then
            location="region:$region"
        elif [[ -n "$zone" && "$zone" != "null" ]]; then
            location="zone:$zone"
        else
            location="(location not defined)"
        fi
        echo "  - $cluster ($location)"
    done
    echo ""
    
    # デフォルトクラスタ（最初のクラスタ）を表示
    default_cluster=$(jq -r ".\"$PROJECT\" | keys[0]" "$CLUSTER_DATA_JSON")
    echo -e "デフォルトクラスタ: ${GREEN}$default_cluster${NC}"
    echo ""
fi

# 使い方
if [[ "$1" != "-v" ]] && [[ "$1" != "--verbose" ]]; then
    echo -e "${CYAN}[使い方]${NC}"
    echo "詳細表示: $0 -v"
    echo "特定プロジェクトの表示: $0 -v PROJECT_NAME"
    echo ""
    echo "例："
    echo "  $0 -v idaas-dev"
fi

# JSON の妥当性確認
echo -e "${CYAN}[JSON妥当性チェック]${NC}"
if jq empty "$CLUSTER_DATA_JSON" 2>/dev/null; then
    echo -e "${GREEN}✓ JSON形式は正しいです${NC}"
else
    echo -e "${RED}✗ JSON形式にエラーがあります${NC}"
    echo ""
    echo "エラー詳細:"
    jq empty "$CLUSTER_DATA_JSON"
    exit 1
fi
