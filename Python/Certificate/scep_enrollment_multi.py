#!/usr/bin/env python3
"""
SCEP証明書発行テストスクリプト（Python版）- WSL対応

固定チャレンジを使用してSCEPサーバーから証明書を取得します。
WSL環境でOpenSSLとsscepコマンドを使用して動作します。

このスクリプトは、WSL_sscep_setup_and_test.mdの手順に基づいて実装されています。

主な機能:
    - OpenSSLコマンドでchallengePassword付きCSRを生成
    - sscepコマンドでAES256/SHA256暗号化を使用した証明書取得
    - HTTP専用（sscepはHTTPSに非対応）

必要な環境:
    - OpenSSL (openssl コマンド)
    - sscep (HTTP対応版)
    - Python 3.7+

必要なライブラリ:
    pip install cryptography requests

使用方法:
    # 基本的な使用法（sscepコマンドを使用、推奨）
    python test_scep_enrollment.py --email test@example.com
    
    # カスタム設定ファイルを使用
    python test_scep_enrollment.py --email user@example.com --config custom_config.json
    
    # 証明書を複数回発行
    python test_scep_enrollment.py --email test@example.com --count 5
    
    # 証明書を並列発行（4スレッド）
    python test_scep_enrollment.py --email test@example.com --count 100 --max-threads 4
    
    # ログファイル付きで実行
    python test_scep_enrollment.py --email test@example.com --count 10 --log-file scep_test.log
    
    # 並列実行＋ログファイル（推奨：エラー追跡可能）
    python test_scep_enrollment.py --email test@example.com --count 100 --max-threads 8 --log-file scep_test.log
    
    # ファイル出力なしで実行（動作確認のみ）
    python test_scep_enrollment.py --email test@example.com --no-output
    
    # 複数回発行を並列実行＆ファイル出力なし（負荷テスト等）
    python test_scep_enrollment.py --email test@example.com --count 100 --max-threads 8 --no-output --log-file load_test.log
    
    # 詳細ログ付き
    python test_scep_enrollment.py --email test@example.com --verbose

事前準備（WSL/Ubuntu）:
    # OpenSSLのインストール
    sudo apt install openssl
    
    # sscepのビルドとインストール
    sudo apt install build-essential libssl-dev git
    mkdir -p ~/tools && cd ~/tools
    git clone https://github.com/certnanny/sscep.git
    cd sscep
    ./bootstrap.sh
    ./configure
    make
    sudo make install
    
    # Pythonライブラリのインストール
    pip install cryptography requests
    
注意事項:
    - sscepはHTTPのみ対応（HTTPSは使用不可）
    - WSL環境でのテストを想定
"""

import argparse
import json
import sys
import os
import subprocess
import tempfile
import platform
import threading
import logging
import traceback
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path
from typing import Dict, Tuple, Optional

import requests
from cryptography import x509
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs7
from cryptography.x509.oid import NameOID

# ASN.1構造を扱うためにpyasn1をインポート
try:
    from pyasn1.codec.der import encoder, decoder
    from pyasn1.type import univ, char, namedtype, tag
    from pyasn1_modules import rfc2315, rfc2314
    HAS_PYASN1 = True
except ImportError:
    HAS_PYASN1 = False


def get_openssl_command() -> str:
    """プラットフォームに応じたOpenSSLコマンドのパスを取得"""
    if platform.system() == "Windows":
        # Windowsの場合はフルパスを使用
        windows_paths = [
            r"C:\Program Files\OpenSSL-Win64\bin\openssl.exe",
            r"C:\Program Files (x86)\OpenSSL-Win32\bin\openssl.exe",
            r"C:\OpenSSL-Win64\bin\openssl.exe",
        ]
        for path in windows_paths:
            if os.path.exists(path):
                return path
        # 見つからない場合は通常のコマンド名を返す（PATHに依存）
        return "openssl"
    else:
        # Linux/macOS/WSLの場合は通常のコマンド名
        return "openssl"


def get_sscep_command() -> str:
    """プラットフォームに応じたsscepコマンドのパスを取得"""
    # sscepは通常PATHに含まれているはず
    return "sscep"


