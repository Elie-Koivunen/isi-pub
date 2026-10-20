<#
=================================================================================
 SCRIPT NAME   : dns-mod.ps1
 DESCRIPTION   : Manages Windows DNS host records and zone delegations,
                 including dual/multi delegation support, plus active
                 DNS query/verification tooling.
 VERSION       : 1.0.0
 AUTHOR        : Elie Koivunen
 CONTACT       : Elie.Koivunen@Dell.com
 CREATED       : 2026-10-19
 LAST MODIFIED : 2026-10-19
 COMPANY       : DELL

 CHANGELOG:
   1.0.0 - Initial release

 REQUIREMENTS:
   - Windows PowerShell 5.1+ or PowerShell 7+
   - RSAT: DNS Server Tools (DnsServer module)
   - Run with an account that has permissions on the target DNS server

 DISCLAIMER:
   Test in a non-production environment before use. Always verify DNS
   changes (host records, delegations, glue records) using nslookup,
   dnscmd, or the DNS Manager console before relying on them in production.
=================================================================================
#>

<#
.SYNOPSIS
    Checks, queries, and configures DNS host records and zone delegations
    (including dual/multi delegation) on a Windows DNS Server.

.DESCRIPTION
    dns-mod.ps1 accepts custom "--key=value" style arguments to:
      1. Create regular DNS host (A) records (--set-host).
      2. Create DNS zone delegations, supporting multiple name servers
         per delegated subdomain (dual delegation) (--set-delegation).
      3. Actively QUERY and verify DNS resolution:
           --query-host=fqdn,fqdn,...
               Resolves each given host FQDN (A record lookup).
           --query-delegation=fqdn,fqdn,...
               Resolves NS/delegation records for each given child zone
               FQDN.
         Both query modes require either --server=<dnsserver> (query a
         specific server) or --server-all (auto-discover and query the
         zone's root/authoritative DNS server; for delegation queries,
         ALSO directly query each delegated name server found).

    Delegation IP (glue) handling for creation:
      - If an IP can be resolved for a name server (via --set-host, an
        existing A record, or standard DNS resolution), the script
        creates the delegation WITH glue.
      - If no IP can be resolved, it creates a plain NS record (valid for
        out-of-bailiwick name servers).

    --set-host and --set-delegation may each be used independently or
    together for CREATION. --query-host and --query-delegation are
    independent QUERY operations and do not perform any creation.

    NOTE: PowerShell's command-line parser treats unquoted commas as array
    constructors, even mid-word. This script automatically flattens and
    re-merges such tokens so you can use the original unquoted,
    comma-separated syntax. If you prefer, you may still quote the whole
    argument for clarity:
        --set-host="host1_ip1,host2_ip2"

.PARAMETER set-host
    Comma-separated list of "fqdn_ip" pairs for host record creation.
    Format: fqdn_ip,fqdn_ip,...
    Example: cls01-ssip.lab.scape_192.168.255.1,cls02-ssip.lab.scape_172.16.1.23

.PARAMETER set-delegation
    Comma-separated list of "childfqdn_nameserverfqdn" pairs for
    delegation creation.
    Format: childfqdn_nsfqdn,childfqdn_nsfqdn,...
    Example: fs-smb.lab.scape_cls01-ssip.lab.scape,fs-smb.lab.scape_cls02-ssip.lab.scape

.PARAMETER query-host
    Comma-separated list of host FQDNs to actively resolve (A record).
    Example: cls01-ssip.lab.scape,cls02-ssip.lab.scape
    Must be used with --server or --server-all.

.PARAMETER query-delegation
    Comma-separated list of child zone FQDNs to actively resolve NS
    records for.
    Example: fs-smb.lab.scape,fs-nfs.lab.scape
    Must be used with --server or --server-all. When used with
    --server-all, each delegated name server discovered is ALSO queried
    directly for the same child name.

.PARAMETER server
    Target a specific DNS server for query or creation operations.
    Mutually exclusive with --server-all.

.PARAMETER server-all
    For query operations only: auto-discover the authoritative/root DNS
    server for each FQDN's parent zone and query it. For
    --query-delegation, additionally queries each delegated name server
    found. Mutually exclusive with --server.

.PARAMETER help
    Optional flag ( -h / --help ). Displays this help menu and exits.

