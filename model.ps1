[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet("start", "start-many", "stop", "status", "gateway", "observability")]
    [string]$Action,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Targets,

    [switch]$GpuMetrics
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Docker {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    & docker @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "docker $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function Invoke-Compose {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    Invoke-Docker -Arguments (@("compose") + $Arguments)
}

function Read-DotEnv {
    param([Parameter(Mandatory = $true)][string]$Path)

    $settings = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith("#")) {
            continue
        }

        $separator = $trimmed.IndexOf("=")
        if ($separator -lt 1) {
            throw "Invalid .env line: '$line'. Expected NAME=value."
        }

        $name = $trimmed.Substring(0, $separator).Trim()
        $value = $trimmed.Substring($separator + 1).Trim()
        if ($value.Length -ge 2 -and
            (($value.StartsWith('"') -and $value.EndsWith('"')) -or
             ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $settings[$name] = $value
    }
    return $settings
}

function Get-Setting {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$FileSettings
    )

    $processValue = [Environment]::GetEnvironmentVariable($Name, "Process")
    if (-not [string]::IsNullOrEmpty($processValue)) {
        return $processValue
    }
    if ($FileSettings.ContainsKey($Name)) {
        return [string]$FileSettings[$Name]
    }
    return $null
}

function Assert-Targets {
    param([string[]]$Values, [int]$Minimum, [int]$Maximum)

    if ($null -eq $Values -or $Values.Count -lt $Minimum -or $Values.Count -gt $Maximum) {
        throw "Expected between $Minimum and $Maximum slot arguments: main or alt."
    }
    foreach ($value in $Values) {
        if ($value -notin @("main", "alt")) {
            throw "Unknown model slot '$value'. Allowed slots: main, alt."
        }
    }
    if (($Values | Select-Object -Unique).Count -ne $Values.Count) {
        throw "Model slots must not be repeated."
    }
}

function Assert-NoTargets {
    param([string[]]$Values)

    if ($null -ne $Values -and $Values.Count -gt 0) {
        throw "Command '$Action' does not accept arguments."
    }
}

function Test-ComposeProfile {
    param([Parameter(Mandatory = $true)][string]$Profile)

    $output = & docker compose config --profiles 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "docker compose config --profiles failed: $($output -join [Environment]::NewLine)"
    }
    return @($output) -contains $Profile
}

function Assert-TlsFiles {
    param([Parameter(Mandatory = $true)][hashtable]$FileSettings)

    $directory = Get-Setting -Name "TLS_CERTS_DIR" -FileSettings $FileSettings
    if ([string]::IsNullOrWhiteSpace($directory)) {
        throw "Missing required setting TLS_CERTS_DIR."
    }
    if (-not [IO.Path]::IsPathRooted($directory)) {
        $directory = Join-Path $PSScriptRoot $directory
    }
    foreach ($name in @("TLS_CERT_FILE", "TLS_KEY_FILE")) {
        $fileName = Get-Setting -Name $name -FileSettings $FileSettings
        if ([string]::IsNullOrWhiteSpace($fileName)) {
            throw "Missing required setting $name."
        }
        $path = if ([IO.Path]::IsPathRooted($fileName)) {
            $fileName
        }
        else {
            Join-Path $directory $fileName
        }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "$name points to a missing TLS file: $path"
        }
    }
}

function Assert-RemoteEndpoint {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$FileSettings
    )

    $value = Get-Setting -Name $Name -FileSettings $FileSettings
    $uri = $null
    if ([string]::IsNullOrWhiteSpace($value) -or
        -not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @("http", "https")) {
        throw "$Name must be an absolute http(s) endpoint."
    }
}

function Assert-NonEmptySetting {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$FileSettings
    )

    if ([string]::IsNullOrWhiteSpace((Get-Setting -Name $Name -FileSettings $FileSettings))) {
        throw "$Name must be set for remote observability."
    }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker CLI was not found in PATH."
}

$envPath = Join-Path $PSScriptRoot ".env"
if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
    throw "Missing .env. Copy .env.example to .env and replace every CHANGE_ME value."
}
$fileSettings = Read-DotEnv -Path $envPath
foreach ($entry in $fileSettings.GetEnumerator()) {
    if ([string]$entry.Value -match "CHANGE_ME") {
        throw "The .env setting $($entry.Key) still contains CHANGE_ME."
    }
}

& docker compose version *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Docker Compose v2 is required ('docker compose')."
}

