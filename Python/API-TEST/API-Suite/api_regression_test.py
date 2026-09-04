#!/usr/bin/env python3
"""
OneGate API Suite リグレッションテストツール

バージョンアップ前後でAPI動作を確認し、差異を検出します。
Windows/Mac/Linux で動作します。

使用方法:
    # ベースライン取得（バージョンアップ前）
    python api_regression_test.py --api-key YOUR_API_KEY --tenant YOUR_TENANT --password YOUR_PASSWORD --save-baseline

    # リグレッションテスト（バージョンアップ後）
    python api_regression_test.py --api-key YOUR_API_KEY --tenant YOUR_TENANT --password YOUR_PASSWORD --compare

    # 通常実行（比較なし）
    python api_regression_test.py --api-key YOUR_API_KEY --tenant YOUR_TENANT --password YOUR_PASSWORD
"""

import argparse
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Any, Tuple
import requests
from requests_toolbelt.multipart.encoder import MultipartEncoder
import difflib
from colorama import init, Fore, Style

# coloramaの初期化（Windows対応）
init(autoreset=True)


class Colors:
    """ターミナル出力用カラー定義"""
    HEADER = Fore.CYAN
    SUCCESS = Fore.GREEN
    WARNING = Fore.YELLOW
    ERROR = Fore.RED
    INFO = Fore.WHITE
    RESET = Style.RESET_ALL


class APITestResult:
    """APIテスト結果を格納するクラス"""
    def __init__(self, name: str, method: str, path: str):
        self.name = name
        self.method = method
        self.path = path
        self.status_code: Optional[int] = None
        self.response_data: Optional[Dict] = None
        self.error_message: Optional[str] = None
        self.success: bool = False
        self.execution_time: float = 0.0

    def to_dict(self) -> Dict:
        """辞書形式に変換"""
        return {
            'name': self.name,
            'method': self.method,
            'path': self.path,
            'status_code': self.status_code,
            'response_data': self.response_data,
            'error_message': self.error_message,
            'success': self.success,
            'execution_time': self.execution_time
        }


