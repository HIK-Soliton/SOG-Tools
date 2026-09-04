# SAML認証テスト自動化スクリプト

## 概要

`dummy_saml_test.py` は、SAML SP Initiated 認証を自動実行するためのPythonスクリプトです。

ローカルで簡易SPを起動し、IdPメタデータから取得したSSO URLへ `SAMLRequest` を送信します。その後、IdPの認証フォーム/APIにユーザーIDとパスワードを送信し、ACSで受け取った `SAMLResponse` を検証します。

## 前提

- Python 3.14.4 で動作確認済み
- IdPメタデータファイル `OneGateCloudMetadata.xml` をこのREADMEと同じフォルダに配置する
- テスト対象は SP Initiated のみ
- NameID形式は `emailAddress`
- SAMLRequestへの署名は不要
- SAMLResponseは署名検証する

## ファイル構成

```text
DUMMY_SAML/
  dummy_saml_test.py
  OneGateCloudMetadata.xml
  requirements.txt
  spec.md
  README.md
```

## セットアップ

このフォルダで仮想環境を作成してから、依存パッケージをインストールします。

```powershell
cd C:\Users\hiki.FOURSEASONS\src\SOG-Tools\Python\DUMMY_SAML
C:/Users/hiki.FOURSEASONS/AppData/Local/Python/pythoncore-3.14-64/python.exe -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

既に `.venv` を作成済みの場合は、作成コマンドは不要です。以下のように仮想環境を有効化してから `pip install` またはスクリプト実行を行います。

```powershell
cd C:\Users\hiki.FOURSEASONS\src\SOG-Tools\Python\DUMMY_SAML
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
```

PowerShellの実行ポリシーにより `Activate.ps1` を実行できない場合は、仮想環境のPythonを直接呼び出します。

```powershell
cd C:\Users\hiki.FOURSEASONS\src\SOG-Tools\Python\DUMMY_SAML
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

## SP情報をIdPに登録する手順

テスト実行前に、IdP側へこのスクリプトが起動するローカルSPの情報を登録します。

### 1. IdPに登録するSP情報

既定値のまま実行する場合、IdPには以下を登録します。

| 項目 | 値 |
| --- | --- |
| SP EntityID | `http://127.0.0.1:8000/metadata` |
| ACS URL | `http://127.0.0.1:8000/acs` |
| ACS Binding | `HTTP-POST` |
| NameID Format | `urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress` |
| AuthnRequest署名 | なし |
| Assertion署名 | 必須 |

`--sp-host`、`--sp-port`、`--entity-id` を指定して実行する場合は、IdP側の登録値も同じ値に合わせます。

例: ポートを `18000` に変更する場合

```powershell
python dummy_saml_test.py --password "固定パスワード" --requests 100 --rps 10 --threads 5 --sp-port 18000
```

この場合、IdPに登録する値は以下になります。

| 項目 | 値 |
| --- | --- |
| SP EntityID | `http://127.0.0.1:18000/metadata` |
| ACS URL | `http://127.0.0.1:18000/acs` |

### 2. IdPメタデータを配置する

IdPからメタデータXMLをダウンロードし、このフォルダに `OneGateCloudMetadata.xml` という名前で配置します。

```text
DUMMY_SAML/
  OneGateCloudMetadata.xml
```

ファイル名や配置場所を変更する場合は、実行時に `--metadata` を指定します。

```powershell
python dummy_saml_test.py --metadata .\metadata\idp_metadata.xml --password "固定パスワード" --requests 100 --rps 10 --threads 5
```

### 3. 登録後にテストを実行する

IdP側へのSP登録と `OneGateCloudMetadata.xml` の配置が完了したら、通常の実行コマンドでテストを開始します。

```powershell
python dummy_saml_test.py --password "固定パスワード" --requests 100 --rps 10 --threads 5
```

IdP側でメタデータURLを指定してSP登録する方式の場合は、スクリプト実行中のみ以下のメタデータURLへアクセスできます。

