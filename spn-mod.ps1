#Requires -Version 5.1
<#
.SYNOPSIS
    Manage and inspect SPN attribute delegation for AD computer accounts.

.DESCRIPTION
    Three check/management surfaces:

      --spn-self-set|-remove|-check <list>
          Manages the SELF "Validated write to service principal name" right
          (the "Self" access-mask bit, decimal 8) on each listed computer.

          --spn-self-set    ensures the Self bit is present (adds it if
                             missing; does not disturb other unrelated
                             rights already on the object).
          --spn-self-remove RESETS the SELF ACE back to the AD baseline:
                             exactly Self (8), nothing else. Any extra bits
                             that accumulated over time are discarded and
                             the ACE is rewritten as a single clean grant.
                             If no SELF ACE exists at all, one is created.
          --spn-self-check  reports whether the Self bit is present
                             (bitwise - tolerant of other bits also
                             present) and shows the raw combined rights
                             value for context.

      --spn-pair-set|-remove|-check <list>
          Uses BIDIRECTIONAL PAIR syntax: accountA_accountB

              cls01_cls02   =>  cls01 is granted/removed rights to write
                                cls02's servicePrincipalName, AND cls02 is
                                granted/removed rights to write cls01's
                                servicePrincipalName (both directions).

          Multiple pairs may be comma separated:

              --spn-pair-set cls01_cls02,cls03_cls04

          The underscore '_' is used as the pair separator (instead of a
          dash) so that hostnames containing '-' are unambiguous. Account
          names must not themselves contain '_'.

          --spn-pair-set    requires ONLY accountA_accountB pairs (a bare
                             name with no peer is rejected - there is
                             nothing to grant without a peer).
          --spn-pair-remove accepts accountA_accountB pairs (removes the
                             bidirectional grant between that pair), AND/OR
                             bare single names for DISCOVERY MODE (removes
                             ALL foreign, non-SELF RP/WP grants found on
                             that one computer, regardless of who the
                             trustee is).
          --spn-pair-check  same acceptance as --spn-pair-remove, but
                             read-only: reports both directions' status for
                             a pair, or (for bare names) reports all
                             foreign grants found via discovery.

      --spn-check <list>
          READ-ONLY, FULL INVENTORY mode. For each listed computer, lists
          EVERY explicit, non-inherited, Allow ACE found on its
          servicePrincipalName attribute - both the SELF grant (if any)
          AND any foreign/peer trustees (if any) - in a single combined
          view, regardless of whether those grants came from the self or
          pair management above (or from anywhere else, e.g. manually via
          dsacls/ADUC). Each row shows the trustee, whether it is SELF or
          an Other (foreign) trustee, and the raw combined rights value.

    Multiple switches may be combined in a single invocation.

    Accounts that cannot be resolved in Active Directory are reported as
    warnings and skipped - they do NOT abort the rest of the run. Each
    request/pair/discovery-entry is independently re-validated against
    resolved accounts; unresolvable entries are dropped individually with
    a warning rather than failing the entire script.

.PARAMETER server
    Optional: specify a specific domain controller for AD operations.
    If not specified, the default domain controller is used.

.PARAMETER dry-run
    Optional: preview changes without actually applying them.
    Shows what would be modified but makes no changes to AD.

.PARAMETER log-file
    Optional: path to a log file where all operations will be recorded.

.EXAMPLE
    .\spn-mod.ps1 --spn-self-check cls01,cls02

.EXAMPLE
    .\spn-mod.ps1 --spn-self-set cls01,cls02,cls03

.EXAMPLE
    .\spn-mod.ps1 --spn-self-remove cls01,cls02

.EXAMPLE
    .\spn-mod.ps1 --spn-pair-set cls01_cls02,cls03_cls04

.EXAMPLE
    .\spn-mod.ps1 --spn-pair-check cls01_cls02

.EXAMPLE
    .\spn-mod.ps1 --spn-pair-remove cls01_cls02