.EXAMPLE
    .\dns-mod.ps1 --set-host=cls01-ssip.lab.scape_192.168.255.1,cls02-ssip.lab.scape_172.16.1.23 `
                  --set-delegation=fs-smb.lab.scape_cls01-ssip.lab.scape,fs-smb.lab.scape_cls02-ssip.lab.scape

    Creates host records and a dual delegation.

.EXAMPLE
    .\dns-mod.ps1 --query-host=cls01-ssip.lab.scape,cls02-ssip.lab.scape --server=dns01.lab.scape

    Resolves both host FQDNs by querying dns01.lab.scape directly.

.EXAMPLE
    .\dns-mod.ps1 --query-host=cls01-ssip.lab.scape,cls02-ssip.lab.scape --server-all

    Auto-discovers lab.scape's root/authoritative DNS server and
    resolves both host FQDNs against it.

.EXAMPLE
    .\dns-mod.ps1 --query-delegation=fs-smb.lab.scape,fs-nfs.lab.scape --server=dns01.lab.scape

    Queries dns01.lab.scape directly for the NS/delegation records of
    both child zones.

.EXAMPLE
    .\dns-mod.ps1 --query-delegation=fs-smb.lab.scape,fs-nfs.lab.scape --server-all

    Auto-discovers lab.scape's root DNS server, queries it for the
    NS/delegation records of both child zones, THEN also resolves each
    delegated name server (SSIP host) found and queries each of them
    directly for the same child FQDN - giving an end-to-end comparison.

.EXAMPLE
    .\dns-mod.ps1 --help

    Displays this help menu.

.NOTES
    Author  : Elie Koivunen
    Contact : Elie.Koivunen@Dell.com
    Version : 1.0.0
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [object[]]$RawArgs
)

#----------------------------------------------------------------------
# 0. Script metadata (used in help/banner output)
#----------------------------------------------------------------------
$ScriptVersion  = '1.0.0'
$ScriptAuthor   = 'Elie Koivunen'
$ScriptContact  = 'Elie.Koivunen@Dell.com'
$ScriptModified = '19-10-2026'

function Show-Banner {
    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor DarkCyan
    Write-Host " Script 	dns-mod.ps1" -ForegroundColor DarkCyan
    Write-Host " Version 	$ScriptVersion" -ForegroundColor DarkCyan 
    Write-Host " Last Modified: $ScriptModified" -ForegroundColor DarkCyan
    Write-Host " Author: 	$ScriptAuthor" -ForegroundColor DarkCyan 
    Write-Host " Contact: 	$ScriptContact" -ForegroundColor DarkCyan
    Write-Host "==================================================================" -ForegroundColor DarkCyan
}

function Show-HelpMenu {
    Show-Banner
    Write-Host ""
    Write-Host "USAGE:" -ForegroundColor Yellow
    Write-Host "  CREATE:"
    Write-Host "    .\dns-mod.ps1 [--set-host=<fqdn_ip,...>] [--set-delegation=<childfqdn_nsfqdn,...>] [--server=<dnsserver>]"
    Write-Host ""
    Write-Host "  QUERY:"
    Write-Host "    .\dns-mod.ps1 --query-host=<fqdn,...>       (--server=<dnsserver> | --server-all)"
    Write-Host "    .\dns-mod.ps1 --query-delegation=<fqdn,...> (--server=<dnsserver> | --server-all)"
    Write-Host ""
    Write-Host "PARAMETERS:" -ForegroundColor Yellow
    Write-Host "  --set-host=fqdn_ip,...                 Create/verify A host records; also used as glue IP source."
    Write-Host "  --set-delegation=childfqdn_nsfqdn,...  Create/verify delegation(s). Repeat childfqdn for dual delegation."
    Write-Host "  --query-host=fqdn,...                   Actively resolve (A) each host FQDN. Requires --server or --server-all."
    Write-Host "  --query-delegation=fqdn,...             Actively resolve NS/delegation records for each child FQDN."
    Write-Host "                                          Requires --server or --server-all."
    Write-Host "  --server=<dnsserver>                   Target a specific DNS server. Mutually exclusive with --server-all."
    Write-Host "  --server-all                            Auto-discover + query the zone's root DNS server. For"
    Write-Host "                                          --query-delegation, ALSO queries each delegated NS/SSIP host."
    Write-Host "  --help / -h                            Show this help menu."
    Write-Host ""
    Write-Host "EXAMPLES:" -ForegroundColor Yellow
    Write-Host "  # Create host records and dual-delegate two subdomains" -ForegroundColor DarkGray
    Write-Host "  .\dns-mod.ps1 --set-host=cls01-ssip.lab.scape_192.168.255.1,cls02-ssip.lab.scape_172.16.1.23 ``"
    Write-Host "                --set-delegation=fs-smb.lab.scape_cls01-ssip.lab.scape,fs-smb.lab.scape_cls02-ssip.lab.scape"
    Write-Host ""
    Write-Host "  # Query host records against a specific server" -ForegroundColor DarkGray
    Write-Host "  .\dns-mod.ps1 --query-host=cls01-ssip.lab.scape,cls02-ssip.lab.scape --server=dns01.lab.scape"
    Write-Host ""
    Write-Host "  # Query host records against the auto-discovered root DNS server" -ForegroundColor DarkGray
    Write-Host "  .\dns-mod.ps1 --query-host=cls01-ssip.lab.scape,cls02-ssip.lab.scape --server-all"
    Write-Host ""
    Write-Host "  # Query delegation NS records against a specific server" -ForegroundColor DarkGray
    Write-Host "  .\dns-mod.ps1 --query-delegation=fs-smb.lab.scape,fs-nfs.lab.scape --server=dns01.lab.scape"
    Write-Host ""
    Write-Host "  # Query delegation against root DNS AND each delegated SSIP host directly" -ForegroundColor DarkGray
    Write-Host "  .\dns-mod.ps1 --query-delegation=fs-smb.lab.scape,fs-nfs.lab.scape --server-all"
    Write-Host ""
    Write-Host "NOTE: If you experience argument parsing issues with commas, you may"
    Write-Host "      optionally quote the entire value, e.g.:"
    Write-Host "      --set-host=`"host1_ip1,host2_ip2`""
    Write-Host ""
    Write-Host "For full PowerShell-style help, run:  Get-Help .\dns-mod.ps1 -Full" -ForegroundColor DarkGray
    Write-Host ""
}

