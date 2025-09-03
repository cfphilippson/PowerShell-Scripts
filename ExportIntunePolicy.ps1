Install-Module Microsoft.Graph -Scope CurrentUser
Install-Module Microsoft.Graph.DeviceManagement -Scope CurrentUser
<# 
.SYNOPSIS
  Exporta políticas do Intune (Device Configurations, Settings Catalog, Compliance) com assignments resolvidos.

.OUTPUT
  intune_export_YYYYMMDD_HHMMSS\
    |_ _summary.csv
    |_ _all_policies.json
    |_ <PolicyName>.json  (um por policy, com assignments)

.NOTES
  Scopes sugeridos (somente leitura):
    DeviceManagementConfiguration.Read.All
    DeviceManagementConfiguration.ReadWrite.All (se for alterar – não é necessário para exportar)
#>

# =============== CONFIG BÁSICA =================================================
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir    = "intune_export_$timestamp"
$Scopes    = @("DeviceManagementConfiguration.Read.All")

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

# =============== CONEXÃO AO GRAPH =============================================
Import-Module Microsoft.Graph -ErrorAction Stop
Import-Module Microsoft.Graph.DeviceManagement -ErrorAction Stop

Write-Host "Conectando ao Microsoft Graph..." -ForegroundColor Cyan
Connect-MgGraph -Scopes $Scopes | Out-Null

# =============== HELPERS (CACHE / FORMATOS) ===================================
# Cache p/ resolver nome de grupo por GUID
$script:GroupCache = @{}

function Resolve-GroupName {
  param([Parameter(Mandatory=$true)][string]$GroupId)
  if ([string]::IsNullOrWhiteSpace($GroupId)) { return $null }
  if ($script:GroupCache.ContainsKey($GroupId)) { return $script:GroupCache[$GroupId] }
  try {
    $g = Get-MgGroup -GroupId $GroupId -ErrorAction Stop
    $script:GroupCache[$GroupId] = $g.DisplayName
    return $g.DisplayName
  } catch {
    $script:GroupCache[$GroupId] = $GroupId
    return $GroupId
  }
}

function Get-TargetType {
  param($Target)
  return (
    $Target.AdditionalProperties['@odata.type'] `
      ?? $Target.'@odata.type' `
      ?? $Target.OdataType `
      ?? $null
  )
}

function Get-TargetGroupId {
  param($Target)
  return (
    $Target.GroupId `
      ?? $Target.AdditionalProperties['groupId'] `
      ?? $Target.AdditionalProperties.groupId `
      ?? $null
  )
}

function Get-TargetFilterInfo {
  param($Target)
  $filterId = (
    $Target.DeviceAndAppManagementAssignmentFilterId `
      ?? $Target.AdditionalProperties['deviceAndAppManagementAssignmentFilterId'] `
      ?? $null
  )
  $filterType = (
    $Target.DeviceAndAppManagementAssignmentFilterType `
      ?? $Target.AdditionalProperties['deviceAndAppManagementAssignmentFilterType'] `
      ?? $null
  )
  return ,@($filterId, $filterType)
}

function Describe-AssignmentTarget {
  param([Parameter(Mandatory=$true)]$Target)

  $type = Get-TargetType -Target $Target
  $groupId = Get-TargetGroupId -Target $Target
  $filter = Get-TargetFilterInfo -Target $Target
  $filterId, $filterType = $filter

  switch ($type) {
    "#microsoft.graph.allDevicesAssignmentTarget"       { $label = "All Devices" }
    "#microsoft.graph.allLicensedUsersAssignmentTarget" { $label = "All Users" }
    "#microsoft.graph.groupAssignmentTarget" {
      $name = Resolve-GroupName -GroupId $groupId
      $label = ("Group: {0}" -f $name)
    }
    default { $label = ($type ? $type : "Unknown Target") }
  }

  if ($filterId) {
    try {
      $f = Get-MgDeviceManagementAssignmentFilter -AssignmentFilterId $filterId -ErrorAction Stop
      $label = ("{0} [Filter: {1} ({2})]" -f $label, $f.DisplayName, $filterType)
    } catch {
      $label = ("{0} [Filter: {1} ({2})]" -f $label, $filterId, $filterType)
    }
  }
  return $label
}

