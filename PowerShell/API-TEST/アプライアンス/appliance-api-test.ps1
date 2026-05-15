
<#
.SYNOPSIS
  アプライアンス管理サービス API を仕様書記載順に順次呼び出すスクリプト

.PARAMETER HostName
  インターフェイスホストの <ホスト名> を指定（https://<ホスト名>.ids.soliton-ods.jp）

.PARAMETER Token
  HTTP ヘッダに付与する Bearer トークン

.PARAMETER DryRun
  破壊的操作（DELETE 等）をスキップ。POST/PUT は送信前に内容を表示して確認用に最小限だけ実行

.PARAMETER HardwareId
  明示的に対象アプライアンスを指定したい場合（未指定時は検索結果の先頭を使用）

.PARAMETER OutputDir
  ダウンロード系の出力先ディレクトリ（既定: ./output）

.PARAMETER y
  Enter待ちをスキップして連続実行する
#>

param(
  [Parameter(Mandatory=$true)]
  [string]$HostName,
  [Parameter(Mandatory=$true)]
  [string]$Token,
  [switch]$DryRun,
  [switch]$production,
  [string]$HardwareId,
  [string]$OutputDir = "./output",
  [switch]$y
)

# ===== 共通設定 =====
# ホスト名検証
if ([string]::IsNullOrWhiteSpace($HostName)) {
  throw "HostNameが空または無効です。"
}
if ($HostName -match '[^a-zA-Z0-9\-]') {
  throw "HostNameに無効な文字が含まれています: $HostName"
}

if ($production) {
  $BaseUri = "https://$HostName.ids.soliton-ods.jp"
} else {
  $BaseUri = "https://$HostName.ids-dev.solitonsys.jp"
}
Write-Host "BaseUri: $BaseUri" -ForegroundColor Yellow

$Headers = @{
  "Authorization" = "Bearer $Token"
  "Content-Type"  = "application/json; charset=utf-8"
  "Accept"        = "*/*"
  "Accept-Language" = "ja-JP"
  "User-Agent"    = "PowerShell/7.0"
}

# 汎用呼び出し関数（JSON送受信用）
function Invoke-Api {
  param(
    [Parameter(Mandatory=$true)][ValidateSet('GET','POST','PUT','DELETE')] [string]$Method,
    [Parameter(Mandatory=$true)] [string]$Path,
    [hashtable]$Query,
    [object]$Body,
    [switch]$ExpectBinary
  )
  # デバッグ出力
  Write-Host "BaseUri: '$script:BaseUri'" -ForegroundColor Magenta
  Write-Host "Path: '$Path'" -ForegroundColor Magenta
  
  # BaseUriの有効性チェック
  if ([string]::IsNullOrWhiteSpace($script:BaseUri)) {
    throw "BaseUriが設定されていません。スクリプトスコープの問題の可能性があります。"
  }
  
  $uri = $script:BaseUri + $Path
  if ($Query) {
    # クエリパラメータのデバッグ出力
    Write-Host "Query parameters:" -ForegroundColor Magenta
    $Query.GetEnumerator() | ForEach-Object { 
      Write-Host "  $($_.Key) = '$($_.Value)'" -ForegroundColor Magenta 
    }
    
    $qs = ($Query.GetEnumerator() | ForEach-Object { 
      $key = $_.Key
      $value = [string]$_.Value
      "$key=$([uri]::EscapeDataString($value))" 
    }) -join "&"
    
    Write-Host "Query string: '$qs'" -ForegroundColor Magenta
    $uri = $uri + "?" + $qs
  }
  
  # デバッグ出力
  Write-Host "Final URI: '$uri'" -ForegroundColor Magenta
  
  # URI検証
  try {
    $null = [System.Uri]::new($uri)
  } catch {
    throw "無効なURI: $uri - $($_.Exception.Message)"
  }
  
  Write-Host "==> $Method $uri" -ForegroundColor Cyan

  try {
    if ($Method -eq 'GET') {
      if ($ExpectBinary) {
        return Invoke-WebRequest -Uri $uri -Headers $script:Headers -Method Get -UseBasicParsing
      } else {
        return Invoke-RestMethod -Uri $uri -Headers $script:Headers -Method Get
      }
    }
    elseif ($Method -eq 'POST' -or $Method -eq 'PUT' -or $Method -eq 'DELETE') {
      $json = $Body | ConvertTo-Json -Depth 10
      if ($DryRun -and $Method -eq 'DELETE') {
        Write-Warning "DryRun: DELETE はスキップします。"
        return $null
      }
      if ($DryRun -and ($Method -eq 'POST' -or $Method -eq 'PUT')) {
        Write-Warning "DryRun: $Method を送信します（実リソースへの影響に注意）。Payload:"
        if ($json) { Write-Host $json }
      }
      return Invoke-RestMethod -Uri $uri -Headers $script:Headers -Method $Method -Body $json
    }
  } catch [System.Net.WebException] {
    $response = $_.Exception.Response
    if ($response) {
      Write-Host "HTTP Status: $($response.StatusCode) $($response.StatusDescription)" -ForegroundColor Red
      Write-Host "Response Headers:" -ForegroundColor Yellow
      $response.Headers | ForEach-Object { Write-Host "  $($_.Key): $($_.Value)" -ForegroundColor Yellow }
      
      # レスポンスボディがあれば表示
      try {
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        $responseBody = $reader.ReadToEnd()
        $reader.Close()
        if ($responseBody) {
          Write-Host "Response Body:" -ForegroundColor Yellow
          Write-Host $responseBody -ForegroundColor Yellow
        }
      } catch {
        Write-Host "レスポンスボディの読み取りに失敗: $($_.Exception.Message)" -ForegroundColor Red
      }
    }
    throw
  }
}

