<#
.SYNOPSIS
    Automated CSV-to-SQL Server Data Synchronization Script (Upsert Engine).

.DESCRIPTION
    This script reads user identity and license information from a local CSV file
    and synchronizes it with a specific SQL Server database table. Instead of blindly 
    inserting data, it performs a delta-check comparison using 'AD_USER_ACCOUNT' as the 
    primary lookup key to determine the appropriate action per row.

.OPERATIONAL LOGIC
    1. Table Validation : Verifies or creates the target SQL table using an idempotent schema.
    2. Data Cleansing   : Sanitizes empty string fields, converts booleans, and normalizes date formats.
    3. Row Comparison   : Queries the database for an existing record matching 'AD_USER_ACCOUNT'.
    4. Smart Action     : 
       - INSERT : If the user does not exist in the database.
       - UPDATE : If the user exists but incoming CSV data differs from the database record.
       - SKIP   : If the user exists and data is identical (prevents unnecessary writes).

.REQUIREMENTS
    - Target CSV path with matching headers ('Name', 'SamAccountName', 'Enabled', etc.)
    - Network connectivity and write permissions to the designated SQL Server Instance.
    - Execution Policy set to allow local script execution (e.g., RemoteSigned).
#>
# ==============================================================================
# CONFIGURATION
# ==============================================================================

# Read the csv file under the same folder.
$csvPath        = Join-Path -Path $PSScriptRoot -ChildPath "Combined_AD_and_SAL_Users.csv"

$serverName     = "CARI-TRACK2019\SQL2019"
$databaseName   = "TRACKER_DBZ_TEST"

$tableName      = "SAL_LICENSES"

# ==============================================================================
# 1. FUNCTIONS DEFINITION
# ==============================================================================

function Get-SafeEnabledValue {
    param ([string]$EnabledString)
    $cleanString = ($EnabledString -as [string]).Trim().ToUpper()
    if ($cleanString -eq "FALSE" -or $cleanString -eq "0" -or [string]::IsNullOrWhiteSpace($cleanString)) { 
        return 0 
    }
    return 1
}

function Get-SafeSqlDate {
    param ([string]$DateString, [string]$UserName)
    $defaultDate = "1900-01-01 00:00:00"
    if ([string]::IsNullOrWhiteSpace($DateString) -or $DateString -match "MISS") {
        return $defaultDate
    } 
    try {
        $parsedDate = Get-Date $DateString -ErrorAction Stop
        return $parsedDate.ToString("yyyy-MM-dd HH:mm:ss")
    }
    catch {
        Write-Warning "Format Error: Could not parse date string '$DateString' for user [$UserName]. Using default fallback date."
        return $defaultDate
    }
}