function Is-PolicyActive {
  param([Parameter(Mandatory=$true)]$Assignments)
  if (-not $Assignments -or $Assignments.Count -eq 0) { return $false }
  foreach ($a in $Assignments) {
    if ($a.TargetODataType -in @(
      "#microsoft.graph.allDevicesAssignmentTarget",
      "#microsoft.graph.allLicensedUsersAssignmentTarget",
      "#microsoft.graph.groupAssignmentTarget"
    )) { return $true }
  }
  return $false
}

# =============== ASSIGNMENTS: COLETORES POR TIPO ===============================
function Get-DC-Assignments {
  param([Parameter(Mandatory=$true)][string]$PolicyId)
  try {
    $assigns = Get-MgDeviceManagementDeviceConfigurationAssignment -DeviceConfigurationId $PolicyId -ErrorAction Stop
  } catch {
    $msg = $_.Exception.Message
    Write-Warning ("[DeviceConfiguration] Falha assignments {0}: {1}" -f $PolicyId, $msg)
    return @()
  }

  foreach ($a in $assigns) {
    $t = $a.Target
    [PSCustomObject]@{
      AssignmentId    = $a.Id
      TargetODataType = (Get-TargetType -Target $t)
      TargetGroupId   = (Get-TargetGroupId -Target $t)
      TargetResolved  = (Describe-AssignmentTarget -Target $t)
    }
  }
}

function Get-SC-Assignments {
  param([Parameter(Mandatory=$true)][string]$PolicyId)
  try {
    $assigns = Get-MgDeviceManagementConfigurationPolicyAssignment -ConfigurationPolicyId $PolicyId -ErrorAction Stop
  } catch {
    $msg = $_.Exception.Message
    Write-Warning ("[SettingsCatalog] Falha assignments {0}: {1}" -f $PolicyId, $msg)
    return @()
  }

  foreach ($a in $assigns) {
    $t = $a.Target
    [PSCustomObject]@{
      AssignmentId    = $a.Id
      TargetODataType = (Get-TargetType -Target $t)
      TargetGroupId   = (Get-TargetGroupId -Target $t)
      TargetResolved  = (Describe-AssignmentTarget -Target $t)
    }
  }
}

function Get-CPL-Assignments {
  param([Parameter(Mandatory=$true)][string]$PolicyId)
  try {
    $assigns = Get-MgDeviceManagementDeviceCompliancePolicyAssignment -DeviceCompliancePolicyId $PolicyId -ErrorAction Stop
  } catch {
    $msg = $_.Exception.Message
    Write-Warning ("[Compliance] Falha assignments {0}: {1}" -f $PolicyId, $msg)
    return @()
  }

  foreach ($a in $assigns) {
    $t = $a.Target
    [PSCustomObject]@{
      AssignmentId    = $a.Id
      TargetODataType = (Get-TargetType -Target $t)
      TargetGroupId   = (Get-TargetGroupId -Target $t)
      TargetResolved  = (Describe-AssignmentTarget -Target $t)
    }
  }
}

# =============== EXPORTS =======================================================
$Master = New-Object System.Collections.Generic.List[object]

# ---- Device Configurations
Write-Host "Coletando Device Configurations..." -ForegroundColor Cyan
$dc = Get-MgDeviceManagementDeviceConfiguration -All
$idx = 0; $tot = ($dc | Measure-Object).Count
foreach ($p in $dc) {
  $idx++
  Write-Host ("[{0}/{1}] DC: {2}" -f $idx, $tot, $p.DisplayName) -ForegroundColor Gray

  $assign = @( Get-DC-Assignments -PolicyId $p.Id )
  $obj = [PSCustomObject]@{
    Type                 = "DeviceConfiguration"
    Id                   = $p.Id
    DisplayName          = $p.DisplayName
    Description          = $p.Description
    Version              = $p.Version
    CreatedDateTime      = $p.CreatedDateTime
    LastModifiedDateTime = $p.LastModifiedDateTime
    ODataType            = $p.'@odata.type'
    Assignments          = $assign
    IsActive             = (Is-PolicyActive -Assignments $assign)
  }

  $safe = ($p.DisplayName -replace '[\\\/:\*\?"<>\|]', '_')
  $obj | ConvertTo-Json -Depth 20 | Out-File -FilePath (Join-Path $OutDir "$safe.json") -Encoding utf8

  $Master.Add([PSCustomObject]@{
    Type            = "DeviceConfiguration"
    PolicyId        = $p.Id
    PolicyName      = $p.DisplayName
    Version         = $p.Version
    IsActive        = $obj.IsActive
    AssignmentCount = ($assign | Measure-Object).Count
    AssignedTargets = (($assign | Select-Object -Expand TargetResolved) -join '; ')
  })
}

