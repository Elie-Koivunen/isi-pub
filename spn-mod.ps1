#Requires -Version 5.1
<#
.SYNOPSIS
    Manage SPN attribute delegation between two AD computer accounts.

.DESCRIPTION
    Grants, checks, or removes explicit ReadProperty/WriteProperty ACEs for
    servicePrincipalName: SELF on each account and the peer on each account.
    Only explicit attribute-scoped allow ACEs containing RP/WP _alone_ are
    managed. Inherited or broader permissions are never removed.

.EXAMPLE
    .\spn-mod.ps1 --machine-account cls01,cls02 --check-priviledge

.EXAMPLE
    .\spn-mod.ps1 --machine-account cls01,cls02 --set-priviledge

.EXAMPLE
    .\spn-mod.ps1 --machine-account cls01,cls02 --remove-priviledge

.EXAMPLE
    .\spn-mod.ps1 --help

.NOTES
    Use Windows PowerShell 5.1 with the ActiveDirectory module (RSAT).
    Modifying computer object ACLs requires delegated permissions.
    The check evaluates relevant explicit ACEs, not full effective access.
#>

$ErrorActionPreference = 'Stop'

function Show-Usage {
@'
SPN Delegation Manager (Superna DR / PowerScale)

Usage:
  .\spn-mod.ps1 --machine-account cls01,cls02 --check-priviledge
  .\spn-mod.ps1 --machine-account cls01,cls02 --set-priviledge
  .\spn-mod.ps1 --machine-account cls01,cls02 --remove-priviledge
  .\spn-mod.ps1 --help

Options:
  --machine-account      Exactly two AD computer account names, comma separated
  --check-priviledge     Check SELF and cross-machine SPN delegation (read-only)
  --set-priviledge       Grant missing ReadProperty + WriteProperty permissions
  --remove-priviledge    Remove explicit SPN-only ReadProperty/WriteProperty ACEs
  --help, -h             Show this help

Correctly spelled --*-privilege flags, and single-hyphen flags, are accepted.
Accounts may be given as cls01 or cls01$ (no trailing $ needed).
Run from Windows PowerShell 5.1 with RSAT ActiveDirectory installed.

Note: Remove affects explicit, SPN-specific ALLOW ACEs for these trustees
that consist only of ReadProperty and/or WriteProperty. It leaves inherited
ACEs and ACEs carrying other permissions untouched.
'@ | Write-Host
}

# Explicit parsing avoids control-flow surprises caused by break/return in switch.
$cli = @($args)

if ($cli.Count -eq 0 -or $cli -contains '--help' -or $cli -contains '-h' -or $cli -contains '-help') {
    Show-Usage
    exit 0
}

$accountArgument = $null
$mode = $null
$i = 0
while ($i -lt $cli.Count) {
    $token = [string]$cli[$i]

    if ($token -match '^--?machine-account$') {
        if ($null -ne $accountArgument -or ($i + 1) -ge $cli.Count) {
            throw 'Supply --machine-account once, followed by cls01,cls02.'
        }
        $i++
        $accountArgument = (@($cli[$i]) -join ',')
    }
    elseif ($token -match '^--?(check|set|remove)-privile(d)?ge$') {
        if ($mode) { throw 'Select exactly one mode: check, set, or remove.' }
        $mode = $Matches[1]
    }
    else {
        throw "Unknown argument '$token'. Run .\spn-mod.ps1 --help."
    }
    $i++
}

if (-not $mode -or -not $accountArgument) {
    throw 'Both --machine-account and an action flag are required. Run --help.'
}

$names = @($accountArgument.Split(',') | ForEach-Object { ([string]$_).Trim().TrimEnd('$') })

if ($names.Count -ne 2 -or
    [string]::IsNullOrWhiteSpace($names[0]) -or
    [string]::IsNullOrWhiteSpace($names[1]) -or
    $names[0] -ieq $names[1]) {
    throw '--machine-account must contain two distinct accounts, e.g. cls01,cls02.'
}

Write-Host "SPN delegation: mode=$mode; computers=$($names -join ', ')" -ForegroundColor Cyan
Write-Host 'Reading Active Directory objects and ACLs...' -ForegroundColor Gray

Import-Module ActiveDirectory -ErrorAction Stop
Add-Type -AssemblyName System.DirectoryServices

# ----------------------------------------------------------------------
# Resolve both names unambiguously to computer objects in current AD domain.
# ----------------------------------------------------------------------
$computers = foreach ($n in $names) {
    $sam = "$n`$"
    try {
        Get-ADComputer -Identity $sam -Properties ObjectSID, DistinguishedName, Name -ErrorAction Stop
    }
    catch {
        throw "Could not resolve computer account '$n' (SamAccountName '$sam'): $($_.Exception.Message)"
    }
}