# 出力フォルダ用意
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }

# 1) アプライアンス検索 (GET /icon/services/seap/api/appliance)
#    クエリ: max, pageNo, key, value, sortKey, sortOrder
#    仕様: -1 指定で全件取得可 / ソート・検索対象属性あり
#    （status, name, info, host, serial, timestamp, reflected, tag など） 
$search = Invoke-Api -Method GET -Path "/icon/services/seap/api/appliance" -Query @{ max = -1; sortKey = "timestamp"; sortOrder = "desc" }
if (-not $search) { throw "検索結果が取得できませんでした。" }
Write-Host "検索応答: $($search | ConvertTo-Json -Depth 6)" -ForegroundColor Yellow

# 検索成功時のみ結果から対象 hardwareId を決定
if (-not $HardwareId) {
　　if ($search -and $search.responseBody -and $search.responseBody.results) {
    # 仕様のサンプルに含まれるフィールドから先頭レコードの hardwareId を採用。 
    $firstRow = $search.responseBody.results | Select-Object -First 1
    if (-not $firstRow) { throw "アプライアンスが見つかりません。" }
    $HardwareId = $firstRow.hardwareId
  }
} else {
  throw "アプライアンス検索に失敗または結果が空です。"
}
Write-Host "ターゲット hardwareId: $HardwareId" -ForegroundColor Green
Write-Host "アプライアンス検索完了。" -ForegroundColor Cyan
if (-not $y) { Read-Host "続行するにはEnterキーを押してください" }

# 2) 全般-表示名・タグ更新 (PUT /icon/services/seap/api/appliance/{hardwareId}/general)
#    必須: name。tagList は登録済みタグ 0-5 個。 
$generalBody = @{
  name    = "Renamed-Appliance"
  memo    = "tag update"
  tagList = @("tag1","tag2")
}
$general = Invoke-Api -Method PUT -Path "/icon/services/seap/api/appliance/$HardwareId/general" -Body $generalBody
if ($general) { Write-Host "一般設定更新応答: $($general | ConvertTo-Json -Depth 6)" -ForegroundColor Yellow }
Write-Host "全般-表示名・タグ更新完了。" -ForegroundColor Cyan
if (-not $y) { Read-Host "続行するにはEnterキーを押してください" }