function Get-SafeString {
    param ($Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" } 
    return $Value.ToString().Trim()
}

# NEW FUNCTION: Fetches an existing row by AD_USER_ACCOUNT to compare changes
function Get-ExistingRow {
    param (
        [System.Data.SqlClient.SqlConnection]$Connection,
        [string]$TableName,
        [string]$AccountName
    )
    
    $query = "SELECT AD_FULL_NAME, AD_USER_ACCOUNT, AD_CLIENT_FOLDER, AD_ENABLED, SAL_PRODUCT, SAL_USER_ACCOUNT, SAL_STATUS, SAL_START_DATE FROM $TableName WHERE AD_USER_ACCOUNT = @SamAccountName"
    $command = $Connection.CreateCommand()
    $command.CommandText = $query
    $null = $command.Parameters.AddWithValue("@SamAccountName", $AccountName)
    
    $reader = $command.ExecuteReader()
    $dt = New-Object System.Data.DataTable
    $dt.Load($reader)
    $command.Dispose()
    
    if ($dt.Rows.Count -gt 0) {
        return $dt.Rows[0] # Return the matching database row
    }
    return $null # No match found
}

# ==============================================================================
# 2. MAIN EXECUTION FLOW
# ==============================================================================

$tableCreationQuery = @"
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[$tableName]') AND type in (N'U'))
BEGIN
    CREATE TABLE [dbo].[$tableName] (
        [AD_FULL_NAME] VARCHAR(200) NOT NULL DEFAULT (''),
        [AD_USER_ACCOUNT] VARCHAR(200) NOT NULL PRIMARY KEY, -- Configured as Unique Primary Key
        [AD_CLIENT_FOLDER] VARCHAR(500) NOT NULL DEFAULT (''),
        [AD_ENABLED] SMALLINT NOT NULL DEFAULT (1),
        [SAL_PRODUCT] VARCHAR(200) NOT NULL DEFAULT (''),
        [SAL_USER_ACCOUNT] VARCHAR(200) NOT NULL DEFAULT (''),
        [SAL_STATUS] VARCHAR(200) NOT NULL DEFAULT (''),
        [SAL_START_DATE] DATETIME NOT NULL DEFAULT ('1900-01-01'),
        [LAST_UPDATED] DATETIME NOT NULL DEFAULT ('1900-01-01')
    );
    PRINT 'Table $tableName created successfully.';
END
"@

if (-not (Test-Path $csvPath)) {
    Write-Error "CSV file not found at: $csvPath. Aborting execution."
    return
}


# ==============================================================================
# 1. Establish SQL Connection with Error Catching
# ==============================================================================

# Change 'YourSqlUsername' and 'YourSqlPassword' to your actual SQL credentials
$sqlUser = "sa"
$sqlPass = "4Score&7Yrs"

$connectionString = "Server=$serverName;Database=$databaseName;User ID=$sqlUser;Password=$sqlPass;TrustServerCertificate=True;"
$connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)

try {
    Write-Host ">>> Attempting to connect to SQL Server: $serverName ..." -ForegroundColor Cyan
    $connection.Open()
    Write-Host ">>> Connection Successful!" -ForegroundColor Green
}
catch {
    Write-Error "[Fatal Error]Script Terminated. Can't connect to the database! Please check if `$serverName is correct or if the SQL Server is running."
    Write-Error "Error Detail: $_"
    if ($connection) { $connection.Dispose() }
    return # Terminate the script immediately
}





Write-Host ">>> Verifying and checking target database table..." -ForegroundColor Cyan
$createCommand = $connection.CreateCommand()
$createCommand.CommandText = $tableCreationQuery
$null = $createCommand.ExecuteNonQuery()
$createCommand.Dispose()

Write-Host ">>> Reading CSV data and initiating smart sync..." -ForegroundColor Cyan
$csvData = Import-Csv -Path $csvPath

# Counters for final summary log
$insertedCount = 0
$updatedCount  = 0
$skippedCount  = 0