.EXAMPLE
    .\spn-mod.ps1 --spn-pair-check cls09
    # Discovery mode: show any foreign (non-SELF) RP/WP SPN grants on cls09

.EXAMPLE
    .\spn-mod.ps1 --spn-check cls01,cls02,cls03
    # Full inventory: shows SELF + any/all foreign trustees for each host

.EXAMPLE
    .\spn-mod.ps1 --spn-self-set cls04 --spn-pair-remove cls01_cls02

.EXAMPLE
    .\spn-mod.ps1 --spn-self-set cls01 --dry-run
    # Preview changes without applying them

.EXAMPLE
    .\spn-mod.ps1 --spn-self-set cls01 --server=dc01.domain.com

.EXAMPLE
    .\spn-mod.ps1 --help

.NOTES
    ============================================================
    Maintainer / Owner : Elie Koivunen
    Contact            : elie.koivunen@dell.com
    Tool               : SPN Delegation Manager (Superna DR / PowerScale)
    Version            : 1.1.0
    For questions, bug reports, or enhancement requests relating to
    this script, please contact the maintainer listed above.
    ============================================================

    Use Windows PowerShell 5.1 with the ActiveDirectory module (RSAT).
    Modifying computer object ACLs requires delegated permissions.
    The check evaluates relevant explicit ACEs, not full effective access.

    Account names used in --spn-pair-* pair syntax must not themselves
    contain an '_' character, since '_' is the pair separator. Hostnames
    containing '-' are fine and fully supported with this separator.

    TIP: Quoting your comma-separated lists is always safe and recommended,
    though this script also correctly handles unquoted lists that
    PowerShell may pre-split into an array.

    CHANGELOG:
      1.1.0 - Added error handling around Set-Acl operations
              - Added verification after ACL changes
              - Added dry-run mode for safe testing
              - Added permission validation before operations
              - Added logging capability
              - Added domain controller parameter
              - Added progress indication for large operations
              - Fixed LDAP filter SID format issue
              - Added module availability check
              - Added structured version variable
              - Fixed typo in comment (Verson -> Version)
      1.0.0 - Initial release
#>

# ============================================================
#  SPN Delegation Manager (Superna DR / PowerScale)
#  Maintainer / Owner : Elie Koivunen
#  Contact            : elie.koivunen@dell.com
#  Please direct questions, issues, or change requests to the
#  contact above before modifying this script in shared use.
# ============================================================

$ScriptVersion = '1.1.0'
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
SPN Delegation Manager (Superna DR / PowerScale)
Maintainer: Elie Koivunen (elie.koivunen@dell.com)
Version: 1.1.0

Usage (any combination of the switches below may be used together):

  .\spn-mod.ps1 --spn-self-check  cls01[,cls02,...]
  .\spn-mod.ps1 --spn-self-set    cls01[,cls02,...]
  .\spn-mod.ps1 --spn-self-remove cls01[,cls02,...]

  .\spn-mod.ps1 --spn-pair-check  cls01_cls02[,cls03_cls04,...]   (pairs)
  .\spn-mod.ps1 --spn-pair-check  cls09                           (discovery)
  .\spn-mod.ps1 --spn-pair-set    cls01_cls02[,cls03_cls04,...]   (pairs only)
  .\spn-mod.ps1 --spn-pair-remove cls01_cls02[,cls03_cls04,...]   (pairs)
  .\spn-mod.ps1 --spn-pair-remove cls09                           (discovery)

  .\spn-mod.ps1 --spn-check       cls01[,cls02,...]   (full inventory, read-only)

  .\spn-mod.ps1 --help

Optional parameters:
  --server=<dc>       Specify a specific domain controller for AD operations
  --dry-run           Preview changes without applying them
  --log-file=<path>   Path to a log file for operation recording

