param(
    [string]$Bucket = "",
    [string]$Profile = "durian-iam",
    [string]$Key = "artifacts/k3s/ecr-provider/v1.34.3/linux-amd64/ecr-credential-provider",
    [switch]$Upload
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

$binary = Join-Path $env:USERPROFILE `
    "durian-build\ecr-provider-v1.34.3\ecr-credential-provider"

$hashFile = Join-Path $repo "scripts\ecr-provider.sha256"

if (-not (Test-Path $binary)) {
    throw "ECR binary not found"
}

if (-not (Test-Path $hashFile)) {
    throw "SHA256 file not found"
}

$expected = (Get-Content $hashFile -Raw).Trim().ToLowerInvariant()
$actual = (Get-FileHash $binary -Algorithm SHA256).Hash.ToLowerInvariant()

if ($expected -ne $actual) {
    throw "SHA256 mismatch - upload blocked"
}

Write-Host "ECR binary SHA256 verified"
Write-Host "Size: $((Get-Item $binary).Length) bytes"
Write-Host "S3 key: $Key"

if (-not $Upload) {
    Write-Host "DRY RUN: No AWS changes made."
    exit 0
}

if ([string]::IsNullOrWhiteSpace($Bucket)) {
    throw "Approved S3 bucket is required"
}

Write-Host "Target: s3://$Bucket/$Key"

$answer = Read-Host "Team approval confirmed? Type UPLOAD"

if ($answer -cne "UPLOAD") {
    throw "Upload cancelled"
}

aws s3api put-object `
    --bucket $Bucket `
    --key $Key `
    --body $binary `
    --server-side-encryption AES256 `
    --metadata "sha256=$actual" `
    --profile $Profile `
    --region ap-northeast-2

if ($LASTEXITCODE -ne 0) {
    throw "S3 upload failed"
}

Write-Host "S3 artifact uploaded."
