<#
.SYNOPSIS
    Entra IDからテストユーザーを削除するスクリプト
    
.DESCRIPTION
    testuser000001～testuserXXXXXXの指定範囲のユーザーを削除します。
    
    DryRunモード：
    - DryRun = $true の場合、削除せずにログに記録のみ
    - DryRun = $false の場合、実際に削除を実行
    
    MSAL.PSによるトークン自動管理：
    - MSAL (Microsoft Authentication Library) を使用
    - トークンのキャッシュと自動更新
    - 有効期限切れ前の自動リフレッシュ
    - 大量ユーザー削除時の401エラーを防止

.EXAMPLE
    # DryRunモードで実行（削除しない）
    .\Remove-EntraUsers.ps1 `
        -Domain "yourname.onmicrosoft.com" `
        -ClientId "your-client-id" `
        -ClientSecret "your-client-secret" `
        -DryRun

.EXAMPLE
    # 実際に削除を実行
    .\Remove-EntraUsers.ps1 `
        -Domain "yourname.onmicrosoft.com" `
        -ClientId "your-client-id" `
        -ClientSecret "your-client-secret"

.EXAMPLE
    # 範囲を指定して削除
    .\Remove-EntraUsers.ps1 `
        -Domain "yourname.onmicrosoft.com" `
        -ClientId "your-client-id" `
        -ClientSecret "your-client-secret" `
        -StartNumber 1 `
        -EndNumber 1000
#>

[CmdletBinding()]
param(
    # ドメイン（テナント識別とUPNに使用）
    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]$Domain = "demo99.netattest.tech",
    
    # アプリケーションID
    [Parameter(Mandatory=$true, HelpMessage="アプリ登録のクライアントIDを入力してください")]
    [ValidateNotNullOrEmpty()]
    [string]$ClientId,
    
    # クライアントシークレット
    [Parameter(Mandatory=$true, HelpMessage="クライアントシークレットを入力してください")]
    [ValidateNotNullOrEmpty()]
    [string]$ClientSecret,
    
    # DryRunモード
    [Parameter(Mandatory=$false)]
    [switch]$DryRun,
    
    # 削除開始番号
    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 999999)]
    [int]$StartNumber = 1,
    
    # 削除終了番号
    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 999999)]
    [int]$EndNumber = 5,
    
    # ログファイルパス
    [Parameter(Mandatory=$false)]
    [string]$DeleteLog = ".\delete_users.log"
)

# 共通ライブラリの読み込み
. "$PSScriptRoot\lib\EntraIDLib.ps1"

# MSAL.PSモジュールの初期化
Initialize-MsalModule

# ===== 削除条件 =====
$UserPrefix = "testuser"

# アクセストークンを取得（EntraIDLib.ps1の関数を使用）
Write-Host "アクセストークン取得中..." -ForegroundColor Cyan
$AccessToken = Get-MsalAccessToken -TenantIdentifier $Domain -ClientId $ClientId -ClientSecret $ClientSecret

Write-Host "✓ アクセストークン取得成功" -ForegroundColor Green
Write-Host "MSAL.PSがトークンのキャッシュと自動更新を管理します" -ForegroundColor Gray

$Headers = New-GraphApiHeaders -AccessToken $AccessToken

# 実行モード表示
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "ユーザー削除スクリプト" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "ドメイン: $Domain" -ForegroundColor Yellow
Write-Host "削除範囲: testuser$('{0:D6}' -f $StartNumber) ～ testuser$('{0:D6}' -f $EndNumber) ($($EndNumber - $StartNumber + 1) ユーザー)" -ForegroundColor Yellow
if ($DryRun) {
    Write-Host "モード: DryRun（削除しない、ログ記録のみ）" -ForegroundColor Green
} else {
    Write-Host "モード: 実削除（警告: 実際に削除されます！）" -ForegroundColor Red
}
Write-Host "ログファイル: $DeleteLog" -ForegroundColor Gray
Write-Host "========================================`n" -ForegroundColor Cyan

# ユーザー削除
function Remove-EntraUser {
    param (
        [string]$UserId,
        [string]$Upn
    )

    if ($DryRun) {
        Write-Host "[DryRun] $Upn を削除対象として記録" -ForegroundColor Yellow
        "[DryRun] delete $Upn" | Out-File $DeleteLog -Append
        return
    }

    Invoke-RestMethod `
      -Uri "https://graph.microsoft.com/v1.0/users/$UserId" `
      -Headers $Headers `
      -Method DELETE `
      -TimeoutSec 30

    Write-Host "✓ 削除: $Upn" -ForegroundColor Green
    "Deleted $Upn" | Out-File $DeleteLog -Append
}

# ユーザー検索＋削除実行

$startTime = Get-Date
$deletedCount = 0
$notFoundCount = 0

for ($i = $StartNumber; $i -le $EndNumber; $i++) {

    # MSAL.PSでトークンを自動更新（100ユーザーごと）
    if (($i % 100) -eq 0 -and $i -gt 0) {
        try {
            $AccessToken = Get-MsalAccessToken -TenantIdentifier $Domain -ClientId $ClientId -ClientSecret $ClientSecret
            $Headers = New-GraphApiHeaders -AccessToken $AccessToken
        } catch {
            # エラーでも既存トークンで継続
            "Token refresh attempt failed at user $i" | Out-File $DeleteLog -Append
        }
    }

    $UserName = "testuser{0:D6}" -f $i
    $Upn = "$UserName@$Domain"

    try {
        # UPN でユーザー取得
        $User = Invoke-RestMethod `
          -Uri "https://graph.microsoft.com/v1.0/users/$Upn" `
          -Headers $Headers `
          -Method GET `
          -TimeoutSec 30 `
          -ErrorAction Stop

        Remove-EntraUser -UserId $User.id -Upn $Upn
        $deletedCount++
    }
    catch {
        $notFoundCount++
        "Not found or failed: $Upn" | Out-File $DeleteLog -Append
    }

    # 進捗表示とスロットリング対策
    if ($i % 100 -eq 0) {
        Write-Host "進捗: $i / $($EndNumber - $StartNumber + 1) 処理完了 (削除: $deletedCount, 未検出: $notFoundCount)" -ForegroundColor Cyan
        Start-Sleep -Milliseconds 300
    }
}

$endTime = Get-Date
$totalTime = ($endTime - $startTime).TotalSeconds
$processedCount = $EndNumber - $StartNumber + 1

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "処理が完了しました！" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "処理対象: $processedCount ユーザー" -ForegroundColor Yellow
if ($DryRun) {
    Write-Host "削除対象: $deletedCount ユーザー（DryRunのため実削除なし）" -ForegroundColor Yellow
} else {
    Write-Host "削除完了: $deletedCount ユーザー" -ForegroundColor Green
}
Write-Host "未検出: $notFoundCount ユーザー" -ForegroundColor Gray
Write-Host "総処理時間: $([math]::Round($totalTime, 2)) 秒" -ForegroundColor Yellow
if ($totalTime -gt 0) {
    Write-Host "平均速度: $([math]::Round($processedCount / $totalTime, 2)) user/s" -ForegroundColor Yellow
}
Write-Host "詳細はログファイルを確認してください: $DeleteLog" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