```text
http://127.0.0.1:8000/metadata
```

テスト実行前にIdPへ登録する場合は、メタデータURL方式ではなく、上記のEntityID、ACS URL、Bindingを手動入力する方法を使用してください。

## 基本的な使い方

仮想環境を有効化している場合:

```powershell
python dummy_saml_test.py --password "固定パスワード" --requests 100 --rps 10 --threads 5
```

仮想環境を有効化しない場合:

```powershell
.\.venv\Scripts\python.exe dummy_saml_test.py --password "固定パスワード" --requests 100 --rps 10 --threads 5
```

この例では、以下の条件でテストを実行します。

- 総リクエスト数: 100
- 秒間リクエスト数: 10
- ワーカースレッド数: 5
- ユーザー: `soliton000001` から `soliton100000` の範囲でランダム選択
- Binding方式: Redirect Binding

## 主なオプション

| オプション | 必須 | 既定値 | 説明 |
| --- | --- | --- | --- |
| `--password` | はい | なし | 認証に使用する固定パスワード |
| `--requests` | はい | なし | 実行する総認証リクエスト数 |
| `--rps` | はい | なし | 秒間リクエスト数 |
| `--threads` | はい | なし | 並列実行するワーカースレッド数 |
| `--metadata` | いいえ | `OneGateCloudMetadata.xml` | IdPメタデータファイルのパス |
| `--user-id` | いいえ | ランダム選択 | 固定のログインユーザーID。未指定時は `soliton000001` から `soliton100000` の範囲でランダム選択 |
| `--binding` | いいえ | `redirect` | `redirect` または `post` |
| `--sp-host` | いいえ | `127.0.0.1` | ローカルSPの待受ホスト |
| `--sp-port` | いいえ | `8000` | ローカルSPの待受ポート |
| `--acs-url` | いいえ | `http://<sp-host>:<sp-port>/acs` | SAMLRequestとSPメタデータに記載するACS URL |
| `--entity-id` | いいえ | `http://127.0.0.1:8000/metadata` | SP EntityID |
| `--login-url` | いいえ | 自動推定 | IdPログインAPI/フォーム送信先URL。OneGateの通常ログインは `/idp/api/password` を指定する |
| `--login-method` | いいえ | `POST` | ログインAPIのHTTPメソッド |
| `--timeout` | いいえ | `30` | HTTPリクエストのタイムアウト秒 |
| `--response-timeout` | いいえ | `30` | ACSでSAMLResponseを待つ秒数 |
| `--insecure-tls` | いいえ | 無効 | TLS証明書検証を無効化 |
| `--verbose` | いいえ | 無効 | 詳細ログを出力 |

## Binding方式を指定する例

Redirect Binding:

```powershell
python dummy_saml_test.py --password "固定パスワード" --requests 100 --rps 10 --threads 5 --binding redirect
```

POST Binding:

```powershell
python dummy_saml_test.py --password "固定パスワード" --requests 100 --rps 10 --threads 5 --binding post
```

## ログインURLを明示する例

IdPのログイン画面が、メタデータのSSO URLとは別のAPIにJSONを送信する構成の場合は、`--login-url` を指定します。

OneGateの通常ログイン画面 `/idp/login` は画面表示用URLです。パスワード認証のAPIは `/idp/api/password` です。

```powershell
python dummy_saml_test.py --password "固定パスワード" --requests 100 --rps 10 --threads 5 --login-url "https://idp.example.com/idp/api/password"
```

誤って `/idp/login` を指定した場合は、スクリプト内で `/idp/api/password` に補正します。

認証時のJSONペイロードは以下です。

```json
{
  "userid": "soliton000001",
  "password": "固定パスワード",
  "rememberMe": "on"
}
```

`userid` は実行ごとにランダムに選ばれます。

## ローカルSPのURL

スクリプト実行中、ローカルSPは以下のURLを提供します。

