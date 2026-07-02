# File paths
$adS3Key = "s3://csoft-automation/AD_EXPORTS/AD_Users_By_ClientOU.csv"
$adCsvPath = "C:\CaribouSoftwareData\SAL_Automation\AD_Users_By_ClientOU.csv"
$salCsvPath = "C:\CaribouSoftwareData\SAL_Automation\SAL_Subscriptions_With_Tags.csv"
$outputCsvPath = "C:\CaribouSoftwareData\SAL_Automation\Combined_AD_and_SAL_Users.csv"
$awsprofile = "salscript"


# Get AD from S3
Write-Host "Get AD .csv object from S3"
aws s3 cp $adS3Key $adCsvPath `
  --region us-west-2 `
  --profile $awsprofile
Write-Host "Retrieved AD .csv object from S3"

# Load CSVs
$adUsers = Import-Csv $adCsvPath
$salUsers = Import-Csv $salCsvPath

# Build lookups
$adLookup = @{}
foreach ($ad in $adUsers) {
    $key = $ad.SamAccountName.ToLower()
    $adLookup[$key] = $ad
}

$salLookup = @{}
foreach ($sal in $salUsers) {
    $key = $sal.UserName.ToLower()
    $salLookup[$key] = $sal
}

# Track processed keys to detect unmatched ones later
$processedKeys = @{}

# Merge AD users first
$combined = foreach ($ad in $adUsers) {
    $key = $ad.SamAccountName.ToLower()
    $salMatch = $salLookup[$key]
    $processedKeys[$key] = $true

    [PSCustomObject]@{
        Name                   = $ad.Name
        SamAccountName         = $ad.SamAccountName
        AD_ClientName          = $ad.ClientName
        DistinguishedName      = $ad.DistinguishedName
        Enabled                = $ad.Enabled

        SAL_Product            = if ($salMatch.Product) { $salMatch.Product } else { "MISSING" }
        ProductUserArn         = if ($salMatch.ProductUserArn) { $salMatch.ProductUserArn } else { "MISSING" }
        UserName               = if ($salMatch.UserName) { $salMatch.UserName } else { "MISSING" }
        Status                 = if ($salMatch.Status) { $salMatch.Status } else { "MISSING" }
        SubscriptionStartDate  = if ($salMatch.SubscriptionStartDate) { $salMatch.SubscriptionStartDate } else { "MISSING" }
        Caribou                = if ($salMatch.Caribou) { $salMatch.Caribou } else { "MISSING" }
        ClientCode             = if ($salMatch.ClientCode) { $salMatch.ClientCode } else { "MISSING" }
    }
}

# Now merge unmatched SAL users
$unmatchedSAL = $salUsers | Where-Object {
    $key = $_.UserName.ToLower()
    -not $processedKeys.ContainsKey($key)
}

$unmatchedObjects = foreach ($sal in $unmatchedSAL) {
    [PSCustomObject]@{
        Name                   = "MISSING"
        SamAccountName         = $sal.UserName
        AD_ClientName          = "MISSING"
        DistinguishedName      = "MISSING"
        Enabled                = "MISSING"

        SAL_Product            = $sal.Product
        ProductUserArn         = $sal.ProductUserArn
        UserName               = $sal.UserName
        Status                 = $sal.Status
        SubscriptionStartDate  = $sal.SubscriptionStartDate
        Caribou                = if ($sal.Caribou) { $sal.Caribou } else { "MISSING" }
        ClientCode             = if ($sal.ClientCode) { $sal.ClientCode } else { "MISSING" }
    }
}

# Combine and export
$combined += $unmatchedObjects
$combined | Export-Csv -Path $outputCsvPath -NoTypeInformation -Encoding UTF8
Write-Host "✅ Combined file written to: $outputCsvPath"
