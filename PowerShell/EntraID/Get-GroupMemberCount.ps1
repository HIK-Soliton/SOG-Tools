<#
.SYNOPSIS
    Entra IDの特定グループのメンバー数を取得し、testuser000001～300000をグループに追加するスクリプト
    
.DESCRIPTION
    Microsoft Graph APIを使用してEntra IDの指定したグループのメンバー数を取得します。
    グループ名を指定しない場合は、デフォルトでgrp001のメンバー数を取得します。
    
    -AddMissingUsersスイッチを指定すると、testuser000001～testuser300000のうち、
    指定グループに所属していないユーザーを自動的にグループに追加します。
    
    アクセストークンの自動管理：
    - トークンの有効期限を自動的に監視
    - 有効期限の1分前に自動的に再取得
    - 大量ユーザー処理時の401エラーを防止
    
.EXAMPLE
    # grp001のメンバー数を取得
    .\Get-GroupMemberCount.ps1 `
        -TenantDomain "yourname.onmicrosoft.com" `
        -ClientId "your-client-id" `
        -ClientSecret "your-secret"
    
.EXAMPLE
    # 特定のグループのメンバー数を取得
    .\Get-GroupMemberCount.ps1 `
        -TenantDomain "yourname.onmicrosoft.com" `
        -ClientId "your-client-id" `
        -ClientSecret "your-secret" `
        -GroupName "grp030"

.EXAMPLE
    # testuser000001～300000をgrp001に追加（不足メンバーのみ）
    .\Get-GroupMemberCount.ps1 `
        -TenantDomain "yourname.onmicrosoft.com" `
        -ClientId "your-client-id" `
        -ClientSecret "your-secret" `
        -GroupName "grp001" `
        -AddMissingUsers

.EXAMPLE
    # 複数のグループのメンバー数を取得
    1..30 | ForEach-Object {
        .\Get-GroupMemberCount.ps1 `
            -TenantDomain "yourname.onmicrosoft.com" `
            -ClientId "your-client-id" `
            -ClientSecret "your-secret" `
            -GroupName "grp$('{0:D3}' -f $_)"
    }
#>

[CmdletBinding()]
param(
    # テナントドメイン名
    [Parameter(Mandatory=$false, HelpMessage="テナント識別用ドメイン名を入力してください（例: yourname.onmicrosoft.com）")]
    [ValidateNotNullOrEmpty()]
    [string]$TenantDomain="demo99.netattest.tech",
    
    # クライアントID（必須）
    [Parameter(Mandatory=$true, HelpMessage="アプリ登録のクライアントIDを入力してください")]
    [ValidateNotNullOrEmpty()]
    [string]$ClientId,
    
    # クライアントシークレット（必須）
    [Parameter(Mandatory=$true, HelpMessage="クライアントシークレットを入力してください")]
    [ValidateNotNullOrEmpty()]
    [string]$ClientSecret,
    
    # グループ名
    [Parameter(HelpMessage="グループ名（例: grp001）")]
    [string]$GroupName = "grp001",
    
    # 不足メンバーを追加
    [switch]$AddMissingUsers,
    
    # 詳細表示
    [switch]$Detailed,
    
    # ログファイルパス（指定しない場合は自動生成）
    [string]$LogFile = ""
)

$ErrorActionPreference = "Stop"

# ログファイル設定
if ([string]::IsNullOrEmpty($LogFile)) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $LogFile = "Get-GroupMemberCount_$timestamp.log"
}

# ログ出力関数
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy/MM/dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # ファイルに出力
    Add-Content -Path $LogFile -Value $logMessage -Encoding UTF8
    
    # コンソールにも出力（レベルに応じた色分け）
    switch ($Level) {
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
        "WARNING" { Write-Host $logMessage -ForegroundColor Yellow }
        "ERROR"   { Write-Host $logMessage -ForegroundColor Red }
        default   { Write-Host $logMessage -ForegroundColor Gray }
    }
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "グループメンバー数取得スクリプト" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "グループ名: $GroupName" -ForegroundColor Yellow
Write-Host "ログファイル: $LogFile" -ForegroundColor Gray
if ($AddMissingUsers) {
    Write-Host "モード: メンバー追加モード（testuser000001～300000）" -ForegroundColor Green
} else {
    Write-Host "モード: メンバー数取得のみ" -ForegroundColor Yellow
}
Write-Host ""

