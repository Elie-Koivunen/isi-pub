#Requires -Version 5.1
<#
=================================================================================
 SCRIPT NAME   : ad-mod.ps1
 DESCRIPTION   : Unified Active Directory and DNS management tool.
                 Combines SPN delegation management for AD computer accounts
                 with Windows DNS host records and zone delegation management.
 VERSION       : 1.0.0
 AUTHOR        : Elie Koivunen
 CONTACT       : Elie.Koivunen@Dell.com
 CREATED       : 2026-11-04
 COMPANY       : DELL

 CHANGELOG:
   1.0.0 - Initial combined release (merges spn-mod v1.1.0 and dns-mod v1.1.0)

 REQUIREMENTS:
   - Windows PowerShell 5.1+ or PowerShell 7+
   - RSAT: Active Directory DS-LDS Tools (for SPN operations)
   - RSAT: DNS Server Tools (for DNS operations)
   - Run with an account that has permissions on the target AD/DNS servers

 DISCLAIMER:
   Test in a non-production environment before use. Always verify changes
   before relying on them in production.
=================================================================================
#>

<#
.SYNOPSIS
    Unified tool for managing AD SPN delegation and DNS records.

.DESCRIPTION
    ad-mod.ps1 combines two management surfaces:

    SPN DELEGATION MANAGEMENT (Active Directory):
      --spn-self-set|-remove|-check <list>
          Manages the SELF "Validated write to service principal name" right
          on each listed computer.

      --spn-pair-set|-remove|-check <list>
          Uses BIDIRECTIONAL PAIR syntax: accountA_accountB
          Manages SPN write rights between computer pairs.

      --spn-check <list>
          READ-ONLY, FULL INVENTORY mode. Lists all explicit SPN-related grants.

    DNS MANAGEMENT (Windows DNS Server):
      --set-host=<fqdn_ip,...>
          Create/verify DNS host (A) records.

      --set-delegation=<childfqdn_nsfqdn,...>
          Create/verify DNS zone delegations (supports dual/multi delegation).

      --query-host=<fqdn,...>
          Actively resolve host FQDNs (A record lookup).

      --query-delegation=<fqdn,...>
          Actively resolve NS/delegation records for child zones.

    Multiple switches may be combined in a single invocation, but SPN and DNS
    operations cannot be mixed in the same run.

.PARAMETER server
    Optional: specify a specific domain controller (for SPN) or DNS server
    (for DNS operations). If not specified, the default server is used.

.PARAMETER dry-run
    Optional: preview changes without actually applying them.

.PARAMETER log-file
    Optional: path to a log file where all operations will be recorded.

.PARAMETER parent-zone
    Optional (DNS only): explicitly specify the parent zone for DNS operations.

.PARAMETER server-all
    Optional (DNS query only): auto-discover and query the zone's root DNS
    server. Mutually exclusive with --server.

.EXAMPLE
    .\ad-mod.ps1 --spn-self-check cls01,cls02

.EXAMPLE
    .\ad-mod.ps1 --spn-pair-set cls01_cls02,cls03_cls04

.EXAMPLE
    .\ad-mod.ps1 --set-host=cls01-ssip.lab.scape_192.168.255.1

.EXAMPLE
    .\ad-mod.ps1 --set-delegation=fs-smb.lab.scape_cls01-ssip.lab.scape

.EXAMPLE
    .\ad-mod.ps1 --query-host=cls01-ssip.lab.scape --server=dns01.lab.scape

.EXAMPLE
    .\ad-mod.ps1 --help

.NOTES
    Maintainer / Owner : Elie Koivunen
    Contact            : elie.koivunen@dell.com
    Version            : 1.0.0
#>

# ============================================================
#  AD/DNS Unified Manager
#  Maintainer / Owner : Elie Koivunen
#  Contact            : elie.koivunen@dell.com
# ============================================================

$ScriptVersion = '1.0.0'
$ScriptAuthor  = 'Elie Koivunen'
$ScriptContact = 'elie.koivunen@dell.com'

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------
# Logging helper
# ----------------------------------------------------------------------
$LogFile = $null
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] [$Level] $Message"

    if ($LogFile) {
        try {
            Add-Content -Path $LogFile -Value $logEntry -ErrorAction SilentlyContinue
        }
        catch {
            # Don't fail if logging fails
        }
    }
}

function Show-Usage {
@'
AD/DNS Unified Manager
Maintainer: Elie Koivunen (elie.koivunen@dell.com)
Version: 1.0.0

USAGE (SPN Operations - Active Directory):
  .\ad-mod.ps1 --spn-self-check  cls01[,cls02,...]
  .\ad-mod.ps1 --spn-self-set    cls01[,cls02,...]
  .\ad-mod.ps1 --spn-self-remove cls01[,cls02,...]

  .\ad-mod.ps1 --spn-pair-check  cls01_cls02[,cls03_cls04,...]   (pairs)
  .\ad-mod.ps1 --spn-pair-check  cls09                           (discovery)
  .\ad-mod.ps1 --spn-pair-set    cls01_cls02[,cls03_cls04,...]   (pairs only)
  .\ad-mod.ps1 --spn-pair-remove cls01_cls02[,cls03_cls04,...]   (pairs)
  .\ad-mod.ps1 --spn-pair-remove cls09                           (discovery)

  .\ad-mod.ps1 --spn-check       cls01[,cls02,...]   (full inventory, read-only)

USAGE (DNS Operations - Windows DNS Server):
  CREATE:
    .\ad-mod.ps1 --set-host=<fqdn_ip,...> [--set-delegation=<childfqdn_nsfqdn,...>]
    .\ad-mod.ps1 --set-delegation=<childfqdn_nsfqdn,...>

  QUERY:
    .\ad-mod.ps1 --query-host=<fqdn,...>       (--server=<dnsserver> | --server-all)
    .\ad-mod.ps1 --query-delegation=<fqdn,...> (--server=<dnsserver> | --server-all)

COMMON PARAMETERS:
  --server=<server>    Target a specific AD domain controller or DNS server
  --server-all         (DNS query only) Auto-discover root DNS server per zone
  --parent-zone=<zone> (DNS only) Explicitly specify parent zone
  --dry-run            Preview changes without applying them
  --log-file=<path>    Path to a log file for operation recording
  --help / -h          Show this help menu

SPN GROUP SEMANTICS:
  self   Manages the SELF "Validated write to service principal name" right.
  pair   BIDIRECTIONAL pair syntax: accountA_accountB
  (plain) --spn-check <list>  READ-ONLY full inventory of all SPN grants.

DNS OPERATION NOTES:
  - Host format: fqdn_ip (e.g., cls01-ssip.lab.scape_192.168.255.1)
  - Delegation format: childfqdn_nsfqdn (e.g., fs-smb.lab.scape_cls01-ssip.lab.scape)
  - Query mode requires --server or --server-all
  - Multiple entries are comma-separated

EXAMPLES:
  # SPN: Set self rights on computers
  .\ad-mod.ps1 --spn-self-set cls01,cls02,cls03

  # SPN: Create bidirectional pair
  .\ad-mod.ps1 --spn-pair-set cls01_cls02

  # SPN: Full inventory
  .\ad-mod.ps1 --spn-check cls01,cls02,cls03

  # DNS: Create host record
  .\ad-mod.ps1 --set-host=cls01-ssip.lab.scape_192.168.255.1

  # DNS: Create delegation
  .\ad-mod.ps1 --set-delegation=fs-smb.lab.scape_cls01-ssip.lab.scape

  # DNS: Query host records
  .\ad-mod.ps1 --query-host=cls01-ssip.lab.scape --server=dns01.lab.scape

  # DNS: Query delegations with auto-discovery
  .\ad-mod.ps1 --query-delegation=fs-smb.lab.scape --server-all

Maintainer / Owner: Elie Koivunen (elie.koivunen@dell.com)
Version: 1.0.0
'@ | Write-Host
}

# ----------------------------------------------------------------------
# CLI parsing
# ----------------------------------------------------------------------
$cli = @($args)

if ($cli.Count -eq 0 -or $cli -contains '--help' -or $cli -contains '-h' -or $cli -contains '-help') {
    Show-Usage
    exit 0
}

# Parse optional parameters
$TargetServer = $null
$DryRun = $false
$LogFilePath = $null
$ParentZoneExplicit = $null
$ServerAll = $false

$filteredArgs = New-Object System.Collections.Generic.List[string]
foreach ($arg in $cli) {
    if ($arg -match '^--server=(.+)$') {
        $TargetServer = $Matches[1]
    }
    elseif ($arg -eq '--dry-run') {
        $DryRun = $true
    }
    elseif ($arg -match '^--log-file=(.+)$') {
        $LogFilePath = $Matches[1]
        $LogFile = $LogFilePath
    }
    elseif ($arg -match '^--parent-zone=(.+)$') {
        $ParentZoneExplicit = $Matches[1]
    }
    elseif ($arg -eq '--server-all') {
        $ServerAll = $true
    }
    else {
        $filteredArgs.Add($arg)
    }
}

# Initialize log file if specified
if ($LogFile) {
    try {
        $logDir = Split-Path -Parent $LogFile
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Write-Log "AD/DNS Unified Manager v$ScriptVersion started"
        Write-Log "Dry-run mode: $DryRun"
        if ($TargetServer) {
            Write-Log "Target server: $TargetServer"
        }
    }
    catch {
        Write-Warning "Failed to initialize log file: $($_.Exception.Message)"
        $LogFile = $null
    }
}