class SCEPClient:
    """SCEPクライアント"""
    
    def __init__(self, url: str, challenge: str, verbose: bool = False):
        self.url = url
        self.challenge = challenge
        self.verbose = verbose
        self.session = requests.Session()
        
    def log(self, message: str, level: str = "INFO"):
        """ログ出力"""
        timestamp = datetime.now().strftime("%Y/%m/%d %H:%M:%S")
        colors = {
            "INFO": "\033[96m",      # Cyan
            "SUCCESS": "\033[92m",   # Green
            "WARNING": "\033[93m",   # Yellow
            "ERROR": "\033[91m",     # Red
            "DEBUG": "\033[90m",     # Gray
        }
        reset = "\033[0m"
        
        if level == "DEBUG" and not self.verbose:
            return
            
        color = colors.get(level, "")
        print(f"{color}[{timestamp}] [{level}] {message}{reset}")
    
    def get_ca_cert(self) -> x509.Certificate:
        """CA証明書を取得"""
        self.log("CA証明書を取得中...", "INFO")
        
        try:
            response = self.session.get(
                f"{self.url}?operation=GetCACert",
                timeout=30
            )
            response.raise_for_status()
            
            # レスポンスの形式を判定
            content_type = response.headers.get('Content-Type', '').lower()
            self.log(f"  Content-Type: {content_type}", "DEBUG")
            self.log(f"  Response size: {len(response.content)} bytes", "DEBUG")
            
            ca_cert = None
            
            # PKCS#7形式の場合（複数証明書の可能性）
            if 'pkcs7' in content_type or len(response.content) > 2000:
                try:
                    # PKCS#7から証明書を抽出
                    certs = pkcs7.load_der_pkcs7_certificates(response.content)
                    if certs:
                        ca_cert = certs[0]  # 最初の証明書をCA証明書とする
                        self.log(f"  ✓ PKCS#7から証明書を抽出 ({len(certs)}個)", "SUCCESS")
                except Exception as e:
                    self.log(f"  PKCS#7パースエラー: {e}", "DEBUG")
            
            # DER形式の単一証明書の場合
            if ca_cert is None:
                ca_cert = x509.load_der_x509_certificate(
                    response.content,
                    default_backend()
                )
                self.log(f"  ✓ DER形式の証明書を読み込み", "SUCCESS")
            
            self.log(f"  Subject: {ca_cert.subject.rfc4514_string()}", "DEBUG")
            self.log(f"  Issuer: {ca_cert.issuer.rfc4514_string()}", "DEBUG")
            
            return ca_cert
            
        except Exception as e:
            self.log(f"CA証明書の取得に失敗: {e}", "ERROR")
            raise
    
    def generate_key_pair(self, key_size: int = 2048) -> rsa.RSAPrivateKey:
        """秘密鍵を生成"""
        self.log("秘密鍵を生成中...", "INFO")
        
        try:
            private_key = rsa.generate_private_key(
                public_exponent=65537,
                key_size=key_size,
                backend=default_backend()
            )
            
            self.log(f"  ✓ 秘密鍵を生成 ({key_size} bits)", "SUCCESS")
            return private_key
            
        except Exception as e:
            self.log(f"秘密鍵の生成に失敗: {e}", "ERROR")
            raise
    
    def generate_csr(
        self,
        private_key: rsa.RSAPrivateKey,
        common_name: str,
        organization: str = "Soliton Systems K.K.",
        country: str = "JP",
        state: str = "Tokyo",
        locality: str = "Shinjuku"
    ) -> x509.CertificateSigningRequest:
        """CSR（証明書署名要求）を生成"""
        self.log("CSRを生成中...", "INFO")
        
        try:
            # Subject構築
            subject = x509.Name([
                x509.NameAttribute(NameOID.COUNTRY_NAME, country),
                x509.NameAttribute(NameOID.STATE_OR_PROVINCE_NAME, state),
                x509.NameAttribute(NameOID.LOCALITY_NAME, locality),
                x509.NameAttribute(NameOID.ORGANIZATION_NAME, organization),
                x509.NameAttribute(NameOID.COMMON_NAME, common_name),
            ])
            
            # CSR構築
            csr = x509.CertificateSigningRequestBuilder().subject_name(
                subject
            ).add_extension(
                x509.KeyUsage(
                    digital_signature=True,
                    key_encipherment=True,
                    content_commitment=False,
                    data_encipherment=False,
                    key_agreement=False,
                    key_cert_sign=False,
                    crl_sign=False,
                    encipher_only=False,
                    decipher_only=False,
                ),
                critical=True,
            ).add_extension(
                x509.ExtendedKeyUsage([
                    x509.oid.ExtendedKeyUsageOID.CLIENT_AUTH,
                ]),
                critical=False,
            ).sign(private_key, hashes.SHA256(), default_backend())
            
            self.log(f"  ✓ CSRを生成", "SUCCESS")
            self.log(f"  Subject: {subject.rfc4514_string()}", "SUCCESS")
            
            return csr
            
        except Exception as e:
            self.log(f"CSRの生成に失敗: {e}", "ERROR")
            raise
    
    def generate_csr_with_openssl(
        self,
        private_key_path: Path,
        common_name: str,
        organization: str = "Soliton Systems K.K.",
        country: str = "JP",
        state: str = "Tokyo",
        locality: str = "Shinjuku",
        output_csr_path: Optional[Path] = None
    ) -> Path:
        """OpenSSLコマンドを使用してCSRを生成（challengePassword含む）"""
        self.log("OpenSSLでCSRを生成中（challengePassword付き）...", "INFO")
        
        try:
            # 一時ディレクトリ内で作業
            with tempfile.TemporaryDirectory() as tmpdir:
                tmpdir_path = Path(tmpdir)
                
                # req.cnfファイルを作成
                req_cnf = tmpdir_path / "req.cnf"
                req_cnf_content = f"""[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
attributes         = req_attributes
req_extensions     = v3_req

[ dn ]
C  = {country}
ST = {state}
L  = {locality}
O  = {organization}
CN = {common_name}

[ req_attributes ]
challengePassword = {self.challenge}

[ v3_req ]
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
"""
                req_cnf.write_text(req_cnf_content, encoding='utf-8')
                self.log(f"  ✓ req.cnfを作成", "DEBUG")
                
                # CSR出力先
                if output_csr_path is None:
                    output_csr_path = tmpdir_path / "client.csr"
                
                # OpenSSLコマンドを取得
                openssl_cmd = get_openssl_command()
                
                # OpenSSLコマンドでCSR生成
                cmd = [
                    openssl_cmd, "req",
                    "-new",
                    "-key", str(private_key_path),
                    "-out", str(output_csr_path),
                    "-config", str(req_cnf)
                ]
                
                self.log(f"  実行: {' '.join(cmd)}", "DEBUG")
                
                result = subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    check=True
                )
                
                if result.returncode != 0:
                    raise RuntimeError(f"OpenSSLエラー: {result.stderr}")
                
                self.log(f"  ✓ CSRを生成（challengePassword付き）", "SUCCESS")
                self.log(f"  Subject: CN={common_name}, O={organization}, C={country}", "SUCCESS")
                
                # CSR内容を確認
                if self.verbose:
                    verify_cmd = [openssl_cmd, "req", "-in", str(output_csr_path), "-text", "-noout"]
                    verify_result = subprocess.run(verify_cmd, capture_output=True, text=True)
                    if "challengePassword" in verify_result.stdout:
                        self.log(f"  ✓ challengePassword確認済み", "DEBUG")
                
                return output_csr_path
                
        except subprocess.CalledProcessError as e:
            self.log(f"OpenSSLコマンドエラー: {e.stderr}", "ERROR")
            raise
        except Exception as e:
            self.log(f"CSRの生成に失敗: {e}", "ERROR")
            raise
    
    def create_pkcs7_envelope(
        self,
        csr: x509.CertificateSigningRequest,
        private_key: rsa.RSAPrivateKey,
        ca_cert: x509.Certificate
    ) -> bytes:
        """SCEP用のPKCS#7エンベロープを作成"""
        self.log("PKCS#7エンベロープを作成中...", "INFO")
        
        try:
            # CSRをDER形式でシリアライズ
            csr_der = csr.public_bytes(serialization.Encoding.DER)
            
            # PKCS#7署名付きデータを作成
            # チャレンジパスワードを含める
            options = [pkcs7.PKCS7Options.DetachedSignature]
            
            # 自己署名証明書を一時的に作成（SCEPプロトコル用）
            temp_cert = self._create_self_signed_cert(private_key, csr.subject)
            
            builder = (
                pkcs7.PKCS7SignatureBuilder()
                .set_data(csr_der)
                .add_signer(temp_cert, private_key, hashes.SHA256())
            )
            
            # チャレンジパスワードを属性として追加
            # Note: cryptographyライブラリの制限により、challengePasswordの
            # 追加は直接サポートされていないため、DER構造を手動で構築
            
            pkcs7_data = builder.sign(
                serialization.Encoding.DER,
                options
            )
            
            self.log(f"  ✓ PKCS#7エンベロープを作成 ({len(pkcs7_data)} bytes)", "SUCCESS")
            
            return pkcs7_data
            
        except Exception as e:
            self.log(f"PKCS#7エンベロープの作成に失敗: {e}", "ERROR")
            self.log(f"  注意: Pythonのcryptographyライブラリには制限があります", "WARNING")
            self.log(f"  完全なSCEP実装には追加のライブラリが必要な場合があります", "WARNING")
            raise
    
    def _create_self_signed_cert(
        self,
        private_key: rsa.RSAPrivateKey,
        subject: x509.Name
    ) -> x509.Certificate:
        """一時的な自己署名証明書を作成（PKCS#7署名用）"""
        from datetime import timedelta
        
        cert = (
            x509.CertificateBuilder()
            .subject_name(subject)
            .issuer_name(subject)
            .public_key(private_key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(datetime.utcnow())
            .not_valid_after(datetime.utcnow() + timedelta(days=1))
            .sign(private_key, hashes.SHA256(), default_backend())
        )
        
        return cert
    
    def enroll(
        self,
        csr: x509.CertificateSigningRequest,
        private_key: rsa.RSAPrivateKey,
        ca_cert: x509.Certificate
    ) -> x509.Certificate:
        """SCEP PKIOperationで証明書を取得"""
        self.log("SCEP PKIOperationで証明書を取得中...", "INFO")
        
        try:
            # PKCS#7エンベロープを作成
            pkcs7_envelope = self.create_pkcs7_envelope(csr, private_key, ca_cert)
            
            # PKIOperation要求を送信
            self.log(f"  PKIOperation要求を送信中... ({len(pkcs7_envelope)} bytes)", "DEBUG")
            
            response = self.session.post(
                f"{self.url}?operation=PKIOperation",
                data=pkcs7_envelope,
                headers={"Content-Type": "application/x-pki-message"},
                timeout=60
            )
            
            response.raise_for_status()
            
            self.log(f"  ✓ サーバーレスポンス受信 ({len(response.content)} bytes)", "SUCCESS")
            
            # PKCS#7レスポンスから証明書を抽出
            # Note: 実際のSCEP実装では、レスポンスの検証が必要
            
            # PKCS#7からの証明書抽出を試行
            try:
                certs = pkcs7.load_der_pkcs7_certificates(response.content)
                if certs:
                    issued_cert = certs[0]
                    self.log(f"  ✓ 証明書を抽出", "SUCCESS")
                    return issued_cert
                else:
                    raise ValueError("PKCS#7レスポンスに証明書が含まれていません")
            except Exception as e:
                self.log(f"  証明書抽出エラー: {e}", "ERROR")
                # レスポンスをファイルに保存（デバッグ用）
                raise
            
        except requests.HTTPError as e:
            self.log(f"HTTP エラー: {e}", "ERROR")
            self.log(f"  ステータスコード: {e.response.status_code}", "ERROR")
            self.log(f"  レスポンス: {e.response.text[:500]}", "ERROR")
            raise
        except Exception as e:
            self.log(f"証明書の取得に失敗: {e}", "ERROR")
            raise
    
    def enroll_with_sscep(
        self,
        ca_cert_path: Path,
        private_key_path: Path,
        csr_path: Path,
        output_cert_path: Path
    ) -> Path:
        """sscepコマンドを使用して証明書を取得（推奨）"""
        self.log("sscepコマンドで証明書を取得中...", "INFO")
        
        try:
            # sscepコマンドを取得
            sscep_cmd = get_sscep_command()
            
            # sscepコマンドを構築
            cmd = [
                sscep_cmd, "enroll",
                "-u", self.url,
                "-c", str(ca_cert_path),
                "-k", str(private_key_path),
                "-r", str(csr_path),
                "-l", str(output_cert_path),
                "-E", "aes256",  # AES256暗号化
                "-S", "sha256",  # SHA256署名
                "-v"  # 詳細出力
            ]
            
            self.log(f"  実行: {' '.join(cmd)}", "DEBUG")
            
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=60
            )
            
            if result.returncode != 0:
                self.log(f"  sscep stdout: {result.stdout}", "DEBUG")
                self.log(f"  sscep stderr: {result.stderr}", "DEBUG")
                raise RuntimeError(f"sscepエラー (code {result.returncode}): {result.stderr}")
            
            # 証明書ファイルが作成されたか確認
            if not output_cert_path.exists():
                raise RuntimeError("証明書ファイルが作成されませんでした")
            
            self.log(f"  ✓ 証明書を取得", "SUCCESS")
            self.log(f"  出力: {output_cert_path}", "DEBUG")
            
            return output_cert_path
            
        except subprocess.TimeoutExpired:
            self.log(f"sscepコマンドがタイムアウトしました", "ERROR")
            raise
        except subprocess.CalledProcessError as e:
            self.log(f"sscepコマンドエラー: {e.stderr}", "ERROR")
            raise
        except Exception as e:
            self.log(f"証明書の取得に失敗: {e}", "ERROR")
            raise


