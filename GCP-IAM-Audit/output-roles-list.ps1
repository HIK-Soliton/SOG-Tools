# ============================================
# プロジェクトで使用中のIAMロールと表示名を出力
# ============================================

Param ($projectId  = "idaas-232202")

$outputFile = "~\Downloads\role_list.csv"

# IAMポリシーから使用中のロールIDを取得
$policyJson = gcloud projects get-iam-policy $projectId `
    --format=json

if ($LASTEXITCODE -ne 0) {
    throw "IAMポリシーの取得に失敗しました。"
}

$policy = $policyJson | ConvertFrom-Json

$roles = $policy.bindings |
    ForEach-Object { $_.role } |
    Sort-Object -Unique

$result = foreach ($role in $roles) {

    $roleInfo = $null
    $errorMessage = $null
    $displayRoleId = $role -replace "^(?:projects|organizations)/[^/]+/", ""

    try {
        if ($role -match "^projects/([^/]+)/roles/(.+)$") {
            # プロジェクトレベルのカスタムロール
            $customRoleProjectId = $Matches[1]
            $customRoleId        = $Matches[2]

            $roleJson = gcloud iam roles describe $customRoleId `
                --project=$customRoleProjectId `
                --format=json 2>$null

            if ($LASTEXITCODE -eq 0) {
                $roleInfo = $roleJson | ConvertFrom-Json
            }
            else {
                $errorMessage = "カスタムロール情報の取得に失敗"
            }
        }
        elseif ($role -match "^organizations/([^/]+)/roles/(.+)$") {
            # 組織レベルのカスタムロール
            $organizationId = $Matches[1]
            $customRoleId   = $Matches[2]

            $roleJson = gcloud iam roles describe $customRoleId `
                --organization=$organizationId `
                --format=json 2>$null

            if ($LASTEXITCODE -eq 0) {
                $roleInfo = $roleJson | ConvertFrom-Json
            }
            else {
                $errorMessage = "組織カスタムロール情報の取得に失敗"
            }
        }
        elseif ($role -match "^roles/") {
            # Google Cloudの定義済みロール
            $roleJson = gcloud iam roles describe $role `
                --format=json 2>$null

            if ($LASTEXITCODE -eq 0) {
                $roleInfo = $roleJson | ConvertFrom-Json
            }
            else {
                $errorMessage = "定義済みロール情報の取得に失敗"
            }
        }
        else {
            $errorMessage = "未対応のロール形式"
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
    }

    if ($null -ne $roleInfo) {
        [PSCustomObject][ordered]@{
            RoleId      = $displayRoleId
            RoleName    = $roleInfo.title
            Description = $roleInfo.description
            Stage       = $roleInfo.stage
            Status      = "取得成功"
        }
    }
    else {
        [PSCustomObject][ordered]@{
            RoleId      = $displayRoleId
            RoleName    = ""
            Description = ""
            Stage       = ""
            Status      = $errorMessage
        }
    }
}

# 画面表示
$result | Format-Table RoleId, RoleName, Stage, Status -AutoSize

# CSV出力
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $encoding = "utf8BOM"
}
else {
    $encoding = "UTF8"
}

$result |
    Export-Csv `
        -Path $outputFile `
        -NoTypeInformation `
        -Encoding $encoding

Write-Host ""
Write-Host "CSVを出力しました: $((Resolve-Path $outputFile).Path)"
Write-Host "出力件数: $($result.Count)"