if ($computers.Count -ne 2) {
    throw 'Failed to resolve exactly two computer objects.'
}

# Build a simple lookup keyed by the user-supplied (stripped) name.
$compByName = @{}
for ($idx = 0; $idx -lt $names.Count; $idx++) {
    $compByName[$names[$idx]] = $computers[$idx]
}

# ----------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------
# servicePrincipalName attribute schema GUID (well-known, fixed across forests)
$spnGuid = [guid]'f3a64788-5306-11d1-a9c5-0000f80367c1'

$selfSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-10')  # NT AUTHORITY\SELF

$rpWp = [System.DirectoryServices.ActiveDirectoryRights]::ReadProperty -bor `
        [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty

# ----------------------------------------------------------------------
# Helper functions
# ----------------------------------------------------------------------

function Get-ComputerAcl {
    param([Parameter(Mandatory)][string]$DistinguishedName)
    Get-Acl -Path "AD:$DistinguishedName"
}

function Test-SpnOnlyAce {
    <#
        Returns $true if the ACE is:
          - not inherited
          - Allow
          - ObjectType == servicePrincipalName attribute GUID
          - IdentityReference resolves to the given SID
          - ActiveDirectoryRights consist ONLY of ReadProperty and/or WriteProperty
            (at least one of the two bits must be set)
    #>
    param(
        [Parameter(Mandatory)]$Ace,
        [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$TrusteeSid
    )

    if ($Ace.IsInherited) { return $false }
    if ($Ace.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { return $false }
    if ($Ace.ObjectType -ne $spnGuid) { return $false }

    try {
        $aceSid = $Ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier])
    }
    catch {
        return $false
    }
    if ($aceSid.Value -ne $TrusteeSid.Value) { return $false }

    $rights = $Ace.ActiveDirectoryRights
    $outsideBits = $rights -band (-bnot $rpWp)
    if ($outsideBits -ne 0) { return $false }   # carries rights beyond RP/WP -> not "SPN-only"
    if (($rights -band $rpWp) -eq 0) { return $false }  # neither RP nor WP actually set

    return $true
}

function Get-SpnOnlyAces {
    param(
        [Parameter(Mandatory)]$Acl,
        [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$TrusteeSid
    )
    $Acl.Access | Where-Object { Test-SpnOnlyAce -Ace $_ -TrusteeSid $TrusteeSid }
}

function Format-RightsLabel {
    param($Rights)
    $hasRp = [bool]($Rights -band [System.DirectoryServices.ActiveDirectoryRights]::ReadProperty)
    $hasWp = [bool]($Rights -band [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty)
    if ($hasRp -and $hasWp) { 'ReadProperty+WriteProperty' }
    elseif ($hasRp)         { 'ReadProperty only' }
    elseif ($hasWp)         { 'WriteProperty only' }
    else                    { 'none' }
}

function Get-FullSpnAceStatus {
    <#
        Returns a status object describing whether a FULL (RP+WP combined)
        explicit SPN-only Allow ACE exists for the given trustee on the ACL.
    #>
    param(
        [Parameter(Mandatory)]$Acl,
        [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$TrusteeSid
    )

    $matches = Get-SpnOnlyAces -Acl $Acl -TrusteeSid $TrusteeSid
    if (-not $matches) {
        return [PSCustomObject]@{ Present = $false; Detail = 'missing' }
    }

    # Combine rights across any matching ACEs (in case RP and WP exist as separate ACEs)
    $combined = 0
    foreach ($m in $matches) { $combined = $combined -bor $m.ActiveDirectoryRights }

    $fullyPresent = (($combined -band $rpWp) -eq $rpWp)
    [PSCustomObject]@{
        Present = $fullyPresent
        Detail  = Format-RightsLabel $combined
    }
}

# ----------------------------------------------------------------------
# Mode: check
# ----------------------------------------------------------------------
function Invoke-CheckMode {
    $rows = New-Object System.Collections.Generic.List[object]

    for ($idx = 0; $idx -lt $computers.Count; $idx++) {
        $me   = $computers[$idx]
        $peer = $computers[1 - $idx]
        $acl  = Get-ComputerAcl -DistinguishedName $me.DistinguishedName

        $selfStatus = Get-FullSpnAceStatus -Acl $acl -TrusteeSid $selfSid
        $peerStatus = Get-FullSpnAceStatus -Acl $acl -TrusteeSid $peer.ObjectSID

        $rows.Add([PSCustomObject]@{
            Computer    = $me.Name
            Trustee     = 'SELF'
            Present     = $selfStatus.Present
            Rights      = $selfStatus.Detail
        })
        $rows.Add([PSCustomObject]@{
            Computer    = $me.Name
            Trustee     = $peer.Name
            Present     = $peerStatus.Present
            Rights      = $peerStatus.Detail
        })
    }

    $rows | Format-Table -AutoSize

    $allGood = -not ($rows | Where-Object { -not $_.Present })
    if ($allGood) {
        Write-Host "`nAll required SPN delegation ACEs are present." -ForegroundColor Green
    } else {
        Write-Host "`nOne or more required SPN delegation ACEs are missing or incomplete." -ForegroundColor Yellow
    }
}