def load_config(config_file: str) -> Dict:
    """設定ファイルを読み込み"""
    try:
        with open(config_file, 'r', encoding='utf-8') as f:
            config_json = json.load(f)
        
        # sscepはHTTPのみ対応のため、HTTPSフラグを無視してHTTPを使用
        return {
            'server': config_json['server']['Value'],
            'https': False,  # sscepはHTTPのみ対応
            'challenge': config_json['challenge']['Value'],
            'cert_subject': config_json.get('cert_subject', {}).get('Value', ''),
        }
    except Exception as e:
        print(f"設定ファイルの読み込みに失敗: {e}", file=sys.stderr)
        sys.exit(1)


def check_requirements(verbose: bool = False) -> bool:
    """必要なコマンドがインストールされているか確認"""
    # 実際のコマンドパスを取得
    openssl_cmd = get_openssl_command()
    sscep_cmd = get_sscep_command()
    
    required_commands = [
        ('openssl', openssl_cmd),
        ('sscep', sscep_cmd)
    ]
    missing = []
    
    for name, cmd in required_commands:
        try:
            result = subprocess.run(
                [cmd, '--version'],
                capture_output=True,
                text=True,
                timeout=5
            )
            if verbose:
                print(f"✓ {name}: {cmd}")
        except FileNotFoundError:
            missing.append(name)
            if verbose:
                print(f"✗ {name}: 見つかりません (探索パス: {cmd})")
        except Exception as e:
            missing.append(name)
            if verbose:
                print(f"✗ {name}: エラー ({e})")
    
    if missing:
        print(f"\n❌ 以下のコマンドが見つかりません: {', '.join(missing)}", file=sys.stderr)
        
        if platform.system() == "Windows":
            print(f"\nインストール方法（Windows）:", file=sys.stderr)
            if 'openssl' in missing:
                print(f"  OpenSSLをインストール:", file=sys.stderr)
                print(f"    https://slproweb.com/products/Win32OpenSSL.html", file=sys.stderr)
                print(f"    推奨: Win64 OpenSSL v3.x.x", file=sys.stderr)
                print(f"    デフォルトパス: C:\\Program Files\\OpenSSL-Win64\\bin\\openssl.exe", file=sys.stderr)
            if 'sscep' in missing:
                print(f"  sscepはWSL環境で使用してください", file=sys.stderr)
        else:
            print(f"\nインストール方法（WSL/Ubuntu）:", file=sys.stderr)
            if 'openssl' in missing:
                print(f"  sudo apt install openssl", file=sys.stderr)
            if 'sscep' in missing:
                print(f"  # sscepはソースからビルド", file=sys.stderr)
                print(f"  sudo apt install build-essential libssl-dev git", file=sys.stderr)
                print(f"  mkdir -p ~/tools && cd ~/tools", file=sys.stderr)
                print(f"  git clone https://github.com/certnanny/sscep.git", file=sys.stderr)
                print(f"  cd sscep", file=sys.stderr)
                print(f"  ./bootstrap.sh && ./configure && make && sudo make install", file=sys.stderr)
        return False
    
    return True


