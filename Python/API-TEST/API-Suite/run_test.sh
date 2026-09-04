#!/bin/bash

# OneGate API Suite リグレッションテスト実行スクリプト
# Mac/Linux用

set -e

# 色の定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}OneGate API Suite リグレッションテスト${NC}"
echo "========================================"

# 引数チェック
if [ $# -lt 3 ]; then
    echo -e "${RED}エラー: 引数が不足しています${NC}"
    echo "使用方法: $0 <API_KEY> <TENANT> <PASSWORD> [baseline|compare|normal]"
    echo ""
    echo "例:"
    echo "  $0 your-api-key your-tenant your-password baseline  # ベースライン保存"
    echo "  $0 your-api-key your-tenant your-password compare   # リグレッションテスト"
    echo "  $0 your-api-key your-tenant your-password normal    # 通常実行"
    exit 1
fi

API_KEY=$1
TENANT=$2
PASSWORD=$3
MODE=${4:-normal}

# Python 3が利用可能かチェック
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}エラー: Python 3がインストールされていません${NC}"
    exit 1
fi

# 依存パッケージのインストールチェック
if ! python3 -c "import requests" &> /dev/null; then
    echo -e "${YELLOW}依存パッケージをインストールしています...${NC}"
    pip3 install -r requirements.txt
fi

# テスト実行
case $MODE in
    baseline)
        echo -e "${YELLOW}ベースラインを保存します...${NC}"
        python3 api_regression_test.py \
            --api-key "$API_KEY" \
            --tenant "$TENANT" \
            --password "$PASSWORD" \
            --save-baseline
        ;;
    compare)
        echo -e "${YELLOW}リグレッションテストを実行します...${NC}"
        python3 api_regression_test.py \
            --api-key "$API_KEY" \
            --tenant "$TENANT" \
            --password "$PASSWORD" \
            --compare
        ;;
    normal)
        echo -e "${YELLOW}通常テストを実行します...${NC}"
        python3 api_regression_test.py \
            --api-key "$API_KEY" \
            --tenant "$TENANT" \
            --password "$PASSWORD"
        ;;
    *)
        echo -e "${RED}エラー: 無効なモード: $MODE${NC}"
        echo "有効なモード: baseline, compare, normal"
        exit 1
        ;;
esac

echo ""
echo -e "${GREEN}完了しました${NC}"