#----------------------------------------------------------------------
# 1. Recursive flattening of $RawArgs
#----------------------------------------------------------------------
function Expand-FlatArgs {
    param([object[]]$Items)

    $result = New-Object System.Collections.Generic.List[string]

    foreach ($item in $Items) {
        if ($null -eq $item) { continue }

        if ($item -is [System.Array]) {
            foreach ($sub in (Expand-FlatArgs -Items $item)) {
                $result.Add($sub)
            }
        }
        else {
            $result.Add([string]$item)
        }
    }

    return $result.ToArray()
}

#----------------------------------------------------------------------
# 2. Token re-merging (reattaches orphan tokens split by the comma
#    operator back onto the preceding --key=value token)
#----------------------------------------------------------------------
function Merge-SplitTokens {
    param([string[]]$Tokens)

    $merged = New-Object System.Collections.Generic.List[string]

    foreach ($token in $Tokens) {
        if ($token -match '^--') {
            $merged.Add($token)
        }
        else {
            if ($merged.Count -eq 0) {
                $merged.Add($token)
            }
            else {
                $lastIndex = $merged.Count - 1
                $merged[$lastIndex] = $merged[$lastIndex] + ',' + $token
            }
        }
    }

    return $merged.ToArray()
}

#----------------------------------------------------------------------
# 3. Raw argument parsing (supports --key=value style, plus -h/--help)
#----------------------------------------------------------------------
$ParsedArgs = @{}

$FlatArgs     = Expand-FlatArgs -Items $RawArgs
$MergedTokens = Merge-SplitTokens -Tokens $FlatArgs