if ($DryRun) {
    Write-Host ""
    Write-Host "*** DRY-RUN MODE: No changes will be made ***" -ForegroundColor Yellow
    Write-Log "DRY-RUN MODE ENABLED"
}

# Detect operation type (SPN or DNS)
$spnPattern = '^--?spn-'
$dnsPattern = '^--(set-host|set-delegation|query-host|query-delegation)'

$hasSpnOps = $false
$hasDnsOps = $false

foreach ($arg in $filteredArgs) {
    if ($arg -match $spnPattern) {
        $hasSpnOps = $true
    }
    if ($arg -match $dnsPattern) {
        $hasDnsOps = $true
    }
}

if ($hasSpnOps -and $hasDnsOps) {
    Write-Host "ERROR: Cannot mix SPN and DNS operations in the same run. Use separate invocations." -ForegroundColor Red
    Write-Log "ERROR: Cannot mix SPN and DNS operations" 'ERROR'
    exit 1
}

if (-not $hasSpnOps -and -not $hasDnsOps) {
    Write-Host "ERROR: No valid operations specified. Use --help for usage information." -ForegroundColor Red
    exit 1
}

# ----------------------------------------------------------------------
# SPN OPERATIONS SECTION
# ----------------------------------------------------------------------
if ($hasSpnOps) {
    # Check ActiveDirectory module availability
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        $msg = "The 'ActiveDirectory' PowerShell module is not available. Install RSAT: Active Directory DS-LDS Tools."
        Write-Log $msg 'ERROR'
        Write-Host "ERROR: $msg" -ForegroundColor Red
        exit 1
    }

    # Check permissions (basic check)
    try {
        $testUser = Get-ADUser -Identity $env:USERNAME -ErrorAction Stop
        Write-Log "Current user: $env:USERNAME"
    }
    catch {
        Write-Warning "Could not verify current user: $($_.Exception.Message)"
    }

    Import-Module ActiveDirectory -ErrorAction Stop
    Add-Type -AssemblyName System.DirectoryServices

    # Each entry: [PSCustomObject]@{ Group='self'|'pair'|'all'; Action='set'|'remove'|'check'; RawArgument=<string> }
    $requests = New-Object System.Collections.Generic.List[object]

    $plainCheckPattern = '^--?spn-check$'
    $groupedPattern    = '^--?spn-(self|pair)-(set|remove|check)$'

    $i = 0
    while ($i -lt $filteredArgs.Count) {
        $token = [string]$filteredArgs[$i]

        if ($token -match $plainCheckPattern) {
            if (($i + 1) -ge $filteredArgs.Count) {
                Write-Host "ERROR: Switch '$token' requires an account list argument." -ForegroundColor Red
                Write-Log "Switch '$token' requires an account list argument" 'ERROR'
                exit 1
            }
            $i++
            $rawArgument = (@($filteredArgs[$i]) -join ',')

            $requests.Add([PSCustomObject]@{
                Group       = 'all'
                Action      = 'check'
                RawArgument = $rawArgument
            })
        }
        elseif ($token -match $groupedPattern) {
            $group  = $Matches[1]
            $action = $Matches[2]

            if (($i + 1) -ge $filteredArgs.Count) {
                Write-Host "ERROR: Switch '$token' requires an account list argument." -ForegroundColor Red
                Write-Log "Switch '$token' requires an account list argument" 'ERROR'
                exit 1
            }
            $i++

            # PowerShell may have already split an unquoted comma list into an
            # array before this script even ran. Normalize to an array first,
            # then rejoin with commas so our own parsing logic works either way.
            $rawArgument = (@($filteredArgs[$i]) -join ',')

            $requests.Add([PSCustomObject]@{
                Group       = $group
                Action      = $action
                RawArgument = $rawArgument
            })
        }
        else {
            Write-Host "ERROR: Unknown argument '$token'. Run .\ad-mod.ps1 --help." -ForegroundColor Red
            Write-Log "Unknown argument '$token'" 'ERROR'
            exit 1
        }
        $i++
    }

    if ($requests.Count -eq 0) {
        Write-Host "ERROR: At least one --spn-check, or --spn-(self|pair)-(set|remove|check) switch is required. Run --help." -ForegroundColor Red
        Write-Log "No valid SPN operations specified" 'ERROR'
        exit 1
    }

    # Format-level parsing helpers
    function ConvertTo-SelfNameList {
        param([string]$Argument, [string]$SwitchLabel)

        $list = @(
            $Argument.Split(',') |
                ForEach-Object { ([string]$_).Trim().TrimEnd('$') } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )

        $dupes = $list | Group-Object -NoElement | Where-Object { $_.Count -gt 1 }
        if ($dupes) {
            Write-Host "ERROR: $($SwitchLabel): duplicate account name(s): $(($dupes | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor Red
            Write-Log "$($SwitchLabel): duplicate account names" 'ERROR'
            exit 1
        }
        if ($list.Count -lt 1) {
            Write-Host "ERROR: $($SwitchLabel) requires at least 1 account name." -ForegroundColor Red
            Write-Log "$($SwitchLabel) requires at least 1 account name" 'ERROR'
            exit 1
        }

        return $list
    }

    function ConvertTo-PairSpec {
        param([string]$Argument, [string]$SwitchLabel, [string]$Action)

        $entries = @($Argument.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        if ($entries.Count -eq 0) {
            Write-Host "ERROR: $SwitchLabel requires at least one entry." -ForegroundColor Red
            Write-Log "$SwitchLabel requires at least one entry" 'ERROR'
            exit 1
        }

        $pairs     = New-Object System.Collections.Generic.List[object]
        $discovery = New-Object System.Collections.Generic.List[string]

        foreach ($entry in $entries) {
            $underscoreCount = ($entry.ToCharArray() | Where-Object { $_ -eq '_' }).Count

            if ($underscoreCount -eq 0) {
                if ($Action -eq 'set') {
                    Write-Host "ERROR: $SwitchLabel : entry '$entry' has no '_' separator; --spn-pair-set requires explicit paired accounts like cls01_cls02." -ForegroundColor Red
                    Write-Log "$SwitchLabel : entry '$entry' has no '_' separator" 'ERROR'
                    exit 1
                }
                $name = $entry.TrimEnd('$')
                if ([string]::IsNullOrWhiteSpace($name)) {
                    Write-Host "ERROR: $SwitchLabel : empty account name in entry '$entry'." -ForegroundColor Red
                    Write-Log "$SwitchLabel : empty account name in entry '$entry'" 'ERROR'
                    exit 1
                }
                $discovery.Add($name)
            }
            elseif ($underscoreCount -eq 1) {
                $parts = $entry.Split('_')
                $a = $parts[0].Trim().TrimEnd('$')
                $b = $parts[1].Trim().TrimEnd('$')

                if ([string]::IsNullOrWhiteSpace($a) -or [string]::IsNullOrWhiteSpace($b)) {
                    Write-Host "ERROR: $SwitchLabel : malformed pair entry '$entry'. Expected format accountA_accountB, e.g. cls01_cls02." -ForegroundColor Red
                    Write-Log "$SwitchLabel : malformed pair entry '$entry'" 'ERROR'
                    exit 1
                }
                if ($a -ieq $b) {
                    Write-Host "ERROR: $SwitchLabel : entry '$entry' has the same account on both sides; a computer cannot be paired with itself." -ForegroundColor Red
                    Write-Log "$SwitchLabel : entry '$entry' has same account on both sides" 'ERROR'
                    exit 1
                }

                $pairs.Add([PSCustomObject]@{ A = $a; B = $b; Raw = $entry })
            }
            else {
                Write-Host "ERROR: $SwitchLabel : entry '$entry' contains multiple '_' characters and cannot be unambiguously parsed as accountA_accountB. Account names must not contain '_' for this syntax." -ForegroundColor Red
                Write-Log "$SwitchLabel : entry '$entry' contains multiple '_' characters" 'ERROR'
                exit 1
            }
        }

        # De-duplicate identical pairs regardless of order (A_B same as B_A).
        $uniquePairs = New-Object System.Collections.Generic.List[object]
        $seenPairs   = New-Object System.Collections.Generic.HashSet[string]
        foreach ($p in $pairs) {
            $sortedKey = (@($p.A.ToLowerInvariant(), $p.B.ToLowerInvariant()) | Sort-Object) -join '|'
            if ($seenPairs.Add($sortedKey)) { $uniquePairs.Add($p) }
        }

        [PSCustomObject]@{
            Pairs     = $uniquePairs
            Discovery = @($discovery | Select-Object -Unique)
        }
    }

    function Get-SwitchLabel {
        param($Req)
        if ($Req.Group -eq 'all') { return '--spn-check' }
        return "--spn-$($Req.Group)-$($Req.Action)"
    }

    # Apply format-level parsing to each request
    foreach ($req in $requests) {
        $label = Get-SwitchLabel -Req $req

        if ($req.Group -eq 'self' -or $req.Group -eq 'all') {
            $names = ConvertTo-SelfNameList -Argument $req.RawArgument -SwitchLabel $label
            $req | Add-Member -NotePropertyName Names -NotePropertyValue $names -Force
        }
        else {
            $spec = ConvertTo-PairSpec -Argument $req.RawArgument -SwitchLabel $label -Action $req.Action
            $req | Add-Member -NotePropertyName PairsRaw     -NotePropertyValue $spec.Pairs -Force
            $req | Add-Member -NotePropertyName DiscoveryRaw -NotePropertyValue $spec.Discovery -Force
        }
    }

    Write-Host 'SPN delegation requests:' -ForegroundColor Cyan
    foreach ($req in $requests) {
        $label = Get-SwitchLabel -Req $req
        if ($req.Group -eq 'self' -or $req.Group -eq 'all') {
            Write-Host ("  {0,-20} {1}" -f $label, ($req.Names -join ', ')) -ForegroundColor Cyan
            Write-Log "Request: $label - $($req.Names -join ', ')"
        }
        else {
            $pairDesc = @($req.PairsRaw | ForEach-Object { $_.Raw })
            $descParts = @()
            if ($pairDesc.Count -gt 0) { $descParts += ($pairDesc -join ', ') }
            if ($req.DiscoveryRaw.Count -gt 0) { $descParts += (($req.DiscoveryRaw | ForEach-Object { "$_ (discovery)" }) -join ', ') }
            Write-Host ("  {0,-20} {1}" -f $label, ($descParts -join ', ')) -ForegroundColor Cyan
            Write-Log "Request: $label - $($descParts -join ', ')"
        }
    }
    Write-Host 'Reading Active Directory objects and ACLs...' -ForegroundColor Gray
    Write-Log "Reading Active Directory objects and ACLs..."

    # Resolve the union of all distinct names across all requests.
    $allNamesSet = New-Object System.Collections.Generic.HashSet[string]
    foreach ($req in $requests) {
        if ($req.Group -eq 'self' -or $req.Group -eq 'all') {
            foreach ($n in $req.Names) { [void]$allNamesSet.Add($n) }
        }
        else {
            foreach ($p in $req.PairsRaw) {
                [void]$allNamesSet.Add($p.A)
                [void]$allNamesSet.Add($p.B)
            }
            foreach ($d in $req.DiscoveryRaw) { [void]$allNamesSet.Add($d) }
        }
    }
    $allNames = @($allNamesSet)

    $compByName  = @{}
    $unresolved  = New-Object System.Collections.Generic.List[string]

    $adParams = @{}
    if ($TargetServer) {
        $adParams['Server'] = $TargetServer
    }

    $totalNames = $allNames.Count
    $currentName = 0

    foreach ($n in $allNames) {
        $currentName++
        $progress = [math]::Round(($currentName / $totalNames) * 100, 1)
        Write-Progress -Activity "Resolving AD computer accounts" -Status "$n ($currentName of $totalNames)" -PercentComplete $progress

        $sam = "$n`$"
        try {
            $compByName[$n] = Get-ADComputer -Identity $sam -Properties ObjectSID, DistinguishedName, Name -ErrorAction Stop @adParams
            Write-Log "Resolved computer account: $n"
        }
        catch {
            $unresolved.Add($n)
            Write-Warning "Could not resolve computer account '$n' (SamAccountName '$sam'): $($_.Exception.Message)"
            Write-Log "Failed to resolve computer account '$n': $($_.Exception.Message)" 'WARN'
        }
    }
    Write-Progress -Activity "Resolving AD computer accounts" -Completed

    if ($unresolved.Count -gt 0) {
        Write-Host ("Skipping unresolved account(s): {0}" -f ($unresolved -join ', ')) -ForegroundColor Yellow
        Write-Log "Skipping unresolved accounts: $($unresolved -join ', ')" 'WARN'
    }

    # Filter each request down to only resolvable accounts/pairs/entries.
    $activeRequests = New-Object System.Collections.Generic.List[object]

    foreach ($req in $requests) {
        $label = Get-SwitchLabel -Req $req

        if ($req.Group -eq 'self' -or $req.Group -eq 'all') {
            $resolvedNames = @($req.Names | Where-Object { $compByName.ContainsKey($_) })
            $droppedNames  = @($req.Names | Where-Object { -not $compByName.ContainsKey($_) })

            if ($droppedNames.Count -gt 0) {
                Write-Warning "$label : dropping unresolved account(s): $($droppedNames -join ', ')"
                Write-Log "$label : dropping unresolved accounts: $($droppedNames -join ', ')" 'WARN'
            }
            if ($resolvedNames.Count -eq 0) {
                Write-Warning "$label : no resolvable accounts remain - skipping this request entirely."
                Write-Log "$label : no resolvable accounts remain - skipping" 'WARN'
                continue
            }

            $req.Names = $resolvedNames
            $activeRequests.Add($req)
        }
        else {
            $validPairs = New-Object System.Collections.Generic.List[object]
            foreach ($p in $req.PairsRaw) {
                $missing = @()
                if (-not $compByName.ContainsKey($p.A)) { $missing += $p.A }
                if (-not $compByName.ContainsKey($p.B)) { $missing += $p.B }

                if ($missing.Count -gt 0) {
                    Write-Warning "$label : dropping pair '$($p.Raw)' - unresolved account(s): $($missing -join ', ')"
                    Write-Log "$label : dropping pair '$($p.Raw)' - unresolved accounts: $($missing -join ', ')" 'WARN'
                    continue
                }
                $validPairs.Add($p)
            }

            $validDiscovery = New-Object System.Collections.Generic.List[string]
            foreach ($d in $req.DiscoveryRaw) {
                if (-not $compByName.ContainsKey($d)) {
                    Write-Warning "$label : dropping discovery target '$d' - unresolved account."
                    Write-Log "$label : dropping discovery target '$d' - unresolved account" 'WARN'
                    continue
                }
                $validDiscovery.Add($d)
            }

            if ($validPairs.Count -eq 0 -and $validDiscovery.Count -eq 0) {
                Write-Warning "$label : no resolvable pairs/targets remain - skipping this request entirely."
                Write-Log "$label : no resolvable pairs/targets remain - skipping" 'WARN'
                continue
            }

            $req | Add-Member -NotePropertyName ResolvedPairs     -NotePropertyValue $validPairs -Force
            $req | Add-Member -NotePropertyName ResolvedDiscovery -NotePropertyValue $validDiscovery -Force
            $activeRequests.Add($req)
        }
    }

    if ($activeRequests.Count -eq 0) {
        Write-Warning 'No requests remain after removing unresolved accounts. Nothing to do.'
        Write-Log "No requests remain after removing unresolved accounts. Nothing to do." 'WARN'
        Write-Host "`nDone." -ForegroundColor Cyan
        exit 0
    }

    # Constants
    $spnGuid = [guid]'f3a64788-5306-11d1-a9c5-0000f80367c1'
    $selfSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-10')
    $rpWp = [System.DirectoryServices.ActiveDirectoryRights]::ReadProperty -bor [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty
    $selfRight = [System.DirectoryServices.ActiveDirectoryRights]::Self

    # Generic ACE helpers
    function Get-ComputerAcl {
        param([Parameter(Mandatory)][string]$DistinguishedName)
        Get-Acl -Path "AD:$DistinguishedName"
    }

    function Get-AceSidString {
        param($Ace)
        try { return ($Ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier])).Value }
        catch { return $Ace.IdentityReference.Value }
    }

    function Test-SidMatches {
        param($Ace, [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$Sid)
        return (Get-AceSidString -Ace $Ace) -eq $Sid.Value
    }

    function Get-TrusteeAces {
        param(
            [Parameter(Mandatory)]$Acl,
            [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$Sid
        )
        $Acl.Access | Where-Object {
            -not $_.IsInherited -and
            $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
            $_.ObjectType -eq $spnGuid -and
            (Test-SidMatches -Ace $_ -Sid $Sid)
        }
    }

    function Get-CombinedMask {
        param($Aces)
        $mask = 0
        foreach ($a in $Aces) { $mask = $mask -bor $a.ActiveDirectoryRights }
        return $mask
    }

    function Format-Mask {
        param($Mask)
        if ($Mask -eq 0) { return 'none' }
        return [int]$Mask
    }

    function Get-TrusteeStatus {
        param(
            [Parameter(Mandatory)]$Acl,
            [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$Sid,
            [Parameter(Mandatory)]$RequiredMask
        )
        $aces = Get-TrusteeAces -Acl $Acl -Sid $Sid
        $combined = Get-CombinedMask -Aces $aces
        [PSCustomObject]@{
            Present = (($combined -band $RequiredMask) -eq $RequiredMask)
            Detail  = Format-Mask $combined
        }
    }

    function Set-TrusteeRights {
        param(
            [Parameter(Mandatory)]$Computer,
            [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$Sid,
            [Parameter(Mandatory)]$GrantMask,
            [Parameter(Mandatory)][string]$Label
        )

        $acl = Get-ComputerAcl -DistinguishedName $Computer.DistinguishedName
        $status = Get-TrusteeStatus -Acl $acl -Sid $Sid -RequiredMask $GrantMask

        if ($status.Present) {
            Write-Host "  [skip] $($Computer.Name): $Label already has the required right(s) on servicePrincipalName (current: $($status.Detail))." -ForegroundColor DarkGray
            Write-Log "[$($Computer.Name)] SKIP: $Label already has required rights (current: $($status.Detail))"
            return
        }

        if ($DryRun) {
            Write-Host "  [dry-run] $($Computer.Name): would grant $Label the required right(s) on servicePrincipalName." -ForegroundColor Cyan
            Write-Log "[$($Computer.Name)] DRY-RUN: would grant $Label required rights on servicePrincipalName"
            return
        }

        $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $Sid, $GrantMask, [System.Security.AccessControl.AccessControlType]::Allow, $spnGuid
        )
        $acl.AddAccessRule($rule)

        try {
            Set-Acl -Path "AD:$($Computer.DistinguishedName)" -AclObject $acl -ErrorAction Stop
            Write-Host "  [added] $($Computer.Name): granted $Label the required right(s) on servicePrincipalName." -ForegroundColor Green
            Write-Log "[$($Computer.Name)] SUCCESS: granted $Label required rights on servicePrincipalName"

            $aclAfter = Get-ComputerAcl -DistinguishedName $Computer.DistinguishedName
            $statusAfter = Get-TrusteeStatus -Acl $aclAfter -Sid $Sid -RequiredMask $GrantMask
            if (-not $statusAfter.Present) {
                Write-Warning "  [verify-fail] $($Computer.Name): verification failed - rights may not have been applied correctly."
                Write-Log "[$($Computer.Name)] VERIFY-FAIL: rights may not have been applied correctly" 'WARN'
            }
        }
        catch {
            Write-Host "  [error] $($Computer.Name): failed to grant rights to ${Label}: $($_.Exception.Message)" -ForegroundColor Red
            Write-Log "[$($Computer.Name)] ERROR: failed to grant rights to ${Label}: $($_.Exception.Message)" 'ERROR'
            throw
        }
    }

    function Remove-TrusteeRightsBits {
        param(
            [Parameter(Mandatory)]$Computer,
            [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$Sid,
            [Parameter(Mandatory)]$ClearMask,
            [Parameter(Mandatory)][string]$Label
        )

        $acl = Get-ComputerAcl -DistinguishedName $Computer.DistinguishedName
        $aces = @(Get-TrusteeAces -Acl $acl -Sid $Sid | Where-Object { ($_.ActiveDirectoryRights -band $ClearMask) -ne 0 })

        if ($aces.Count -eq 0) {
            Write-Host "  [skip] $($Computer.Name): no matching right(s) to clear for ${Label}." -ForegroundColor DarkGray
            Write-Log "[$($Computer.Name)] SKIP: no matching rights to clear for ${Label}"
            return
        }

        if ($DryRun) {
            Write-Host "  [dry-run] $($Computer.Name): would clear target right(s) for $Label." -ForegroundColor Cyan
            Write-Log "[$($Computer.Name)] DRY-RUN: would clear target rights for $Label"
            return
        }

        $changed = $false
        foreach ($ace in $aces) {
            $oldMask   = $ace.ActiveDirectoryRights
            $remainder = $oldMask -band (-bnot $ClearMask)

            $acl.RemoveAccessRuleSpecific($ace) | Out-Null
            $changed = $true

            if ($remainder -ne 0) {
                $newRule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
                    $Sid, $remainder, [System.Security.AccessControl.AccessControlType]::Allow, $spnGuid
                )
                $acl.AddAccessRule($newRule)
                Write-Host "  [cleared] $($Computer.Name): cleared target right(s) for $Label; preserved unrelated right(s): $(Format-Mask $remainder)" -ForegroundColor Yellow
                Write-Log "[$($Computer.Name)] CLEARED: target rights for $Label; preserved: $(Format-Mask $remainder)"
            }
            else {
                Write-Host "  [removed] $($Computer.Name): removed ACE entirely for $Label (no other rights were present)." -ForegroundColor Yellow
                Write-Log "[$($Computer.Name)] REMOVED: ACE entirely for $Label"
            }
        }

        if ($changed) {
            try {
                Set-Acl -Path "AD:$($Computer.DistinguishedName)" -AclObject $acl -ErrorAction Stop
                Write-Log "[$($Computer.Name)] SUCCESS: ACL changes applied"
            }
            catch {
                Write-Host "  [error] $($Computer.Name): failed to apply ACL changes: $($_.Exception.Message)" -ForegroundColor Red
                Write-Log "[$($Computer.Name)] ERROR: failed to apply ACL changes: $($_.Exception.Message)" 'ERROR'
                throw
            }
        }
    }

    function Reset-SelfToBaseline {
        param([Parameter(Mandatory)]$Computer)

        $acl = Get-ComputerAcl -DistinguishedName $Computer.DistinguishedName
        $aces = @(Get-TrusteeAces -Acl $acl -Sid $selfSid)

        if ($aces.Count -eq 0) {
            if ($DryRun) {
                Write-Host "  [dry-run] $($Computer.Name): would create baseline SELF grant (Self = 8)." -ForegroundColor Cyan
                Write-Log "[$($Computer.Name)] DRY-RUN: would create baseline SELF grant"
                return
            }

            $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
                $selfSid, $selfRight, [System.Security.AccessControl.AccessControlType]::Allow, $spnGuid
            )
            $acl.AddAccessRule($rule)

            try {
                Set-Acl -Path "AD:$($Computer.DistinguishedName)" -AclObject $acl -ErrorAction Stop
                Write-Host "  [reset] $($Computer.Name): no existing SELF ACE found; created baseline grant (Self = 8)." -ForegroundColor Green
                Write-Log "[$($Computer.Name)] SUCCESS: created baseline SELF grant"
            }
            catch {
                Write-Host "  [error] $($Computer.Name): failed to create baseline SELF grant: $($_.Exception.Message)" -ForegroundColor Red
                Write-Log "[$($Computer.Name)] ERROR: failed to create baseline SELF grant: $($_.Exception.Message)" 'ERROR'
                throw
            }
            return
        }

        $combined = Get-CombinedMask -Aces $aces

        if ($aces.Count -eq 1 -and $combined -eq $selfRight) {
            Write-Host "  [skip] $($Computer.Name): SELF already at baseline (Self = 8); nothing to reset." -ForegroundColor DarkGray
            Write-Log "[$($Computer.Name)] SKIP: SELF already at baseline"
            return
        }

        if ($DryRun) {
            Write-Host "  [dry-run] $($Computer.Name): would reset SELF to baseline (Self = 8); previous combined rights were $(Format-Mask $combined)." -ForegroundColor Cyan
            Write-Log "[$($Computer.Name)] DRY-RUN: would reset SELF to baseline; previous: $(Format-Mask $combined)"
            return
        }

        foreach ($ace in $aces) {
            $acl.RemoveAccessRuleSpecific($ace) | Out-Null
        }

        $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $selfSid, $selfRight, [System.Security.AccessControl.AccessControlType]::Allow, $spnGuid
        )
        $acl.AddAccessRule($rule)

        try {
            Set-Acl -Path "AD:$($Computer.DistinguishedName)" -AclObject $acl -ErrorAction Stop
            Write-Host "  [reset] $($Computer.Name): previous combined rights were $(Format-Mask $combined); SELF restored to baseline (Self = 8)." -ForegroundColor Yellow
            Write-Log "[$($Computer.Name)] SUCCESS: SELF restored to baseline; previous: $(Format-Mask $combined)"
        }
        catch {
            Write-Host "  [error] $($Computer.Name): failed to reset SELF to baseline: $($_.Exception.Message)" -ForegroundColor Red
            Write-Log "[$($Computer.Name)] ERROR: failed to reset SELF to baseline: $($_.Exception.Message)" 'ERROR'
            throw
        }
    }

    function Resolve-SidToLabel {
        param([Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$Sid)

        try {
            return $Sid.Translate([System.Security.Principal.NTAccount]).Value
        }
        catch {
            try {
                $sidBytes = $Sid.Value
                $sidHex = ($sidBytes -split '-' | ForEach-Object { '{0:X2}' -f [int]$_ }) -join '\'
                $obj = Get-ADObject -LDAPFilter "(objectSid=$sidHex)" -Properties Name -ErrorAction Stop @adParams
                if ($obj) { return $obj.Name }
            }
            catch {
                try {
                    $obj = Get-ADObject -Filter { ObjectSid -eq $Sid } -Properties Name -ErrorAction Stop @adParams
                    if ($obj) { return $obj.Name }
                }
                catch { }
            }
        }
        return $Sid.Value
    }

    # SELF: check / set / remove
    function Invoke-SelfCheck {
        param([string[]]$Names)
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($n in $Names) {
            $me  = $compByName[$n]
            $acl = Get-ComputerAcl -DistinguishedName $me.DistinguishedName
            $status = Get-TrusteeStatus -Acl $acl -Sid $selfSid -RequiredMask $selfRight
            $rows.Add([PSCustomObject]@{
                Group = 'self'; Computer = $me.Name; Trustee = 'SELF'; Type = 'Self'
                Present = $status.Present; Rights = $status.Detail
            })
        }
        $rows
    }

    function Invoke-SelfSet {
        param([string[]]$Names)
        foreach ($n in $Names) {
            $me = $compByName[$n]
            Write-Host "Processing (self-set) $($me.Name):" -ForegroundColor Cyan
            Write-Log "Processing (self-set) $($me.Name)"
            Set-TrusteeRights -Computer $me -Sid $selfSid -GrantMask $selfRight -Label 'SELF'
        }
    }

    function Invoke-SelfRemove {
        param([string[]]$Names)
        foreach ($n in $Names) {
            $me = $compByName[$n]
            Write-Host "Processing (self-remove) $($me.Name):" -ForegroundColor Cyan
            Write-Log "Processing (self-remove) $($me.Name)"
            Reset-SelfToBaseline -Computer $me
        }
    }

    # PAIR: bidirectional pairs
    function Invoke-PairCheckExplicit {
        param($Pairs)
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($p in $Pairs) {
            $compA = $compByName[$p.A]
            $compB = $compByName[$p.B]

            $aclA = Get-ComputerAcl -DistinguishedName $compA.DistinguishedName
            $statusAtoB = Get-TrusteeStatus -Acl $aclA -Sid $compB.ObjectSID -RequiredMask $rpWp
            $rows.Add([PSCustomObject]@{
                Group = 'pair'; Computer = $compA.Name; Trustee = $compB.Name; Type = 'Other'
                Present = $statusAtoB.Present; Rights = $statusAtoB.Detail
            })

            $aclB = Get-ComputerAcl -DistinguishedName $compB.DistinguishedName
            $statusBtoA = Get-TrusteeStatus -Acl $aclB -Sid $compA.ObjectSID -RequiredMask $rpWp
            $rows.Add([PSCustomObject]@{
                Group = 'pair'; Computer = $compB.Name; Trustee = $compA.Name; Type = 'Other'
                Present = $statusBtoA.Present; Rights = $statusBtoA.Detail
            })
        }
        $rows
    }

    function Invoke-PairSetExplicit {
        param($Pairs)
        foreach ($p in $Pairs) {
            $compA = $compByName[$p.A]
            $compB = $compByName[$p.B]
            Write-Host "Processing (pair-set) $($p.Raw):" -ForegroundColor Cyan
            Write-Log "Processing (pair-set) $($p.Raw)"
            Set-TrusteeRights -Computer $compA -Sid $compB.ObjectSID -GrantMask $rpWp -Label $compB.Name
            Set-TrusteeRights -Computer $compB -Sid $compA.ObjectSID -GrantMask $rpWp -Label $compA.Name
        }
    }

    function Invoke-PairRemoveExplicit {
        param($Pairs)
        foreach ($p in $Pairs) {
            $compA = $compByName[$p.A]
            $compB = $compByName[$p.B]
            Write-Host "Processing (pair-remove) $($p.Raw):" -ForegroundColor Cyan
            Write-Log "Processing (pair-remove) $($p.Raw)"
            Remove-TrusteeRightsBits -Computer $compA -Sid $compB.ObjectSID -ClearMask $rpWp -Label $compB.Name
            Remove-TrusteeRightsBits -Computer $compB -Sid $compA.ObjectSID -ClearMask $rpWp -Label $compA.Name
        }
    }

    # PAIR: discovery mode
    function Get-ForeignRpWpGrants {
        param([Parameter(Mandatory)]$Acl)

        $candidateAces = $Acl.Access | Where-Object {
            -not $_.IsInherited -and
            $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
            $_.ObjectType -eq $spnGuid -and
            -not (Test-SidMatches -Ace $_ -Sid $selfSid) -and
            ($_.ActiveDirectoryRights -band $rpWp) -ne 0
        }

        if (-not $candidateAces) { return @() }

        $bySid = $candidateAces | Group-Object { Get-AceSidString -Ace $_ }

        foreach ($grp in $bySid) {
            $sid  = New-Object System.Security.Principal.SecurityIdentifier($grp.Name)
            $mask = Get-CombinedMask -Aces $grp.Group
            [PSCustomObject]@{
                Sid   = $sid
                Label = Resolve-SidToLabel -Sid $sid
                Mask  = $mask
            }
        }
    }

    function Invoke-PairCheckDiscoverySingle {
        param([Parameter(Mandatory)][string]$Name)
        $rows = New-Object System.Collections.Generic.List[object]
        $me  = $compByName[$Name]
        $acl = Get-ComputerAcl -DistinguishedName $me.DistinguishedName

        $found = @(Get-ForeignRpWpGrants -Acl $acl)

        if ($found.Count -eq 0) {
            $rows.Add([PSCustomObject]@{
                Group = 'pair'; Computer = $me.Name; Trustee = '(none found)'; Type = '-'
                Present = $false; Rights = 'no foreign RP/WP SPN grants'
            })
            return $rows
        }

        foreach ($grant in $found) {
            $rows.Add([PSCustomObject]@{
                Group = 'pair'; Computer = $me.Name; Trustee = $grant.Label; Type = 'Other'
                Present = $true; Rights = Format-Mask $grant.Mask
            })
        }
        $rows
    }

    function Invoke-PairRemoveDiscoverySingle {
        param([Parameter(Mandatory)][string]$Name)
        $me  = $compByName[$Name]
        Write-Host "Processing (pair-remove, discovery) $($me.Name):" -ForegroundColor Cyan
        Write-Log "Processing (pair-remove, discovery) $($me.Name)"

        $acl = Get-ComputerAcl -DistinguishedName $me.DistinguishedName
        $found = @(Get-ForeignRpWpGrants -Acl $acl)

        if ($found.Count -eq 0) {
            Write-Host "  [skip] $($me.Name): no foreign (non-SELF) RP/WP SPN grants found." -ForegroundColor DarkGray
            Write-Log "[$($me.Name)] SKIP: no foreign RP/WP SPN grants found"
            return
        }

        foreach ($grant in $found) {
            Remove-TrusteeRightsBits -Computer $me -Sid $grant.Sid -ClearMask $rpWp -Label $grant.Label
        }
    }

    # FULL INVENTORY: --spn-check
    function Invoke-SpnFullCheck {
        param([string[]]$Names)

        $rows = New-Object System.Collections.Generic.List[object]

        foreach ($n in $Names) {
            $me  = $compByName[$n]
            $acl = Get-ComputerAcl -DistinguishedName $me.DistinguishedName

            $allAces = $acl.Access | Where-Object {
                -not $_.IsInherited -and
                $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
                $_.ObjectType -eq $spnGuid
            }

            if (-not $allAces) {
                $rows.Add([PSCustomObject]@{
                    Group = 'all'; Computer = $me.Name; Trustee = '(none found)'; Type = '-'
                    Present = $false; Rights = 'no explicit SPN ACEs'
                })
                continue
            }

            $bySid = $allAces | Group-Object { Get-AceSidString -Ace $_ }

            foreach ($grp in $bySid) {
                $sidStr = $grp.Name
                $isSelf = ($sidStr -eq $selfSid.Value)
                $label  = if ($isSelf) { 'SELF' } else {
                    try { Resolve-SidToLabel -Sid (New-Object System.Security.Principal.SecurityIdentifier($sidStr)) }
                    catch { $sidStr }
                }
                $mask = Get-CombinedMask -Aces $grp.Group

                $rows.Add([PSCustomObject]@{
                    Group = 'all'; Computer = $me.Name; Trustee = $label
                    Type  = if ($isSelf) { 'Self' } else { 'Other' }
                    Present = $true; Rights = Format-Mask $mask
                })
            }
        }

        $rows
    }

    # Dispatch: process each ACTIVE request in order; collect check rows.
    $checkRows = New-Object System.Collections.Generic.List[object]

    $totalRequests = $activeRequests.Count
    $currentRequest = 0

    foreach ($req in $activeRequests) {
        $currentRequest++
        $progress = [math]::Round(($currentRequest / $totalRequests) * 100, 1)
        Write-Progress -Activity "Processing requests" -Status "Request $currentRequest of $totalRequests" -PercentComplete $progress

        switch ("$($req.Group):$($req.Action)") {
            'self:check' { $checkRows.AddRange([object[]](Invoke-SelfCheck -Names $req.Names)) }
            'self:set'   { Invoke-SelfSet    -Names $req.Names }
            'self:remove'{ Invoke-SelfRemove -Names $req.Names }

            'all:check'  { $checkRows.AddRange([object[]](Invoke-SpnFullCheck -Names $req.Names)) }

            'pair:check' {
                if ($req.ResolvedPairs.Count -gt 0) {
                    $checkRows.AddRange([object[]](Invoke-PairCheckExplicit -Pairs $req.ResolvedPairs))
                }
                foreach ($d in $req.ResolvedDiscovery) {
                    $checkRows.AddRange([object[]](Invoke-PairCheckDiscoverySingle -Name $d))
                }
            }
            'pair:set' {
                Invoke-PairSetExplicit -Pairs $req.ResolvedPairs
            }
            'pair:remove' {
                if ($req.ResolvedPairs.Count -gt 0) {
                    Invoke-PairRemoveExplicit -Pairs $req.ResolvedPairs
                }
                foreach ($d in $req.ResolvedDiscovery) {
                    Invoke-PairRemoveDiscoverySingle -Name $d
                }
            }
            default { throw "Unhandled request '$($req.Group):$($req.Action)'." }
        }
    }
    Write-Progress -Activity "Processing requests" -Completed

    if ($checkRows.Count -gt 0) {
        Write-Host ''
        $checkRows | Format-Table -Property Group, Computer, Trustee, Type, Present, Rights -AutoSize

        $realFailures = @(
            $checkRows | Where-Object { $_.Group -eq 'self' -and -not $_.Present }
        ) + @(
            $checkRows | Where-Object { $_.Group -eq 'pair' -and -not $_.Present -and $_.Trustee -ne '(none found)' }
        )

        if ($realFailures.Count -eq 0) {
            Write-Host "`nNo missing required rights detected." -ForegroundColor Green
            Write-Log "No missing required rights detected"
        } else {
            Write-Host "`nOne or more required SPN delegation rights are missing or incomplete." -ForegroundColor Yellow
            Write-Log "One or more required SPN delegation rights are missing or incomplete" 'WARN'
        }
    }

    if ($unresolved.Count -gt 0) {
        Write-Host ("`nNote: {0} account(s) could not be resolved and were skipped: {1}" -f $unresolved.Count, ($unresolved -join ', ')) -ForegroundColor Yellow
    }

    Write-Log "Script completed successfully"
    Write-Host "`nDone." -ForegroundColor Cyan
    exit 0
}

# ----------------------------------------------------------------------
# DNS OPERATIONS SECTION
# ----------------------------------------------------------------------
if ($hasDnsOps) {
    # Check DnsServer module availability
    $dnsModule = Get-Module -ListAvailable -Name DnsServer
    if (-not $dnsModule) {
        Write-Host "ERROR: The 'DnsServer' PowerShell module is not available. Install RSAT: DNS Server Tools." -ForegroundColor Red
        Write-Log "DnsServer module not available" 'ERROR'
        exit 1
    }

    Import-Module DnsServer -ErrorAction Stop

    # Parse DNS-specific arguments from filteredArgs
    $ParsedArgs = @{}

    foreach ($rawArg in $filteredArgs) {
        switch -Regex ($rawArg) {
            '^--([^=]+)=(.*)$' {
                $ParsedArgs[$Matches[1].ToLower()] = $Matches[2]
                continue
            }
            '^--([^=]+)$' {
                $ParsedArgs[$Matches[1].ToLower()] = $true
                continue
            }
            default {
                Write-Host "WARNING: Unrecognized argument '$rawArg' ignored." -ForegroundColor DarkYellow
            }
        }
    }

    $SetHostRaw         = $ParsedArgs['set-host']
    $SetDelegationRaw   = $ParsedArgs['set-delegation']
    $QueryHostRaw       = $ParsedArgs['query-host']
    $QueryDelegationRaw = $ParsedArgs['query-delegation']
    $DnsServerName      = if ($TargetServer) { $TargetServer } else { 'localhost' }

    $IsQueryMode = [bool]($QueryHostRaw -or $QueryDelegationRaw)

    if ($IsQueryMode -and -not $ServerAll -and -not $TargetServer) {
        Write-Host "ERROR: Query mode (--query-host / --query-delegation) requires either --server=<dnsserver> or --server-all." -ForegroundColor Red
        Write-Log "Query mode requires --server or --server-all" 'ERROR'
        exit 1
    }

    if (-not $IsQueryMode -and -not $SetHostRaw -and -not $SetDelegationRaw) {
        Write-Host "ERROR: No actionable DNS switches supplied." -ForegroundColor DarkYellow
        exit 1
    }

    if ($IsQueryMode) {
        if ($ServerAll) {
            Write-Host "Mode: QUERY (auto-discovering root DNS server per zone; delegation queries will also hit each delegated NS)." -ForegroundColor DarkCyan
        } else {
            Write-Host "Mode: QUERY (target server: $DnsServerName)." -ForegroundColor DarkCyan
        }
    }
    elseif ($SetHostRaw -and -not $SetDelegationRaw) {
        Write-Host "Mode: CREATE --set-host only (host record management)." -ForegroundColor DarkCyan
    }
    elseif ($SetDelegationRaw -and -not $SetHostRaw) {
        Write-Host "Mode: CREATE --set-delegation only (delegation management, glue IP optional)." -ForegroundColor DarkCyan
    }
    else {
        Write-Host "Mode: CREATE --set-host + --set-delegation (host records used as glue where applicable)." -ForegroundColor DarkCyan
    }

    # Helper: validate IP address
    function Test-ValidIPv4Address {
        param([string]$IP)

        if ($IP -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
            return $false
        }

        $octets = $IP -split '\.'
        foreach ($octet in $octets) {
            if ([int]$octet -gt 255) {
                return $false
            }
        }

        return $true
    }

    # Helper: split an FQDN into (Label, ParentZone)
    function Split-Fqdn {
        param(
            [Parameter(Mandatory)][string]$Fqdn,
            [string]$ExplicitParentZone
        )

        if ($ExplicitParentZone) {
            if (-not $Fqdn.EndsWith($ExplicitParentZone)) {
                Write-Host "ERROR: FQDN '$Fqdn' does not end with specified parent zone '$ExplicitParentZone'." -ForegroundColor Red
                exit 1
            }
            $label = $Fqdn.Substring(0, $Fqdn.Length - $ExplicitParentZone.Length - 1)
            [PSCustomObject]@{
                Label = $label
                ParentZone = $ExplicitParentZone
            }
        }
        else {
            $parts = $Fqdn -split '\.', 2
            if ($parts.Count -ne 2) {
                Write-Host "ERROR: Cannot determine parent zone from FQDN '$Fqdn' (expected label.zone format)." -ForegroundColor Red
                exit 1
            }
            Write-Warning "Auto-detected parent zone '$($parts[1])' from FQDN '$Fqdn'. Use --parent-zone to specify explicitly if this is incorrect."
            [PSCustomObject]@{
                Label = $parts[0]
                ParentZone = $parts[1]
            }
        }
    }

    # Helper: test if a zone exists on the target DNS server
    function Test-ZoneExists {
        param(
            [string]$ZoneName,
            [string]$TargetServer = $DnsServerName
        )

        try {
            $zone = Get-DnsServerZone -Name $ZoneName -ComputerName $TargetServer -ErrorAction SilentlyContinue
            return ($null -ne $zone)
        }
        catch {
            return $false
        }
    }

    # Parse --set-host into a hashtable: FQDN -> IP
    $SetHostMap = @{}

    if ($SetHostRaw) {
        foreach ($entry in ([string]$SetHostRaw) -split ',') {
            $entry = $entry.Trim()
            if (-not $entry) { continue }
            if ($entry -notmatch '^(?<fqdn>[^_]+)_(?<ip>.+)$') {
                Write-Host "ERROR: Invalid --set-host entry (expected fqdn_ip): $entry" -ForegroundColor Red
                exit 1
            }
            $fqdn = $Matches['fqdn']
            $ip   = $Matches['ip']

            if (-not (Test-ValidIPv4Address -IP $ip)) {
                Write-Host "ERROR: Invalid IP address (octet out of range 0-255) in --set-host entry: $entry" -ForegroundColor Red
                exit 1
            }

            $SetHostMap[$fqdn] = $ip
        }
    }

    # Parse --set-delegation into: ChildFQDN -> @(NameServerFQDN, ...)
    $DelegationMap = @{}

    if ($SetDelegationRaw) {
        foreach ($entry in ([string]$SetDelegationRaw) -split ',') {
            $entry = $entry.Trim()
            if (-not $entry) { continue }
            if ($entry -notmatch '^(?<child>[^_]+)_(?<ns>.+)$') {
                Write-Host "ERROR: Invalid --set-delegation entry (expected childfqdn_nsfqdn): $entry" -ForegroundColor Red
                exit 1
            }
            $child = $Matches['child']
            $ns    = $Matches['ns']

            if (-not $DelegationMap.ContainsKey($child)) {
                $DelegationMap[$child] = @()
            }
            $DelegationMap[$child] += $ns
        }
    }

    # Validate parent zones exist before CREATE operations
    if (-not $IsQueryMode) {
        $zonesToCheck = New-Object System.Collections.Generic.List[string]

        if ($SetHostMap.Count -gt 0) {
            foreach ($fqdn in $SetHostMap.Keys) {
                $split = Split-Fqdn -Fqdn $fqdn -ExplicitParentZone $ParentZoneExplicit
                if ($zonesToCheck -notcontains $split.ParentZone) {
                    $zonesToCheck.Add($split.ParentZone)
                }
            }
        }

        if ($DelegationMap.Count -gt 0) {
            foreach ($child in $DelegationMap.Keys) {
                $split = Split-Fqdn -Fqdn $child -ExplicitParentZone $ParentZoneExplicit
                if ($zonesToCheck -notcontains $split.ParentZone) {
                    $zonesToCheck.Add($split.ParentZone)
                }
            }
        }

        foreach ($zone in $zonesToCheck) {
            if (-not (Test-ZoneExists -ZoneName $zone)) {
                Write-Host "ERROR: Parent zone '$zone' does not exist on DNS server '$DnsServerName'." -ForegroundColor Red
                Write-Log "Parent zone '$zone' does not exist" 'ERROR'
                exit 1
            }
        }
    }

    # Helper: resolve an IP for a name server using a fallback chain
    function Resolve-NameServerIP {
        param([string]$NsFqdn)

        if ($SetHostMap.ContainsKey($NsFqdn)) {
            return $SetHostMap[$NsFqdn]
        }

        try {
            $split = Split-Fqdn -Fqdn $NsFqdn -ExplicitParentZone $ParentZoneExplicit
            $rec = Get-DnsServerResourceRecord -ZoneName $split.ParentZone `
                                                -Name $split.Label `
                                                -RRType A `
                                                -ComputerName $DnsServerName `
                                                -ErrorAction SilentlyContinue
            if ($rec) {
                $firstIp = ($rec | Select-Object -First 1).RecordData.IPv4Address.ToString()
                if ($firstIp) { return $firstIp }
            }
        } catch { }

        try {
            $resolved = Resolve-DnsName -Name $NsFqdn -Type A -ErrorAction SilentlyContinue |
                        Where-Object { $_.Type -eq 'A' } |
                        Select-Object -First 1
            if ($resolved -and $resolved.IPAddress) {
                return $resolved.IPAddress
            }
        } catch { }

        return $null
    }

    # Helper: get existing delegation/NS entries for a child label
    function Get-ExistingDelegationNameServers {
        param(
            [string]$ParentZone,
            [string]$Label,
            [string]$TargetServer = $DnsServerName
        )

        $nsNames = New-Object System.Collections.Generic.List[string]

        try {
            $deleg = Get-DnsServerZoneDelegation -Name $ParentZone `
                                                  -ChildZoneName $Label `
                                                  -ComputerName $TargetServer `
                                                  -ErrorAction SilentlyContinue
            if ($deleg) {
                foreach ($d in $deleg) { $nsNames.Add($d.NameServer) }
            }
        } catch { }

        try {
            $nsRecords = Get-DnsServerResourceRecord -ZoneName $ParentZone `
                                                      -Name $Label `
                                                      -RRType NS `
                                                      -ComputerName $TargetServer `
                                                      -ErrorAction SilentlyContinue
            if ($nsRecords) {
                foreach ($rec in $nsRecords) {
                    $nsName = $rec.RecordData.NameServer.TrimEnd('.')
                    if ($nsName -and ($nsNames -notcontains $nsName)) {
                        $nsNames.Add($nsName)
                    }
                }
            }
        } catch { }

        return ($nsNames | Select-Object -Unique)
    }

    # QUERY HELPERS
    function Resolve-ZoneRootServer {
        param(
            [string]$Zone,
            [string]$PreferredServer
        )

        try {
            $params = @{
                Name = $Zone
                Type = 'NS'
                ErrorAction = 'Stop'
            }
            if ($PreferredServer) {
                $params['Server'] = $PreferredServer
            }

            $nsAnswers = Resolve-DnsName @params |
                         Where-Object { $_.Type -eq 'NS' }

            if (-not $nsAnswers) { return $null }

            $firstNs = ($nsAnswers | Select-Object -First 1).NameHost

            $aAnswer = Resolve-DnsName -Name $firstNs -Type A -ErrorAction SilentlyContinue |
                       Where-Object { $_.Type -eq 'A' } |
                       Select-Object -First 1

            return [PSCustomObject]@{
                Name = $firstNs
                IPAddress = if ($aAnswer) { $aAnswer.IPAddress } else { $firstNs }
            }
        }
        catch {
            return $null
        }
    }

    function Resolve-FqdnIP {
        param([string]$Fqdn)

        try {
            $a = Resolve-DnsName -Name $Fqdn -Type A -ErrorAction SilentlyContinue |
                 Where-Object { $_.Type -eq 'A' } |
                 Select-Object -First 1
            if ($a) { return $a.IPAddress }
        } catch { }

        return $null
    }

    function Invoke-AQuery {
        param(
            [string]$Name,
            [string]$Server
        )

        try {
            $result = Resolve-DnsName -Name $Name -Type A -Server $Server -ErrorAction Stop |
                      Where-Object { $_.Type -eq 'A' }
            return $result
        }
        catch {
            return $null
        }
    }

    function Invoke-NSQuery {
        param(
            [string]$Name,
            [string]$Server
        )

        try {
            $result = Resolve-DnsName -Name $Name -Type NS -Server $Server -ErrorAction Stop |
                      Where-Object { $_.Type -eq 'NS' }
            return $result
        }
        catch {
            return $null
        }
    }

    # Parse comma-separated FQDN lists
    function Get-FqdnList {
        param([string]$Raw)

        $list = New-Object System.Collections.Generic.List[string]
        if (-not $Raw) { return $list.ToArray() }

        foreach ($entry in ([string]$Raw) -split ',') {
            $entry = $entry.Trim()
            if ($entry) { $list.Add($entry) }
        }
        return $list.ToArray()
    }

    # QUERY MODE: --query-host
    function Invoke-QueryHost {
        param([string[]]$FqdnList)

        foreach ($fqdn in $FqdnList) {
            Write-Host ""
            Write-Host "Query (A): $fqdn" -ForegroundColor Yellow

            if ($ServerAll) {
                $split = Split-Fqdn -Fqdn $fqdn -ExplicitParentZone $ParentZoneExplicit
                $root  = Resolve-ZoneRootServer -Zone $split.ParentZone -PreferredServer $DnsServerName

                if (-not $root) {
                    Write-Host "  ERROR: Could not auto-discover root DNS server for zone '$($split.ParentZone)'." -ForegroundColor Red
                    continue
                }

                Write-Host "  Root DNS server for '$($split.ParentZone)': $($root.Name) ($($root.IPAddress))" -ForegroundColor DarkCyan

                $answer = Invoke-AQuery -Name $fqdn -Server $root.IPAddress
                if ($answer) {
                    foreach ($a in $answer) {
                        Write-Host "    -> $($a.IPAddress)" -ForegroundColor Green
                    }
                } else {
                    Write-Host "    -> No answer / resolution failed." -ForegroundColor DarkGray
                }
            }
            else {
                $answer = Invoke-AQuery -Name $fqdn -Server $DnsServerName
                if ($answer) {
                    foreach ($a in $answer) {
                        Write-Host "  [$DnsServerName] -> $($a.IPAddress)" -ForegroundColor Green
                    }
                } else {
                    Write-Host "  [$DnsServerName] -> No answer / resolution failed." -ForegroundColor DarkGray
                }
            }
        }
    }

    # QUERY MODE: --query-delegation
    function Invoke-QueryDelegation {
        param([string[]]$FqdnList)

        foreach ($fqdn in $FqdnList) {
            Write-Host ""
            Write-Host "Query (Delegation/NS): $fqdn" -ForegroundColor Yellow

            $split = Split-Fqdn -Fqdn $fqdn -ExplicitParentZone $ParentZoneExplicit

            if ($ServerAll) {
                $root = Resolve-ZoneRootServer -Zone $split.ParentZone -PreferredServer $DnsServerName

                if (-not $root) {
                    Write-Host "  ERROR: Could not auto-discover root DNS server for zone '$($split.ParentZone)'." -ForegroundColor Red
                    continue
                }

                Write-Host "  Root DNS server for '$($split.ParentZone)': $($root.Name) ($($root.IPAddress))" -ForegroundColor DarkCyan

                $nsAnswer = Invoke-NSQuery -Name $fqdn -Server $root.IPAddress

                if (-not $nsAnswer) {
                    Write-Host "    -> No NS/delegation records found at root server." -ForegroundColor DarkGray
                    continue
                }

                $nsNames = $nsAnswer | Select-Object -ExpandProperty NameHost -Unique
                Write-Host "    Delegated name servers found:" -ForegroundColor Green
                foreach ($ns in $nsNames) {
                    Write-Host "      NS: $ns"
                }

                Write-Host "  Querying each delegated name server (SSIP host) directly for '$fqdn':" -ForegroundColor DarkCyan
                foreach ($ns in $nsNames) {
                    $nsIp = Resolve-FqdnIP -Fqdn $ns
                    if (-not $nsIp) {
                        Write-Host "    [$ns] -> ERROR: could not resolve this name server's IP; skipping direct query." -ForegroundColor Red
                        continue
                    }

                    $directAnswer = Invoke-AQuery -Name $fqdn -Server $nsIp
                    if ($directAnswer) {
                        foreach ($a in $directAnswer) {
                            Write-Host "    [$ns ($nsIp)] -> $($a.IPAddress)" -ForegroundColor Green
                        }
                    } else {
                        Write-Host "    [$ns ($nsIp)] -> No answer / resolution failed." -ForegroundColor DarkGray
                    }
                }
            }
            else {
                $nsAnswer = Invoke-NSQuery -Name $fqdn -Server $DnsServerName

                if ($nsAnswer) {
                    $nsNames = $nsAnswer | Select-Object -ExpandProperty NameHost -Unique
                    Write-Host "  [$DnsServerName] Delegated name servers found:" -ForegroundColor Green
                    foreach ($ns in $nsNames) {
                        Write-Host "    NS: $ns"
                    }
                } else {
                    Write-Host "  [$DnsServerName] -> No NS/delegation records found." -ForegroundColor DarkGray
                }
            }
        }
    }

    # CREATE MODE FUNCTIONS
    function Show-HostRecordStatus {
        param([string]$Fqdn)

        $split = Split-Fqdn -Fqdn $Fqdn -ExplicitParentZone $ParentZoneExplicit
        Write-Host "Host record: $Fqdn" -ForegroundColor Yellow

        try {
            $existing = Get-DnsServerResourceRecord -ZoneName $split.ParentZone `
                                                      -Name $split.Label `
                                                      -RRType A `
                                                      -ComputerName $DnsServerName `
                                                      -ErrorAction SilentlyContinue
        } catch {
            $existing = $null
        }

        if ($existing) {
            foreach ($rec in $existing) {
                Write-Host ("  Exists -> {0}" -f $rec.RecordData.IPv4Address) -ForegroundColor Green
            }
        } else {
            Write-Host "  Not present." -ForegroundColor DarkGray
        }
    }

    function Show-DelegationStatus {
        param([string]$ChildFqdn)

        $split = Split-Fqdn -Fqdn $ChildFqdn -ExplicitParentZone $ParentZoneExplicit
        Write-Host "Delegation: $ChildFqdn  (zone: $($split.ParentZone), label: $($split.Label))" -ForegroundColor Yellow

        $nsNames = Get-ExistingDelegationNameServers -ParentZone $split.ParentZone -Label $split.Label

        if ($nsNames -and $nsNames.Count -gt 0) {
            Write-Host "  Delegation EXISTS:" -ForegroundColor Green
            foreach ($ns in $nsNames) {
                Write-Host ("    NS: {0}" -f $ns)
            }
        } else {
            Write-Host "  No delegation currently configured." -ForegroundColor DarkGray
        }
    }

    function New-HostRecordIfNeeded {
        param(
            [string]$Fqdn,
            [string]$IPAddress
        )

        $split = Split-Fqdn -Fqdn $Fqdn -ExplicitParentZone $ParentZoneExplicit

        $existing = Get-DnsServerResourceRecord -ZoneName $split.ParentZone `
                                                 -Name $split.Label `
                                                 -RRType A `
                                                 -ComputerName $DnsServerName `
                                                 -ErrorAction SilentlyContinue

        $already = $existing | Where-Object { $_.RecordData.IPv4Address.ToString() -eq $IPAddress }

        if ($already) {
            Write-Host "Host record '$Fqdn' -> $IPAddress already exists. Skipping." -ForegroundColor DarkGray
            return
        }

        if ($DryRun) {
            Write-Host "[DRY-RUN] Would create host record: $Fqdn -> $IPAddress" -ForegroundColor Cyan
            return
        }

        try {
            Add-DnsServerResourceRecordA -ZoneName $split.ParentZone `
                                          -Name $split.Label `
                                          -IPv4Address $IPAddress `
                                          -ComputerName $DnsServerName `
                                          -ErrorAction Stop
            Write-Host "Created host record: $Fqdn -> $IPAddress" -ForegroundColor Green
        }
        catch {
            $existing = Get-DnsServerResourceRecord -ZoneName $split.ParentZone `
                                                     -Name $split.Label `
                                                     -RRType A `
                                                     -ComputerName $DnsServerName `
                                                     -ErrorAction SilentlyContinue
            $already = $existing | Where-Object { $_.RecordData.IPv4Address.ToString() -eq $IPAddress }

            if ($already) {
                Write-Host "Host record '$Fqdn' -> $IPAddress was created by another process. No action needed." -ForegroundColor Yellow
            }
            else {
                Write-Host "Failed to create host record:" -ForegroundColor Red
                Write-Host "  FQDN: $Fqdn" -ForegroundColor Red
                Write-Host "  IP: $IPAddress" -ForegroundColor Red
                Write-Host "  Zone: $($split.ParentZone)" -ForegroundColor Red
                Write-Host "  Label: $($split.Label)" -ForegroundColor Red
                Write-Host "  Server: $DnsServerName" -ForegroundColor Red
                Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    function New-DelegationIfNeeded {
        param(
            [string]$ChildFqdn,
            [string[]]$NameServers
        )

        $split = Split-Fqdn -Fqdn $ChildFqdn -ExplicitParentZone $ParentZoneExplicit

        $existingNS = Get-ExistingDelegationNameServers -ParentZone $split.ParentZone -Label $split.Label

        if ($existingNS -and $existingNS.Count -gt 0) {
            Write-Host "Delegation for '$ChildFqdn' already has some entries. Verifying all required name servers are present..." -ForegroundColor Yellow
        }

        foreach ($ns in $NameServers) {

            if ($existingNS -contains $ns) {
                Write-Host "  NS '$ns' already delegated for '$ChildFqdn'. Skipping." -ForegroundColor DarkGray
                continue
            }

            $ip = Resolve-NameServerIP -NsFqdn $ns

            if ($ip) {
                if ($DryRun) {
                    Write-Host "[DRY-RUN] Would add NS '$ns' (glue: $ip) to delegation for '$ChildFqdn'." -ForegroundColor Cyan
                    continue
                }

                try {
                    Add-DnsServerZoneDelegation -Name $split.ParentZone `
                                                 -ChildZoneName $split.Label `
                                                 -NameServer $ns `
                                                 -IPAddress @([ipaddress]$ip) `
                                                 -ComputerName $DnsServerName `
                                                 -ErrorAction Stop
                    Write-Host "  Added NS '$ns' (glue: $ip) to delegation for '$ChildFqdn'." -ForegroundColor Green
                }
                catch {
                    Write-Host "  Failed to add NS '$ns' (with glue) to delegation '$ChildFqdn':" -ForegroundColor Red
                    Write-Host "    Child FQDN: $ChildFqdn" -ForegroundColor Red
                    Write-Host "    Name Server: $ns" -ForegroundColor Red
                    Write-Host "    IP: $ip" -ForegroundColor Red
                    Write-Host "    Zone: $($split.ParentZone)" -ForegroundColor Red
                    Write-Host "    Label: $($split.Label)" -ForegroundColor Red
                    Write-Host "    Server: $DnsServerName" -ForegroundColor Red
                    Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
            else {
                if ($DryRun) {
                    Write-Host "[DRY-RUN] Would add NS '$ns' (no glue) to delegation for '$ChildFqdn'." -ForegroundColor Cyan
                    continue
                }

                Write-Host "  No IP resolvable for '$ns'. Creating plain NS record (no glue) for '$ChildFqdn'..." -ForegroundColor DarkYellow
                try {
                    Add-DnsServerResourceRecord -ZoneName $split.ParentZone `
                                                 -NS `
                                                 -Name $split.Label `
                                                 -NameServer $ns `
                                                 -ComputerName $DnsServerName `
                                                 -ErrorAction Stop
                    Write-Host "  Added NS '$ns' (no glue) to delegation for '$ChildFqdn'." -ForegroundColor Green
                }
                catch {
                    Write-Host "  Failed to add NS '$ns' (no glue) to delegation '$ChildFqdn':" -ForegroundColor Red
                    Write-Host "    Child FQDN: $ChildFqdn" -ForegroundColor Red
                    Write-Host "    Name Server: $ns" -ForegroundColor Red
                    Write-Host "    Zone: $($split.ParentZone)" -ForegroundColor Red
                    Write-Host "    Label: $($split.Label)" -ForegroundColor Red
                    Write-Host "    Server: $DnsServerName" -ForegroundColor Red
                    Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
    }

    # MAIN DNS DISPATCH
    if ($IsQueryMode) {
        Write-Host ""
        Write-Host "==== DNS Query Results ====" -ForegroundColor Cyan

        if ($QueryHostRaw) {
            $hostList = Get-FqdnList -Raw $QueryHostRaw
            Invoke-QueryHost -FqdnList $hostList
        }

        if ($QueryDelegationRaw) {
            $delegList = Get-FqdnList -Raw $QueryDelegationRaw
            Invoke-QueryDelegation -FqdnList $delegList
        }

        Write-Host ""
        Write-Host "Done." -ForegroundColor Cyan
        exit 0
    }

    # CREATE MODE
    Write-Host ""
    Write-Host "==== Current Configuration Report ====" -ForegroundColor Cyan

    if ($SetHostMap.Count -gt 0) {
        Write-Host "`n-- Host Records --" -ForegroundColor Magenta
        foreach ($fqdn in $SetHostMap.Keys) {
            Show-HostRecordStatus -Fqdn $fqdn
        }
    }

    if ($DelegationMap.Count -gt 0) {
        Write-Host "`n-- Delegations --" -ForegroundColor Magenta
        foreach ($child in $DelegationMap.Keys) {
            Show-DelegationStatus -ChildFqdn $child
        }
    }

    Write-Host ""
    Write-Host "==== Applying Configuration ====" -ForegroundColor Cyan

    if ($SetHostMap.Count -gt 0) {
        Write-Host "`n-- Creating/Verifying Host Records --" -ForegroundColor Magenta
        foreach ($fqdn in $SetHostMap.Keys) {
            New-HostRecordIfNeeded -Fqdn $fqdn -IPAddress $SetHostMap[$fqdn]
        }
    }

    if ($DelegationMap.Count -gt 0) {
        Write-Host "`n-- Creating/Verifying Delegations --" -ForegroundColor Magenta
        foreach ($child in $DelegationMap.Keys) {
            New-DelegationIfNeeded -ChildFqdn $child -NameServers $DelegationMap[$child]
        }
    }

    Write-Host ""
    Write-Host "==== Post-Change Verification ====" -ForegroundColor Cyan

    if ($SetHostMap.Count -gt 0) {
        foreach ($fqdn in $SetHostMap.Keys) {
            Show-HostRecordStatus -Fqdn $fqdn
        }
    }

    if ($DelegationMap.Count -gt 0) {
        foreach ($child in $DelegationMap.Keys) {
            Show-DelegationStatus -ChildFqdn $child
        }
    }

    Write-Host "`nDone." -ForegroundColor Cyan
    exit 0
}
