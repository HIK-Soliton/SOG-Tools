<#
.SYNOPSIS
    Entra IDに30万件のユーザーを作成し、グループに分散配置するスクリプト
    
.DESCRIPTION
    testuser000001～testuser300000のユーザーを作成し、
    grp001～grp030の30グループに順番に配置します。
    
    既存ユーザーの処理：
    - デフォルト：既に登録されているユーザーは完全にスキップ
    - UpdateExistingUsers スイッチ有効時：既存ユーザーにもグループ追加処理を実行
    
    MSAL.PSによるトークン自動管理：
    - MSAL (Microsoft Authentication Library) を使用
    - トークンのキャッシュと自動更新
    - 有効期限切れ前の自動リフレッシュ
    - 大量ユーザー作成時の401エラーを防止
#>

[CmdletBinding()]
param(
    # 既存ユーザーにグループ追加処理を実行
    [switch]$UpdateExistingUsers = $false,
    
    # テナントドメイン（認証とユーザーUPNに使用）
    [string]$TenantDomain = "demo99.netattest.tech",
    
    # アプリケーション（クライアント）ID（必須）
    [Parameter(Mandatory)]
    [string]$ClientId,
    
    # クライアントシークレット（必須）
    [Parameter(Mandatory)]
    [string]$ClientSecret,
    
    # ユーザーの初期パスワード（必須）
    [Parameter(Mandatory)]
    [string]$InitialPassword
)

# 共通ライブラリの読み込み
. "$PSScriptRoot\lib\EntraIDLib.ps1"

# MSAL.PSモジュールの初期化
Initialize-MsalModule

# ===== ユーザー設定 =====
$StartNumber     = 1    # ユーザー開始番号
$TotalUsers      = 300000

# ===== グループ設定 =====
$GroupPrefix = "grp"
$GroupCount  = 1

# ===== ログ =====
$LogFile = ".\create_users$(Get-Date -Format 'yyyyMMddHHmmss').log"

# アクセストークンを取得
Write-Host "アクセストークン取得中..." -ForegroundColor Cyan
$AccessToken = Get-MsalAccessToken -TenantIdentifier $TenantDomain -ClientId $ClientId -ClientSecret $ClientSecret

Write-Host "✓ アクセストークン取得成功" -ForegroundColor Green
Write-Host "MSAL.PSがトークンのキャッシュと自動更新を管理します" -ForegroundColor Gray

$Headers = New-GraphApiHeaders -AccessToken $AccessToken

# グループ存在確認／作成
$Groups = @{}

