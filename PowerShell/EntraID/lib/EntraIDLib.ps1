<#
.SYNOPSIS
    Entra ID / Microsoft Graph API 操作用の共通ライブラリ

.DESCRIPTION
    MSAL.PSを使用したトークン管理とMicrosoft Graph APIへのアクセスを提供します。
    各スクリプトから `. .\EntraIDLib.ps1` で読み込んで使用します。

.NOTES
    必要なモジュール: MSAL.PS
    このライブラリは自動的にMSAL.PSのインストールを確認し、必要に応じてインストールします。
#>

# ===== MSAL.PS モジュール管理 =====

<#
.SYNOPSIS
    MSAL.PSモジュールの初期化とインストール確認

.DESCRIPTION
    MSAL.PSモジュールがインストールされているか確認し、
    未インストールの場合は自動的にインストールします。

.EXAMPLE
    Initialize-MsalModule
#>
function Initialize-MsalModule {
    [CmdletBinding()]
    param()
    
    Write-Host "MSAL.PSモジュール確認中..." -ForegroundColor Cyan
    
    if (-not (Get-Module -ListAvailable -Name MSAL.PS)) {
        Write-Host "  MSAL.PSモジュールがインストールされていません" -ForegroundColor Yellow
        Write-Host "  インストールを開始します..." -ForegroundColor Yellow
        
        try {
            Install-Module -Name MSAL.PS -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            Write-Host "  ✓ MSAL.PSモジュールのインストールが完了しました" -ForegroundColor Green
        } catch {
            Write-Host "  ✗ MSAL.PSモジュールのインストールに失敗しました: $_" -ForegroundColor Red
            throw
        }
    } else {
        Write-Host "  ✓ MSAL.PSモジュールが利用可能です" -ForegroundColor Green
    }
    
    Import-Module MSAL.PS -ErrorAction Stop
}

# ===== トークン管理 =====

<#
.SYNOPSIS
    MSAL.PSを使用してアクセストークンを取得

.DESCRIPTION
    Microsoft Graph API用のアクセストークンを取得します。
    MSAL.PSが自動的にトークンのキャッシュと更新を管理します。

.PARAMETER TenantIdentifier
    テナントIDまたはドメイン名（例: "contoso.onmicrosoft.com" または GUID）

.PARAMETER ClientId
    アプリケーション（クライアント）ID

.PARAMETER ClientSecret
    クライアントシークレット

.EXAMPLE
    $token = Get-MsalAccessToken -TenantIdentifier "contoso.onmicrosoft.com" -ClientId $clientId -ClientSecret $secret

.OUTPUTS
    String - アクセストークン
#>
function Get-MsalAccessToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$TenantIdentifier,
        
        [Parameter(Mandatory=$true)]
        [string]$ClientId,
        
        [Parameter(Mandatory=$true)]
        [string]$ClientSecret
    )
    
    try {
        # ClientSecretをSecureStringに変換
        $clientSecretSecure = ConvertTo-SecureString -String $ClientSecret -AsPlainText -Force
        
        # MSAL.PSでトークン取得（自動的にキャッシュと更新を管理）
        $tokenResponse = Get-MsalToken `
            -ClientId $ClientId `
            -ClientSecret $clientSecretSecure `
            -TenantId $TenantIdentifier `
            -Scopes "https://graph.microsoft.com/.default" `
            -ForceRefresh:$false
        
        return $tokenResponse.AccessToken
    } catch {
        throw "アクセストークンの取得に失敗しました: $_"
    }
}

<#
.SYNOPSIS
    Microsoft Graph API用の認証ヘッダーを作成

.DESCRIPTION
    アクセストークンを使用してHTTPリクエスト用の認証ヘッダーを作成します。

.PARAMETER AccessToken
    アクセストークン

.EXAMPLE
    $headers = New-GraphApiHeaders -AccessToken $token

.OUTPUTS
    Hashtable - 認証ヘッダー
#>
function New-GraphApiHeaders {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$AccessToken
    )
    
    return @{
        "Authorization" = "Bearer $AccessToken"
        "Content-Type"  = "application/json"
    }
}

# ===== ユーザー操作 =====

<#
.SYNOPSIS
    Entra IDからユーザーを取得

.DESCRIPTION
    UPNまたはユーザーIDでユーザー情報を取得します。

.PARAMETER Headers
    認証ヘッダー

.PARAMETER UserPrincipalName
    ユーザープリンシパル名（例: "user@contoso.com"）

.PARAMETER UserId
    ユーザーID（GUID）

.EXAMPLE
    $user = Get-EntraIDUser -Headers $headers -UserPrincipalName "user@contoso.com"

.OUTPUTS
    PSCustomObject - ユーザー情報
#>
function Get-EntraIDUser {
    [CmdletBinding(DefaultParameterSetName='ByUPN')]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Headers,
        
        [Parameter(Mandatory=$true, ParameterSetName='ByUPN')]
        [string]$UserPrincipalName,
        
        [Parameter(Mandatory=$true, ParameterSetName='ById')]
        [string]$UserId
    )
    
    try {
        $identifier = if ($PSCmdlet.ParameterSetName -eq 'ByUPN') { $UserPrincipalName } else { $UserId }
        $uri = "https://graph.microsoft.com/v1.0/users/$identifier"
        
        return Invoke-RestMethod -Uri $uri -Headers $Headers -Method GET -TimeoutSec 30
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 404) {
            return $null
        }
        throw
    }
}

<#
.SYNOPSIS
    Entra IDにユーザーを作成

.DESCRIPTION
    新しいユーザーをEntra IDに作成します。

.PARAMETER Headers
    認証ヘッダー

.PARAMETER DisplayName
    表示名

.PARAMETER UserPrincipalName
    ユーザープリンシパル名（例: "user@contoso.com"）

.PARAMETER MailNickname
    メールニックネーム

.PARAMETER Password
    初期パスワード

.PARAMETER AccountEnabled
    アカウントを有効にするかどうか（デフォルト: $true）

.PARAMETER ForceChangePasswordNextSignIn
    次回サインイン時にパスワード変更を強制するかどうか（デフォルト: $false）

.EXAMPLE
    $user = New-EntraIDUser -Headers $headers -DisplayName "Test User" -UserPrincipalName "testuser@contoso.com" -MailNickname "testuser" -Password "P@ssw0rd!"

.OUTPUTS
    PSCustomObject - 作成されたユーザー情報
#>
function New-EntraIDUser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Headers,
        
        [Parameter(Mandatory=$true)]
        [string]$DisplayName,
        
        [Parameter(Mandatory=$true)]
        [string]$UserPrincipalName,
        
        [Parameter(Mandatory=$true)]
        [string]$MailNickname,
        
        [Parameter(Mandatory=$true)]
        [string]$Password,
        
        [Parameter(Mandatory=$false)]
        [bool]$AccountEnabled = $true,
        
        [Parameter(Mandatory=$false)]
        [bool]$ForceChangePasswordNextSignIn = $false
    )
    
    $body = @{
        accountEnabled = $AccountEnabled
        displayName = $DisplayName
        mailNickname = $MailNickname
        userPrincipalName = $UserPrincipalName
        passwordProfile = @{
            forceChangePasswordNextSignIn = $ForceChangePasswordNextSignIn
            password = $Password
        }
    } | ConvertTo-Json -Depth 5
    
    return Invoke-RestMethod `
        -Uri "https://graph.microsoft.com/v1.0/users" `
        -Headers $Headers `
        -Method POST `
        -Body $body `
        -TimeoutSec 30
}