Write-Log "========== スクリプト開始 =========="
Write-Log "グループ名: $GroupName"
Write-Log "テナントドメイン: $TenantDomain"
Write-Log "モード: $(if ($AddMissingUsers) { 'メンバー追加モード' } else { 'メンバー数取得のみ' })"

# アクセストークン取得関数（有効期限も取得）
function Get-AccessToken {
    param(
        [string]$TenantDomain,
        [string]$ClientId,
        [string]$ClientSecret
    )
    
    try {
        $tokenUrl = "https://login.microsoftonline.com/$TenantDomain/oauth2/v2.0/token"
        $tokenBody = @{
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = "https://graph.microsoft.com/.default"
            grant_type    = "client_credentials"
        }
        $tokenResponse = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $tokenBody -ContentType "application/x-www-form-urlencoded" -TimeoutSec 30
        $accessToken = $tokenResponse.access_token
        
        # トークンから有効期限を取得（JWTデコード）
        $tokenExpiry = $null
        try {
            $tokenParts = $accessToken.Split('.')
            if ($tokenParts.Length -ge 2) {
                $payload = $tokenParts[1]
                $payload = $payload.Replace('-', '+').Replace('_', '/')
                while ($payload.Length % 4 -ne 0) { $payload += '=' }
                
                $payloadJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
                $claims = $payloadJson | ConvertFrom-Json
                
                if ($claims.exp) {
                    # Unix Epoch（1970/1/1からの秒数）をDateTimeに変換
                    $tokenExpiry = [DateTimeOffset]::FromUnixTimeSeconds($claims.exp).LocalDateTime
                }
            }
        } catch {
            Write-Host "  警告: トークンのデコードに失敗しました" -ForegroundColor Yellow
        }
        
        return @{
            Token = $accessToken
            Expiry = $tokenExpiry
        }
    } catch {
        throw "アクセストークンの取得に失敗しました: $_"
    }
}

# アクセストークン取得
Write-Host "[1/4] アクセストークン取得中..." -ForegroundColor Green
try {
    $tokenInfo = Get-AccessToken -TenantDomain $TenantDomain -ClientId $ClientId -ClientSecret $ClientSecret
    $accessToken = $tokenInfo.Token
    $tokenExpiry = $tokenInfo.Expiry
    
    Write-Host "  ✓ アクセストークン取得成功" -ForegroundColor Green
    if ($tokenExpiry) {
        Write-Host "  トークン有効期限: $($tokenExpiry.ToString('yyyy/MM/dd HH:mm:ss'))" -ForegroundColor Gray
        Write-Log "アクセストークン取得成功（有効期限: $($tokenExpiry.ToString('yyyy/MM/dd HH:mm:ss')))" "SUCCESS"
    } else {
        Write-Log "アクセストークン取得成功" "SUCCESS"
    }
    
    # 認証ヘッダー
    $headers = @{
        "Authorization" = "Bearer $accessToken"
        "Content-Type"  = "application/json"
    }
} catch {
    Write-Host "  ✗ トークン取得失敗: $_" -ForegroundColor Red    Write-Log "アクセストークン取得エラー: $_" "ERROR"    exit 1
}

# グループ検索
Write-Host "`n[2/4] グループを検索中..." -ForegroundColor Green
try {
    $searchUri = "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$GroupName'&`$select=id,displayName,description"
    $groupResponse = Invoke-RestMethod -Method Get -Uri $searchUri -Headers $headers -TimeoutSec 30
    
    if ($groupResponse.value.Count -eq 0) {
        Write-Host "  ✗ グループが見つかりません: $GroupName" -ForegroundColor Red
        exit 1
    }
    
    $group = $groupResponse.value[0]
    Write-Host "  ✓ グループ検出: $($group.displayName) (ID: $($group.id))" -ForegroundColor Green
    Write-Log "グループ検出: $($group.displayName) (ID: $($group.id))" "SUCCESS"
    
    if ($group.description) {
        Write-Host "  説明: $($group.description)" -ForegroundColor Gray
        Write-Log "グループ説明: $($group.description)"
    }
} catch {
    Write-Host "  ✗ グループ検索エラー: $_" -ForegroundColor Red
    Write-Log "グループ検索エラー: $_" "ERROR"
    exit 1
}

