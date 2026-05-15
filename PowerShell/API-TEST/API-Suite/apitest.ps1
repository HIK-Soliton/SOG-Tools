Param (
    [Parameter(Mandatory)]
    [string]$apiKey,
    [Parameter(Mandatory)]
    [string]$tenant,
    [Parameter(Mandatory)]
    [string]$password
)

# 初期設定
$baseUri = "https://$tenant.ids-dev.solitonsys.jp/icon/services/seap/api"
$header = @{ Authorization = "Bearer $apiKey" }
$boundary = "680dd7c4-82ea-4e5e-8b84-245e5b5fc0e0"
$LF = "`r`n"
$encodingId = @{
    sjis = "20";
    utf8 = "30"
}
$importTypeId = @{
    add = "1";
    modify = "2";
    delete = "3";
}

$scriptDir = Split-Path $MyInvocation.MyCommand.Path -parent
$dataDir = Join-Path $scriptDir "data"
Set-Location $scriptDir

<# AttributeIdを取得する関数（とりあえず未使用）
function Get-AttributeIdByCode {
    param (
        [string]$JsonContent,
        [string]$AttributeCode
    )

    # 属性カテゴリのリスト
    $attributeCategories = @(
        'extAttributes',
        'actAttributes',
        'pwdAttributes',
        'vtAttributes',
        'defAttributes',
        'ssoAttributes',
        'optionalAttributes',
        'tagAttributes'
    )

    foreach ($category in $attributeCategories) {
        if ($jsonContent.$category) {
            foreach ($attr in $jsonContent.$category) {
                if ($attr.attributeCode -eq $AttributeCode) {
                    return $attr.attributeId
                }
            }
        }
    }

    return "AttributeCode '$AttributeCode' not found."
}
#>