<#
.SYNOPSIS
    Entra IDからユーザーを削除

.DESCRIPTION
    指定されたユーザーをEntra IDから削除します。

.PARAMETER Headers
    認証ヘッダー

.PARAMETER UserId
    削除するユーザーのID（GUID）またはUPN

.EXAMPLE
    Remove-EntraIDUser -Headers $headers -UserId "user@contoso.com"
#>
function Remove-EntraIDUser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Headers,
        
        [Parameter(Mandatory=$true)]
        [string]$UserId
    )
    
    Invoke-RestMethod `
        -Uri "https://graph.microsoft.com/v1.0/users/$UserId" `
        -Headers $Headers `
        -Method DELETE `
        -TimeoutSec 30
}

# ===== グループ操作 =====

<#
.SYNOPSIS
    グループにユーザーを追加

.DESCRIPTION
    指定されたユーザーをグループに追加します。

.PARAMETER Headers
    認証ヘッダー

.PARAMETER GroupId
    グループのID（GUID）

.PARAMETER UserId
    追加するユーザーのID（GUID）

.EXAMPLE
    Add-EntraIDUserToGroup -Headers $headers -GroupId $groupId -UserId $userId
#>
function Add-EntraIDUserToGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Headers,
        
        [Parameter(Mandatory=$true)]
        [string]$GroupId,
        
        [Parameter(Mandatory=$true)]
        [string]$UserId
    )
    
    $body = @{
        "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$UserId"
    } | ConvertTo-Json
    
    Invoke-RestMethod `
        -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId/members/`$ref" `
        -Headers $Headers `
        -Method POST `
        -Body $body `
        -TimeoutSec 30
}

<#
.SYNOPSIS
    グループを検索または作成

.DESCRIPTION
    表示名でグループを検索し、存在しない場合は作成します。

.PARAMETER Headers
    認証ヘッダー

.PARAMETER DisplayName
    グループの表示名

.PARAMETER MailNickname
    メールニックネーム（省略時は表示名を使用）

.EXAMPLE
    $group = Get-OrCreateEntraIDGroup -Headers $headers -DisplayName "TestGroup"

.OUTPUTS
    PSCustomObject - グループ情報（idプロパティを含む）
#>
function Get-OrCreateEntraIDGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Headers,
        
        [Parameter(Mandatory=$true)]
        [string]$DisplayName,
        
        [Parameter(Mandatory=$false)]
        [string]$MailNickname
    )
    
    if ([string]::IsNullOrEmpty($MailNickname)) {
        $MailNickname = $DisplayName
    }
    
    # グループを検索
    $uri = "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$DisplayName'"
    $result = Invoke-RestMethod -Uri $uri -Headers $Headers -Method GET -TimeoutSec 30
    
    if ($result.value.Count -gt 0) {
        return $result.value[0]
    }
    
    # グループを作成
    $body = @{
        displayName     = $DisplayName
        mailEnabled     = $false
        mailNickname    = $MailNickname
        securityEnabled = $true
    } | ConvertTo-Json
    
    return Invoke-RestMethod `
        -Uri "https://graph.microsoft.com/v1.0/groups" `
        -Headers $Headers `
        -Method POST `
        -Body $body `
        -TimeoutSec 30
}

# ===== エクスポート =====

# モジュールとして読み込まれた場合にエクスポートする関数
Export-ModuleMember -Function @(
    'Initialize-MsalModule',
    'Get-MsalAccessToken',
    'New-GraphApiHeaders',
    'Get-EntraIDUser',
    'New-EntraIDUser',
    'Remove-EntraIDUser',
    'Add-EntraIDUserToGroup',
    'Get-OrCreateEntraIDGroup'
)