# メンバー数取得
Write-Host "`n[3/4] メンバー数を取得中..." -ForegroundColor Green
try {
    # $countパラメータを使用して効率的に取得
    $membersUri = "https://graph.microsoft.com/v1.0/groups/$($group.id)/members/`$count"
    $memberCount = Invoke-RestMethod -Method Get -Uri $membersUri -Headers $headers -TimeoutSec 30
    
    Write-Host "  ✓ メンバー数取得成功" -ForegroundColor Green
} catch {
    # $countが使えない場合は全メンバーを取得してカウント
    Write-Host "  $count API使用不可、全メンバーを取得してカウント中..." -ForegroundColor Yellow
    
    try {
        $allMembers = @()
        $membersNextLink = "https://graph.microsoft.com/v1.0/groups/$($group.id)/members?`$top=999&`$select=id"
        
        while ($membersNextLink) {
            $membersResponse = Invoke-RestMethod -Method Get -Uri $membersNextLink -Headers $headers -TimeoutSec 30
            $allMembers += $membersResponse.value
            $membersNextLink = $membersResponse.'@odata.nextLink'
            
            if ($allMembers.Count % 1000 -eq 0) {
                Write-Host "  取得中... $($allMembers.Count) メンバー" -ForegroundColor Gray
            }
        }
        
        $memberCount = $allMembers.Count
        Write-Host "  ✓ メンバー数取得成功" -ForegroundColor Green
    } catch {
        Write-Host "  ✗ メンバー数取得エラー: $_" -ForegroundColor Red
        exit 1
    }
}

# 結果表示
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "結果" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "グループ名: $($group.displayName)" -ForegroundColor Yellow
Write-Host "グループID: $($group.id)" -ForegroundColor Gray
Write-Host "メンバー数: $memberCount 人" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan

