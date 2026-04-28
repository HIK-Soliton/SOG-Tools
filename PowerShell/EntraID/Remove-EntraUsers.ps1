<#
.SYNOPSIS
    Entra IDからテストユーザーを削除するスクリプト
    
.DESCRIPTION
    testuser000001～testuserXXXXXXの指定範囲のユーザーを削除します。
    
    DryRunモード：
    - DryRun = $true の場合、削除せずにログに記録のみ
    - DryRun = $false の場合、実際に削除を実行
    
    アクセストークンの自動管理：
    - トークンの有効期限を自動的に監視
    - 有効期限の5分前に自動的に再取得
    - 大量ユーザー削除時の401エラーを防止

.EXAMPLE
    # DryRunモードで実行（削除しない）
    .\Remove-EntraUsers.ps1 `
        -TenantDomain "yourname.onmicrosoft.com" `
        -ClientId "your-client-id" `
        -ClientSecret "your-client-secret" `
        -DryRun

.EXAMPLE
    # 実際に削除を実行
    .\Remove-EntraUsers.ps1 `
        -TenantDomain "yourname.onmicrosoft.com" `
        -ClientId "your-client-id" `
        -ClientSecret "your-client-secret"

.EXAMPLE
    # 範囲を指定して削除
    .\Remove-EntraUsers.ps1 `
        -TenantDomain "yourname.onmicrosoft.com" `
        -ClientId "your-client-id" `
        -ClientSecret "your-client-secret" `
        -StartNumber 1 `
        -EndNumber 1000
#>

[CmdletBinding()]
param(
    # テナント識別用ドメイン（認証に使用）
    [Parameter(Mandatory=$true, HelpMessage="テナント識別用ドメイン名を入力してください（例: yourname.onmicrosoft.com）")]
    [ValidateNotNullOrEmpty()]
    [string]$TenantDomain = "demo99.netattest.tech",
    
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
    
    # ユーザードメイン（UPN用）
    [Parameter(Mandatory=$false)]
    [string]$Domain = "demo99.netattest.tech",
    
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

# パラメータ

# ===== 削除条件 =====
$UserPrefix = "testuser"

# アクセストークン取得関数（有効期限も取得）
function Get-AccessToken {
    param(
        [string]$TenantDomain,
        [string]$ClientId,
        [string]$ClientSecret
    )
    
    try {
        $TokenResponse = Invoke-RestMethod `
          -Uri "https://login.microsoftonline.com/$TenantDomain/oauth2/v2.0/token" `
          -Method POST `
          -ContentType "application/x-www-form-urlencoded" `
          -TimeoutSec 30 `
          -Body @{
              client_id     = $ClientId
              client_secret = $ClientSecret
              scope         = "https://graph.microsoft.com/.default"
              grant_type    = "client_credentials"
          }
        
        $AccessToken = $TokenResponse.access_token
        
        # トークンから有効期限を取得（JWTデコード）
        $TokenExpiry = $null
        try {
            $tokenParts = $AccessToken.Split('.')
            if ($tokenParts.Length -ge 2) {
                $payload = $tokenParts[1]
                $payload = $payload.Replace('-', '+').Replace('_', '/')
                while ($payload.Length % 4 -ne 0) { $payload += '=' }
                
                $payloadJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
                $claims = $payloadJson | ConvertFrom-Json
                
                if ($claims.exp) {
                    # Unix Epoch（1970/1/1からの秒数）をDateTimeに変換
                    $TokenExpiry = [DateTimeOffset]::FromUnixTimeSeconds($claims.exp).LocalDateTime
                }
            }
        } catch {
            Write-Host "  警告: トークンのデコードに失敗しました" -ForegroundColor Yellow
        }
        
        return @{
            Token = $AccessToken
            Expiry = $TokenExpiry
        }
    } catch {
        throw "アクセストークンの取得に失敗しました: $_"
    }
}

# 初回アクセストークン取得
Write-Host "アクセストークン取得中..." -ForegroundColor Cyan
$TokenInfo = Get-AccessToken -TenantDomain $TenantDomain -ClientId $ClientId -ClientSecret $ClientSecret
$AccessToken = $TokenInfo.Token
$TokenExpiry = $TokenInfo.Expiry

if ($TokenExpiry) {
    Write-Host "トークン有効期限: $($TokenExpiry.ToString('yyyy/MM/dd HH:mm:ss'))" -ForegroundColor Gray
}

$Headers = @{
    Authorization  = "Bearer $AccessToken"
    "Content-Type" = "application/json"
}

# 実行モード表示
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "ユーザー削除スクリプト" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "テナントドメイン: $TenantDomain" -ForegroundColor Yellow
Write-Host "対象ドメイン: $Domain" -ForegroundColor Yellow
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

    # トークン有効期限チェック（期限の5分前に再取得）
    if ($TokenExpiry) {
        $minutesUntilExpiry = ($TokenExpiry - (Get-Date)).TotalMinutes
        if ($minutesUntilExpiry -lt 5) {
            Write-Host "`n🔄 アクセストークンの有効期限が近づいています（残り: $([math]::Round($minutesUntilExpiry, 1))分）" -ForegroundColor Yellow
            Write-Host "🔄 トークンを再取得中..." -ForegroundColor Yellow
            
            try {
                $TokenInfo = Get-AccessToken -TenantDomain $TenantDomain -ClientId $ClientId -ClientSecret $ClientSecret
                $AccessToken = $TokenInfo.Token
                $TokenExpiry = $TokenInfo.Expiry
                
                # ヘッダーを更新
                $Headers["Authorization"] = "Bearer $AccessToken"
                
                Write-Host "✓ トークン再取得成功（新しい有効期限: $($TokenExpiry.ToString('yyyy/MM/dd HH:mm:ss'))）" -ForegroundColor Green
                Write-Host "⏸ トークン安定化のため3秒待機..." -ForegroundColor Gray
                Start-Sleep -Seconds 3
                
                "Token refreshed at user $i" | Out-File $DeleteLog -Append
            } catch {
                Write-Host "✗ トークン再取得失敗: $_" -ForegroundColor Red
                "Token refresh failed at user $i : $_" | Out-File $DeleteLog -Append
            }
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

