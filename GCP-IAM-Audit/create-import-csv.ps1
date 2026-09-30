param(
    [Parameter(Mandatory = $false)]
    [Alias("project")]
    [string]$ProjectId = "idaas-dev",

    [Parameter(Mandatory = $false)]
    [string]$OutputFile = "~\Downloads\Google Cloud ロール申請_移行用.csv"
)

$ErrorActionPreference = "Stop"

# ============================================
# 固定値
# ============================================

$reason = "旧アカウント台帳から移行"
$applicant = "息 拓之"

$currentDateTime = Get-Date
$datetimeString  = $currentDateTime.ToString("yyyy/MM/dd HH:mm")
$dateString      = $currentDateTime.ToString("yyyy/MM/dd")

# ============================================
# JSON配列形式へ変換
# 例: ["item1","item2"]
# ============================================

function ConvertTo-JsonArrayString {
    param(
        [AllowNull()]
        [object[]]$Values
    )

    $items = @(
        $Values |
            Where-Object {
                $null -ne $_ -and
                -not [string]::IsNullOrWhiteSpace([string]$_)
            } |
            ForEach-Object {
                [string]$_
            } |
            Sort-Object -Unique
    )

    if ($items.Count -eq 0) {
        return ""
    }

    # 1件の場合もJSON配列として出力する
    return ConvertTo-Json -InputObject @($items) -Compress
}

# ============================================
# gcloudのJSON結果を取得
# ============================================

function Invoke-GcloudJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$ErrorMessage
    )

    $stderrPath = [System.IO.Path]::GetTempFileName()
    try {
        $json = & gcloud @Arguments 2> $stderrPath

        if ($LASTEXITCODE -ne 0) {
            $detail = Get-Content -LiteralPath $stderrPath -Raw
            throw "$ErrorMessage`n$detail"
        }
    }
    finally {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }

    $jsonText = $json -join [Environment]::NewLine

    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        return @()
    }

    return $jsonText | ConvertFrom-Json
}

# ============================================
# ロール種別の判定
# ============================================

function Test-StorageRole {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Role
    )

    # 定義済みStorageロール
    if ($Role -match "^roles/storage\.") {
        return $true
    }

    # 基本ロールもストレージ操作を含む可能性があるため対象とする
    if ($Role -in @(
        "roles/owner",
        "roles/editor",
        "roles/viewer"
    )) {
        return $true
    }

    # カスタムロールは名前だけでは権限内容を判定できないため、
    # 必要に応じて下の配列へ対象ロールを追加
    $storageCustomRoles = @(
        # "projects/example-project/roles/custom_storage_role"
    )

    return $Role -in $storageCustomRoles
}

function Test-CloudRunRole {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Role
    )

    # Cloud Run定義済みロール
    if ($Role -match "^roles/run\.") {
        return $true
    }

    # Cloud Run Functions関連を含める場合
    if ($Role -match "^roles/cloudfunctions\.") {
        return $true
    }

    # 基本ロールもCloud Run操作を含む可能性があるため対象とする
    if ($Role -in @(
        "roles/owner",
        "roles/editor",
        "roles/viewer"
    )) {
        return $true
    }

    # カスタムロールは名前だけでは権限内容を判定できないため、
    # 必要に応じて下の配列へ対象ロールを追加
    $cloudRunCustomRoles = @(
        # "projects/example-project/roles/custom_cloudrun_role"
    )

    return $Role -in $cloudRunCustomRoles
}

function Test-TargetMember {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Member
    )

    return $Member -match "^(serviceAccount|user|group):"
}

# ============================================
# プロジェクト存在・参照チェック
# ============================================

Write-Host "プロジェクトを確認しています: $ProjectId"

& gcloud projects describe $ProjectId --format=json 2>&1 | Out-Null

if ($LASTEXITCODE -ne 0) {
    throw "プロジェクト '$ProjectId' が存在しないか、参照権限がありません。"
}

# ============================================
# プロジェクトIAMポリシー取得
# ============================================

Write-Host "プロジェクトIAMポリシーを取得しています..."

$projectPolicy = Invoke-GcloudJson `
    -Arguments @(
        "projects",
        "get-iam-policy",
        $ProjectId,
        "--format=json"
    ) `
    -ErrorMessage "IAMポリシーの取得に失敗しました。"

# ============================================
# バケット一覧取得
# ============================================