# 不足メンバーを追加
if ($AddMissingUsers) {
    Write-Host "`n[4/4] 不足メンバーを追加中..." -ForegroundColor Green
    Write-Host "  対象: testuser000001～testuser300000" -ForegroundColor Gray
    Write-Host "  トークン自動管理: 有効期限の1分前に自動再取得" -ForegroundColor Gray
    
    # 既存メンバーのUPNリストを取得
    Write-Host "`n  既存メンバーのUPNリストを取得中..." -ForegroundColor Yellow
    $existingMembers = @{}
    $membersNextLink = "https://graph.microsoft.com/v1.0/groups/$($group.id)/members?`$top=999&`$select=userPrincipalName"
    
    while ($membersNextLink) {
        $membersResponse = Invoke-RestMethod -Method Get -Uri $membersNextLink -Headers $headers -TimeoutSec 30
        foreach ($member in $membersResponse.value) {
            if ($member.userPrincipalName) {
                $existingMembers[$member.userPrincipalName] = $true
            }
        }
        $membersNextLink = $membersResponse.'@odata.nextLink'
    }
    
    Write-Host "  ✓ 既存メンバー数: $($existingMembers.Count)" -ForegroundColor Green
    Write-Log "既存メンバー数: $($existingMembers.Count)" "SUCCESS"
    
    # testuser000001～300000をチェック
    $startTime = Get-Date
    Write-Log "testuser000001～300000のチェック開始"
    $checkedCount = 0
    $addedCount = 0
    $skippedCount = 0
    $errorCount = 0
    $totalUsers = 300000
    
    Write-Host "`n  testuser000001～300000をチェック中..." -ForegroundColor Yellow
    
    for ($i = 1; $i -le $totalUsers; $i++) {
        # トークン有効期限チェック（期限の1分前に再取得）
        if ($tokenExpiry) {
            $minutesUntilExpiry = ($tokenExpiry - (Get-Date)).TotalMinutes
            if ($minutesUntilExpiry -lt 1) {
                Write-Host "`n    🔄 アクセストークンの有効期限が近づいています（残り: $([math]::Round($minutesUntilExpiry, 1))分）" -ForegroundColor Yellow
                Write-Host "    🔄 トークンを再取得中..." -ForegroundColor Yellow
                
                try {
                    $tokenInfo = Get-AccessToken -TenantDomain $TenantDomain -ClientId $ClientId -ClientSecret $ClientSecret
                    $accessToken = $tokenInfo.Token
                    $tokenExpiry = $tokenInfo.Expiry
                    
                    # ヘッダーを更新
                    $headers["Authorization"] = "Bearer $accessToken"
                    
                    Write-Host "    ✓ トークン再取得成功（新しい有効期限: $($tokenExpiry.ToString('yyyy/MM/dd HH:mm:ss'))）" -ForegroundColor Green
                    Write-Log "アクセストークン再取得成功（有効期限: $($tokenExpiry.ToString('yyyy/MM/dd HH:mm:ss'))）" "SUCCESS"
                    Write-Host "    ⏸ トークン安定化のため3秒待機..." -ForegroundColor Gray
                    Start-Sleep -Seconds 3
                } catch {
                    Write-Host "    ✗ トークン再取得失敗: $_" -ForegroundColor Red
                    Write-Log "アクセストークン再取得失敗: $_" "ERROR"
                    Write-Host "    既存のトークンで続行します" -ForegroundColor Yellow
                    Write-Log "既存のトークンで続行" "WARNING"
                }
            }
        }
        
        $userName = "testuser{0:D6}" -f $i
        $upn = "$userName@$TenantDomain"
        $checkedCount++
        
        # 既にメンバーの場合はスキップ
        if ($existingMembers.ContainsKey($upn)) {
            $skippedCount++
        } else {
            # ユーザーを取得してグループに追加
            try {
                # ユーザーID取得
                $userUri = "https://graph.microsoft.com/v1.0/users/$upn"
                $user = Invoke-RestMethod -Method Get -Uri $userUri -Headers $headers -TimeoutSec 30 -ErrorAction Stop
                
                # グループに追加
                $memberBody = @{
                    "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($user.id)"
                } | ConvertTo-Json
                
                Invoke-RestMethod `
                    -Uri "https://graph.microsoft.com/v1.0/groups/$($group.id)/members/`$ref" `
                    -Headers $headers `
                    -Method POST `
                    -Body $memberBody `
                    -TimeoutSec 30 | Out-Null
                
                $addedCount++
                
                # 最初の10件のみコンソール表示
                if ($addedCount -le 10) {
                    Write-Host "    ✓ 追加: $upn" -ForegroundColor Green
                }
                
                # すべてログに記録
                Write-Log "メンバー追加: $upn" "SUCCESS"
            } catch {
                # ユーザーが存在しない場合はスキップ（エラーカウントしない）
                if ($_.Exception.Message -match "404" -or $_.Exception.Message -match "does not exist") {
                    # 存在しないユーザーは無視
                } elseif ($_.Exception.Message -match "already exist") {
                    # 既にメンバーの場合もスキップ
                    $skippedCount++
                } else {
                    $errorCount++
                    if ($errorCount -le 5) {
                        Write-Host "    ✗ エラー: $upn - $_" -ForegroundColor Red
                    }
                    Write-Log "メンバー追加エラー: $upn - $_" "ERROR"
                }
            }
        }
        
        # 進捗表示
        if ($checkedCount % 5000 -eq 0) {
            $elapsed = ((Get-Date) - $startTime).TotalSeconds
            $rate = if ($elapsed -gt 0) { [math]::Round($checkedCount / $elapsed, 2) } else { 0 }
            Write-Host "    進捗: $checkedCount / $totalUsers (追加: $addedCount, スキップ: $skippedCount, エラー: $errorCount) | 速度: $rate user/s" -ForegroundColor Cyan
        }
        
        # スロットリング対策
        if ($checkedCount % 100 -eq 0) {
            Start-Sleep -Milliseconds 200
        }
    }
    
    $endTime = Get-Date
    $totalTime = ($endTime - $startTime).TotalSeconds
    
    Write-Host "`n  ✓ メンバー追加処理完了" -ForegroundColor Green
    Write-Log "メンバー追加処理完了" "SUCCESS"
    Write-Host "  チェック数: $checkedCount ユーザー" -ForegroundColor Yellow
    Write-Host "  追加: $addedCount ユーザー" -ForegroundColor Green
    Write-Host "  スキップ: $skippedCount ユーザー（既にメンバー）" -ForegroundColor Gray
    Write-Log "処理結果 - チェック数: $checkedCount, 追加: $addedCount, スキップ: $skippedCount, エラー: $errorCount"
    if ($errorCount -gt 5) {
        Write-Host "  エラー: $errorCount ユーザー（詳細は最初の5件のみ表示）" -ForegroundColor Red
    } else {
        Write-Host "  エラー: $errorCount ユーザー" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Gray" })
    }
    Write-Host "  処理時間: $([math]::Round($totalTime, 2)) 秒" -ForegroundColor Yellow
    Write-Log "処理時間: $([math]::Round($totalTime, 2)) 秒"
    
    # 最終メンバー数を取得
    Write-Host "`n  最終メンバー数を確認中..." -ForegroundColor Yellow
    try {
        $membersUri = "https://graph.microsoft.com/v1.0/groups/$($group.id)/members/`$count"
        $finalMemberCount = Invoke-RestMethod -Method Get -Uri $membersUri -Headers $headers -TimeoutSec 30
        Write-Host "  ✓ 最終メンバー数: $finalMemberCount 人" -ForegroundColor Green
        Write-Log "最終メンバー数: $finalMemberCount 人" "SUCCESS"
    } catch {
        Write-Host "  最終メンバー数の取得に失敗しました" -ForegroundColor Yellow
        Write-Log "最終メンバー数の取得に失敗" "WARNING"
    }
}

# 詳細表示オプション
if ($Detailed -and $memberCount -gt 0 -and $memberCount -le 100) {
    Write-Host "`n詳細情報（最初の100件まで表示）:" -ForegroundColor Yellow
    Write-Log "詳細情報取得（最初の100件）"
    
    try {
        $membersUri = "https://graph.microsoft.com/v1.0/groups/$($group.id)/members?`$top=100&`$select=userPrincipalName,displayName"
        $membersResponse = Invoke-RestMethod -Method Get -Uri $membersUri -Headers $headers -TimeoutSec 30
        
        $membersResponse.value | ForEach-Object {
            Write-Host "  - $($_.userPrincipalName) ($($_.displayName))" -ForegroundColor Gray
        }
        Write-Log "詳細情報取得成功: $($membersResponse.value.Count) 件" "SUCCESS"
    } catch {
        Write-Host "  メンバー詳細の取得に失敗しました" -ForegroundColor Yellow
        Write-Log "メンバー詳細の取得に失敗: $_" "WARNING"
    }
} elseif ($Detailed -and $memberCount -gt 100) {
    Write-Host "`n  注意: メンバー数が100人を超えるため、詳細表示を省略しました" -ForegroundColor Yellow
    Write-Log "詳細表示省略（メンバー数: $memberCount > 100）" "WARNING"
}

Write-Host "`n処理が完了しました！" -ForegroundColor Cyan
Write-Log "========== スクリプト終了 =========="
Write-Host "`nログファイル: $LogFile" -ForegroundColor Green
# オブジェクトとして返却（パイプライン対応）
if ($AddMissingUsers) {
    [PSCustomObject]@{
        GroupName = $group.displayName
        GroupId = $group.id
        InitialMemberCount = $memberCount
        CheckedUsers = $checkedCount
        AddedUsers = $addedCount
        SkippedUsers = $skippedCount
        ErrorCount = $errorCount
        FinalMemberCount = if ($finalMemberCount) { $finalMemberCount } else { $memberCount + $addedCount }
    }
} else {
    [PSCustomObject]@{
        GroupName = $group.displayName
        GroupId = $group.id
        MemberCount = $memberCount
    }
}