foreach ($rawArg in $MergedTokens) {
    switch -Regex ($rawArg) {
        '^(-h|--help)$' {
            Show-HelpMenu
            exit 0
        }
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

if ($ParsedArgs.Count -eq 0) {
    Show-HelpMenu
    exit 0
}

$SetHostRaw         = $ParsedArgs['set-host']
$SetDelegationRaw   = $ParsedArgs['set-delegation']
$QueryHostRaw       = $ParsedArgs['query-host']
$QueryDelegationRaw = $ParsedArgs['query-delegation']
$ServerAll          = $ParsedArgs.ContainsKey('server-all')
$DnsServerExplicit  = $ParsedArgs.ContainsKey('server')
$DnsServerName      = if ($DnsServerExplicit) { $ParsedArgs['server'] } else { 'localhost' }

#----------------------------------------------------------------------
# 4. Pre-flight
#----------------------------------------------------------------------
function Write-Section($title) {
    Write-Host ""
    Write-Host "==== $title ====" -ForegroundColor Cyan
}

function Fail($msg) {
    Write-Host "ERROR: $msg" -ForegroundColor Red
    exit 1
}

Show-Banner

if (-not (Get-Module -ListAvailable -Name DnsServer)) {
    Fail "The 'DnsServer' PowerShell module is not available. Install RSAT: DNS Server Tools."
}
Import-Module DnsServer -ErrorAction Stop

if ($ServerAll -and $DnsServerExplicit) {
    Fail "--server and --server-all are mutually exclusive. Specify only one."
}

$IsQueryMode = [bool]($QueryHostRaw -or $QueryDelegationRaw)

if ($IsQueryMode -and -not $ServerAll -and -not $DnsServerExplicit) {
    Fail "Query mode (--query-host / --query-delegation) requires either --server=<dnsserver> or --server-all."
}

if (-not $IsQueryMode -and -not $SetHostRaw -and -not $SetDelegationRaw) {
    Write-Host "No actionable switches supplied." -ForegroundColor DarkYellow
    Show-HelpMenu
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

#----------------------------------------------------------------------
# 5. Helper: split an FQDN into (Label, ParentZone)
#----------------------------------------------------------------------
function Split-Fqdn {
    param([Parameter(Mandatory)][string]$Fqdn)

    $parts = $Fqdn -split '\.', 2
    if ($parts.Count -ne 2) {
        Fail "Cannot determine parent zone from FQDN '$Fqdn' (expected label.zone format)."
    }
    [PSCustomObject]@{
        Label      = $parts[0]
        ParentZone = $parts[1]
    }
}

#----------------------------------------------------------------------
# 6. Parse comma-separated FQDN lists (used by --query-host / --query-delegation)
#----------------------------------------------------------------------
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

#----------------------------------------------------------------------
# 7. Parse --set-host into a hashtable: FQDN -> IP  (for CREATE mode)
#----------------------------------------------------------------------
$SetHostMap = @{}

if ($SetHostRaw) {
    foreach ($entry in ([string]$SetHostRaw) -split ',') {
        $entry = $entry.Trim()
        if (-not $entry) { continue }
        if ($entry -notmatch '^(?<fqdn>[^_]+)_(?<ip>.+)$') {
            Fail "Invalid --set-host entry (expected fqdn_ip): $entry"
        }
        $fqdn = $Matches['fqdn']
        $ip   = $Matches['ip']
        if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
            Fail "Invalid IP address in --set-host entry: $entry"
        }
        $SetHostMap[$fqdn] = $ip
    }
}

#----------------------------------------------------------------------
# 8. Parse --set-delegation into: ChildFQDN -> @(NameServerFQDN, ...)  (CREATE)
#----------------------------------------------------------------------
$DelegationMap = @{}

if ($SetDelegationRaw) {
    foreach ($entry in ([string]$SetDelegationRaw) -split ',') {
        $entry = $entry.Trim()
        if (-not $entry) { continue }
        if ($entry -notmatch '^(?<child>[^_]+)_(?<ns>.+)$') {
            Fail "Invalid --set-delegation entry (expected childfqdn_nsfqdn): $entry"
        }
        $child = $Matches['child']
        $ns    = $Matches['ns']

        if (-not $DelegationMap.ContainsKey($child)) {
            $DelegationMap[$child] = @()
        }
        $DelegationMap[$child] += $ns
    }
}

#----------------------------------------------------------------------
# 9. Helper: resolve an IP for a name server using a fallback chain
#    (used during CREATE delegation; not used in query mode)
#----------------------------------------------------------------------
function Resolve-NameServerIP {
    param([string]$NsFqdn)

    if ($SetHostMap.ContainsKey($NsFqdn)) {
        return $SetHostMap[$NsFqdn]
    }

    try {
        $split = Split-Fqdn -Fqdn $NsFqdn
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

#----------------------------------------------------------------------
# 10. Helper: get existing delegation/NS entries for a child label
#     (merges Get-DnsServerZoneDelegation + plain NS records)
#----------------------------------------------------------------------
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

#----------------------------------------------------------------------
# 11. QUERY HELPERS
#----------------------------------------------------------------------

# Resolve the authoritative/root DNS server for a given zone, via normal
# DNS resolution (NS lookup, then A lookup of the first NS found).
# Returns a PSCustomObject { Name, IPAddress } or $null on failure.
function Resolve-ZoneRootServer {
    param([string]$Zone)

    try {
        $nsAnswers = Resolve-DnsName -Name $Zone -Type NS -ErrorAction Stop |
                     Where-Object { $_.Type -eq 'NS' }

        if (-not $nsAnswers) { return $null }

        $firstNs = ($nsAnswers | Select-Object -First 1).NameHost

        $aAnswer = Resolve-DnsName -Name $firstNs -Type A -ErrorAction SilentlyContinue |
                   Where-Object { $_.Type -eq 'A' } |
                   Select-Object -First 1

        return [PSCustomObject]@{
            Name      = $firstNs
            IPAddress = if ($aAnswer) { $aAnswer.IPAddress } else { $firstNs }
        }
    }
    catch {
        return $null
    }
}

# Resolve a single FQDN's IP address (used to find SSIP host IPs when
# querying delegated name servers directly).
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

# Perform an A record query against a specific server (by name or IP),
# returning the result set or $null on failure.
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

# Perform an NS record query against a specific server (by name or IP),
# returning the result set or $null on failure.
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

#----------------------------------------------------------------------
# 12. QUERY MODE: --query-host
#----------------------------------------------------------------------
function Invoke-QueryHost {
    param([string[]]$FqdnList)

    foreach ($fqdn in $FqdnList) {
        Write-Host ""
        Write-Host "Query (A): $fqdn" -ForegroundColor Yellow

        if ($ServerAll) {
            $split = Split-Fqdn -Fqdn $fqdn
            $root  = Resolve-ZoneRootServer -Zone $split.ParentZone

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

#----------------------------------------------------------------------
# 13. QUERY MODE: --query-delegation
#----------------------------------------------------------------------
function Invoke-QueryDelegation {
    param([string[]]$FqdnList)

    foreach ($fqdn in $FqdnList) {
        Write-Host ""
        Write-Host "Query (Delegation/NS): $fqdn" -ForegroundColor Yellow

        $split = Split-Fqdn -Fqdn $fqdn

        if ($ServerAll) {
            $root = Resolve-ZoneRootServer -Zone $split.ParentZone

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

#----------------------------------------------------------------------
# 14. CREATE MODE FUNCTIONS (host records + delegation)
#----------------------------------------------------------------------
function Show-HostRecordStatus {
    param([string]$Fqdn)

    $split = Split-Fqdn -Fqdn $Fqdn
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

    $split = Split-Fqdn -Fqdn $ChildFqdn
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

    $split = Split-Fqdn -Fqdn $Fqdn

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

    try {
        Add-DnsServerResourceRecordA -ZoneName $split.ParentZone `
                                      -Name $split.Label `
                                      -IPv4Address $IPAddress `
                                      -ComputerName $DnsServerName `
                                      -ErrorAction Stop
        Write-Host "Created host record: $Fqdn -> $IPAddress" -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to create host record '$Fqdn': $_" -ForegroundColor Red
    }
}

function New-DelegationIfNeeded {
    param(
        [string]$ChildFqdn,
        [string[]]$NameServers
    )

    $split = Split-Fqdn -Fqdn $ChildFqdn

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
                Write-Host "  Failed to add NS '$ns' (with glue) to delegation '$ChildFqdn': $_" -ForegroundColor Red
            }
        }
        else {
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
                Write-Host "  Failed to add NS '$ns' (no glue) to delegation '$ChildFqdn': $_" -ForegroundColor Red
            }
        }
    }
}

#----------------------------------------------------------------------
# 15. MAIN
#----------------------------------------------------------------------

if ($IsQueryMode) {

    Write-Section "DNS Query Results"

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

# ---- CREATE MODE ----

Write-Section "Current Configuration Report"

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

Write-Section "Applying Configuration"

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

Write-Section "Post-Change Verification"

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