Write-Host "Cloud Storageのバケット一覧を取得しています..."

$bucketObjects = Invoke-GcloudJson `
    -Arguments @(
        "storage",
        "buckets",
        "list",
        "--project=$ProjectId",
        "--format=json(name)"
    ) `
    -ErrorMessage "Cloud Storageバケット一覧の取得に失敗しました。"

$allBuckets = @(
    $bucketObjects |
        ForEach-Object {
            # nameがgs://形式でなければ補正
            if ([string]$_.name -match "^gs://") {
                [string]$_.name
            }
            else {
                "gs://$($_.name)"
            }
        } |
        Sort-Object -Unique
)

# ============================================
# Cloud Runサービス一覧取得
# ============================================

Write-Host "Cloud Runサービス一覧を取得しています..."

$cloudRunServices = Invoke-GcloudJson `
    -Arguments @(
        "run",
        "services",
        "list",
        "--project=$ProjectId",
        "--platform=managed",
        "--format=json(metadata.name,metadata.labels)"
    ) `
    -ErrorMessage "Cloud Runサービス一覧の取得に失敗しました。"

$allCloudRunServices = @()

foreach ($service in $cloudRunServices) {

    $serviceName = $null
    $region      = $null

    if ($service.metadata.name) {
        $serviceName = [string]$service.metadata.name
    }
    elseif ($service.name) {
        $serviceName = [string]$service.name
    }

    if ($service.metadata.labels."cloud.googleapis.com/location") {
        $region = [string]$service.metadata.labels."cloud.googleapis.com/location"
    }
    elseif ($service.metadata.labels."run.googleapis.com/region") {
        $region = [string]$service.metadata.labels."run.googleapis.com/region"
    }
    elseif ($service.region) {
        $region = [string]$service.region
    }

    if (
        -not [string]::IsNullOrWhiteSpace($serviceName) -and
        -not [string]::IsNullOrWhiteSpace($region)
    ) {
        $allCloudRunServices += [PSCustomObject]@{
            Name        = $serviceName
            Region      = $region
            DisplayName = "$serviceName ($region)"
        }
    }
}

$allCloudRunServices = @(
    $allCloudRunServices |
        Sort-Object Name, Region -Unique
)

# ============================================
# メンバー情報用のマップ
# ============================================

$memberData = @{}

function Initialize-Member {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Member
    )

    if (-not $memberData.ContainsKey($Member)) {
        $memberData[$Member] = [PSCustomObject]@{
            Member            = $Member
            Roles             = [System.Collections.Generic.HashSet[string]]::new()
            Buckets           = [System.Collections.Generic.HashSet[string]]::new()
            CloudRunServices  = [System.Collections.Generic.HashSet[string]]::new()
        }
    }

    return $memberData[$Member]
}

# ============================================
# プロジェクトIAMをメンバーごとに集約
# ============================================

foreach ($binding in $projectPolicy.bindings) {

    $role = [string]$binding.role

    foreach ($member in $binding.members) {

        if (-not (Test-TargetMember -Member ([string]$member))) {
            continue
        }

        $memberEntry = Initialize-Member -Member ([string]$member)
        $null = $memberEntry.Roles.Add($role)
    }
}

# ============================================
# バケット個別IAMポリシー取得
# ============================================

foreach ($bucket in $allBuckets) {

    Write-Host "バケットIAMを確認しています: $bucket"

    $bucketPolicyOutput = & gcloud storage buckets get-iam-policy `
        $bucket `
        "--format=json" 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "バケットIAMを取得できませんでした: $bucket"
        continue
    }

    $bucketPolicyText = $bucketPolicyOutput -join [Environment]::NewLine

    if ([string]::IsNullOrWhiteSpace($bucketPolicyText)) {
        continue
    }

    $bucketPolicy = $bucketPolicyText | ConvertFrom-Json

    foreach ($binding in $bucketPolicy.bindings) {

        $role = [string]$binding.role

        foreach ($member in $binding.members) {

            if (-not (Test-TargetMember -Member ([string]$member))) {
                continue
            }

            $memberEntry = Initialize-Member -Member ([string]$member)
            $null = $memberEntry.Roles.Add($role)
            $null = $memberEntry.Buckets.Add($bucket)
        }
    }
}

# ============================================
# Cloud Runサービス個別IAMポリシー取得
# ============================================

