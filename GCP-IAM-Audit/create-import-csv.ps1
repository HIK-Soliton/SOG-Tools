# ============================================
# Google Cloud IAM情報を申請CSV形式で出力
# ============================================

Param ($projectId = "idaas-dev")

$outputFile = "~\Downloads\Google Cloud ロール申請_移行用.csv"

# 固定値
$reason = "旧アカウント台帳から移行"
$applicant = "息 拓之"

# 日時は処理開始時点で統一
$currentDateTime = Get-Date
$datetimeString = $currentDateTime.ToString("yyyy/MM/dd HH:mm")
$dateString = $currentDateTime.ToString("yyyy/MM/dd")

# IAMポリシーをJSON形式で取得
$policyJson = gcloud projects get-iam-policy $projectId `
    --format=json

if ($LASTEXITCODE -ne 0) {
    throw "IAMポリシーの取得に失敗しました。プロジェクトIDとgcloudの認証状態を確認してください。"
}

$policy = $policyJson | ConvertFrom-Json

# メンバーとロールの組み合わせを作成
$memberRoleList = foreach ($binding in $policy.bindings) {

    foreach ($member in $binding.members) {

        $memberParts = $member -split ":", 2

        if ($memberParts.Count -eq 2) {
            $memberType = $memberParts[0]
            $memberName = $memberParts[1]
        }
        else {
            $memberType = "unknown"
            $memberName = $member
        }

        # CSVの「アカウント種別」に変換
        $accountType = switch ($memberType) {
            "group"          { "グループ" }
            "user"           { "ユーザー" }
            "serviceAccount" { "サービスアカウント" }
            "domain"         { "ドメイン" }
            default          { $memberType }
        }

        $role = $binding.role -replace "^(?:projects|organizations)/[^/]+/", ""

        [PSCustomObject]@{
            Member      = $member
            AccountType = $accountType
            AccountName = $memberName
            Email       = $memberName
            Role        = $role
        }
    }
}

# 同一メンバーに割り当てられているロールを1行に集約
$result = $memberRoleList |
    Group-Object Member |
    ForEach-Object {

        $first = $_.Group | Select-Object -First 1

        # ロールを重複排除して配列にする
        $roles = @(
            $_.Group.Role |
                Sort-Object -Unique
        )

        # 添付CSVの形式に合わせてJSON配列形式に変換
        # 例: ["roles/owner","roles/billing.projectManager"]
        $roleJson = ConvertTo-Json `
            -InputObject @($roles) `
            -Compress

        # ConvertTo-Jsonは1件の場合に文字列化することがあるため補正
        if ($roles.Count -eq 1) {
            $escapedRole = $roles[0].Replace('\', '\\').Replace('"', '\"')
            $roleJson = '["' + $escapedRole + '"]'
        }

        # 2段階認証情報
        # サービスアカウントは2段階認証の対象外として扱う
        if ($first.AccountType -eq "サービスアカウント") {
            $twoFactorEnabled = "FALSE"
            $twoFactorReason = "サービスアカウントのため対象外"
        }
        else {
            $twoFactorEnabled = "TRUE"
            $twoFactorReason = "設定済み"
        }

        [PSCustomObject][ordered]@{
            "プロジェクト"                 = $projectId
            "用途"                         = ""
            "申請理由"                     = $reason
            "申請種別"                     = "旧アカウント台帳から移行"
            "利用開始日"                   = $dateString
            "利用終了日"                   = ""
            "アカウント種別"               = $first.AccountType
            "アカウント名"                 = $first.AccountName
            "メールアドレス"               = $first.Email
            "ロール"                       = $roleJson
            "bucket"                       = ""
            "CroudRun"                     = ""
            "権限設定方法"                 = "作業手順内で設定"
            "2段階認証設定済み"            = $twoFactorEnabled
            "2段階認証を設定していない理由" = $twoFactorReason
            "申請者"                       = $applicant
            "AppliedDatetime"              = $datetimeString
            "ApprovalStatus"               = "承認済み"
            "ApprovalDatetime"             = $datetimeString
            "更新日時"                     = $datetimeString
            "登録日時"                     = $datetimeString
        }
    }

# アカウント種別、アカウント名の順に並べ替え
$result = $result |
    Sort-Object "アカウント種別", "アカウント名"

# PowerShellのバージョンに応じて文字コードを選択
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $csvEncoding = "utf8BOM"
}
else {
    # Windows PowerShell 5.1のUTF8にはBOMが付く
    $csvEncoding = "UTF8"
}

$result |
    Export-Csv `
        -Path $outputFile `
        -NoTypeInformation `
        -Encoding $csvEncoding

Write-Host ""
Write-Host "CSVを作成しました。"
Write-Host "出力先: $((Resolve-Path $outputFile).Path)"
Write-Host "出力件数: $($result.Count)"