class OneGateAPITester:
    """OneGate API テスター"""
    
    ENCODING_ID = {
        'sjis': '20',
        'utf8': '30'
    }
    
    IMPORT_TYPE_ID = {
        'add': '1',
        'modify': '2',
        'delete': '3'
    }
    
    def __init__(self, api_key: str, tenant: str, password: str, base_dir: Optional[Path] = None):
        """
        初期化
        
        Args:
            api_key: APIキー
            tenant: テナント名
            password: テスト用パスワード
            base_dir: スクリプトのベースディレクトリ
        """
        self.api_key = api_key
        self.tenant = tenant
        self.password = password
        self.base_uri = f"https://{tenant}.ids-dev.solitonsys.jp/icon/services/seap/api"
        self.headers = {'Authorization': f'Bearer {api_key}'}
        self.boundary = "680dd7c4-82ea-4e5e-8b84-245e5b5fc0e0"
        
        # ディレクトリ設定
        if base_dir is None:
            base_dir = Path(__file__).parent
        self.base_dir = base_dir
        self.data_dir = base_dir / 'data'
        self.results_dir = base_dir / 'results'
        self.results_dir.mkdir(exist_ok=True)
        
        # テスト結果格納
        self.test_results: List[APITestResult] = []
    
    def _print_header(self, text: str):
        """ヘッダー出力"""
        print(f"\n{Colors.HEADER}{'='*60}")
        print(f"{text}")
        print(f"{'='*60}{Colors.RESET}")
    
    def _print_test_name(self, name: str):
        """テスト名出力"""
        print(f"\n{Colors.WARNING}▶ {name}{Colors.RESET}")
    
    def _print_success(self, message: str):
        """成功メッセージ出力"""
        print(f"{Colors.SUCCESS}✓ {message}{Colors.RESET}")
    
    def _print_error(self, message: str):
        """エラーメッセージ出力"""
        print(f"{Colors.ERROR}✗ {message}{Colors.RESET}")
    
    def invoke_api(self, 
                   path: str, 
                   method: str = 'GET',
                   content_type: Optional[str] = None,
                   data: Optional[bytes] = None,
                   params: Optional[Dict] = None) -> Tuple[Optional[requests.Response], Optional[str]]:
        """
        API呼び出し
        
        Returns:
            (response, error_message) のタプル
        """
        url = f"{self.base_uri}{path}"
        headers = self.headers.copy()
        
        if content_type:
            headers['Content-Type'] = content_type
        
        try:
            response = requests.request(
                method=method,
                url=url,
                headers=headers,
                data=data,
                params=params,
                timeout=30
            )
            return response, None
        except requests.exceptions.RequestException as e:
            return None, str(e)
    
    def invoke_csv_import(self,
                         path: str,
                         csv_file_path: Path,
                         encoding_id: Optional[str] = None,
                         specific_type: Optional[str] = None) -> Tuple[Optional[requests.Response], Optional[str]]:
        """
        CSVインポートAPI呼び出し
        """
        url = f"{self.base_uri}{path}"
        
        fields = {}
        
        # エンコーディングIDまたはtype指定
        if specific_type:
            fields['type'] = specific_type
        elif encoding_id:
            fields['encodingId'] = encoding_id
        
        # ファイル追加
        with open(csv_file_path, 'rb') as f:
            fields['file'] = (csv_file_path.name, f, 'application/octet-stream')
            
            multipart_data = MultipartEncoder(fields=fields, boundary=self.boundary)
            
            headers = self.headers.copy()
            headers['Content-Type'] = multipart_data.content_type
            
            try:
                response = requests.post(
                    url=url,
                    headers=headers,
                    data=multipart_data,
                    timeout=30
                )
                return response, None
            except requests.exceptions.RequestException as e:
                return None, str(e)
    
    def test_employee_apis(self) -> bool:
        """利用者管理APIテスト"""
        self._print_header("利用者管理APIテスト")
        
        # 利用者登録
        self._print_test_name("利用者登録")
        result = APITestResult("利用者登録", "POST", "/employee")
        start_time = time.time()
        
        # JSONファイル読み込み
        json_file = self.data_dir / 'OneGateUser_add.json'
        if not json_file.exists():
            self._print_error(f"ファイルが見つかりません: {json_file}")
            return False
        
        with open(json_file, 'r', encoding='utf-8') as f:
            body = json.load(f)
        
        # パスワード置換
        for attr in body.get('defAttributes', []):
            if attr.get('attributeCode') == 'DEF_ATTR_0001':
                username = attr['value'][0]['value']
            if attr.get('attributeCode') == 'DEF_ATTR_0002':
                attr['value'][0]['value'] = self.password
        
        body_bytes = json.dumps(body, ensure_ascii=False).encode('utf-8')
        response, error = self.invoke_api(
            '/employee',
            method='POST',
            content_type='application/json',
            data=body_bytes
        )
        
        result.execution_time = time.time() - start_time
        
        if error:
            result.error_message = error
            self._print_error(f"エラー: {error}")
            self.test_results.append(result)
            return False
        
        result.status_code = response.status_code
        
        try:
            response_json = response.json()
            result.response_data = response_json
            
            if response_json.get('status') == 'failed':
                error_info = response_json.get('errorInfo', {})
                error_msg = f"[{error_info.get('errorCode')}] {error_info.get('errorMessage')}"
                result.error_message = error_msg
                self._print_error(error_msg)
            else:
                result.success = True
                self._print_success(f"成功: {response_json.get('status')}")
        except json.JSONDecodeError:
            result.error_message = "JSONデコードエラー"
            self._print_error("JSONデコードエラー")
        
        self.test_results.append(result)
        
        if not result.success:
            return False
        
        # 利用者検索
        self._print_test_name("利用者検索")
        result = APITestResult("利用者検索", "GET", f"/employee?key=name&value={username}")
        start_time = time.time()
        
        response, error = self.invoke_api(
            '/employee',
            params={'key': 'name', 'value': username}
        )
        
        result.execution_time = time.time() - start_time
        
        if error:
            result.error_message = error
            self._print_error(f"エラー: {error}")
            self.test_results.append(result)
            return False
        
        result.status_code = response.status_code
        
        try:
            response_json = response.json()
            result.response_data = response_json
            
            if response_json.get('status') == 'failed':
                error_info = response_json.get('errorInfo', {})
                error_msg = f"[{error_info.get('errorCode')}] {error_info.get('errorMessage')}"
                result.error_message = error_msg
                self._print_error(error_msg)
                self.test_results.append(result)
                return False
            
            result.success = True
            self._print_success(f"成功: {response_json.get('status')}")
            
            # 社員ID取得
            employee_id = response_json.get('responseBody', {}).get('results', {}).get('employeeId')
            
            if not employee_id:
                self._print_error("社員IDが取得できませんでした")
                return False
            
        except json.JSONDecodeError:
            result.error_message = "JSONデコードエラー"
            self._print_error("JSONデコードエラー")
            self.test_results.append(result)
            return False
        
        self.test_results.append(result)
        
        # 社員IDが必要なAPI
        employee_apis = [
            {
                'name': '利用者情報取得',
                'path': f'/employee/{employee_id}',
                'method': 'GET',
                'content_type': 'text/plain; charset=utf-8'
            },
            {
                'name': '利用者更新',
                'path': f'/employee/{employee_id}',
                'method': 'PUT',
                'content_type': 'application/json',
                'data_file': 'OneGateUser_mod.json'
            },
            {
                'name': '利用者削除',
                'path': f'/employee/{employee_id}',
                'method': 'DELETE',
                'content_type': 'text/plain'
            }
        ]
        
        for api in employee_apis:
            self._print_test_name(api['name'])
            result = APITestResult(api['name'], api['method'], api['path'])
            start_time = time.time()
            
            data = None
            if 'data_file' in api:
                json_file = self.data_dir / api['data_file']
                if json_file.exists():
                    with open(json_file, 'r', encoding='utf-8') as f:
                        data = f.read().encode('utf-8')
            
            response, error = self.invoke_api(
                api['path'],
                method=api['method'],
                content_type=api.get('content_type'),
                data=data
            )
            
            result.execution_time = time.time() - start_time
            
            if error:
                result.error_message = error
                self._print_error(f"エラー: {error}")
            else:
                result.status_code = response.status_code
                try:
                    response_json = response.json()
                    result.response_data = response_json
                    
                    if response_json.get('status') == 'failed':
                        error_info = response_json.get('errorInfo', {})
                        error_msg = f"[{error_info.get('errorCode')}] {error_info.get('errorMessage')}"
                        result.error_message = error_msg
                        self._print_error(error_msg)
                    else:
                        result.success = True
                        self._print_success(f"成功: {response_json.get('status')}")
                except json.JSONDecodeError:
                    result.error_message = "JSONデコードエラー"
                    self._print_error("JSONデコードエラー")
            
            self.test_results.append(result)
        
        return True
    
    def test_employee_import_export(self) -> bool:
        """利用者インポート・エクスポートテスト"""
        self._print_header("利用者インポート・エクスポートテスト")
        
        test_types = [
            {
                'name': '利用者',
                'path': '/employee',
                'csvname': 'OneGateUser.csv',
                'query': f"encodingId={self.ENCODING_ID['sjis']}&key=name&value=oguser"
            },
            {
                'name': 'アプリケーションロール',
                'path': '/employee/role/cloud',
                'csvname': 'OneGateUserCloudServiceRole.csv',
                'query': f"encodingId={self.ENCODING_ID['sjis']}&key=name&value=oguser"
            },
            {
                'name': 'Webアプリ',
                'path': '/employee/role/web',
                'csvname': 'OneGateUserWebSsoRole.csv',
                'query': f"encodingId={self.ENCODING_ID['sjis']}&key=name&value=oguser"
            },
            {
                'name': 'ICカード割り当て',
                'path': '/employee/ic-card',
                'csvname': 'OneGateUserIcCard.csv',
                'query': f"encodingId={self.ENCODING_ID['sjis']}&key=name&value=oguser"
            }
        ]
        
        # インポート
        for test_type in test_types:
            self._print_test_name(f"{test_type['name']}インポート")
            result = APITestResult(
                f"{test_type['name']}インポート",
                "POST",
                f"{test_type['path']}/import"
            )
            start_time = time.time()
            
            csv_file = self.data_dir / test_type['csvname']
            if not csv_file.exists():
                self._print_warning(f"CSVファイルが見つかりません: {csv_file}")
                continue
            
            response, error = self.invoke_csv_import(
                f"{test_type['path']}/import",
                csv_file,
                encoding_id=self.ENCODING_ID['utf8']
            )
            
            result.execution_time = time.time() - start_time
            
            if error:
                result.error_message = error
                self._print_error(f"エラー: {error}")
            else:
                result.status_code = response.status_code
                try:
                    response_json = response.json()
                    result.response_data = response_json
                    
                    if response_json.get('status') == 'failed':
                        error_info = response_json.get('errorInfo', {})
                        error_msg = f"[{error_info.get('errorCode')}] {error_info.get('errorMessage')}"
                        result.error_message = error_msg
                        self._print_error(error_msg)
                    else:
                        result.success = True
                        self._print_success(f"成功: {response_json.get('status')}")
                except json.JSONDecodeError:
                    result.success = True
                    self._print_success(f"ステータスコード: {response.status_code}")
            
            self.test_results.append(result)
        
        # エクスポート
        for test_type in test_types:
            self._print_test_name(f"{test_type['name']}エクスポート")
            result = APITestResult(
                f"{test_type['name']}エクスポート",
                "GET",
                f"{test_type['path']}/export"
            )
            start_time = time.time()
            
            # クエリパラメータを解析
            params = {}
            if test_type.get('query'):
                for param in test_type['query'].split('&'):
                    key, value = param.split('=')
                    params[key] = value
            
            response, error = self.invoke_api(
                f"{test_type['path']}/export",
                params=params
            )
            
            result.execution_time = time.time() - start_time
            
            if error:
                result.error_message = error
                self._print_error(f"エラー: {error}")
            else:
                result.status_code = response.status_code
                result.success = True
                self._print_success(f"ステータスコード: {response.status_code}")
            
            self.test_results.append(result)
        
        return True
    
    def test_password_manager(self) -> bool:
        """PasswordManagerテスト"""
        self._print_header("PasswordManagerテスト")
        
        test_types = [
            {
                'name': 'Webアプリ設定',
                'path': '/settings/password-manager/web-sso',
                'csvname': 'websso.csv',
                'type': self.IMPORT_TYPE_ID['modify']
            },
            {
                'name': 'Webアプリユーザー設定',
                'path': '/settings/password-manager/user-web-sso',
                'csvname': 'userwebsso.csv',
                'type': self.IMPORT_TYPE_ID['modify']
            },
            {
                'name': 'Windowsアプリ設定',
                'path': '/settings/password-manager/win-app-sso',
                'csvname': 'winappsso.csv',
                'type': self.IMPORT_TYPE_ID['modify']
            },
            {
                'name': 'Windowsアプリユーザー設定',
                'path': '/settings/password-manager/user-win-app-sso',
                'csvname': 'userwinappsso.csv',
                'type': self.IMPORT_TYPE_ID['modify']
            },
            {
                'name': 'モバイルアプリ設定',
                'path': '/settings/password-manager/mobile-app-sso',
                'csvname': 'mobileappsso.csv',
                'type': self.IMPORT_TYPE_ID['modify']
            },
            {
                'name': 'モバイルアプリユーザー設定',
                'path': '/settings/password-manager/user-mobile-app-sso',
                'csvname': 'usermobileappsso.csv',
                'type': self.IMPORT_TYPE_ID['modify']
            },
            {
                'name': 'Windowsサインイン設定',
                'path': '/settings/password-manager/desktop-sso',
                'csvname': 'windowsSignin.csv',
                'type': self.IMPORT_TYPE_ID['modify']
            }
        ]
        
        # インポート
        for test_type in test_types:
            self._print_test_name(f"{test_type['name']}インポート")
            result = APITestResult(
                f"{test_type['name']}インポート",
                "POST",
                f"{test_type['path']}/import"
            )
            start_time = time.time()
            
            csv_file = self.data_dir / test_type['csvname']
            if not csv_file.exists():
                self._print_warning(f"CSVファイルが見つかりません: {csv_file}")
                continue
            
            response, error = self.invoke_csv_import(
                f"{test_type['path']}/import",
                csv_file,
                specific_type=test_type['type']
            )
            
            result.execution_time = time.time() - start_time
            
            if error:
                result.error_message = error
                self._print_error(f"エラー: {error}")
            else:
                result.status_code = response.status_code
                try:
                    response_json = response.json()
                    result.response_data = response_json
                    
                    if response_json.get('status') == 'failed':
                        error_info = response_json.get('errorInfo', {})
                        error_msg = f"[{error_info.get('errorCode')}] {error_info.get('errorMessage')}"
                        result.error_message = error_msg
                        self._print_error(error_msg)
                    else:
                        result.success = True
                        self._print_success(f"成功: {response_json.get('status')}")
                except json.JSONDecodeError:
                    result.success = True
                    self._print_success(f"ステータスコード: {response.status_code}")
            
            self.test_results.append(result)
        
        # エクスポート
        for test_type in test_types:
            self._print_test_name(f"{test_type['name']}エクスポート")
            result = APITestResult(
                f"{test_type['name']}エクスポート",
                "GET",
                f"{test_type['path']}/export"
            )
            start_time = time.time()
            
            response, error = self.invoke_api(f"{test_type['path']}/export")
            
            result.execution_time = time.time() - start_time
            
            if error:
                result.error_message = error
                self._print_error(f"エラー: {error}")
            else:
                result.status_code = response.status_code
                result.success = True
                self._print_success(f"ステータスコード: {response.status_code}")
            
            self.test_results.append(result)
        
        return True
    
    def _print_warning(self, message: str):
        """警告メッセージ出力"""
        print(f"{Colors.WARNING}⚠ {message}{Colors.RESET}")
    
    def run_all_tests(self) -> bool:
        """すべてのテストを実行"""
        print(f"\n{Colors.HEADER}{'='*60}")
        print(f"OneGate API Suite リグレッションテスト開始")
        print(f"テナント: {self.tenant}")
        print(f"{'='*60}{Colors.RESET}")
        
        success = True
        
        # 利用者管理
        if not self.test_employee_apis():
            success = False
        
        # 利用者インポート・エクスポート
        self.test_employee_import_export()
        
        # PasswordManager
        self.test_password_manager()
        
        return success
    
    def save_results(self, filename: str = None) -> Path:
        """テスト結果を保存"""
        if filename is None:
            timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
            filename = f"api_test_results_{timestamp}.json"
        
        filepath = self.results_dir / filename
        
        results_data = {
            'timestamp': datetime.now().isoformat(),
            'tenant': self.tenant,
            'total_tests': len(self.test_results),
            'passed': sum(1 for r in self.test_results if r.success),
            'failed': sum(1 for r in self.test_results if not r.success),
            'results': [r.to_dict() for r in self.test_results]
        }
        
        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(results_data, f, ensure_ascii=False, indent=2)
        
        return filepath
    
    def print_summary(self):
        """テスト結果サマリー出力"""
        total = len(self.test_results)
        passed = sum(1 for r in self.test_results if r.success)
        failed = total - passed
        
        print(f"\n{Colors.HEADER}{'='*60}")
        print(f"テスト結果サマリー")
        print(f"{'='*60}{Colors.RESET}")
        print(f"総テスト数: {total}")
        print(f"{Colors.SUCCESS}成功: {passed}{Colors.RESET}")
        if failed > 0:
            print(f"{Colors.ERROR}失敗: {failed}{Colors.RESET}")
        
        if failed > 0:
            print(f"\n{Colors.ERROR}失敗したテスト:{Colors.RESET}")
            for result in self.test_results:
                if not result.success:
                    print(f"  - {result.name}: {result.error_message}")