def save_files(
    output_dir: Path,
    timestamp: str,
    ca_cert: x509.Certificate,
    private_key: rsa.RSAPrivateKey,
    csr: x509.CertificateSigningRequest,
    cert: x509.Certificate
) -> Dict[str, Path]:
    """証明書と鍵をファイルに保存"""
    
    files = {}
    
    # CA証明書
    ca_cert_file = output_dir / f"ca_cert_{timestamp}.pem"
    ca_cert_file.write_bytes(
        ca_cert.public_bytes(serialization.Encoding.PEM)
    )
    files['ca_cert'] = ca_cert_file
    
    # 秘密鍵
    key_file = output_dir / f"private_key_{timestamp}.pem"
    key_file.write_bytes(
        private_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption()
        )
    )
    files['private_key'] = key_file
    
    # CSR
    csr_file = output_dir / f"cert_request_{timestamp}.pem"
    csr_file.write_bytes(
        csr.public_bytes(serialization.Encoding.PEM)
    )
    files['csr'] = csr_file
    
    # 証明書
    cert_file = output_dir / f"issued_cert_{timestamp}.pem"
    cert_file.write_bytes(
        cert.public_bytes(serialization.Encoding.PEM)
    )
    files['cert'] = cert_file
    
    # PFXファイル（Windows用）
    pfx_file = output_dir / f"issued_cert_{timestamp}.pfx"
    # Note: PFX作成にはpyOpenSSLが必要（オプション）
    
    return files