# ---- Settings Catalog
Write-Host "Coletando Settings Catalog (Configuration Policies)..." -ForegroundColor Cyan
$sc = Get-MgDeviceManagementConfigurationPolicy -All
$idx = 0; $tot = ($sc | Measure-Object).Count
foreach ($p in $sc) {
  $idx++
  Write-Host ("[{0}/{1}] SC: {2}" -f $idx, $tot, $p.Name) -ForegroundColor Gray

  $assign = @( Get-SC-Assignments -PolicyId $p.Id )
  $obj = [PSCustomObject]@{
    Type                 = "SettingsCatalog"
    Id                   = $p.Id
    DisplayName          = $p.Name
    Description          = $p.Description
    Version              = $p.Version
    CreatedDateTime      = $p.CreatedDateTime
    LastModifiedDateTime = $p.LastModifiedDateTime
    Technologies         = $p.Technologies
    Assignments          = $assign
    IsActive             = (Is-PolicyActive -Assignments $assign)
  }

  $safe = ($p.Name -replace '[\\\/:\*\?"<>\|]', '_')
  $obj | ConvertTo-Json -Depth 20 | Out-File -FilePath (Join-Path $OutDir "$safe.json") -Encoding utf8

  $Master.Add([PSCustomObject]@{
    Type            = "SettingsCatalog"
    PolicyId        = $p.Id
    PolicyName      = $p.Name
    Version         = $p.Version
    IsActive        = $obj.IsActive
    AssignmentCount = ($assign | Measure-Object).Count
    AssignedTargets = (($assign | Select-Object -Expand TargetResolved) -join '; ')
  })
}

# ---- Compliance Policies
Write-Host "Coletando Compliance Policies..." -ForegroundColor Cyan
$cpl = Get-MgDeviceManagementDeviceCompliancePolicy -All
$idx = 0; $tot = ($cpl | Measure-Object).Count
foreach ($p in $cpl) {
  $idx++
  Write-Host ("[{0}/{1}] CPL: {2}" -f $idx, $tot, $p.DisplayName) -ForegroundColor Gray

  $assign = @( Get-CPL-Assignments -PolicyId $p.Id )
  $obj = [PSCustomObject]@{
    Type                 = "Compliance"
    Id                   = $p.Id
    DisplayName          = $p.DisplayName
    Description          = $p.Description
    Version              = $p.Version
    CreatedDateTime      = $p.CreatedDateTime
    LastModifiedDateTime = $p.LastModifiedDateTime
    Platform             = $p.'@odata.type'
    Assignments          = $assign
    IsActive             = (Is-PolicyActive -Assignments $assign)
  }

  $safe = ($p.DisplayName -replace '[\\\/:\*\?"<>\|]', '_')
  $obj | ConvertTo-Json -Depth 20 | Out-File -FilePath (Join-Path $OutDir "$safe.json") -Encoding utf8

  $Master.Add([PSCustomObject]@{
    Type            = "Compliance"
    PolicyId        = $p.Id
    PolicyName      = $p.DisplayName
    Version         = $p.Version
    IsActive        = $obj.IsActive
    AssignmentCount = ($assign | Measure-Object).Count
    AssignedTargets = (($assign | Select-Object -Expand TargetResolved) -join '; ')
  })
}

# =============== SAÍDAS MESTRAS ===============================================
$masterJson = Join-Path $OutDir "_all_policies.json"
$masterCsv  = Join-Path $OutDir "_summary.csv"

$Master | ConvertTo-Json -Depth 20 | Out-File -FilePath $masterJson -Encoding utf8
$Master | Export-Csv -Path $masterCsv -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "✅ Export finalizado." -ForegroundColor Green
Write-Host ("Pasta: {0}" -f (Resolve-Path $OutDir))
Write-Host ("- JSON mestre : {0}" -f (Resolve-Path $masterJson))
Write-Host ("- CSV resumo  : {0}" -f (Resolve-Path $masterCsv))
Write-Host "Arquivos JSON individuais por policy também foram gerados na pasta."
