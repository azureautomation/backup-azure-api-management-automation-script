<#
.SYNOPSIS
	This Azure Automation runbook automates Azure API Management backup to Blob storage and deletes old backups from blob storage. 

.DESCRIPTION
	You should use this Runbook if you want manage Azure API Management backups in Blob storage. 
	This is a PowerShell runbook, as opposed to a PowerShell Workflow runbook. 
	It requires Az.ApiManagement module to be installed.
	The script uses the Managed Identity to login and perform the backup.

.PARAMETER ApimResourceGroupName
	Specifies the name of the resource group where the Azure Api Management instance is located.
	
.PARAMETER ApimInstanceName
	Specifies the name of the Azure Api Management which script will backup.

.PARAMETER StorageAccountName
	Specifies the name of the storage account where backup file will be uploaded.

.PARAMETER StorageAccountKey
	Specifies the key of the storage account where backup file will be uploaded.

.PARAMETER BlobContainerName
	Specifies the container name of the storage account where backup file will be uploaded. Container will be created 
	if it does not exist.

.PARAMETER BackupFilePrefix
	Specifies the backup blob file prefix. The suffix will be automatically generated based on the date in the format 
	yyyyMMddHHmm followed by the .bak file extension. Default value apim_.

.PARAMETER RetentionDays
	Specifies the number of days how long backups are kept in blob storage. The default value is 30 days as the backups 
	expire after that. Script will remove all older files from container, thus a dedicated container should be used 
	for this script.

.INPUTS
	None.

.OUTPUTS
	Human-readable informational and error messages produced during the job. Not intended to be consumed by another runbook.
#>

param(
    [parameter(Mandatory=$true)]
    [String] $ApimResourceGroupName,
    [parameter(Mandatory=$true)]
    [String] $ApimInstanceName,
    [parameter(Mandatory=$true)]
    [String]$StorageAccountName,
    [parameter(Mandatory=$true)]
    [String]$StorageAccountKey,
    [parameter(Mandatory=$true)]
    [string]$BlobContainerName,
    [parameter(Mandatory=$false)]
    [string]$BackupFilePrefix = "apim_",
    [parameter(Mandatory=$false)]
    [Int32]$RetentionDays = 30
)

function Login() {
    try
    {
        Write-Verbose "Logging in to Azure with Managed Identity..." -Verbose
        Import-Module Az
        Connect-AzAccount -Identity
    }
    catch {
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}

function Create-Blob-Container([string]$blobContainerName, $storageContext) {
	Write-Verbose "Checking if blob container '$blobContainerName' already exists" -Verbose
	if (Get-AzStorageContainer -ErrorAction "Stop" -Context $storageContext | Where-Object { $_.Name -eq $blobContainerName }) {
		Write-Verbose "Container '$blobContainerName' already exists" -Verbose
	} else {
		New-AzStorageContainer -ErrorAction "Stop" -Name $blobContainerName -Permission Off -Context $storageContext
		Write-Verbose "Container '$blobContainerName' created" -Verbose
	}
}

function Backup-To-Blob-Storage([string]$apimResourceGroupName, [string]$apimInstanceName, $storageContext, [string]$blobContainerName, [string]$backupPrefix) {

	$backupBlobName = $backupPrefix + (Get-Date).ToString("yyyyMMddHHmm") + ".bak"
	Write-Verbose "Starting APIM backup to blob '$blobContainerName/$backupBlobName'" -Verbose
	Backup-AzApiManagement -Name $apimInstanceName -ResourceGroupName $apimResourceGroupName -StorageContext $storageContext `
                       -TargetContainerName $blobContainerName `
                       -TargetBlobName $backupBlobName
}

function Delete-Old-Backups([int]$retentionDays, [string]$blobContainerName, $storageContext) {
	Write-Output "Removing backups older than '$retentionDays' days from container: '$blobContainerName'"
	$isOldDate = [DateTime]::UtcNow.AddDays(-$retentionDays)
	$blobs = Get-AzStorageBlob -Container $blobContainerName -Context $storageContext
	foreach ($blob in ($blobs | Where-Object { $_.LastModified.UtcDateTime -lt $isOldDate -and $_.BlobType -eq "BlockBlob" })) {
		Write-Verbose ("Removing blob: " + $blob.Name) -Verbose
		Remove-AzStorageBlob -Blob $blob.Name -Container $blobContainerName -Context $storageContext
	}
}

Write-Verbose "Starting APIM backup" -Verbose
Write-Verbose "Establishing storage context" -Verbose
$StorageContext = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $StorageAccountKey

Login

Create-Blob-Container `
	-blobContainerName $blobContainerName `
	-storageContext $storageContext
	
Backup-To-Blob-Storage `
	-apimResourceGroupName $ApimResourceGroupName `
    -apimInstanceName $ApimInstanceName `
    -storageContext $StorageContext `
    -blobContainerName $BlobContainerName `
    -backupPrefix $BackupFilePrefix
	
Delete-Old-Backups `
	-retentionDays $RetentionDays `
	-storageContext $StorageContext `
	-blobContainerName $BlobContainerName
	
Write-Verbose "APIM backup script finished" -Verbose