class RegressionComparator:
    """リグレッション比較クラス"""
    
    def __init__(self, baseline_file: Path, current_file: Path):
        """
        初期化
        
        Args:
            baseline_file: ベースライン結果ファイル
            current_file: 現在の結果ファイル
        """
        with open(baseline_file, 'r', encoding='utf-8') as f:
            self.baseline = json.load(f)
        
        with open(current_file, 'r', encoding='utf-8') as f:
            self.current = json.load(f)
    
    def compare(self) -> Dict[str, Any]:
        """比較実行"""
        differences = {
            'new_tests': [],
            'removed_tests': [],
            'status_changes': [],
            'response_changes': [],
            'performance_changes': []
        }
        
        baseline_tests = {r['name']: r for r in self.baseline['results']}
        current_tests = {r['name']: r for r in self.current['results']}
        
        # 新規テスト検出
        for name in current_tests:
            if name not in baseline_tests:
                differences['new_tests'].append(name)
        
        # 削除されたテスト検出
        for name in baseline_tests:
            if name not in current_tests:
                differences['removed_tests'].append(name)
        
        # 共通テストの比較
        for name in baseline_tests:
            if name not in current_tests:
                continue
            
            baseline_result = baseline_tests[name]
            current_result = current_tests[name]
            
            # ステータス変更検出
            if baseline_result['success'] != current_result['success']:
                differences['status_changes'].append({
                    'test_name': name,
                    'baseline': 'SUCCESS' if baseline_result['success'] else 'FAILED',
                    'current': 'SUCCESS' if current_result['success'] else 'FAILED',
                    'baseline_error': baseline_result.get('error_message'),
                    'current_error': current_result.get('error_message')
                })
            
            # レスポンスデータ変更検出（成功時のみ）
            if baseline_result['success'] and current_result['success']:
                baseline_data = baseline_result.get('response_data')
                current_data = current_result.get('response_data')
                
                if baseline_data != current_data:
                    differences['response_changes'].append({
                        'test_name': name,
                        'baseline_status_code': baseline_result.get('status_code'),
                        'current_status_code': current_result.get('status_code')
                    })
            
            # パフォーマンス変化検出（20%以上の差）
            baseline_time = baseline_result.get('execution_time', 0)
            current_time = current_result.get('execution_time', 0)
            
            if baseline_time > 0:
                change_ratio = (current_time - baseline_time) / baseline_time
                if abs(change_ratio) > 0.2:  # 20%以上の変化
                    differences['performance_changes'].append({
                        'test_name': name,
                        'baseline_time': baseline_time,
                        'current_time': current_time,
                        'change_ratio': change_ratio
                    })
        
        return differences
    
    def print_comparison_report(self, differences: Dict[str, Any]):
        """比較レポート出力"""
        print(f"\n{Colors.HEADER}{'='*60}")
        print(f"リグレッション比較レポート")
        print(f"{'='*60}{Colors.RESET}")
        
        print(f"\nベースライン: {self.baseline['timestamp']}")
        print(f"現在: {self.current['timestamp']}")
        
        has_differences = False
        
        # 新規テスト
        if differences['new_tests']:
            has_differences = True
            print(f"\n{Colors.INFO}【新規テスト】{Colors.RESET}")
            for test in differences['new_tests']:
                print(f"  + {test}")
        
        # 削除されたテスト
        if differences['removed_tests']:
            has_differences = True
            print(f"\n{Colors.WARNING}【削除されたテスト】{Colors.RESET}")
            for test in differences['removed_tests']:
                print(f"  - {test}")
        
        # ステータス変更
        if differences['status_changes']:
            has_differences = True
            print(f"\n{Colors.ERROR}【ステータス変更】{Colors.RESET}")
            for change in differences['status_changes']:
                print(f"  テスト名: {change['test_name']}")
                print(f"    {change['baseline']} → {change['current']}")
                if change['current'] == 'FAILED':
                    print(f"    エラー: {change['current_error']}")
        
        # レスポンス変更
        if differences['response_changes']:
            has_differences = True
            print(f"\n{Colors.WARNING}【レスポンス変更】{Colors.RESET}")
            for change in differences['response_changes']:
                print(f"  テスト名: {change['test_name']}")
                print(f"    ステータスコード: {change['baseline_status_code']} → {change['current_status_code']}")
        
        # パフォーマンス変化
        if differences['performance_changes']:
            has_differences = True
            print(f"\n{Colors.INFO}【パフォーマンス変化（20%以上）】{Colors.RESET}")
            for change in differences['performance_changes']:
                change_pct = change['change_ratio'] * 100
                color = Colors.SUCCESS if change_pct < 0 else Colors.WARNING
                print(f"  テスト名: {change['test_name']}")
                print(f"    {change['baseline_time']:.3f}秒 → {change['current_time']:.3f}秒 "
                      f"({color}{change_pct:+.1f}%{Colors.RESET})")
        
        if not has_differences:
            print(f"\n{Colors.SUCCESS}✓ デグレは検出されませんでした{Colors.RESET}")
        
        print(f"\n{Colors.HEADER}{'='*60}{Colors.RESET}")