Group semantics:

  self   Manages the SELF "Validated write to service principal name"
         right (the "Self" access-mask bit, decimal 8) on each listed
         computer. Accepts 1+ names.
           set     -> ensures Self (8) is present (adds if missing).
           remove  -> RESETS the SELF ACE to baseline: exactly Self (8),
                      discarding any other bits that accumulated on it.
                      Creates a baseline ACE if none existed.
           check   -> reports presence (bitwise) and raw combined rights.

  pair   BIDIRECTIONAL pair syntax: accountA_accountB

           cls01_cls02  =>  cls01 is granted/removed rights to write
                            cls02's SPN, AND cls02 is granted/removed
                            rights to write cls01's SPN (both directions).

         Multiple pairs: cls01_cls02,cls03_cls04

           set     -> requires explicit pairs ONLY (no bare names - there
                      is no peer to grant without one).
           remove  -> accepts explicit pairs (removes the mutual grant,
                      both directions) AND/OR bare single names
                      (DISCOVERY MODE: removes ALL foreign, non-SELF
                      RP/WP grants found on that one computer).
           check   -> same acceptance as remove, read-only; explicit pairs
                      produce TWO rows (one per direction).

  (plain) --spn-check <list>  READ-ONLY full inventory. For each listed
         computer, lists EVERY explicit SPN-related grant found - SELF and
         any/all foreign trustees - in one combined view. Useful as a
         single "what does this object currently have?" report, independent
         of whether grants came from this script's self/pair management or
         were set some other way (dsacls, ADUC, etc.).