# ----------------------------------------------------------------------
# Mode: set
# ----------------------------------------------------------------------
function Add-SpnAceIfMissing {
    param(
        [Parameter(Mandatory)]$Computer,
        [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$TrusteeSid,
        [Parameter(Mandatory)][string]$TrusteeLabel
    )

    $acl = Get-ComputerAcl -DistinguishedName $Computer.DistinguishedName
    $status = Get-FullSpnAceStatus -Acl $acl -TrusteeSid $TrusteeSid

    if ($status.Present) {
        Write-Host "  [skip] $($Computer.Name): $TrusteeLabel already has ReadProperty+WriteProperty on servicePrincipalName." -ForegroundColor DarkGray
        return
    }

    $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $TrusteeSid,
        $rpWp,
        [System.Security.AccessControl.AccessControlType]::Allow,
        $spnGuid
    )

    $acl.AddAccessRule($rule)
    Set-Acl -Path "AD:$($Computer.DistinguishedName)" -AclObject $acl

    Write-Host "  [added] $($Computer.Name): granted ReadProperty+WriteProperty on servicePrincipalName to $TrusteeLabel." -ForegroundColor Green
}

function Invoke-SetMode {
    for ($idx = 0; $idx -lt $computers.Count; $idx++) {
        $me   = $computers[$idx]
        $peer = $computers[1 - $idx]

        Write-Host "Processing $($me.Name):" -ForegroundColor Cyan
        Add-SpnAceIfMissing -Computer $me -TrusteeSid $selfSid -TrusteeLabel 'SELF'
        Add-SpnAceIfMissing -Computer $me -TrusteeSid $peer.ObjectSID -TrusteeLabel $peer.Name
    }

    Write-Host "`nDone. Re-run with --check-priviledge to verify." -ForegroundColor Cyan
}

# ----------------------------------------------------------------------
# Mode: remove
# ----------------------------------------------------------------------
function Remove-SpnOnlyAces {
    param(
        [Parameter(Mandatory)]$Computer,
        [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$TrusteeSid,
        [Parameter(Mandatory)][string]$TrusteeLabel
    )

    $acl = Get-ComputerAcl -DistinguishedName $Computer.DistinguishedName
    $toRemove = Get-SpnOnlyAces -Acl $acl -TrusteeSid $TrusteeSid

    if (-not $toRemove) {
        Write-Host "  [skip] $($Computer.Name): no explicit SPN-only ACE found for $TrusteeLabel." -ForegroundColor DarkGray
        return
    }

    foreach ($ace in $toRemove) {
        $label = Format-RightsLabel $ace.ActiveDirectoryRights
        $acl.RemoveAccessRuleSpecific($ace) | Out-Null
        Write-Host "  [removed] $($Computer.Name): removed '$label' ACE for $TrusteeLabel on servicePrincipalName." -ForegroundColor Yellow
    }

    Set-Acl -Path "AD:$($Computer.DistinguishedName)" -AclObject $acl
}

function Invoke-RemoveMode {
    for ($idx = 0; $idx -lt $computers.Count; $idx++) {
        $me   = $computers[$idx]
        $peer = $computers[1 - $idx]

        Write-Host "Processing $($me.Name):" -ForegroundColor Cyan
        Remove-SpnOnlyAces -Computer $me -TrusteeSid $selfSid -TrusteeLabel 'SELF'
        Remove-SpnOnlyAces -Computer $me -TrusteeSid $peer.ObjectSID -TrusteeLabel $peer.Name
    }

    Write-Host "`nDone. Re-run with --check-priviledge to verify." -ForegroundColor Cyan
}

# ----------------------------------------------------------------------
# Dispatch
# ----------------------------------------------------------------------
switch ($mode) {
    'check'  { Invoke-CheckMode }
    'set'    { Invoke-SetMode }
    'remove' { Invoke-RemoveMode }
    default  { throw "Unhandled mode '$mode'." }
}