def main():
    """メイン処理"""
    parser = argparse.ArgumentParser(
        description='OneGate API Suite リグレッションテスト',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
使用例:
  # ベースライン取得（バージョンアップ前）
  python api_regression_test.py --api-key YOUR_KEY --tenant YOUR_TENANT --password YOUR_PASS --save-baseline

  # リグレッションテスト（バージョンアップ後）
  python api_regression_test.py --api-key YOUR_KEY --tenant YOUR_TENANT --password YOUR_PASS --compare

  # 通常実行
  python api_regression_test.py --api-key YOUR_KEY --tenant YOUR_TENANT --password YOUR_PASS
        """
    )
    
    parser.add_argument('--api-key', required=True, help='APIキー')
    parser.add_argument('--tenant', required=True, help='テナント名')
    parser.add_argument('--password', required=True, help='テスト用パスワード')
    parser.add_argument('--save-baseline', action='store_true', help='ベースラインとして保存')
    parser.add_argument('--compare', action='store_true', help='ベースラインと比較')
    parser.add_argument('--baseline-file', help='ベースラインファイル指定')
    
    args = parser.parse_args()
    
    # テスト実行
    tester = OneGateAPITester(args.api_key, args.tenant, args.password)
    tester.run_all_tests()
    tester.print_summary()
    
    # 結果保存
    if args.save_baseline:
        result_file = tester.save_results('baseline.json')
        print(f"\n{Colors.SUCCESS}✓ ベースラインを保存しました: {result_file}{Colors.RESET}")
    else:
        result_file = tester.save_results()
        print(f"\n{Colors.INFO}テスト結果を保存しました: {result_file}{Colors.RESET}")
    
    # 比較実行
    if args.compare:
        baseline_file = args.baseline_file
        if baseline_file is None:
            baseline_file = tester.results_dir / 'baseline.json'
        else:
            baseline_file = Path(baseline_file)
        
        if not baseline_file.exists():
            print(f"\n{Colors.ERROR}エラー: ベースラインファイルが見つかりません: {baseline_file}{Colors.RESET}")
            print(f"先に --save-baseline オプションでベースラインを作成してください")
            sys.exit(1)
        
        comparator = RegressionComparator(baseline_file, result_file)
        differences = comparator.compare()
        comparator.print_comparison_report(differences)
        
        # デグレがある場合は終了コード1
        if (differences['status_changes'] or 
            differences['removed_tests']):
            sys.exit(1)
    
    sys.exit(0)


if __name__ == '__main__':
    main()
