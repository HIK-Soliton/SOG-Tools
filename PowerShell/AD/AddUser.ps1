param (
    [int]$target_user_count = 75000,
    [int]$start_number,
    [switch]$is_update,
    [switch]$is_delete,
    [int]$group_count = 300,
    [Parameter(Mandatory=$true)]
    [string]$password
)

if (($is_update -or $is_delete) -and -not $start_number) {
    Write-Error "-update または -delete スイッチを使用する場合は -start パラメータの指定が必須です。"
    exit 1
}

if (-not $start_number) {
    $searcher = [ADSISearcher]"(&(samAccountName=Test*)(objectClass=user))"
    $searcher.PropertiesToLoad.Add("samAccountName") | Out-Null
    $searcher.PageSize = 1000
    $start_number = $searcher.FindAll().Count + 1
}

$application_role_groups = @("AuthenticationG")
$credential = Get-Credential "Administrator"
$today_date = (Get-Date).ToString("yyyyMMdd")

$group_names = @()
$group_names += $application_role_groups
for ($j = 1; $j -lt (1 + $group_count); $j++) {
    $group_number_string = $j.ToString().PadLeft(5, '0')
    $group_names += "Group" +  $group_number_string
}

$ad_domain_info = Get-ADDomain
$distinguished_name = $ad_domain_info.DistinguishedName
$domain_name = $ad_domain_info.DNSRoot
$organizational_unit_path = "OU=OneGateサービス開発チーム,OU=1G,OU=クラウドプラットフォームG,OU=技術部,OU=IT Security事業部,OU=OneGate"
#$organizational_unit_path = "OU=OneGate"
$ou_parts = $organizational_unit_path -split ","
$current_path = $distinguished_name

for ($i = ($ou_parts.Count - 1); $i -ge 0 ; $i--) {
    $ou_name = ($ou_parts[$i] -split "=" )[1]
    $target_distinguished_name = "OU=" + (@($ou_name, $current_path) -join ",")
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$ou_name'" -SearchBase $current_path -Credential $credential -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $ou_name -Path $current_path -ProtectedFromAccidentalDeletion $false -Credential $credential
    }
    $current_path = $target_distinguished_name
}

$secure_password = ConvertTo-SecureString $password -AsPlainText -Force
$total_count = $target_user_count - $start_number + 1
$success_count = 0
$fail_count = 0

for ($i=$start_number; $i -lt $target_user_count; $i++) {
    $user_number_string = $i.ToString().PadLeft(5, '0')
    $user_name = "Test" + $user_number_string
    Write-Progress -Activity "ユーザー処理中" -Status "$user_name (($i - $start_number) / $total_count)" -PercentComplete (($i - $start_number) / $total_count * 100)
    if ($is_update) {
        Set-ADUser -Identity "$user_name.sol" `
            -sAMAccountName "$user_name" `
            -userPrincipalName "$user_name@sog.example.com" `
            -description "サイズを増やすためにとりあえず適当に入れている文字列ぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺ" `
            -EmailAddress "$user_number_string@sog.example.com" `
            -Credential $credential
        if ($?) {
            $success_count++
        } else {
            $fail_count++
        }
    } elseif ($is_delete) {
        Remove-ADUser -Identity $user_name -Credential $credential -Confirm:$false
        if ($?) {
            $success_count++
        } else {
            $fail_count++
        }
    } else {
        New-ADUser -name "$user_name" `
            -UserPrincipalName "$user_name@$domain_name" `
            -AccountPassword $secure_password `
            -Path "$current_path" `
            -sAMAccountName "$user_name" `
            -SurName "試験" `
            -givenName "太郎$user_number_string" `
            -department "テスト用ユーザー" `
            -Title "ただの人" `
            -DisplayName "試験 太郎$user_number_string" `
            -EmailAddress "$user_number_string@example.com" `
            -description "サイズを増やすためにとりあえず適当に入れている文字列ぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺぺ" `
            -Enabled $true -Credential $credential
        if ($?) {
            Add-ADPrincipalGroupMembership -Identity $user_name -MemberOf $group_names -Credential $credential
            $success_count++
        } else {
            $fail_count++
        }
    }
}

Write-Progress -Activity "ユーザー処理中" -Completed
Write-Host "処理完了: 成功 $success_count 件, 失敗 $fail_count 件"