foreach ($row in $csvData) {
    
    # 1. Sanitize incoming CSV values
    $fullName      = Get-SafeString $row.Name
    $userAccount   = Get-SafeString $row.SamAccountName
    $clientFolder  = Get-SafeString $row.AD_ClientName
    $enabledValue  = Get-SafeEnabledValue -EnabledString $row.Enabled
    $salProduct    = Get-SafeString $row.SAL_Product
    $salUser       = Get-SafeString $row.UserName
    $salStatus     = Get-SafeString $row.Status
    $startDate     = Get-SafeSqlDate -DateString $row.SubscriptionStartDate -UserName $row.UserName
    $currentTimestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

    # Skip processing entirely if there isn't a valid identifier name in the CSV
    if ([string]::IsNullOrWhiteSpace($fullName)) { continue }

    # 2. Check if a row with this AD_USER_ACCOUNT already exists in SQL Server
    $existingRow = Get-ExistingRow -Connection $connection -TableName $tableName -AccountName $userAccount

    if ($null -ne $existingRow) {
        # 3. COMPARE DIFFERENCES
        # SQL Server DATETIME might return variations in string parsing, so cast dates cleanly for equality checks
        $dbDate = ([DateTime]$existingRow["SAL_START_DATE"]).ToString("yyyy-MM-dd HH:mm:ss")
        $csvDateCheck = ([DateTime]$startDate).ToString("yyyy-MM-dd HH:mm:ss")

        $hasChanges = $false
        if ($existingRow["AD_FULL_NAME"].ToString().Trim() -ne $fullName)  { $hasChanges = $true }
        if ($existingRow["AD_CLIENT_FOLDER"].ToString().Trim() -ne $clientFolder) { $hasChanges = $true }
        if ([int]$existingRow["AD_ENABLED"]                    -ne $enabledValue)  { $hasChanges = $true }
        if ($existingRow["SAL_PRODUCT"].ToString().Trim()       -ne $salProduct)    { $hasChanges = $true }
        if ($existingRow["SAL_USER_ACCOUNT"].ToString().Trim()  -ne $salUser)       { $hasChanges = $true }
        if ($existingRow["SAL_STATUS"].ToString().Trim()        -ne $salStatus)     { $hasChanges = $true }
        if ($dbDate                                            -ne $csvDateCheck)  { $hasChanges = $true }

        if ($hasChanges) {
            # 4. EXECUTE UPDATE
            $updateQuery = @"
            UPDATE $tableName 
            SET
                AD_FULL_NAME = @Name,
                AD_USER_ACCOUNT = @SamAccountName, 
                AD_CLIENT_FOLDER = @AD_ClientName, 
                AD_ENABLED = @Enabled,
                SAL_PRODUCT = @SAL_Product,
                SAL_USER_ACCOUNT = @UserName,
                SAL_STATUS = @Status,
                SAL_START_DATE = @SubscriptionStartDate,
                LAST_UPDATED = @LastUpdated
            WHERE AD_USER_ACCOUNT = @SamAccountName
"@
            $actionCommand = $connection.CreateCommand()
            $actionCommand.CommandText = $updateQuery
            $updatedCount++
        } else {
            # No changes found - skip this record completely
            $skippedCount++
            continue
        }
    } 
    else {
        # 5. EXECUTE INSERT (Record is brand new)
        $insertQuery = @"
        INSERT INTO $tableName (
            AD_FULL_NAME, AD_USER_ACCOUNT, AD_CLIENT_FOLDER, AD_ENABLED, 
            SAL_PRODUCT, SAL_USER_ACCOUNT, SAL_STATUS, SAL_START_DATE, LAST_UPDATED
        ) 
        VALUES (
            @Name, @SamAccountName, @AD_ClientName, @Enabled, 
            @SAL_Product, @UserName, @Status, @SubscriptionStartDate, @LastUpdated
        )
"@
        $actionCommand = $connection.CreateCommand()
        $actionCommand.CommandText = $insertQuery
        $insertedCount++
    }

    # Bind variables to parameters (Shared mapping for both INSERT and UPDATE queries)
    $null = $actionCommand.Parameters.AddWithValue("@Name", $fullName)
    $null = $actionCommand.Parameters.AddWithValue("@SamAccountName", $userAccount)
    $null = $actionCommand.Parameters.AddWithValue("@AD_ClientName", $clientFolder)
    $null = $actionCommand.Parameters.AddWithValue("@Enabled", $enabledValue)
    $null = $actionCommand.Parameters.AddWithValue("@SAL_Product", $salProduct)
    $null = $actionCommand.Parameters.AddWithValue("@UserName", $salUser)
    $null = $actionCommand.Parameters.AddWithValue("@Status", $salStatus)
    $null = $actionCommand.Parameters.AddWithValue("@SubscriptionStartDate", $startDate)
    $null = $actionCommand.Parameters.AddWithValue("@LastUpdated", $currentTimestamp)

    try {
        $null = $actionCommand.ExecuteNonQuery()
    }
    catch {
        Write-Error "Database Operation Failure on Record: $fullName. Error Details: $_"
    }
    finally {
        $actionCommand.Dispose()
    }
}

$connection.Close()
$connection.Dispose()

# ==============================================================================
# SUMMARY REPORT
# ==============================================================================
Write-Host "`n>>> Sync Summary Report:" -ForegroundColor Cyan
Write-Host "    Inserted (New Users): $insertedCount" -ForegroundColor Green
Write-Host "    Updated (Changed)   : $updatedCount" -ForegroundColor Yellow
Write-Host "    Skipped (No Changes): $skippedCount" -ForegroundColor Gray
Write-Host ">>> Process Finished Successfully!" -ForegroundColor Green