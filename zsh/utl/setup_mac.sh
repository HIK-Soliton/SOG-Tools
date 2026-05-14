#!/bin/bash
# GCP Cluster Functions - Setup Script for Mac
# 
# このスクリプトは、gcp_cluster_functions.zsh を Mac の zsh 環境にセットアップします

set -e  # エラーが発生したら終了

# カラー出力用
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== GCP Cluster Functions Setup for Mac ===${NC}\n"

# ================================================================================
# 前提条件のチェック
# ================================================================================

echo -e "${BLUE}[1/5] 前提条件のチェック...${NC}"

# Homebrewのチェック
if ! command -v brew &> /dev/null; then
    echo -e "${RED}✗ Homebrew がインストールされていません${NC}"
    echo "Homebrew をインストールしてください: https://brew.sh/ja/"
    exit 1
else
    echo -e "${GREEN}✓ Homebrew がインストールされています${NC}"
fi

# gcloud CLI のチェック
if ! command -v gcloud &> /dev/null; then
    echo -e "${YELLOW}⚠ gcloud CLI がインストールされていません${NC}"
    read -p "gcloud CLI をインストールしますか？ (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "gcloud CLI をインストール中..."
        brew install --cask google-cloud-sdk
    else
        echo -e "${RED}gcloud CLI は必須です。手動でインストールしてください。${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}✓ gcloud CLI がインストールされています${NC}"
fi

# kubectl のチェック
if ! command -v kubectl &> /dev/null; then
    echo -e "${YELLOW}⚠ kubectl がインストールされていません${NC}"
    read -p "kubectl をインストールしますか？ (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "kubectl をインストール中..."
        brew install kubectl
    else
        echo -e "${RED}kubectl は必須です。手動でインストールしてください。${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}✓ kubectl がインストールされています${NC}"
fi

# jq のチェック
if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}⚠ jq がインストールされていません${NC}"
    read -p "jq をインストールしますか？ (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "jq をインストール中..."
        brew install jq
    else
        echo -e "${RED}jq は必須です（JSON解析用）。手動でインストールしてください。${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}✓ jq がインストールされています${NC}"
fi

# gke-gcloud-auth-plugin のチェック
echo -e "\n${BLUE}gke-gcloud-auth-plugin の確認中...${NC}"
if ! gcloud components list 2>/dev/null | grep -q "gke-gcloud-auth-plugin.*Installed"; then
    echo -e "${YELLOW}⚠ gke-gcloud-auth-plugin がインストールされていません${NC}"
    read -p "gke-gcloud-auth-plugin をインストールしますか？ (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "gke-gcloud-auth-plugin をインストール中..."
        gcloud components install gke-gcloud-auth-plugin
    else
        echo -e "${RED}gke-gcloud-auth-plugin は GKE v1.25+ で必須です。${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}✓ gke-gcloud-auth-plugin がインストールされています${NC}"
fi

# ================================================================================
# スクリプトのコピー
# ================================================================================

echo -e "\n${BLUE}[2/5] スクリプトファイルのコピー...${NC}"

# ホームディレクトリに .soliton-tools ディレクトリを作成
TOOLS_DIR="$HOME/.soliton-tools"
if [ ! -d "$TOOLS_DIR" ]; then
    mkdir -p "$TOOLS_DIR"
    echo -e "${GREEN}✓ ディレクトリを作成しました: $TOOLS_DIR${NC}"
else
    echo -e "${GREEN}✓ ディレクトリは既に存在します: $TOOLS_DIR${NC}"
fi

# スクリプトファイルの場所を確認
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_FILE="$SCRIPT_DIR/gcp_cluster_functions.zsh"

if [ ! -f "$SOURCE_FILE" ]; then
    echo -e "${RED}✗ gcp_cluster_functions.zsh が見つかりません${NC}"
    echo "場所: $SOURCE_FILE"
    exit 1
fi

# スクリプトをコピー
cp "$SOURCE_FILE" "$TOOLS_DIR/"
echo -e "${GREEN}✓ スクリプトをコピーしました: $TOOLS_DIR/gcp_cluster_functions.zsh${NC}"

# 設定サンプルもコピー（存在する場合）
if [ -f "$SCRIPT_DIR/gcp_cluster_config_sample.zsh" ]; then
    cp "$SCRIPT_DIR/gcp_cluster_config_sample.zsh" "$TOOLS_DIR/"
    echo -e "${GREEN}✓ 設定サンプルをコピーしました: $TOOLS_DIR/gcp_cluster_config_sample.zsh${NC}"
fi

# ================================================================================
# .zshrc への追加
# ================================================================================

echo -e "\n${BLUE}[3/5] .zshrc の設定...${NC}"

ZSHRC="$HOME/.zshrc"
SOURCE_LINE="source $TOOLS_DIR/gcp_cluster_functions.zsh"

