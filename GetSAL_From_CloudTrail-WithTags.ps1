# Parameters
$region = "us-west-2"
$identityProvider = "ActiveDirectoryIdentityProvider={DirectoryId=sd-85adcc5608}"
$product = "REMOTE_DESKTOP_SERVICES"
$jsonOutputPath = "C:\CaribouSoftwareData\SAL_Automation\Last_ListProductSubscriptions_Events.json"
$csvOutputPath = "C:\CaribouSoftwareData\SAL_Automation\SAL_Subscriptions_With_Tags.csv"
$awsprofile = "salscript"

# Trigger the CloudTrail event
aws license-manager-user-subscriptions list-product-subscriptions `
  --region $region `
  --identity-provider $identityProvider `
  --product $product `
  --profile $awsprofile `
  | Out-Null

Write-Host "✅ list-product-subscriptions called. Waiting 30 seconds for CloudTrail to ingest the event..."
Start-Sleep -Seconds 30

# Get the most recent ListProductSubscriptions event
$lookupResult = aws cloudtrail lookup-events `
  --region $region `
  --lookup-attributes AttributeKey=EventName,AttributeValue=ListProductSubscriptions `
  --max-results 1 `
  --profile $awsprofile `
  | ConvertFrom-Json

if ($lookupResult.Events.Count -eq 0) {
    Write-Warning "❌ No ListProductSubscriptions event found in CloudTrail."
    return
}

# Parse first event to get eventTime
$firstEvent = $lookupResult.Events[0]
$eventTime = $firstEvent.EventTime

Write-Host "✅ Found eventTime: $eventTime — querying all events with same timestamp after 120 second pause..."
Start-Sleep -Seconds 120

# Get all events with same eventTime
$allEvents = aws cloudtrail lookup-events `
  --region $region `
  --lookup-attributes AttributeKey=EventName,AttributeValue=ListProductSubscriptions `
  --profile $awsprofile `
  | ConvertFrom-Json | Select-Object -ExpandProperty Events | Where-Object {
      $_.EventTime -eq $eventTime
  }

if (-not $allEvents) {
    Write-Warning "❌ No matching events found at eventTime $eventTime"
    return
}

$allEvents | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonOutputPath -Encoding utf8

Write-Host "✅ Found $($allEvents.Count) matching ListProductSubscriptions events at same time"

# Combine productUserSummaries from all matching events
$userSummaries = @()
foreach ($evt in $allEvents) {
    $evtJson = $evt.CloudTrailEvent | ConvertFrom-Json
    $evtSummaries = $evtJson.responseElements.productUserSummaries
    if ($evtSummaries) {
        $userSummaries += $evtSummaries
    }
}

if ($userSummaries.Count -eq 0) {
    Write-Warning "❌ No productUserSummaries found in any events."
    return
}

Write-Host "✅ Collected $($userSummaries.Count) user summaries from all event shards"

#  Load existing CSV if it exists
$existingTagData = @{}
if (Test-Path $csvOutputPath) {
    $csvRows = Import-Csv -Path $csvOutputPath

    foreach ($row in $csvRows) {
        # Use ProductUserArn as the unique key
        $arn = $row.ProductUserArn

        # Collect all non-metadata tag properties with non-empty and non-"MISSING" values
        $validTags = $row.PSObject.Properties | Where-Object {
            $_.Name -notin @("Product", "ProductUserArn", "UserName", "Status", "SubscriptionStartDate") -and
            $_.Value -and $_.Value -ne "MISSING"
        }

        if ($validTags.Count -gt 0) {
            $existingTagData[$arn] = $true
        }
    }
}


# Process each user
Write-Host "✅ About to process each user ARN for Tags"
$combinedRows = @()
$allTagKeys = @{}

foreach ($user in $userSummaries) {
    $arn = $user.productUserArn
    if (-not $arn) {
        Write-Warning "⚠️ Skipping user '$($user.userName)' — no productUserArn found."
        continue
    }

    # Build base row
    $row = [ordered]@{
        Product              = $product
        ProductUserArn       = $arn
        UserName             = $user.userName
        Status               = $user.status
        SubscriptionStartDate = $user.subscriptionStartDate
    }

    $tags = @{}

    if ($existingTagData.ContainsKey($arn)) {
        Write-Host "⏭️ Skipping tag fetch for $arn (tags already present in previous CSV)"

        # Load existing tags from the CSV so they're preserved
        $existingRow = $csvRows | Where-Object { $_.ProductUserArn -eq $arn }
        if ($existingRow) {
            foreach ($prop in $existingRow.PSObject.Properties) {
                if ($prop.Name -notin @("Product", "ProductUserArn", "UserName", "Status", "SubscriptionStartDate")) {
                    $tags[$prop.Name] = $prop.Value
                    $allTagKeys[$prop.Name] = $true
                }
            }
        }
    }
    else {
        # Get tags for this ARN
        $tagResult = aws license-manager-user-subscriptions list-tags-for-resource `
            --region $region `
            --resource-arn $arn `
            --profile $awsprofile `
            | ConvertFrom-Json

        foreach ($kvp in $tagResult.Tags.PSObject.Properties) {
            $tags[$kvp.Name] = $kvp.Value
            $allTagKeys[$kvp.Name] = $true
        }

        Write-Host "✅ Retrieved tags for $arn"
    }

    # Add tag columns to the row
    foreach ($kvp in $tags.GetEnumerator()) {
        $row[$kvp.Key] = $kvp.Value
    }

    $combinedRows += [PSCustomObject]$row
}

# Normalize tag columns across all rows
$allTagKeysList = $allTagKeys.Keys
$finalRows = $combinedRows | ForEach-Object {
    $row = $_
    foreach ($tagKey in $allTagKeysList) {
        if (-not $row.PSObject.Properties.Match($tagKey)) {
            $row | Add-Member -NotePropertyName $tagKey -NotePropertyValue "" -Force
        }
    }
    $row
}

# Export to CSV
$finalRows | Export-Csv -Path $csvOutputPath -NoTypeInformation -Encoding UTF8
Write-Host "✅ Subscription + tag data exported to $csvOutputPath"