function Invoke-OneGateAPI {
    param (
        [Parameter(Mandatory)]
        [string]$uri,
        [string]$contentType = $null,
        [Parameter(Mandatory)]
        [hashtable]$headers,
        [Parameter(Mandatory)]
        [string]$method,
        [object]$body
    )
    try {
        if ($body) {
            Invoke-WebRequest $uri `
                -ContentType $contentType `
                -Headers $header `
                -Method $method `
                -Body $body `
                -UseBasicParsing
        } else {
            Invoke-WebRequest $uri `
                -ContentType $contentType `
                -Headers $headers `
                -Method $method `
                -UseBasicParsing
        }
   } catch {
        Write-Error "APIの呼び出しに失敗しました: $($_.Exception.Message)"
        throw $_
    }
}

function Invoke-OneGateCsvImport {
    param (
        [Parameter(Mandatory)]
        [string]$uri,
        [Parameter(Mandatory)]
        [hashtable]$headers,
        [Parameter(Mandatory)]
        [string]$boundary,
        [Parameter(Mandatory)]
        [string]$localCsvFilePath,
        [Parameter(Mandatory)]
        [string]$csvFileName,
        [string]$encodingId = $null,
        [string]$specificType = $null # PasswordManagerのtype
    )
    # マルチパートフォームデータの準備
    $LF = "`r`n"
    $fileBin = [System.IO.File]::ReadAllText($localCsvFilePath)
    # SPMの場合
    if ($specificType) {
        $multipartParts = (
            "--$boundary",
            "Content-Disposition: form-data; name=`"type`"$LF",
            "$specificType"
        )
    # SPM以外
    } elseif ($encodingId) {
        $multipartParts = (
            "--$boundary",
            "Content-Disposition: form-data; name=`"encodingId`"$LF",
            $encodingId
        )
    } else {
        $multipartParts = @()
    }
    $multipartParts += @(
        "--$boundary",
        "Content-Disposition: form-data; name=`"file`"; filename=`"$csvFileName`"",
        "Content-Type: application/octet-stream$LF",
        $fileBin,
        "--$boundary--$LF"
    )
    $multipartBody = $multipartParts -join $LF
    Invoke-OneGateAPI `
	    -uri $uri `
   	    -contentType "multipart/form-data; boundary=$boundary" `
   	    -headers $headers `
   	    -method "POST" `
        -body ([Text.Encoding]::UTF8.GetBytes($multipartBody))
}

function Invoke-OneGateSyncJob {
    param (
        [Parameter(Mandatory)]
        [string]$baseUri,
        [Parameter(Mandatory)]
        [hashtable]$headers
    )
    # batchJobGroupId取得
    $uri = $baseUri + "/schedule/jobs/"
    try {
        $resp = Invoke-OneGateAPI `
            -uri $uri `
            -headers $headers `
            -method "GET"
    }
    catch {
        Write-Error "APIの呼び出しに失敗しました: $($_.Exception.Message)"
        throw $_
    }
    $batchJobGroupId = (($resp.Content | ConvertFrom-Json).responseBody.batchjobGroupList `
        | Where-Object { $_.code -eq "DIFFSYNC"}).batchJobGroupId
    $uri = $baseUri + "/schedule/jobs/enqueue/$batchJobGroupId"
    Write-Debug $uri
    Invoke-OneGateAPI `
	    -uri $uri `
        -contentType "text/plain" `
   	    -headers $headers `
   	    -method "GET" `
}

### 利用者管理

# 利用者登録
Write-Host "利用者登録" -ForegroundColor Yellow
$uri = $baseUri + "/employee"
$contentType = "application/json"
$method = "POST"

# JSONファイルを読み込み、ダミーパスワードを実際のパスワードで置換
$body = Get-Content .\data\OneGateUser_add.json -Encoding UTF8 -Raw
$body = $body -replace '"DUMMY_PASSWORD"', ('"' + $password + '"')
$body = $body.TrimEnd()
$username = (($body | ConvertFrom-Json).defAttributes `
    | Where-Object { $_.attributeCode -eq "DEF_ATTR_0001" }).value[0].value

$result = Invoke-OneGateAPI `
    -uri $uri `
    -contentType $contentType `
    -headers $header `
    -method $method `
    -body ([Text.Encoding]::UTF8.GetBytes($body)) `
    | ConvertFrom-Json
if ($result.status -eq "failed") {
    Write-Error "[$($result.errorInfo.errorCode)] $($result.errorInfo.errorMessage)"
} else {
    Write-Host $result.status -ForegroundColor Green
    Write-Debug $($result.responseBody | ConvertTo-Json -Depth 100 -Compress)
}

# 利用者検索
Write-Host "利用者検索" -ForegroundColor Yellow
$uri = $baseUri + "/employee?key=name&value=$username"
$contentType = "text/plain; charset=utf-8"
$method = "GET"

$result = Invoke-OneGateAPI `
    -uri $uri `
    -contentType $contentType `
    -headers $header `
    -method $method `
    | ConvertFrom-Json
if ($result.status -eq "failed") {
    Write-Error "[$($result.errorInfo.errorCode)] $($result.errorInfo.errorMessage)"
} else {
    Write-Host $result.status -ForegroundColor Green
    Write-Debug $($result.responseBody | ConvertTo-Json -Depth 100 -Compress)
}

# 社員ID取得
$employeeId = $($result.responseBody.results.employeeId)

# 社員IDが必要な利用者API
if ($employeeId) {
    $targetTypeLlist = @(
        @{
            name = "利用者情報取得";
            path = "/employee/$employeeId";
            contentType = "text/plain; charset=utf-8";
            method = "GET";
        },
        @{
            name = "利用者更新";
            path = "/employee/$employeeId";
            contentType = "application/json";
            method = "PUT";
            body = $(Get-Content .\data\OneGateUser_mod.json -Encoding UTF8)
        },
        @{
            name = "利用者削除";
            path = "/employee/$employeeId";
            contentType = "text/plain";
            method = "DELETE";
        }
    )

    foreach ($targetType in $targetTypeLlist) {
        Write-Host $targetType.name -ForegroundColor Yellow
        if ($targetType.body) {
            $body = [Text.Encoding]::UTF8.GetBytes($targetType.body)
        } else {
            $body = $null
        }
            $result = Invoke-OneGateAPI `
                -uri $($baseUri + $targetType.path) `
                -contentType  $targetType.contentType `
                -headers $header `
                -method $targetType.method `
                -body $body `
                | ConvertFrom-Json
        if ($result.status -eq "failed") {
            Write-Error "[$($result.errorInfo.errorCode)] $($result.errorInfo.errorMessage)"
        } else {
            Write-Host $result.status -ForegroundColor Green
            Write-Debug $($result.responseBody | ConvertTo-Json -Depth 100 -Compress)
        }
    }
}

## 利用者インポート・エクスポート
$targetTypeLlist = @(
    @{
        name = "利用者";
        path = "/employee";
        csvname = "OneGateUser.csv";
        query = "encodingId=$($encodingId.sjis)&key=name&value=oguser";
    },
    @{
        name = "アプリケーションロール"
        path = "/employee/role/cloud";
        csvname = "OneGateUserCloudServiceRole.csv";
        query = "encodingId=$($encodingId.sjis)&key=name&value=oguser";
    },
    @{
        name = "Webアプリ"
        path = "/employee/role/web";
        csvname = "OneGateUserWebSsoRole.csv";
        query = "encodingId=$($encodingId.sjis)&key=name&value=oguser";
    },
    @{
        name = "ICカード割り当て"
        path = "/employee/ic-card";
        csvname = "OneGateUserIcCard.csv";
        query = "encodingId=$($encodingId.sjis)&key=name&value=oguser";
    }
)

# インポート
foreach ($targetType in $targetTypeLlist) {
    Write-Host $($targetType.name + "インポート") -ForegroundColor Yellow
    $result = Invoke-OneGateCsvImport `
        -uri ($baseUri + $targetType.path + "/import") `
        -header $header `
        -boundary $boundary `
        -localCsvFilePath (Join-Path $dataDir $targetType.csvname) `
        -csvFileName $targetType.csvname `
        -encodingId $encodingId.utf8 `
        | ConvertFrom-Json
    if ($result.status -eq "failed") {
        Write-Error "[$($result.errorInfo.errorCode)] $($result.errorInfo.errorMessage)"
    } else {
        Write-Host $result.status -ForegroundColor Green
    }
}

# エクスポート
foreach ($targetType in $targetTypeLlist) {
    Write-Host $($targetType.Name + "エクスポート") -ForegroundColor Yellow
    $uri = $baseUri + $targetType.path + "/export?" + $targetType.query
    $contentType = "text/plain; charset=utf-8"
    $method = "GET"

    $result = Invoke-OneGateAPI `
        -uri $uri `
        -contentType $contentType `
        -headers $header `
        -method $method
    Write-Host $result.StatusCode -ForegroundColor Green
    Write-Debug $result.Content
}

### PasswordManager管理

## PasswordManagerインポート・エクスポート
$targetTypeLlist = @(
    @{
        name = "Webアプリ設定"
        path = "/settings/password-manager/web-sso";
        csvname = "websso.csv";
        type = $importTypeId.modify;
    },
    @{
        name = "Webアプリユーザー設定"
        path = "/settings/password-manager/user-web-sso";
        csvname = "userwebsso.csv";
        type = $importTypeId.modify;
    },
    @{
        name = "Windowsアプリ設定"
        path = "/settings/password-manager/win-app-sso";
        csvname = "winappsso.csv";
        type = $importTypeId.modify;
    },
    @{
        name = "Windowsアプリユーザー設定"
        path = "/settings/password-manager/user-win-app-sso";
        csvname = "userwinappsso.csv";
        type = $importTypeId.modify;
    },
    @{
        name = "モバイルアプリ設定"
        path = "/settings/password-manager/mobile-app-sso";
        csvname = "mobileappsso.csv";
        type = $importTypeId.modify;
    },
    @{
        name = "モバイルアプリユーザー設定"
        path = "/settings/password-manager/user-mobile-app-sso";
        csvname = "usermobileappsso.csv";
        type = $importTypeId.modify;
    },
    @{
        name = "Windowsサインイン設定"
        path = "/settings/password-manager/desktop-sso";
        csvname = "windowsSignin.csv";
        type = $importTypeId.modify;
    }
)
$contentType = "text/plain; charset=utf-8"
$method = "GET"

# インポート
foreach ($targetType in $targetTypeLlist) {
    Write-Host $($targetType.name + "インポート") -ForegroundColor Yellow
    $result = Invoke-OneGateCsvImport `
        -uri ($baseUri + $targetType.path + "/import") `
        -header $header `
        -boundary $boundary `
        -localCsvFilePath (Join-Path $dataDir $targetType.csvname) `
        -csvFileName $targetType.csvname `
        -specificType $targetType.type `
        | ConvertFrom-Json
    if ($result.status -eq "failed") {
        Write-Error "[$($result.errorInfo.errorCode)] $($result.errorInfo.errorMessage)"
    } else {
        Write-Host $result.status -ForegroundColor Green
    }
}

# エクスポート
foreach ($targetType in $targetTypeLlist) {
    Write-Host $($targetType.Name + "エクスポート") -ForegroundColor Yellow
    $uri = $baseUri + $targetType.path + "/export?" + $targetType.query

    $result = Invoke-OneGateAPI `
        -uri $uri `
        -contentType $contentType `
        -headers $header `
        -method $method
    Write-Host $result.StatusCode -ForegroundColor Green
    Write-Debug $result.Content
}

### 証明書・ログエクスポート
$targetTypeLlist = @(
    @{
        name = "証明書"
        path = "/certificate/certificates"
        query = "max=20&pageNo=1&status=1&encodingId=$($encodingId.utf8)"
    },
    @{
        name = "証明書ログ"
        path = "/certificate/certificates/logs"
        query = "max=20&pageNo=1&log=1"
    },
    @{
        name = "管理ログ"
        path = "/logs/managed/"
        query = "max=20&pageNo=1&key=log_timestamp&value=$searchTeam"
    },
    @{
        name = "管理者ログインログ"
        path = "/logs/login/manager"
        query = "max=20&pageNo=1&key=log_timestamp&value=$searchTeam"
    },
    @{
        name = "利用者ログインログ"
        path = "/logs/login/employee"
        query = "max=20&pageNo=1&key=log_timestamp&value=$searchTeam"
    },
    @{
        name = "利用者操作ログ"
        path = "/logs/employee"
        query = "max=20&pageNo=1&key=log_timestamp&value=$searchTeam"
    },
    @{
        name = "同期実行ログ"
        path = "/tasks/summary"
        query = "max=20&pageNo=1&key=log_timestamp&value=$searchTeam"
    },
    @{
        name = "SSOアクセスログ"
        path = "/logs/sso"
        query = "max=20&pageNo=1"
    }
)
$searchTeam = (Get-Date((Get-Date).AddDays(-30)) -Format "yyyy/MM/dd") + "-" #検索期間
$contentType = "text/plain; charset=utf-8"
$method = "GET"

foreach ($targetType in $targetTypeLlist) {
    Write-Host $($targetType.Name + "エクスポート") -ForegroundColor Yellow
    $uri = $baseUri + $targetType.path + "/export?" + $targetType.query

    $result = Invoke-OneGateAPI `
        -uri $uri `
        -contentType $contentType `
        -headers $header `
        -method $method
    Write-Host $result.StatusCode -ForegroundColor Green
    Write-Debug $result.Content
}

# 同期処理実行
$result = (Invoke-OneGateSyncJob `
    -baseUri $baseUri `
    -headers $header).Content `
    | ConvertFrom-Json
if ($result.status -eq "failed") {
    Write-Error "[$($result.errorInfo.errorCode)] $($result.errorInfo.errorMessage)"
} else {
    Write-Host $result.status -ForegroundColor Green
    Write-Debug $($result.responseBody | ConvertTo-Json -Depth 100 -Compress)
}
# 同期完了まで待機
$uri = $baseUri + "/tasks/summary?key=status&value=Processing"
$contentType = "text/plain; charset=utf-8"
$method = "GET"

Write-Host "Waiting for the job to end..." -ForegroundColor Yellow
do {
    $resp = Invoke-OneGateAPI `
        -uri $uri `
        -contentType $contentType `
        -headers $header `
        -method $method `
        | ConvertFrom-Json
    Write-Debug $resp
    Start-Sleep -Seconds 60
} while ($resp.responseBody.total -gt 0)

exit 0;