# スレッド間の出力制御用ロック
print_lock = threading.Lock()

# グローバルロガー
logger = None


def setup_logging(log_file: Optional[str] = None, verbose: bool = False) -> logging.Logger:
    """
    ログ設定を初期化
    
    Args:
        log_file: ログファイルのパス（Noneの場合はコンソールのみ）
        verbose: 詳細ログを出力するか
    
    Returns:
        設定済みのロガー
    """
    logger = logging.getLogger('scep_enrollment')
    logger.setLevel(logging.DEBUG if verbose else logging.INFO)
    
    # 既存のハンドラをクリア
    logger.handlers.clear()
    
    # フォーマッタ
    formatter = logging.Formatter(
        '%(asctime)s [%(levelname)s] [Thread-%(thread)d] %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S'
    )
    
    # コンソールハンドラ（ERRORのみ）
    console_handler = logging.StreamHandler(sys.stderr)
    console_handler.setLevel(logging.ERROR)
    console_handler.setFormatter(formatter)
    logger.addHandler(console_handler)
    
    # ファイルハンドラ
    if log_file:
        file_handler = logging.FileHandler(log_file, encoding='utf-8')
        file_handler.setLevel(logging.DEBUG if verbose else logging.INFO)
        file_handler.setFormatter(formatter)
        logger.addHandler(file_handler)
    
    return logger


def thread_safe_print(message: str, end: str = '\n'):
    """スレッドセーフな出力関数"""
    with print_lock:
        print(message, end=end)