Push-Location $PSScriptRoot
try {
    switch ($Action) {
        "start" {
            Assert-Targets -Values $Targets -Minimum 1 -Maximum 1
            $slot = $Targets[0]
            Invoke-Compose -Arguments @(
                "--profile", "main", "--profile", "alt",
                "stop", "vllm-main", "vllm-alt"
            )
            $arguments = @("--profile", $slot)
            if ($GpuMetrics) {
                $arguments += @("--profile", "gpu-metrics")
            }
            $arguments += @("up", "-d")
            Invoke-Compose -Arguments $arguments
            Write-Host "Model slot '$slot' is starting in the background."
            Write-Host "Follow progress: docker compose --profile $slot logs -f vllm-$slot"
        }

        "start-many" {
            Assert-Targets -Values $Targets -Minimum 2 -Maximum 2
            if ((Get-Setting -Name "ALLOW_CONCURRENT_MODELS" -FileSettings $fileSettings) -cne "true") {
                throw "start-many requires ALLOW_CONCURRENT_MODELS=true. No VRAM preflight is performed."
            }
            $arguments = @()
            foreach ($slot in $Targets) {
                $arguments += @("--profile", $slot)
            }
            if ($GpuMetrics) {
                $arguments += @("--profile", "gpu-metrics")
            }
            $arguments += @("up", "-d")
            Invoke-Compose -Arguments $arguments
            Write-Host "Requested model slots: $($Targets -join ', ')."
            Write-Host ("MAIN_VLLM_GPU_MEMORY_UTILIZATION={0}; ALT_VLLM_GPU_MEMORY_UTILIZATION={1}" -f `
                (Get-Setting -Name "MAIN_VLLM_GPU_MEMORY_UTILIZATION" -FileSettings $fileSettings), `
                (Get-Setting -Name "ALT_VLLM_GPU_MEMORY_UTILIZATION" -FileSettings $fileSettings))
            Write-Warning "Concurrent startup was explicitly enabled; available VRAM was not preflighted."
        }

        "stop" {
            Assert-NoTargets -Values $Targets
            Invoke-Compose -Arguments @(
                "--profile", "main", "--profile", "alt",
                "stop", "vllm-main", "vllm-alt"
            )
            Write-Host "Both vLLM slots are stopped. The rest of the stack is still running."
        }

        "status" {
            Assert-NoTargets -Values $Targets
            Invoke-Compose -Arguments @(
                "--profile", "main",
                "--profile", "alt",
                "--profile", "gpu-metrics",
                "--profile", "gateway",
                "--profile", "local-observability",
                "ps"
            )
        }

        "gateway" {
            if ($null -eq $Targets -or $Targets.Count -ne 1 -or
                $Targets[0] -notin @("internal", "migration", "external", "status")) {
                throw "Usage: model.ps1 gateway <internal|migration|external|status>"
            }
            $mode = $Targets[0]
            if ($mode -eq "status") {
                Invoke-Compose -Arguments @("--profile", "gateway", "ps", "caddy")
                break
            }
            if ($mode -in @("migration", "external")) {
                Assert-TlsFiles -FileSettings $fileSettings
            }
            if ($mode -eq "migration") {
                foreach ($name in @("OLD_PUBLIC_API_HOST", "OLD_PUBLIC_CHAT_HOST", "PUBLIC_API_HOST", "PUBLIC_CHAT_HOST")) {
                    Assert-NonEmptySetting -Name $name -FileSettings $fileSettings
                }
            }
            $configPath = Join-Path $PSScriptRoot "caddy\Caddyfile.$mode"
            if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
                throw "Missing Caddy config for gateway mode '$mode': $configPath"
            }
            if (-not (Test-ComposeProfile -Profile "gateway")) {
                throw "compose.yaml does not define the expected 'gateway' profile."
            }
            $env:GATEWAY_MODE = $mode
            $env:CADDY_CONFIG_FILE = "./caddy/Caddyfile.$mode"
            Invoke-Compose -Arguments @("--profile", "gateway", "up", "-d", "caddy")
        }

        "observability" {
            if ($null -eq $Targets -or $Targets.Count -ne 1 -or
                $Targets[0] -notin @("local", "remote")) {
                throw "Usage: model.ps1 observability <local|remote>"
            }
            $mode = $Targets[0]
            if ($mode -eq "remote") {
                Assert-RemoteEndpoint -Name "REMOTE_METRICS_URL" -FileSettings $fileSettings
                Assert-RemoteEndpoint -Name "REMOTE_LOKI_URL" -FileSettings $fileSettings
                Assert-RemoteEndpoint -Name "REMOTE_TEMPO_ENDPOINT" -FileSettings $fileSettings
                foreach ($name in @("REMOTE_METRICS_TOKEN", "REMOTE_LOKI_TOKEN", "REMOTE_TEMPO_TOKEN")) {
                    Assert-NonEmptySetting -Name $name -FileSettings $fileSettings
                }
            }
            $env:OBSERVABILITY_MODE = $mode
            if ($mode -eq "local") {
                if (-not (Test-ComposeProfile -Profile "local-observability")) {
                    throw "compose.yaml does not define the expected 'local-observability' profile."
                }
                $env:ALLOY_CONFIG_FILE = "./observability/config.alloy"
                Invoke-Compose -Arguments @("--profile", "local-observability", "up", "-d")
            }
            else {
                $remoteConfig = Join-Path $PSScriptRoot "observability\config.remote.alloy"
                if (-not (Test-Path -LiteralPath $remoteConfig -PathType Leaf)) {
                    throw "Remote observability requires observability/config.remote.alloy."
                }
                $env:ALLOY_CONFIG_FILE = "./observability/config.remote.alloy"
                Invoke-Compose -Arguments @(
                    "--profile", "local-observability",
                    "stop", "prometheus", "loki", "tempo", "grafana"
                )
                Invoke-Compose -Arguments @("up", "-d", "alloy")
            }
        }
    }
}
finally {
    Pop-Location
}