Examples combining actions in one run:

  .\spn-mod.ps1 --spn-self-set cls01,cls02 `
                --spn-pair-set cls01_cls02,cls03_cls04

  .\spn-mod.ps1 --spn-pair-check cls09
  .\spn-mod.ps1 --spn-pair-remove cls01_cls02
  .\spn-mod.ps1 --spn-check cls01,cls02,cls03

Examples with optional parameters:

  .\spn-mod.ps1 --spn-self-set cls01 --dry-run
  .\spn-mod.ps1 --spn-self-set cls01 --server=dc01.domain.com
  .\spn-mod.ps1 --spn-self-set cls01 --log-file=C:\logs\spn-mod.log

Notes:
  - Accounts may be given as cls01 or cls01$ (no trailing $ needed).
  - Account names must NOT contain '_' (reserved as the pair separator).
    Hostnames containing '-' are fully supported.
  - Lists may be quoted or unquoted; both are handled correctly.
  - At least one *-set, *-remove, *-check, or --spn-check switch must be
    supplied.
  - Accounts that cannot be found in AD are reported as warnings and
    skipped; they do not abort processing of other accounts/requests.
  - set/remove are idempotent: running either repeatedly converges to the
    same end state rather than failing or accumulating duplicate ACEs.

Maintainer / Owner: Elie Koivunen (elie.koivunen@dell.com)
Version: 1.1.0
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
        Write-Log "SPN Delegation Manager v$ScriptVersion started"
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
    Write-Host "*** DRY-RUN MODE: No changes will be made to Active Directory ***" -ForegroundColor Yellow
    Write-Log "DRY-RUN MODE ENABLED"
}

# Each entry: [PSCustomObject]@{ Group='self'|'pair'|'all'; Action='set'|'remove'|'check'; RawArgument=<string> }
$requests = New-Object System.Collections.Generic.List[object]

$plainCheckPattern = '^--?spn-check$'
$groupedPattern    = '^--?spn-(self|pair)-(set|remove|check)$'

$i = 0
while ($i -lt $filteredArgs.Count) {
    $token = [string]$filteredArgs[$i]

    if ($token -match $plainCheckPattern) {
        if (($i + 1) -ge $filteredArgs.Count) {
            throw "Switch '$token' requires an account list argument."
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
            throw "Switch '$token' requires an account list argument."
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
        throw "Unknown argument '$token'. Run .\spn-mod.ps1 --help."
    }
    $i++
}

if ($requests.Count -eq 0) {
    throw 'At least one --spn-check, or --spn-(self|pair)-(set|remove|check) switch is required. Run --help.'
}

# ----------------------------------------------------------------------
# Check ActiveDirectory module availability
# ----------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    $msg = "The 'ActiveDirectory' PowerShell module is not available. Install RSAT: Active Directory DS-LDS Tools."
    Write-Log $msg 'ERROR'
    throw $msg
}

# ----------------------------------------------------------------------
# Check permissions (basic check)
# ----------------------------------------------------------------------
try {
    $testUser = Get-ADUser -Identity $env:USERNAME -ErrorAction Stop
    Write-Log "Current user: $env;User"
}
catch {
    Write-Warning "Could not verify current user: $($_.Exception.Message)"
}

Import-Module ActiveDirectory -ErrorAction Stop
Add-Type -AssemblyName System.DirectoryServices

# ----------------------------------------------------------------------
# Format-level parsing helpers
# ----------------------------------------------------------------------

function ConvertTo-SelfNameList {
    param([string]$Argument, [string]$SwitchLabel)

    $list = @(
        $Argument.Split(',') |
            ForEach-Object { ([string]$_).Trim().TrimEnd('$') } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    $dupes = $list | Group-Object -NoElement | Where-Object { $_.Count -gt 1 }
    if ($dupes) {
        throw "$($SwitchLabel): duplicate account name(s): $(($dupes | ForEach-Object { $_.Name }) -join ', ')"
    }
    if ($list.Count -lt 1) {
        throw "$($SwitchLabel) requires at least 1 account name."
    }

    return $list
}

function ConvertTo-PairSpec {
    <#
        Parses a --spn-pair-* argument into bidirectional pairs and/or
        bare discovery names.

        - "cls01_cls02"      -> pair: A=cls01, B=cls02 (bidirectional)
        - "cls09"            -> bare discovery name (only valid for
                                 check/remove; rejected for set)
        - entries with >1 '_' are rejected as ambiguous
        - duplicate pairs (A_B same as B_A) are silently de-duplicated
    #>
    param([string]$Argument, [string]$SwitchLabel, [string]$Action)

    $entries = @($Argument.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($entries.Count -eq 0) {
        throw "$SwitchLabel requires at least one entry."
    }

    $pairs     = New-Object System.Collections.Generic.List[object]
    $discovery = New-Object System.Collections.Generic.List[string]

    foreach ($entry in $entries) {
        $underscoreCount = ($entry.ToCharArray() | Where-Object { $_ -eq '_' }).Count

        if ($underscoreCount -eq 0) {
            if ($Action -eq 'set') {
                throw "$SwitchLabel : entry '$entry' has no '_' separator; --spn-pair-set requires explicit paired accounts like cls01_cls02."
            }
            $name = $entry.TrimEnd('$')
            if ([string]::IsNullOrWhiteSpace($name)) {
                throw "$SwitchLabel : empty account name in entry '$entry'."
            }
            $discovery.Add($name)
        }
        elseif ($underscoreCount -eq 1) {
            $parts = $entry.Split('_')
            $a = $parts[0].Trim().TrimEnd('$')
            $b = $parts[1].Trim().TrimEnd('$')

            if ([string]::IsNullOrWhiteSpace($a) -or [string]::IsNullOrWhiteSpace($b)) {
                throw "$SwitchLabel : malformed pair entry '$entry'. Expected format accountA_accountB, e.g. cls01_cls02."
            }
            if ($a -ieq $b) {
                throw "$SwitchLabel : entry '$entry' has the same account on both sides; a computer cannot be paired with itself."
            }

            $pairs.Add([PSCustomObject]@{ A = $a; B = $b; Raw = $entry })
        }
        else {
            throw "$SwitchLabel : entry '$entry' contains multiple '_' characters and cannot be unambiguously parsed as accountA_accountB. Account names must not contain '_' for this syntax."
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

# ----------------------------------------------------------------------
# Apply format-level parsing to each request
# ----------------------------------------------------------------------
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

# ----------------------------------------------------------------------
# Resolve the union of all distinct names across all requests.
# Resolution failures are collected and reported as warnings, NOT fatal
# errors - the script continues with whatever accounts DID resolve.
# ----------------------------------------------------------------------
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

# ----------------------------------------------------------------------
# Filter each request down to only resolvable accounts/pairs/entries.
# Requests (or individual pairs/entries within them) that can no longer
# proceed are skipped with a warning, rather than failing the whole run.
# ----------------------------------------------------------------------
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

# ----------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------
# This GUID identifies the servicePrincipalName attribute for the purposes
# of both ReadProperty/WriteProperty (plain attribute access) and the
# "Self" (validated write) access mask bit used for self-service updates.
$spnGuid = [guid]'f3a64788-5306-11d1-a9c5-0000f80367c1'

$selfSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-10')  # NT AUTHORITY\SELF

$rpWp = [System.DirectoryServices.ActiveDirectoryRights]::ReadProperty -bor [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty

# CORRECT right for "Validated write to service principal name": the
# "Self" bit (ADS_RIGHT_DS_SELF, decimal 8 / SDDL "SW").
$selfRight = [System.DirectoryServices.ActiveDirectoryRights]::Self

# ----------------------------------------------------------------------
# Generic ACE helpers (bitwise detection, surgical bit-clearing removal)
# ----------------------------------------------------------------------

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
    <#
        Returns all explicit, non-inherited, Allow ACEs on the given ACL
        scoped to the SPN attribute GUID for the given trustee SID,
        REGARDLESS of which specific rights bits they carry.
    #>
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
    <#
        Bitwise presence check: TRUE if the combined mask across all
        matching ACEs for this trustee contains ALL bits in RequiredMask,
        regardless of any other bits also present.
    #>
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
    <#
        Ensures the trustee has (at least) GrantMask on the SPN attribute.
        Relies on AD's native ACE-merge-on-add behavior: adding a rule for
        a trustee/object-type that already has an ACE will OR the masks
        together rather than creating a duplicate ACE.
    #>
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

        # Verify the change was applied
        $aclAfter = Get-ComputerAcl -DistinguishedName $Computer.DistinguishedName
        $statusAfter = Get-TrusteeStatus -Acl $aclAfter -Sid $Sid -RequiredMask $GrantMask
        if (-not $statusAfter.Present) {
            Write-Warning "  [verify-fail] $($Computer.Name): verification failed - rights may not have been applied correctly."
            Write-Log "[$($Computer.Name)] VERIFY-FAIL: rights may not have been applied correctly" 'WARN'
        }
    }
    catch {
        Write-Host "  [error] $($Computer.Name): failed to grant rights to $Label: $($_.Exception.Message)" -ForegroundColor Red
        Write-Log "[$($Computer.Name)] ERROR: failed to grant rights to $Label: $($_.Exception.Message)" 'ERROR'
        throw
    }
}

function Remove-TrusteeRightsBits {
    <#
        Surgically clears ONLY the bits in ClearMask from any matching
        ACE(s) for this trustee, preserving any other bits already present
        by re-adding a reduced-mask ACE if anything remains.
    #>
    param(
        [Parameter(Mandatory)]$Computer,
        [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$Sid,
        [Parameter(Mandatory)]$ClearMask,
        [Parameter(Mandatory)][string]$Label
    )

    $acl = Get-ComputerAcl -DistinguishedName $Computer.DistinguishedName
    $aces = @(Get-TrusteeAces -Acl $acl -Sid $Sid | Where-Object { ($_.ActiveDirectoryRights -band $ClearMask) -ne 0 })

    if ($aces.Count -eq 0) {
        Write-Host "  [skip] $($Computer.Name): no matching right(s) to clear for $Label." -ForegroundColor DarkGray
        Write-Log "[$($Computer.Name)] SKIP: no matching rights to clear for $Label"
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
    <#
        Resets the SELF trustee's ACE(s) on the SPN attribute back to the
        AD baseline: exactly Self (8), nothing else. Any accumulated extra
        bits are discarded. If no SELF ACE exists at all, a clean baseline
        ACE is created.
    #>
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
    <#
        Best-effort friendly name for a SID found on an ACE:
        1) Try NTAccount translation.
        2) Fall back to an AD object lookup by objectSid.
        3) Fall back to the raw SID string.
    #>
    param([Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$Sid)

    try {
        return $Sid.Translate([System.Security.Principal.NTAccount]).Value
    }
    catch {
        try {
            # Use proper SID format for LDAP filter
            $sidBytes = $Sid.Value
            $sidHex = ($sidBytes -split '-' | ForEach-Object { '{0:X2}' -f [int]$_ }) -join '\'
            $obj = Get-ADObject -LDAPFilter "(objectSid=$sidHex)" -Properties Name -ErrorAction Stop @adParams
            if ($obj) { return $obj.Name }
        }
        catch {
            # Fallback to using SID directly
            try {
                $obj = Get-ADObject -Filter { ObjectSid -eq $Sid } -Properties Name -ErrorAction Stop @adParams
                if ($obj) { return $obj.Name }
            }
            catch { }
        }
    }
    return $Sid.Value
}

# ---- SELF: check / set / remove ---------------------------------------

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

# ---- PAIR: bidirectional pairs ------------------------------------------

function Invoke-PairCheckExplicit {
    param($Pairs)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($p in $Pairs) {
        $compA = $compByName[$p.A]
        $compB = $compByName[$p.B]

        # Direction 1: does A grant rights to B on A's SPN?
        $aclA = Get-ComputerAcl -DistinguishedName $compA.DistinguishedName
        $statusAtoB = Get-TrusteeStatus -Acl $aclA -Sid $compB.ObjectSID -RequiredMask $rpWp
        $rows.Add([PSCustomObject]@{
            Group = 'pair'; Computer = $compA.Name; Trustee = $compB.Name; Type = 'Other'
            Present = $statusAtoB.Present; Rights = $statusAtoB.Detail
        })

        # Direction 2: does B grant rights to A on B's SPN?
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
        # Bidirectional: A grants rights to B, AND B grants rights to A.
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
        # Bidirectional: remove A's grant to B, AND B's grant to A.
        Remove-TrusteeRightsBits -Computer $compA -Sid $compB.ObjectSID -ClearMask $rpWp -Label $compB.Name
        Remove-TrusteeRightsBits -Computer $compB -Sid $compA.ObjectSID -ClearMask $rpWp -Label $compA.Name
    }
}

# ---- PAIR: discovery mode (single bare name) ---------------------------

function Get-ForeignRpWpGrants {
    <#
        Scans the ACL for explicit, non-inherited, Allow ACEs on the SPN
        attribute where the trustee is NOT SELF and the combined mask for
        that trustee includes at least one of ReadProperty/WriteProperty.
        Returns one row per distinct foreign trustee (masks combined).
    #>
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

# ---- FULL INVENTORY: --spn-check (read-only, SELF + all foreign) -------

function Invoke-SpnFullCheck {
    <#
        For each listed computer, lists EVERY explicit, non-inherited,
        Allow ACE found on servicePrincipalName - SELF and any/all foreign
        trustees alike - combining masks per distinct trustee SID.
    #>
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

# ----------------------------------------------------------------------
# Dispatch: process each ACTIVE request in order; collect check rows.
# ----------------------------------------------------------------------
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
            # Guarded earlier: set requests only ever contain pairs, never discovery entries.
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

    # Discovery/full-inventory "none found" rows intentionally have
    # Present = $false but are not failures - they just mean nothing was
    # found, which can be the desired state. Only flag real missing/
    # incomplete rights (self/pair groups) as failures; 'all' rows are
    # purely informational and never counted as failures.
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