# 3) 管理-バックアップ開始 (POST /icon/services/seap/api/appliance/{hardwareId}/backup)
#    必須: backupName (1-64)。 
$backupStartBody = @{ backupName = "backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')" }
$backupStart = Invoke-Api -Method POST -Path "/icon/services/seap/api/appliance/$HardwareId/backup" -Body $backupStartBody
# 5秒待機
Start-Sleep -Seconds 5
Write-Host "バックアップ開始応答: $($backupStart | ConvertTo-Json -Depth 6)" -ForegroundColor Yellow
Write-Host "バックアップ開始完了。" -ForegroundColor Cyan
if (-not $y) { Read-Host "続行するにはEnterキーを押してください" }

# 4) 管理-バックアップ一覧取得 (GET /icon/services/seap/api/appliance/{hardwareId}/backup)
#    クエリ: sortOrder。レスポンス: ApplianceBackupInfo[]。
$backupList = Invoke-Api -Method GET -Path "/icon/services/seap/api/appliance/$HardwareId/backup" -Query @{ sortOrder = "DESC" }
if ($backupList) {
  Write-Host ("バックアップ一覧: " + (ConvertTo-Json $backupList -Depth 6)) -ForegroundColor Yellow
}

# 最新バックアップを選定（ダウンロード用: 先頭）
$latestBackup = $backupList.responseBody | Select-Object -First 1
$downloadRequestId = $latestBackup.backupRequestId
$downloadFileName  = $latestBackup.backupName

# 最古バックアップを選定（削除用: 末尾）
$oldestBackup = $backupList.responseBody | Select-Object -Last 1
$backupRequestId = $oldestBackup.backupRequestId
$backupFileName  = $oldestBackup.backupName
Write-Host "バックアップ一覧取得完了。" -ForegroundColor Cyan
if (-not $y) { Read-Host "続行するにはEnterキーを押してください" }

