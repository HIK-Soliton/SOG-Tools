# 概要
SAML認証のテストを自動実行するPythonスクリプト
テスト対象はSP Initiatedのみとする。

# 機能
SAML SP機能
* SAML SPとして動作し、ランダムなユーザーに向けたSAMLRequestを発行できる
* SAML SPとしてのパラメータをメタデータに出力できる
* SAML IdPのメタデータを取り込んで、認証先IdPとして登録できる
* Binding方式はRedirectまたはPOSTを選択可能
* NameID形式はemailaddress

# SAML認証機能
発行したSAML Requestを使って、IdPのフォーム認証を実行する
* 認証時のペイロード
```json
{userid: "userid", password: "password", rememberMe: "on"}
```
* 認証成功時のレスポンス
{"passwordChangeFlag":false,"isAuthFinished":true}
* 認証ユーザーの指定方法
    soliton000001～soliton100000の中から毎回ランダムに選出する
* パスワードはスクリプト開始時に引数で指定する
* 秒間にリクエストする認証処理数とスレッド数をスクリプト開始時に引数で指定する


## 認証処理内容
1. SAML SPとして動作し、ランダムなユーザーに向けたSAML Requestを発行
2. 発行したSAML RequestをSAML認証サーバー（IdP）に送信
3. IdPの認証フォームにユーザーIDと固定のパスワードを送信して認証
4. 認証結果はサーバーに記録されるためログの記録は不要
