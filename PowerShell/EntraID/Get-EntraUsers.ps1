<#
.SYNOPSIS
    Entra IDのユーザー一覧を取得するスクリプト
    
.DESCRIPTION
    Microsoft Graph APIを使用してEntra IDのユーザー一覧を取得します。
    フィルタリング、グループメンバーシップの表示、CSV出力が可能です。
    
    MSAL.PSによるトークン自動管理：
    - MSAL (Microsoft Authentication Library) を使用
    - トークンのキャッシュと自動更新
    - 有効期限切れ前の自動リフレッシュ
    - 大量ユーザー取得時の401エラーを防止
    
.EXAMPLE
    # すべてのユーザーを取得
    .\Get-EntraUsers.ps1 `
        -ClientId "your-client-id" `
        -ClientSecret "your-secret" `
        -Domain "yourname.onmicrosoft.com"
    
.EXAMPLE
    # testuser*のユーザーのみ取得
    .\Get-EntraUsers.ps1 `
        -ClientId "your-client-id" `
        -ClientSecret "your-secret" `
        -Domain "yourname.onmicrosoft.com" `
        -Filter "testuser"
    
.EXAMPLE
    # グループ情報を含めて取得
    .\Get-EntraUsers.ps1 `
        -ClientId "your-client-id" `
        -ClientSecret "your-secret" `
        -Domain "yourname.onmicrosoft.com" `
        -Filter "testuser" `
        -IncludeGroups
    
.EXAMPLE
    # CSV出力
    .\Get-EntraUsers.ps1 `
        -ClientId "your-client-id" `
        -ClientSecret "your-secret" `
        -Domain "yourname.onmicrosoft.com" `
        -OutputCsv "users.csv"
    
.EXAMPLE
    # CSV出力（グループ情報含む）
    .\Get-EntraUsers.ps1 `
        -ClientId "your-client-id" `
        -ClientSecret "your-secret" `
        -Domain "yourname.onmicrosoft.com" `
        -Filter "testuser" `
        -IncludeGroups `
        -OutputCsv "users_with_groups.csv"
#>

[CmdletBinding()]
param(
    # ドメイン名
    [Parameter(HelpMessage="Entra IDのプライマリドメイン名（例: yourname.onmicrosoft.com）")]
    [string]$Domain,
    
    # テナントID
    [Parameter(HelpMessage="Entra IDのテナントID（省略時はドメイン名から自動判定）")]
    [string]$TenantId,
    
    # クライアントID
    [Parameter(Mandatory=$true, HelpMessage="アプリ登録のクライアントIDを入力してください")]
    [ValidateNotNullOrEmpty()]
    [string]$ClientId,
    
    # クライアントシークレット
    [Parameter(Mandatory=$true, HelpMessage="クライアントシークレットを入力してください")]
    [ValidateNotNullOrEmpty()]
    [string]$ClientSecret,
    
    # フィルター（ユーザー名の一部）
    [Parameter(HelpMessage="ユーザー名フィルター（例: testuser）")]
    [string]$Filter,
    
    # グループ情報を取得
    [switch]$IncludeGroups,
    
    # CSV出力先
    [Parameter(HelpMessage="CSV出力先ファイルパス")]
    [string]$OutputCsv,
    
    # 最大取得件数
    [Parameter(HelpMessage="取得する最大ユーザー数（デフォルト: すべて）")]
    [int]$MaxResults = 0
)

$ErrorActionPreference = "Continue"

# 共通ライブラリの読み込み
. "$PSScriptRoot\lib\EntraIDLib.ps1"

# MSAL.PSモジュールの初期化
Write-Host "[0/3] MSAL.PSモジュール確認中..." -ForegroundColor Green
Initialize-MsalModule

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Entra ID ユーザー一覧取得スクリプト" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# テナント識別子を決定
if ($TenantId) {
    $tenantIdentifier = $TenantId
    Write-Host "テナント識別子: $tenantIdentifier (テナントID)" -ForegroundColor Gray
} elseif ($Domain) {
    $tenantIdentifier = $Domain
    Write-Host "テナント識別子: $tenantIdentifier (ドメイン名)" -ForegroundColor Gray
} else {
    Write-Host "エラー: テナントIDまたはドメイン名のいずれかが必要です" -ForegroundColor Red
    exit 1
}

# MSAL.PSでアクセストークンを取得（EntraIDLib.ps1の関数を使用）
Write-Host "[1/3] アクセストークン取得中..." -ForegroundColor Green
try {
    $accessToken = Get-MsalAccessToken -TenantIdentifier $tenantIdentifier -ClientId $ClientId -ClientSecret $ClientSecret
    
    Write-Host "  ✓ アクセストークン取得成功" -ForegroundColor Green
    Write-Host "  MSAL.PSがトークンのキャッシュと自動更新を管理します" -ForegroundColor Gray
    
    # 認証ヘッダー
    $headers = New-GraphApiHeaders -AccessToken $accessToken
} catch {
    Write-Host "  ✗ トークン取得失敗: $_" -ForegroundColor Red
    exit 1
}