# 5) 管理-バックアップダウンロード (GET /icon/services/seap/api/appliance/{hardwareId}/backup/{requestId}/download)
#    返却: バックアップファイル。
if ($downloadRequestId) {
  $resp = Invoke-Api -Method GET -Path "/icon/services/seap/api/appliance/$HardwareId/backup/$downloadRequestId/download" -ExpectBinary
  if ($resp -and $resp.RawContentLength -gt 0) {
    $outPath = (Join-Path $OutputDir $downloadFileName) + ".bin"
    # PowerShellのカレントディレクトリを基準に絶対パス変換
    $absolutePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($outPath)
    Write-Host "保存先: $absolutePath" -ForegroundColor Magenta
    
    # 出力ディレクトリの確実な作成
    $outDir = Split-Path $absolutePath -Parent
    if (-not (Test-Path $outDir)) {
      New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    
    # バイナリファイル出力
    [System.IO.File]::WriteAllBytes($absolutePath, $resp.Content)
    Write-Host "バックアップを保存しました: $absolutePath" -ForegroundColor Green
  } else {
    Write-Warning "バックアップダウンロードに失敗しました。"
  }
}
Write-Host "バックアップダウンロード完了。" -ForegroundColor Cyan
if (-not $y) { Read-Host "続行するにはEnterキーを押してください" }

# 6) 管理-バックアップ削除 (DELETE /icon/services/seap/api/appliance/{hardwareId}/backup)
#    必須 JSON: backupRequestId。
if ($backupRequestId) {
  $backupDeleteBody = @{ backupRequestId = $backupRequestId }
  $backupDelete = Invoke-Api -Method DELETE -Path "/icon/services/seap/api/appliance/$HardwareId/backup" -Body $backupDeleteBody
  if ($backupDelete) { Write-Host "バックアップ削除応答: $($backupDelete | ConvertTo-Json -Depth 6)" -ForegroundColor Yellow }
} else {
  Write-Warning "バックアップ requestId が取得できなかったため削除はスキップします。"
}
Write-Host "バックアップ削除完了。" -ForegroundColor Cyan
if (-not $y) { Read-Host "続行するにはEnterキーを押してください" }

# 7) 管理-停止・再起動 (POST /power/reboot, /power/shutdown)　
$reboot = Invoke-Api -Method POST -Path "/icon/services/seap/api/appliance/$HardwareId/power/reboot"
# $shutdown = Invoke-Api -Method POST -Path "/icon/services/seap/api/appliance/$HardwareId/power/shutdown"
Write-Host "再起動応答: $($reboot | ConvertTo-Json -Depth 6)" -ForegroundColor Yellow
# 60秒待機
Start-Sleep -Seconds 60
Write-Host "再起動コマンド送信完了。" -ForegroundColor Cyan
if (-not $y) { Read-Host "続行するにはEnterキーを押してください" }

# 8) 管理-ファーム一覧取得 (GET /firmware)　
$firmList = Invoke-Api -Method GET -Path "/icon/services/seap/api/appliance/$HardwareId/firmware" -Query @{ sortOrder = "DESC" }
if ($firmList) { Write-Host ("ファーム一覧: " + (ConvertTo-Json $firmList -Depth 6)) -ForegroundColor Yellow }
Write-Host "ファーム一覧取得完了。" -ForegroundColor Cyan
if (-not $y) { Read-Host "続行するにはEnterキーを押してください" }

# 9) 管理-ファームアップデート (POST /firmware/{updateVersion}/update)
#     引数: updateVersion（例: versionText "1.0.1"）。対象は OneGate 接続が必要。
$targetVersion = ($firmList.responseBody | Where-Object { $_.versionType -eq 1 } | Select-Object -First 1).versionText
if ($targetVersion) {
  $fwUpdate = Invoke-Api -Method POST -Path "/icon/services/seap/api/appliance/$HardwareId/firmware/$targetVersion/update"
  if ($fwUpdate) { Write-Host "ファーム更新開始応答: $($fwUpdate | ConvertTo-Json -Depth 6)" -ForegroundColor Yellow }
} else {
  Write-Warning "更新対象のバージョンが見つからなかったため、ファーム更新はスキップします。"
}
# 60秒待機
Start-Sleep -Seconds 60
Write-Host "ファームアップデート完了。" -ForegroundColor Cyan
if (-not $y) { Read-Host "続行するにはEnterキーを押してください" }

# 10) ログ-ログエクスポート (GET /logs/{logType}/export)
#     クエリ: key, value, sortKey, sortOrder。返却: Syslog風テキスト。
$logType = "SYSLOG" # 例。必要に応じて仕様に合わせて調整
$logResp = Invoke-Api -Method GET -Path "/icon/services/seap/api/appliance/$HardwareId/logs/$logType/export" -Query @{ sortKey="timestamp"; sortOrder="desc" }
if ($logResp) {
  $logPath = Join-Path $OutputDir "logs_${HardwareId}_${logType}.log"
  $logResp | Out-File -FilePath $logPath -Encoding utf8
  Write-Host "ログを保存しました: $logPath" -ForegroundColor Green
}
Write-Host "ログエクスポート完了。" -ForegroundColor Cyan
if (-not $y) { Read-Host "続行するにはEnterキーを押してください" }

# 11) アプライアンス削除 (DELETE /icon/services/seap/api/appliance/{id})
#    仕様: {id}=削除対象ハードウェアID。戻り: RegisteredAppliance。
$deleted = Invoke-Api -Method DELETE -Path "/icon/services/seap/api/appliance/$HardwareId"
if ($deleted) { Write-Host "削除応答: $($deleted | ConvertTo-Json -Depth 6)" -ForegroundColor Yellow }
Write-Host "アプライアンス削除完了。" -ForegroundColor Cyan
if (-not $y) { Read-Host "続行するにはEnterキーを押してください" }

Write-Host "API 呼び出し完了。" -ForegroundColor Green