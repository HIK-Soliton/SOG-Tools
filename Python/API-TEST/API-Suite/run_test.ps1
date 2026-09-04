# OneGate API Suite リグレッションテスト実行スクリプト
# Windows用

param(
    [Parameter(Mandatory=$true)]
    [string]$ApiKey,
    
    [Parameter(Mandatory=$true)]
    [string]$Tenant,
    
    [Parameter(Mandatory=$true)]
    [string]$Password,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet('baseline', 'compare', 'normal')]
    [string]$Mode = 'normal'
)

Write-Host "OneGate API Suite リグレッションテスト" -ForegroundColor Green
Write-Host "========================================"

# Python 3が利用可能かチェック
try {
    $pythonVersion = & python --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Python not found"
    }
    Write-Host "Python: $pythonVersion" -ForegroundColor Gray
} catch {
    Write-Host "エラー: Python 3がインストールされていません" -ForegroundColor Red
    exit 1
}

# 依存パッケージのインストールチェック
try {
    & python -c "import requests" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "依存パッケージをインストールしています..." -ForegroundColor Yellow
        & pip install -r requirements.txt
    }
} catch {
    Write-Host "依存パッケージのインストールに失敗しました" -ForegroundColor Red
    exit 1
}

# テスト実行
switch ($Mode) {
    'baseline' {
        Write-Host "ベースラインを保存します..." -ForegroundColor Yellow
        & python api_regression_test.py `
            --api-key $ApiKey `
            --tenant $Tenant `
            --password $Password `
            --save-baseline
    }
    'compare' {
        Write-Host "リグレッションテストを実行します..." -ForegroundColor Yellow
        & python api_regression_test.py `
            --api-key $ApiKey `
            --tenant $Tenant `
            --password $Password `
            --compare
    }
    'normal' {
        Write-Host "通常テストを実行します..." -ForegroundColor Yellow
        & python api_regression_test.py `
            --api-key $ApiKey `
            --tenant $Tenant `
            --password $Password
    }
}

if ($LASTEXITCODE -eq 0) {
    Write-Host "`n完了しました" -ForegroundColor Green
} else {
    Write-Host "`nエラーが発生しました" -ForegroundColor Red
    exit $LASTEXITCODE
}