def enroll_certificate(
    index: int,
    total_count: int,
    client: 'SCEPClient',
    ca_cert: x509.Certificate,
    ca_cert_path: Path,
    output_dir: Path,
    email: str,
    key_size: int,
    no_output: bool,
    verbose: bool,
    log: logging.Logger = None
) -> Dict:
    """
    証明書を1つ発行する関数（スレッドで並列実行される）
    
    Args:
        index: 証明書発行のインデックス（0から始まる）
        total_count: 発行する証明書の総数
        client: SCEPクライアント
        ca_cert: CA証明書
        ca_cert_path: CA証明書のファイルパス
        output_dir: 出力ディレクトリ
        email: 証明書のCN
        key_size: RSA鍵長
        no_output: ファイル出力を行わないか
        verbose: 詳細ログを表示するか
    
    Returns:
        発行された証明書の情報を含む辞書
    """
    try:
        i = index + 1  # 1から始まる番号
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")[:19]
        
        if log:
            log.info(f"証明書発行開始: [{i}/{total_count}] index={index}, timestamp={timestamp}")
        
        if total_count > 1 and verbose:
            thread_safe_print(f"\n[スレッド] 証明書発行 {i}/{total_count} 開始")
        
        # [3] 秘密鍵生成
        if verbose:
            thread_safe_print(f"[{i}] 秘密鍵を生成中 ({key_size} bits)...")
        if log:
            log.debug(f"[{i}] 秘密鍵生成開始 ({key_size} bits)")
        private_key = client.generate_key_pair(key_size=key_size)
        
        # 秘密鍵をファイルに保存
        private_key_path = output_dir / f"private_key_{timestamp}.pem"
        private_key_path.write_bytes(
            private_key.private_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.PKCS8,
                encryption_algorithm=serialization.NoEncryption()
            )
        )
        
        # [4] CSR生成
        if verbose:
            thread_safe_print(f"[{i}] CSRを生成中...")
        if log:
            log.debug(f"[{i}] CSR生成開始 (email={email})")
        
        # OpenSSL使用（challengePassword付き）
        csr_path = output_dir / f"cert_request_{timestamp}.pem"
        client.generate_csr_with_openssl(
            private_key_path=private_key_path,
            common_name=email,
            output_csr_path=csr_path
        )
        
        # [5] SCEP経由で証明書取得
        if verbose:
            thread_safe_print(f"[{i}] SCEP経由で証明書を取得中...")
        if log:
            log.debug(f"[{i}] SCEP証明書取得開始")
        
        cert_path = output_dir / f"issued_cert_{timestamp}.pem"
        
        # sscepコマンド使用
        client.enroll_with_sscep(
            ca_cert_path=ca_cert_path,
            private_key_path=private_key_path,
            csr_path=csr_path,
            output_cert_path=cert_path
        )
        
        # [6] 証明書検証
        cert = x509.load_pem_x509_certificate(
            cert_path.read_bytes(),
            default_backend()
        )
        
        # 成功メッセージ
        thread_safe_print(f"✓ [{i}/{total_count}] 証明書発行完了 (Serial: {cert.serial_number:X})")
        
        if log:
            log.info(f"証明書発行成功: [{i}/{total_count}] Serial={cert.serial_number:X}, Subject={cert.subject.rfc4514_string()}")
        
        return {
            'index': index,
            'timestamp': timestamp,
            'ca_cert_path': ca_cert_path,
            'private_key_path': private_key_path,
            'csr_path': csr_path,
            'cert_path': cert_path,
            'cert': cert,
            'success': True,
            'error': None
        }
        
    except Exception as e:
        error_msg = str(e)
        error_trace = traceback.format_exc()
        
        thread_safe_print(f"✗ [{i}/{total_count}] 証明書発行失敗: {error_msg}")
        
        if log:
            log.error(f"証明書発行失敗: [{i}/{total_count}] index={index}")
            log.error(f"エラー詳細: {error_msg}")
            log.error(f"スタックトレース:\n{error_trace}")
        
        return {
            'index': index,
            'success': False,
            'error': error_msg,
            'traceback': error_trace
        }


