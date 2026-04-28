【事前準備】

■利用者情報（JSON）の作成

1.OneGateテナントに任意のユーザーを作成する
	→できるかぎり多くの属性値を設定する

2.利用者取得APIで登録ユーザー情報を取得し、パスワードを追加してファイルに保存する

---------------

$apiKey = "<APIキー>"
$tenant = "<テナントコード>"
$baseUri = "https://$tenant.ids-dev.solitonsys.jp/icon/services/seap/api"
$header = @{ Authorization = "Bearer $apiKey" }

$employeeId = <employeeId>

# パスワードのattributeIdを取得
$uri = $baseUri + "/employee/-1"
$resp = Invoke-WebRequest $uri `
	-Headers $header `
	-ContentType "application/json; charset=utf-8" `
	-Method "GET" `
	| ConvertFrom-Json

# パスワード設定用のオブジェクト
$pwdAttributes = $resp.responseBody.pwdAttributes
$pwdAttributes[0].value = @(@{value = "notiloSP@ssw0rd"})

# ユーザー情報を取得してパスワードをセット　※GWS等と連携する場合、そのパスワードも必要
$uri = $baseUri + "/employee/$employeeId"
$resp = Invoke-WebRequest $uri `
	-Headers $header `
	-ContentType "application/json; charset=utf-8" `
	-Method "GET" `
	| ConvertFrom-Json
$resp.responseBody.pwdAttributes = $pwdAttributes

# ファイルに出力
$resp.responseBody | ConvertTo-Json -Depth 100 | Out-File ./OneGateUser_add.json -Encoding utf8

---------------

3.変更処理用に、ファイルをコピーして適当な属性値を変更し、「OneGateUser_mod.json」として保存する

4.重複エラーになるので、該当のユーザーはテナントから削除しておく

5.作成したファイルをdataフォルダに保存する


■APIキーの発行
管理ページにログインして、APIキーを発行しておく


■PasswordManager設定
1.ログイン名「oguser000」のユーザーを作成して、PasswordManagerのアプリケーションロールを設定する
2.dataフォルダにあるPasswordManager関連のインポートCSVを「追加」インポートして設定を登録する


■その他コメント
利用者インポートとSPMインポートなど冗長なところは、利用者管理、SPM管理などでスクリプトを分けて、
Wrapperから実行する方がいいかもと思ったのでとりあえずスルー。


【実行方法】
引数にAPIキーとテナントコードを指定して起動する

.\apitest.ps1 -apiKey $apiKey -tenant $tenant

デバッグ指定でレスポンスの内容やエクスポート内容を表示

.\apitest.ps1 -apiKey $apiKey -tenant $tenant -debug