# ユーザー一覧を取得
Write-Host "`n[2/3] ユーザー一覧を取得中..." -ForegroundColor Green
Write-Host "  MSAL.PSによる自動トークン管理が有効" -ForegroundColor Gray

# フィルター条件を構築
$filterQuery = ""
if ($Filter) {
    # startsWith を使用（部分一致）
    $filterQuery = "`$filter=startsWith(userPrincipalName,'$Filter') or startsWith(displayName,'$Filter')"
    Write-Host "  フィルター: $Filter" -ForegroundColor Gray
}

# ページング対応でユーザーを取得
$allUsers = @()
$nextLink = if ($filterQuery) {
    "https://graph.microsoft.com/v1.0/users?$filterQuery&`$top=999&`$select=id,userPrincipalName,displayName,accountEnabled,createdDateTime"
} else {
    "https://graph.microsoft.com/v1.0/users?`$top=999&`$select=id,userPrincipalName,displayName,accountEnabled,createdDateTime"
}

$pageCount = 0
while ($nextLink -and ($MaxResults -eq 0 -or $allUsers.Count -lt $MaxResults)) {
    # MSAL.PSでトークンを取得（自動的にキャッシュから取得または更新）
    try {
        $accessToken = Get-MsalAccessToken -TenantIdentifier $tenantIdentifier -ClientId $ClientId -ClientSecret $ClientSecret
        $headers = New-GraphApiHeaders -AccessToken $accessToken
    } catch {
        Write-Host "  ⚠ トークン更新時の警告: $_" -ForegroundColor Yellow
        # エラーでもAPI呼び出しを試行（既存トークンで継続）
    }
    
    try {
        $response = Invoke-RestMethod -Method Get -Uri $nextLink -Headers $headers -TimeoutSec 30
        $allUsers += $response.value
        $pageCount++
        
        Write-Host "  取得中... $($allUsers.Count) ユーザー (ページ $pageCount)" -ForegroundColor Gray
        
        $nextLink = $response.'@odata.nextLink'
        
        # MaxResults指定時の制限
        if ($MaxResults -gt 0 -and $allUsers.Count -ge $MaxResults) {
            $allUsers = $allUsers[0..($MaxResults-1)]
            break
        }
    } catch {
        Write-Host "  ✗ ユーザー取得エラー: $_" -ForegroundColor Red
        break
    }
}

Write-Host "  ✓ $($allUsers.Count) ユーザーを取得しました" -ForegroundColor Green

# グループ情報を取得（オプション）
if ($IncludeGroups -and $allUsers.Count -gt 0) {
    Write-Host "`n  グループメンバーシップを取得中..." -ForegroundColor Yellow
    Write-Host "  （各ユーザーのAPI呼び出しが必要なため、時間がかかる場合があります）" -ForegroundColor Gray
    Write-Host "  MSAL.PSによる自動トークン管理が有効" -ForegroundColor Gray
    
    $groupFetchStart = Get-Date
    $successCount = 0
    $errorCount = 0
    
    for ($i = 0; $i -lt $allUsers.Count; $i++) {
        # MSAL.PSでトークンを自動更新（100ユーザーごと）
        if (($i % 100) -eq 0 -and $i -gt 0) {
            try {
                $accessToken = Get-MsalAccessToken -TenantIdentifier $tenantIdentifier -ClientId $ClientId -ClientSecret $ClientSecret
                $headers = New-GraphApiHeaders -AccessToken $accessToken
            } catch {
                # エラーでも既存トークンで継続
            }
        }
        
        $user = $allUsers[$i]
        try {
            # ページング対応でグループを取得（大量グループ対策）
            $allGroups = @()
            $groupsNextLink = "https://graph.microsoft.com/v1.0/users/$($user.id)/memberOf?`$select=displayName,id&`$top=999"
            
            while ($groupsNextLink) {
                $groupsResponse = Invoke-RestMethod -Method Get -Uri $groupsNextLink -Headers $headers -TimeoutSec 30
                $allGroups += $groupsResponse.value
                $groupsNextLink = $groupsResponse.'@odata.nextLink'
            }
            
            $groupNames = ($allGroups | ForEach-Object { $_.displayName }) -join ", "
            $groupCount = $allGroups.Count
            
            # ユーザーオブジェクトにグループ情報を追加
            $allUsers[$i] | Add-Member -NotePropertyName "Groups" -NotePropertyValue $groupNames -Force
            $allUsers[$i] | Add-Member -NotePropertyName "GroupCount" -NotePropertyValue $groupCount -Force
            
            $successCount++
            
            if (($i + 1) % 50 -eq 0) {
                $elapsed = ((Get-Date) - $groupFetchStart).TotalSeconds
                $rate = if ($elapsed -gt 0) { [math]::Round(($i + 1) / $elapsed, 2) } else { 0 }
                Write-Host "    進捗: $($i + 1) / $($allUsers.Count) ($rate user/s)" -ForegroundColor Gray
            }
        } catch {
            $allUsers[$i] | Add-Member -NotePropertyName "Groups" -NotePropertyValue "取得失敗: $_" -Force
            $allUsers[$i] | Add-Member -NotePropertyName "GroupCount" -NotePropertyValue 0 -Force
            $errorCount++
            
            if ($errorCount -le 5) {
                Write-Host "    ⚠ $($user.userPrincipalName): グループ取得失敗" -ForegroundColor Yellow
            }
        }
        
        # スロットリング対策
        if (($i + 1) % 100 -eq 0) {
            Start-Sleep -Milliseconds 200
        }
    }
    
    $groupFetchEnd = Get-Date
    $totalTime = ($groupFetchEnd - $groupFetchStart).TotalSeconds
    Write-Host "  ✓ グループ情報取得完了（成功: $successCount, 失敗: $errorCount, 時間: $([math]::Round($totalTime, 1))秒）" -ForegroundColor Green
}