| URL | 説明 |
| --- | --- |
| `http://127.0.0.1:8000/metadata` | SPメタデータ |
| `http://127.0.0.1:8000/acs` | SAMLResponse受信先ACS |

IdP側にSP情報を登録する必要がある場合は、上記のメタデータURLまたはACS URLを使用してください。

## IdPがSAMLRequestを受け入れない場合

IdP側でSAMLRequestが拒否される場合は、送信されたSAMLRequest内の以下の値が、IdPに登録したSP情報と一致しているか確認します。

| SAMLRequest内の項目 | 確認するIdP側の登録値 |
| --- | --- |
| `saml:Issuer` | SP EntityID |
| `AssertionConsumerServiceURL` | ACS URL |
| `Destination` | IdPのSSO URL |
| `ProtocolBinding` | ACS Binding |

既定では以下の値がSAMLRequestに入ります。

```xml
<saml:Issuer>http://127.0.0.1:8000/metadata</saml:Issuer>
AssertionConsumerServiceURL="http://127.0.0.1:8000/acs"
Destination="https://<tenant>/idp/sso"
ProtocolBinding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
```

IdP側に登録したEntityIDやACS URLが異なる場合は、`--entity-id` と `--acs-url` を指定して実行します。

```powershell
python dummy_saml_test.py --password "固定パスワード" --requests 1 --rps 1 --threads 1 --entity-id "https://sp.example.com/metadata" --acs-url "https://sp.example.com/acs"
```

注意: `--acs-url` に外部から到達可能なURLを指定する場合でも、スクリプト自体は `--sp-host` と `--sp-port` で指定したローカルアドレスで待ち受けます。IdPからACSへ戻す必要がある場合は、リバースプロキシ、ngrok、SSHトンネルなどで `--acs-url` のURLからローカルSPへ到達できるようにしてください。

### `Service not available.` になる場合

認証APIが成功した後に `/idp/sso-failed` へ遷移し、画面本文が `Service not available.` になる場合は、認証した利用者が対象SAMLサービスを利用できない状態の可能性があります。

ランダムに選ばれたユーザーではなく、ブラウザでSAMLResponseが返ることを確認済みのユーザーを `--user-id` で指定して切り分けます。

```powershell
python dummy_saml_test.py --user-id "soliton000001" --password "固定パスワード" --requests 1 --rps 1 --threads 1 --verbose
```

固定ユーザーで成功し、ランダムユーザーで失敗する場合は、SAMLサービスのロール割当または利用許可の対象外ユーザーが含まれていると判断できます。

## 成功判定

各リクエストで以下を確認します。

- IdPへのSAMLRequest送信がHTTPエラーにならないこと
- 認証API/フォーム送信がHTTPエラーにならないこと
- ACSで `SAMLResponse` を受信できること
- IdPメタデータ内の証明書でSAMLResponseの署名検証に成功すること
- SAML StatusCode が `Success` であること
- `InResponseTo` が発行したSAMLRequestのIDと一致すること
- `Audience` がSP EntityIDと一致すること
- `Recipient` がACS URLと一致すること

## 実行結果

実行完了時にJSON形式でサマリを出力します。

```json
{
  "total": 100,
  "success": 100,
  "failure": 0,
  "elapsedSeconds": 10.123
}
```

失敗したリクエストは、標準ログにユーザーID、経過秒数、エラー内容を出力します。

## 注意点

- `--sp-port` のポートが使用中の場合は、別のポートを指定してください。
- HTTPS環境で検証用証明書を使っている場合は、必要に応じて `--insecure-tls` を指定してください。
- SAMLRequestに署名が必要なIdP設定では、このスクリプトの現状実装では認証できません。
- MFAや追加画面が挟まるIdPでは、追加の画面操作/API呼び出し実装が必要です。
- IdPがブラウザJavaScript前提のログインフローの場合、`requests` ベースでは完了できないことがあります。その場合はPlaywright等によるブラウザ自動化への切り替えを検討してください。

## ヘルプ表示

```powershell
python dummy_saml_test.py --help
```