for ($i = 1; $i -le $GroupCount; $i++) {
    $GroupName = "{0}{1:D3}" -f $GroupPrefix, $i

    $uri = "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$GroupName'"
    $result = Invoke-RestMethod -Uri $uri -Headers $Headers -Method GET -TimeoutSec 30

    if ($result.value.Count -eq 0) {
        $body = @{
            displayName     = $GroupName
            mailEnabled     = $false
            mailNickname    = $GroupName
            securityEnabled = $true
        } | ConvertTo-Json

        $group = Invoke-RestMethod `
          -Uri "https://graph.microsoft.com/v1.0/groups" `
          -Headers $Headers `
          -Method POST `
          -Body $body `
          -TimeoutSec 30

        $Groups[$GroupName] = $group.id
    }
    else {
        $Groups[$GroupName] = $result.value[0].id
    }
}

# ユーザー作成＋グループ追加
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "ユーザー作成を開始します" -ForegroundColor Cyan
Write-Host "対象: $TotalUsers ユーザー (testuser000001 ～ testuser$($TotalUsers.ToString('000000')))" -ForegroundColor Yellow
Write-Host "グループ: $GroupCount グループに分散配置" -ForegroundColor Yellow
if ($UpdateExistingUsers) {
    Write-Host "既存ユーザー: グループ追加処理を実行" -ForegroundColor Green
} else {
    Write-Host "既存ユーザー: スキップ（作成もグループ追加もしない）" -ForegroundColor Yellow
}
Write-Host "========================================`n" -ForegroundColor Cyan

$startTime = Get-Date

for ($i = $StartNumber; $i -le $TotalUsers; $i++) {

    # MSAL.PSでトークンを自動更新（100ユーザーごと）
    if (($i % 100) -eq 0 -and $i -gt 0) {
        try {
            $AccessToken = Get-MsalAccessToken -TenantIdentifier $TenantDomain -ClientId $ClientId -ClientSecret $ClientSecret
            $Headers = New-GraphApiHeaders -AccessToken $AccessToken
        } catch {
            # エラーでも既存トークンで継続
            "Token refresh attempt failed at user $i" | Out-File $LogFile -Append
        }
    }

    $UserName = "testuser{0:D6}" -f $i
    $Upn = "$UserName@$TenantDomain"

    $GroupIndex = (($i - 1) % $GroupCount) + 1
    $GroupName = "{0}{1:D3}" -f $GroupPrefix, $GroupIndex
    $GroupId   = $Groups[$GroupName]

    try {
        # ユーザーが既に存在するかチェック
        $userExists = $false
        try {
            $checkUri = "https://graph.microsoft.com/v1.0/users/$Upn"
            $existingUser = Invoke-RestMethod -Uri $checkUri -Headers $Headers -Method GET -TimeoutSec 30 -ErrorAction Stop
            $userExists = $true
        } catch {
            # 404エラー = ユーザーが存在しない（正常）
            $userExists = $false
        }
        
        # ユーザーが既に存在する場合の処理
        if ($userExists) {
            if (-not $UpdateExistingUsers) {
                # 既存ユーザーをスキップ
                "SKIPPED $Upn : User already exists" | Out-File $LogFile -Append
                continue  # 次のユーザーへ
            }
            
            # UpdateExistingUsersスイッチが有効な場合：グループ追加処理を実行
            $userId = $existingUser.id
            $MemberBody = @{
                "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$userId"
            } | ConvertTo-Json

            try {
                Invoke-RestMethod `
                  -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId/members/`$ref" `
                  -Headers $Headers `
                  -Method POST `
                  -Body $MemberBody `
                  -TimeoutSec 30
                
                "$Upn updated (added to $GroupName)" | Out-File $LogFile -Append
            } catch {
                # 既にグループメンバーの場合は無視
                if ($_.Exception.Message -match "already exist") {
                    "$Upn : Already member of $GroupName" | Out-File $LogFile -Append
                } else {
                    throw
                }
            }
            continue  # 次のユーザーへ
        }
        
        # ユーザー作成（新規ユーザーのみ）
        $UserBody = @{
            accountEnabled = $true
            displayName = $UserName
            mailNickname = $UserName
            userPrincipalName = $Upn
            passwordProfile = @{
                forceChangePasswordNextSignIn = $false
                password = $InitialPassword
            }
        } | ConvertTo-Json -Depth 5

        $User = Invoke-RestMethod `
          -Uri "https://graph.microsoft.com/v1.0/users" `
          -Headers $Headers `
          -Method POST `
          -Body $UserBody `
          -TimeoutSec 30

        # グループに追加
        $MemberBody = @{
            "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($User.id)"
        } | ConvertTo-Json

        Invoke-RestMethod `
          -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId/members/`$ref" `
          -Headers $Headers `
          -Method POST `
          -Body $MemberBody `
          -TimeoutSec 30

        "$Upn created -> $GroupName" | Out-File $LogFile -Append
    }
    catch {
        "ERROR $Upn : $_" | Out-File $LogFile -Append
    }

    # 進捗表示とスロットリング
    if ($i % 100 -eq 0) {
        Write-Host "進捗: $i / $TotalUsers ユーザー処理完了" -ForegroundColor Cyan
        Start-Sleep -Milliseconds 500
    }
}

$endTime = Get-Date
$totalTime = ($endTime - $startTime).TotalSeconds

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "処理が完了しました！" -ForegroundColor Green
Write-Host "総処理時間: $([math]::Round($totalTime, 2)) 秒" -ForegroundColor Yellow
Write-Host "平均速度: $([math]::Round($TotalUsers / $totalTime, 2)) user/s" -ForegroundColor Yellow
Write-Host "詳細はログファイルを確認してください: $LogFile" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