# 結果表示
Write-Host "`n[3/3] 結果表示" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan

if ($allUsers.Count -eq 0) {
    Write-Host "該当するユーザーが見つかりませんでした" -ForegroundColor Yellow
} else {
    # サマリー表示
    $enabledCount = ($allUsers | Where-Object { $_.accountEnabled -eq $true }).Count
    $disabledCount = $allUsers.Count - $enabledCount
    
    Write-Host "総ユーザー数: $($allUsers.Count)" -ForegroundColor Yellow
    Write-Host "  有効: $enabledCount" -ForegroundColor Green
    Write-Host "  無効: $disabledCount" -ForegroundColor Gray
    Write-Host ""
    
    # 最初の10件を表示
    $displayCount = [Math]::Min(10, $allUsers.Count)
    Write-Host "最初の $displayCount 件を表示:" -ForegroundColor Cyan
    Write-Host ""
    
    $allUsers[0..($displayCount-1)] | ForEach-Object {
        $status = if ($_.accountEnabled) { "有効" } else { "無効" }
        $statusColor = if ($_.accountEnabled) { "Green" } else { "Gray" }
        
        Write-Host "  [$status] $($_.userPrincipalName)" -ForegroundColor $statusColor
        Write-Host "      表示名: $($_.displayName)" -ForegroundColor Gray
        if ($_.GroupCount -ne $null) {
            Write-Host "      グループ数: $($_.GroupCount)" -ForegroundColor Gray
            if ($_.Groups -and $_.Groups.Length -gt 0) {
                $groupList = if ($_.Groups.Length -gt 100) { $_.Groups.Substring(0, 100) + "..." } else { $_.Groups }
                Write-Host "      グループ: $groupList" -ForegroundColor Gray
            }
        }
        Write-Host ""
    }
    
    if ($allUsers.Count -gt $displayCount) {
        Write-Host "  ... 他 $($allUsers.Count - $displayCount) 件" -ForegroundColor Gray
        Write-Host ""
    }
}

# CSV出力
if ($OutputCsv -and $allUsers.Count -gt 0) {
    Write-Host "CSV出力中: $OutputCsv" -ForegroundColor Cyan
    try {
        if ($IncludeGroups) {
            $allUsers | Select-Object userPrincipalName, displayName, accountEnabled, createdDateTime, GroupCount, Groups | Export-Csv -Path $OutputCsv -Encoding UTF8 -NoTypeInformation
        } else {
            $allUsers | Select-Object userPrincipalName, displayName, accountEnabled, createdDateTime | Export-Csv -Path $OutputCsv -Encoding UTF8 -NoTypeInformation
        }
        Write-Host "  ✓ CSV出力完了: $OutputCsv" -ForegroundColor Green
        
        # ファイルサイズ表示
        $fileInfo = Get-Item $OutputCsv
        $fileSizeMB = [math]::Round($fileInfo.Length / 1MB, 2)
        Write-Host "  ファイルサイズ: $fileSizeMB MB" -ForegroundColor Gray
    } catch {
        Write-Host "  ✗ CSV出力失敗: $_" -ForegroundColor Red
    }
}

Write-Host "`n処理が完了しました！" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