# バックアップを作成
if [ -f "$ZSHRC" ]; then
    cp "$ZSHRC" "$ZSHRC.backup.$(date +%Y%m%d_%H%M%S)"
    echo -e "${GREEN}✓ .zshrc のバックアップを作成しました${NC}"
fi

# 既に追加されているかチェック
if grep -q "gcp_cluster_functions.zsh" "$ZSHRC" 2>/dev/null; then
    echo -e "${YELLOW}⚠ .zshrc には既に gcp_cluster_functions.zsh の読み込み設定があります${NC}"
    read -p "上書きしますか？ (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "スキップしました"
    else
        # 既存の行を削除して新しい行を追加
        sed -i.tmp '/gcp_cluster_functions.zsh/d' "$ZSHRC"
        echo "" >> "$ZSHRC"
        echo "# Soliton GCP Cluster Functions" >> "$ZSHRC"
        echo "$SOURCE_LINE" >> "$ZSHRC"
        echo -e "${GREEN}✓ .zshrc を更新しました${NC}"
    fi
else
    # 新規追加
    echo "" >> "$ZSHRC"
    echo "# Soliton GCP Cluster Functions" >> "$ZSHRC"
    echo "$SOURCE_LINE" >> "$ZSHRC"
    echo -e "${GREEN}✓ .zshrc に追加しました${NC}"
fi

# ================================================================================
# クラスタ情報のカスタマイズ
# ================================================================================

echo -e "\n${BLUE}[4/5] ClusterData.json の設定...${NC}"

# ClusterData.json の場所を確認
if [[ -f "$HOME/ClusterData.json" ]]; then
    echo -e "${GREEN}✓ ClusterData.json が見つかりました: $HOME/ClusterData.json${NC}"
else
    echo -e "${YELLOW}⚠ ClusterData.json が見つかりません: $HOME/ClusterData.json${NC}"
    echo ""
    read -p "ClusterData.json のパスを指定しますか？ (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        read -p "ClusterData.json のフルパスを入力してください: " cluster_data_path
        if [[ -f "$cluster_data_path" ]]; then
            echo -e "${GREEN}✓ ファイルを確認しました: $cluster_data_path${NC}"
            echo ""
            echo ".zshrc に環境変数を設定します..."
            echo "" >> "$ZSHRC"
            echo "# ClusterData.json の場所" >> "$ZSHRC"
            echo "export SOLITON_CLUSTER_DATA_JSON=\"$cluster_data_path\"" >> "$ZSHRC"
            echo -e "${GREEN}✓ 環境変数を設定しました${NC}"
        else
            echo -e "${RED}✗ ファイルが見つかりません: $cluster_data_path${NC}"
            echo "後で手動で設定してください："
            echo "  export SOLITON_CLUSTER_DATA_JSON=\"/path/to/ClusterData.json\""
        fi
    else
        echo "ClusterData.json を $HOME/ にコピーするか、"
        echo "環境変数 SOLITON_CLUSTER_DATA_JSON でパスを指定してください"
    fi
fi

echo ""
echo "スクリプトは以下のクラスタ情報を参照します："
echo "  - デフォルト: \$HOME/ClusterData.json"
echo "  - カスタム: \$SOLITON_CLUSTER_DATA_JSON"

# ================================================================================
# セットアップ完了
# ================================================================================

echo -e "\n${BLUE}[5/5] セットアップ完了${NC}"
echo -e "${GREEN}✓ すべてのセットアップが完了しました！${NC}\n"

echo "次のステップ："
echo "1. 新しいターミナルを開くか、以下のコマンドで設定を再読み込み："
echo -e "   ${YELLOW}source ~/.zshrc${NC}"
echo ""
echo "2. 関数を使ってクラスタに接続："
echo -e "   ${YELLOW}connect-soliton-gcp-cluster -p idaas-dev${NC}"
echo -e "   ${YELLOW}cgcp-dev${NC}  # エイリアス"
echo ""
echo "3. ヘルプを表示："
echo -e "   ${YELLOW}connect-soliton-gcp-cluster --help${NC}"
echo ""
echo "4. クラスタ一覧を表示："
echo -e "   ${YELLOW}list-soliton-gcp-clusters idaas-dev${NC}"
echo ""

echo "詳細なドキュメントは GCP_CLUSTER_README.md を参照してください。"
echo ""

read -p "今すぐ設定を再読み込みしますか？ (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "設定を再読み込み中..."
    # 現在のシェルで source を実行
    source "$TOOLS_DIR/gcp_cluster_functions.zsh"
    echo -e "${GREEN}✓ 設定が再読み込みされました${NC}"
    echo ""
    echo "試してみましょう："
    echo -e "${YELLOW}connect-soliton-gcp-cluster --help${NC}"
fi

echo ""
echo -e "${GREEN}セットアップスクリプトを終了します。${NC}"
