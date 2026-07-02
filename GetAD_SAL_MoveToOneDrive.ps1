# Paths
$script1 = "C:\CaribouSoftwareData\SAL_Automation\GetSAL_From_CloudTrail-WithTags.ps1"
$script2 = "C:\CaribouSoftwareData\SAL_Automation\GetAD_FromS3_Combine_SAL_CSV.ps1"

# Run scripts
Write-Host "▶ Running GetSAL_From_CloudTrail-WithTags.ps1..."
& $script1

Write-Host "▶ GetAD_FromS3_Combine_SAL_CSV.ps1..."
& $script2

Copy-Item -Path "C:\CaribouSoftwareData\SAL_Automation\Combined_AD_and_SAL_Users.csv" -Destination "S:\onedrive\OneDrive - Caribou Software, Inc\DBOX_CSMAIN\Caribou on the Cloud\1-Pricing for Amazon\Daily AWS SAL Export\Combined_AD_and_SAL_Users.csv" -Force
Write-Host "▶ Moved .csv from SAL_Automation to OneDrive ..."