def main():
    parser = argparse.ArgumentParser(
        description='SCEP証明書発行テストスクリプト（Python版）',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
使用例:
  # 基本的な使用法
  %(prog)s --email test@example.com
  
  # 複数回発行
  %(prog)s --email test@example.com --count 10
  
  # 並列実行（4スレッド）+ ログファイル
  %(prog)s --email test@example.com --count 100 --max-threads 4 --log-file test.log
  
  # 負荷テスト（ファイル出力なし）
  %(prog)s --email test@example.com --count 100 --max-threads 8 --no-output --log-file load_test.log
  
  # 詳細ログ付き
  %(prog)s --email user@example.com --verbose --log-file debug.log
        """
    )
    
    parser.add_argument(
        '--email',
        default='test@example.com',
        help='証明書のCN（Common Name）に設定するメールアドレス（デフォルト: test@example.com）'
    )
    parser.add_argument(
        '--config',
        default='ChromeOS_SKMSetting_json.txt',
        help='SCEP設定ファイル（JSON）のパス（デフォルト: ChromeOS_SKMSetting_json.txt）'
    )
    parser.add_argument(
        '--output-dir',
        default='SCEP_Output',
        help='証明書と鍵の出力先ディレクトリ（デフォルト: SCEP_Output）'
    )
    parser.add_argument(
        '--key-size',
        type=int,
        default=2048,
        choices=[2048, 3072, 4096],
        help='RSA鍵長（ビット）（デフォルト: 2048）'
    )
    parser.add_argument(
        '-v', '--verbose',
        action='store_true',
        help='詳細ログを表示'
    )
    parser.add_argument(
        '--count',
        type=int,
        default=1,
        help='証明書発行を繰り返す回数（デフォルト: 1）'
    )
    parser.add_argument(
        '--no-output',
        action='store_true',
        help='ファイル出力を行わない（証明書発行の動作確認のみ）'
    )
    parser.add_argument(
        '--max-threads',
        type=int,
        default=1,
        help='証明書発行を並列実行する最大スレッド数（デフォルト: 1=順次実行）'
    )
    parser.add_argument(
        '--log-file',
        type=str,
        help='ログファイルのパス（指定しない場合はエラーのみコンソール出力）'
    )
    
    args = parser.parse_args()
    
    # ロギング設定
    global logger
    log_file_path = None
    if args.log_file:
        script_dir_for_log = Path(__file__).parent
        log_file_path = script_dir_for_log / args.log_file if not Path(args.log_file).is_absolute() else Path(args.log_file)
    
    logger = setup_logging(log_file=log_file_path, verbose=args.verbose)
    
    if log_file_path:
        print(f"📝 ログファイル: {log_file_path}")
        logger.info(f"=== SCEP証明書発行テスト開始 ===")
        logger.info(f"ログファイル: {log_file_path}")
    
    # スクリプトのディレクトリを基準にパスを解決
    script_dir = Path(__file__).parent
    config_path = script_dir / args.config if not Path(args.config).is_absolute() else Path(args.config)
    
    # 出力ディレクトリの設定
    if args.no_output:
        # ファイル出力しない場合は一時ディレクトリを使用
        temp_dir = tempfile.mkdtemp(prefix="scep_test_")
        output_dir = Path(temp_dir)
    else:
        output_dir = script_dir / args.output_dir if not Path(args.output_dir).is_absolute() else Path(args.output_dir)
        # 出力ディレクトリ作成
        output_dir.mkdir(exist_ok=True)
    
    print()
    print("=" * 60)
    print("SCEP 証明書発行テスト（Python版）")
    print("=" * 60)
    print()
    
    # 必要なコマンドの確認
    print("必要なコマンドを確認中...")
    if not check_requirements(verbose=args.verbose):
        sys.exit(1)
    print()
    
    # 証明書発行の繰り返し回数を確認
    repeat_count = max(1, args.count)
    if repeat_count > 1:
        print(f"証明書発行を {repeat_count} 回繰り返します")
        print()
    
    if logger:
        logger.info(f"証明書発行回数: {repeat_count}")
        logger.info(f"最大スレッド数: {max(1, args.max_threads)}")
        logger.info(f"ファイル出力: {'無効' if args.no_output else '有効'}")
    
    # ファイル出力モードの表示
    if args.no_output:
        print("⚠️  ファイル出力なしモード（証明書は一時ファイルに保存されます）")
        print()
    
    # マルチスレッド実行の設定
    max_threads = max(1, args.max_threads)
    if max_threads > 1:
        print(f"🔀 並列実行モード: 最大 {max_threads} スレッド")
        print()
    elif repeat_count > 1:
        print(f"🔄 順次実行モード")
        print()
    
    # 各証明書発行の結果を保存するリスト
    issued_certificates = []
    
    try:
        # [1] 設定ファイル読み込み（1回だけ）
        print(f"[1/1] 設定ファイルを読み込み中: {config_path}")
        if logger:
            logger.info(f"設定ファイル読み込み: {config_path}")
        
        config = load_config(str(config_path))
        
        protocol = "https" if config['https'] else "http"
        scep_url = f"{protocol}://{config['server']}/scep/static"
        
        print(f"  サーバー: {config['server']}")
        print(f"  SCEP URL: {scep_url}")
        if not config['https']:
            print(f"  ⚠️  注意: HTTPを使用（sscepはHTTPSに非対応）")
        print()
        
        if logger:
            logger.info(f"SCEP URL: {scep_url}")
            logger.info(f"サーバー: {config['server']}")
        
        # [2] SCEPクライアント初期化（1回だけ）
        client = SCEPClient(scep_url, config['challenge'], verbose=args.verbose)
        
        # [2] CA証明書を取得（1回だけ）
        print("[2/6] CA証明書を取得中...")
        if logger:
            logger.info("CA証明書取得開始")
        
        ca_cert = client.get_ca_cert()
        
        if logger:
            logger.info(f"CA証明書取得成功: Subject={ca_cert.subject.rfc4514_string()}")
        
        # CA証明書をファイルに保存
        timestamp_ca = datetime.now().strftime("%Y%m%d_%H%M%S")
        ca_cert_path = output_dir / f"ca_cert_{timestamp_ca}.pem"
        ca_cert_path.write_bytes(
            ca_cert.public_bytes(serialization.Encoding.PEM)
        )
        if not args.no_output:
            print(f"  ✓ CA証明書を保存: {ca_cert_path}")
        else:
            print(f"  ✓ CA証明書を取得")
        print()
        
        # 証明書発行を並列または順次実行
        print("証明書発行を開始します...")
        print()
        
        if logger:
            logger.info(f"証明書発行開始: 全{repeat_count}件")
        
        # ThreadPoolExecutorを使用した並列実行
        issued_certificates = []
        
        if max_threads > 1:
            # 並列実行
            if logger:
                logger.info(f"並列実行モード: 最大{max_threads}スレッド")
            
            with ThreadPoolExecutor(max_workers=max_threads) as executor:
                # すべてのタスクを投入
                futures = []
                for i in range(repeat_count):
                    future = executor.submit(
                        enroll_certificate,
                        i,
                        repeat_count,
                        client,
                        ca_cert,
                        ca_cert_path,
                        output_dir,
                        args.email,
                        args.key_size,
                        args.no_output,
                        args.verbose,
                        logger
                    )
                    futures.append(future)
                
                # 完了したタスクの結果を収集
                for future in as_completed(futures):
                    try:
                        result = future.result()
                        if result['success']:
                            issued_certificates.append(result)
                    except Exception as e:
                        error_msg = f"タスク実行エラー: {e}"
                        thread_safe_print(f"✗ {error_msg}")
                        if logger:
                            logger.error(f"{error_msg}\n{traceback.format_exc()}")
        else:
            # 順次実行
            if logger:
                logger.info("順次実行モード")
            
            for i in range(repeat_count):
                if repeat_count > 1 and not args.verbose:
                    print(f"証明書発行 {i + 1}/{repeat_count} 回目...")
                
                result = enroll_certificate(
                    i,
                    repeat_count,
                    client,
                    ca_cert,
                    ca_cert_path,
                    output_dir,
                    args.email,
                    args.key_size,
                    args.no_output,
                    args.verbose,
                    logger
                )
                
                if result['success']:
                    issued_certificates.append(result)
        
        # 結果をインデックス順にソート
        issued_certificates.sort(key=lambda x: x['index'])
        # 結果をインデックス順にソート
        issued_certificates.sort(key=lambda x: x['index'])
        
        # 成功・失敗のカウント
        success_count = len(issued_certificates)
        failed_count = repeat_count - success_count
        
        if logger:
            logger.info(f"証明書発行完了: 成功={success_count}, 失敗={failed_count}, 合計={repeat_count}")
        
        # 最終結果表示
        print()
        print("=" * 60)
        if repeat_count == 1:
            if success_count == 1:
                print("✓ SCEP証明書発行が完了しました")
            else:
                print("✗ SCEP証明書発行に失敗しました")
        else:
            print(f"✓ SCEP証明書発行が完了しました")
            print(f"  成功: {success_count}/{repeat_count}")
            if failed_count > 0:
                print(f"  失敗: {failed_count}/{repeat_count}")
        print("=" * 60)
        print()
        
        # 全ての証明書情報を表示
        if success_count > 0:
            for idx, issued in enumerate(issued_certificates, 1):
                cert = issued['cert']
                if repeat_count > 1:
                    print(f"[{idx}/{success_count}] 発行された証明書情報:")
                else:
                    print("発行された証明書情報:")
                print(f"  Subject: {cert.subject.rfc4514_string()}")
                print(f"  Issuer: {cert.issuer.rfc4514_string()}")
                print(f"  Serial: {cert.serial_number:X}")
                print(f"  有効期限: {cert.not_valid_before_utc} ～ {cert.not_valid_after_utc}")
                print()
                if not args.no_output:
                    print("出力ファイル:")
                    print(f"  CA証明書: {issued['ca_cert_path']}")
                    print(f"  秘密鍵: {issued['private_key_path']}")
                    print(f"  CSR: {issued['csr_path']}")
                    print(f"  証明書: {issued['cert_path']}")
                if idx < len(issued_certificates):
                    print()
        
        if not args.no_output:
            print()
            print(f"出力ディレクトリ: {output_dir}")
            print()
        
        # 最後の証明書のコマンド例を表示（ファイル出力ありで成功した場合のみ）
        if not args.no_output and success_count > 0:
            last_issued = issued_certificates[-1]
            print("使用したコマンド（参考）:")
            print(f"  sscep enroll \\")
            print(f"    -u {scep_url} \\")
            print(f"    -c {last_issued['ca_cert_path'].name} \\")
            print(f"    -k {last_issued['private_key_path'].name} \\")
            print(f"    -r {last_issued['csr_path'].name} \\")
            print(f"    -l {last_issued['cert_path'].name} \\")
            print(f"    -E aes256 -S sha256 -v")
        print("=" * 60)
        
    except FileNotFoundError as e:
        error_msg = f"ファイルが見つかりません: {e}"
        print(f"\n❌ {error_msg}", file=sys.stderr)
        if logger:
            logger.error(error_msg)
            logger.error(traceback.format_exc())
        
        print(f"\n必要なコマンド:", file=sys.stderr)
        print(f"  - openssl: OpenSSLがインストールされているか確認", file=sys.stderr)
        print(f"  - sscep: sscepコマンドがインストールされているか確認", file=sys.stderr)
        print(f"\nインストール方法（WSL/Ubuntu）:", file=sys.stderr)
        print(f"  sudo apt install openssl", file=sys.stderr)
        print(f"  # sscepはソースからビルド（HTTPサポート付き）", file=sys.stderr)
        sys.exit(1)
    except subprocess.CalledProcessError as e:
        error_msg = f"コマンド実行エラー: {e}"
        print(f"\n❌ {error_msg}", file=sys.stderr)
        if logger:
            logger.error(error_msg)
            logger.error(f"Return code: {e.returncode}")
            if e.output:
                logger.error(f"Output: {e.output}")
            if e.stderr:
                logger.error(f"Stderr: {e.stderr}")
        
        if args.verbose:
            traceback.print_exc()
        sys.exit(1)
    except Exception as e:
        error_msg = f"エラー: {e}"
        print(f"\n❌ {error_msg}", file=sys.stderr)
        if logger:
            logger.error(error_msg)
            logger.error(traceback.format_exc())
        
        if args.verbose:
            traceback.print_exc()
        sys.exit(1)
    finally:
        # 一時ディレクトリのクリーンアップ（エラー時）
        if args.no_output and 'output_dir' in locals():
            import shutil
            try:
                if output_dir.exists():
                    shutil.rmtree(output_dir)
                    if args.verbose:
                        print(f"\n一時ディレクトリを削除しました: {output_dir}")
            except Exception as e:
                if args.verbose:
                    print(f"\n⚠️  一時ディレクトリの削除に失敗: {e}", file=sys.stderr)
        
        # ログ終了
        if logger:
            logger.info("=== SCEP証明書発行テスト終了 ===")


if __name__ == '__main__':
    main()