foreach ($service in $allCloudRunServices) {

    Write-Host "Cloud Run IAMを確認しています: $($service.DisplayName)"

    $runPolicyOutput = & gcloud run services get-iam-policy `
        $service.Name `
        "--region=$($service.Region)" `
        "--project=$ProjectId" `
        "--platform=managed" `
        "--format=json" 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Cloud Run IAMを取得できませんでした: $($service.DisplayName)"
        continue
    }

    $runPolicyText = $runPolicyOutput -join [Environment]::NewLine

    if ([string]::IsNullOrWhiteSpace($runPolicyText)) {
        continue
    }

    $runPolicy = $runPolicyText | ConvertFrom-Json

    foreach ($binding in $runPolicy.bindings) {

        $role = [string]$binding.role

        foreach ($member in $binding.members) {

            if (-not (Test-TargetMember -Member ([string]$member))) {
                continue
            }

            $memberEntry = Initialize-Member -Member ([string]$member)
            $null = $memberEntry.Roles.Add($role)
            $null = $memberEntry.CloudRunServices.Add($service.DisplayName)
        }
    }
}

# ============================================
# CSVデータ生成
# ============================================

$result = foreach ($entry in $memberData.Values) {

    $memberParts = $entry.Member -split ":", 2

    if ($memberParts.Count -eq 2) {
        $memberType = $memberParts[0]
        $memberName = $memberParts[1]
    }
    else {
        $memberType = "unknown"
        $memberName = $entry.Member
    }

    $accountType = switch ($memberType) {
        "group"          { "グループ" }
        "user"           { "ユーザー" }
        "serviceAccount" { "サービスアカウント" }
        "domain"         { "ドメイン" }
        "allUsers"       { "すべてのユーザー" }
        "allAuthenticatedUsers" { "すべての認証済みユーザー" }
        default          { $memberType }
    }

    if ($accountType -eq "サービスアカウント") {
        $twoFactorEnabled = "FALSE"
        $twoFactorReason  = "サービスアカウントのため対象外"
    }
    elseif (
        $accountType -eq "すべてのユーザー" -or
        $accountType -eq "すべての認証済みユーザー"
    ) {
        $twoFactorEnabled = "FALSE"
        $twoFactorReason  = "特別なIAMプリンシパルのため対象外"
    }
    else {
        $twoFactorEnabled = "TRUE"
        $twoFactorReason  = "設定済み"
    }

    [PSCustomObject][ordered]@{
        "プロジェクト"                  = $ProjectId
        "用途"                          = ""
        "申請理由"                      = $reason
        "申請種別"                      = "ロール変更"
        "利用開始日"                    = $dateString
        "利用終了日"                    = ""
        "アカウント種別"                = $accountType
        "アカウント名"                  = $memberName
        "メールアドレス"                = $memberName
        "ロール"                        = ConvertTo-JsonArrayString -Values @($entry.Roles)
        "bucket"                        = ConvertTo-JsonArrayString -Values @($entry.Buckets)
        "CroudRun"                      = ConvertTo-JsonArrayString -Values @($entry.CloudRunServices)
        "権限設定方法"                  = "作業手順内で設定"
        "2段階認証設定済み"             = $twoFactorEnabled
        "2段階認証を設定していない理由" = $twoFactorReason
        "申請者"                        = $applicant
        "AppliedDatetime"               = $datetimeString
        "ApprovalStatus"                = "承認済み"
        "ApprovalDatetime"              = $datetimeString
        "更新日時"                      = $datetimeString
        "登録日時"                      = $datetimeString
    }
}

$result = @(
    $result |
        Sort-Object "アカウント種別", "アカウント名"
)

# ============================================
# CSV出力
# ============================================

if ($PSVersionTable.PSVersion.Major -ge 7) {
    $csvEncoding = "utf8BOM"
}
else {
    # Windows PowerShell 5.1ではUTF8にBOMが付く
    $csvEncoding = "UTF8"
}

$result |
    Export-Csv `
        -Path $OutputFile `
        -NoTypeInformation `
        -Encoding $csvEncoding

Write-Host ""
Write-Host "CSVを作成しました。"
Write-Host "プロジェクト: $ProjectId"
Write-Host "出力先: $((Resolve-Path $OutputFile).Path)"
Write-Host "出力件数: $($result.Count)"
Write-Host "バケット数: $($allBuckets.Count)"
Write-Host "Cloud Runサービス数: $($allCloudRunServices.Count)"