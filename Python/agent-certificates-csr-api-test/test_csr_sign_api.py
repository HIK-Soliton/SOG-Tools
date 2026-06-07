#!/usr/bin/env python3
"""
CSR署名APIテストツール

エージェント用API－証明書発行(CSR署名)をテストするためのスクリプト
"""

import os
import sys
import argparse
import requests
from pathlib import Path
from typing import Optional
from dotenv import load_dotenv


class CSRSignAPITester:
    """CSR署名APIテストクラス"""
    
    def __init__(self, base_url: str, username: str, password: str):
        """
        初期化
        
        Args:
            base_url: APIのベースURL（例: https://example.com）
            username: サイト管理者ユーザー名
            password: サイト管理者パスワード
        """
        self.base_url = base_url.rstrip('/')
        self.auth = (username, password)
        self.session = requests.Session()
        self.session.auth = self.auth
    
    def sign_certificate(
        self,
        csr_file_path: str,
        cert_type: str = "server",
        output_format: str = "pem",
        encoding: Optional[str] = None,
        valid_days: Optional[int] = None
    ) -> bytes:
        """
        CSRファイルに署名して証明書を取得
        
        Args:
            csr_file_path: CSRファイルのパス
            cert_type: 証明書タイプ（"server" または "client"）
            output_format: 出力形式（"pem", "der", または "" (デフォルト)）
            encoding: CSRファイルのエンコード方式（"PEM" または "DER"、省略可）
            valid_days: 証明書の有効期限（日数）
        
        Returns:
            証明書データ（バイナリ）
        
        Raises:
            ValueError: パラメータが不正な場合
            FileNotFoundError: CSRファイルが見つからない場合
            requests.HTTPError: API呼び出しが失敗した場合
        """
        # パラメータ検証
        if cert_type not in ["server", "client"]:
            raise ValueError(f"cert_type must be 'server' or 'client', got: {cert_type}")
        
        if output_format not in ["", "pem", "der"]:
            raise ValueError(f"output_format must be '', 'pem' or 'der', got: {output_format}")
        
        # CSRファイルの読み込み
        csr_path = Path(csr_file_path)
        if not csr_path.exists():
            raise FileNotFoundError(f"CSR file not found: {csr_file_path}")
        
        with open(csr_path, 'rb') as f:
            csr_data = f.read()
        
        # エンドポイント構築
        endpoint_suffix = f".{output_format}" if output_format else ""
        endpoint = f"{self.base_url}/icon/services/seap/onpre/agent/certificates/csr/{cert_type}/sign{endpoint_suffix}"
        
        # リクエストボディ構築
        files = {
            'csr': (csr_path.name, csr_data, 'application/octet-stream')
        }
        
        data = {}
        if encoding:
            data['encoding'] = encoding
        if valid_days is not None:
            data['validDays'] = str(valid_days)
        
        # API呼び出し
        print(f"Requesting: {endpoint}")
        print(f"Parameters: {data}")
        
        response = self.session.post(
            endpoint,
            files=files,
            data=data,
            verify=False  # SSL証明書検証を無効化（テスト環境用）
        )
        
        # エラーチェック
        if response.status_code != 200:
            error_msg = f"API call failed: HTTP {response.status_code}"
            try:
                error_detail = response.json()
                error_msg += f"\nError: {error_detail}"
            except:
                error_msg += f"\nResponse: {response.text}"
            raise requests.HTTPError(error_msg)
        
        return response.content
    
    def save_certificate(self, cert_data: bytes, output_path: str):
        """
        証明書をファイルに保存
        
        Args:
            cert_data: 証明書データ
            output_path: 出力ファイルパス
        """
        output_file = Path(output_path)
        output_file.parent.mkdir(parents=True, exist_ok=True)
        
        with open(output_file, 'wb') as f:
            f.write(cert_data)
        
        print(f"Certificate saved: {output_path}")


def main():
    """メイン関数"""
    # 引数解析
    parser = argparse.ArgumentParser(
        description="CSR署名APIテストツール",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
使用例:
  # サーバー証明書（PEM形式）を取得
  python test_csr_sign_api.py -c server.csr -t server -f pem -o server.crt
  
  # クライアント証明書（DER形式、有効期限1825日）を取得
  python test_csr_sign_api.py -c client.csr -t client -f der -v 1825 -o client.crt
  
  # .envファイルから環境変数を読み込む
  python test_csr_sign_api.py -c server.csr -o server.crt
        """
    )
    
    parser.add_argument(
        '-c', '--csr',
        required=True,
        help='CSRファイルのパス'
    )
    
    parser.add_argument(
        '-t', '--type',
        choices=['server', 'client'],
        default='server',
        help='証明書タイプ（デフォルト: server）'
    )
    
    parser.add_argument(
        '-f', '--format',
        choices=['', 'pem', 'der'],
        default='pem',
        help='出力形式（デフォルト: pem）'
    )
    
    parser.add_argument(
        '-e', '--encoding',
        choices=['PEM', 'DER'],
        help='CSRファイルのエンコード方式（省略可）'
    )
    
    parser.add_argument(
        '-v', '--valid-days',
        type=int,
        help='証明書の有効期限（日数）。サーバー: 1-825、クライアント: 1-3650'
    )
    
    parser.add_argument(
        '-o', '--output',
        required=True,
        help='出力ファイルパス'
    )
    
    parser.add_argument(
        '-u', '--url',
        help='APIベースURL（環境変数API_BASE_URLで指定可）'
    )
    
    parser.add_argument(
        '--username',
        help='サイト管理者ユーザー名（環境変数API_USERNAMEで指定可）'
    )
    
    parser.add_argument(
        '--password',
        help='サイト管理者パスワード（環境変数API_PASSWORDで指定可）'
    )
    
    args = parser.parse_args()
    
    # 環境変数の読み込み
    load_dotenv()
    
    # 認証情報の取得
    base_url = args.url or os.getenv('API_BASE_URL')
    username = args.username or os.getenv('API_USERNAME')
    password = args.password or os.getenv('API_PASSWORD')
    
    # 必須パラメータチェック
    if not base_url:
        print("Error: API_BASE_URL is required. Set it in .env file or use --url option.", file=sys.stderr)
        sys.exit(1)
    
    if not username:
        print("Error: API_USERNAME is required. Set it in .env file or use --username option.", file=sys.stderr)
        sys.exit(1)
    
    if not password:
        print("Error: API_PASSWORD is required. Set it in .env file or use --password option.", file=sys.stderr)
        sys.exit(1)
    
    # SSL警告を抑制（テスト環境用）
    import urllib3
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    
    try:
        # APIテスター初期化
        tester = CSRSignAPITester(base_url, username, password)
        
        # 証明書署名
        cert_data = tester.sign_certificate(
            csr_file_path=args.csr,
            cert_type=args.type,
            output_format=args.format,
            encoding=args.encoding,
            valid_days=args.valid_days
        )
        
        # 証明書保存
        tester.save_certificate(cert_data, args.output)
        
        print(f"\n✓ Successfully signed and saved certificate!")
        print(f"  CSR: {args.csr}")
        print(f"  Type: {args.type}")
        print(f"  Format: {args.format or 'default'}")
        print(f"  Output: {args.output}")
        
    except Exception as e:
        print(f"\n✗ Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
