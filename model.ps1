[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet("preflight", "start", "start-many", "stop", "status", "gateway", "observability")]
    [string]$Action,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Targets,

    [switch]$GpuMetrics
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Docker {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    # docker compose пишет прогресс в stderr. При $ErrorActionPreference = 'Stop'
    # PowerShell 5.1 превращает эти строки в терминирующие NativeCommandError,
    # как только вызывающий код перенаправляет или конвейеризует вывод, из-за
    # чего запуск вида '.\model.ps1 gateway internal *> log.txt' падал бы при
    # успешном выполнении. Решает только фактический код возврата.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & docker @Arguments
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($LASTEXITCODE -ne 0) {
        throw "docker $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function Invoke-Compose {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    Invoke-Docker -Arguments (@("compose") + $Arguments)
}

# Windows PowerShell 5.1 оборачивает каждую строку stderr нативной команды в
# ErrorRecord, что при $ErrorActionPreference = 'Stop' обрывает скрипт даже
# когда программа вернула код 0. Утилиты вроде 'caddy validate' пишут в stderr
# и при успехе, поэтому любой docker-вызов с захватом вывода идёт через эту функцию.
function Invoke-DockerCapture {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & docker @Arguments 2>&1
    }
    finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = @($output | ForEach-Object { [string]$_ })
    }
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

# Слоты определяются по профилям Compose, а не жёстко зашитым списком main/alt.
# Профили инфраструктуры исключаются, всё остальное считается слотом модели.
# Благодаря этому добавление третьего слота требует правки только compose.yaml
# и config/litellm.yaml — скрипты менять не нужно.
function Get-ModelSlots {
    $result = Invoke-DockerCapture -Arguments @("compose", "config", "--profiles")
    if ($result.ExitCode -ne 0) {
        throw "docker compose config --profiles failed: $($result.Output -join [Environment]::NewLine)"
    }
    $infrastructure = @("gateway", "local-observability", "telemetry", "gpu-metrics")
    return @($result.Output |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and ($_ -notin $infrastructure) })
}

function Assert-Targets {
    param([string[]]$Values, [int]$Minimum, [int]$Maximum)

    $slots = Get-ModelSlots
    $known = $slots -join ", "
    if ($null -eq $Values -or $Values.Count -lt $Minimum) {
        throw "Expected at least $Minimum slot argument(s). Available slots: $known."
    }
    if ($Maximum -gt 0 -and $Values.Count -gt $Maximum) {
        throw "Expected at most $Maximum slot argument(s). Available slots: $known."
    }
    foreach ($value in $Values) {
        if ($value -notin $slots) {
            throw "Unknown model slot '$value'. Available slots: $known."
        }
    }
    if (($Values | Select-Object -Unique).Count -ne $Values.Count) {
        throw "Model slots must not be repeated."
    }
}

function Get-SlotProfileArguments {
    $arguments = @()
    foreach ($slot in Get-ModelSlots) {
        $arguments += @("--profile", $slot)
    }
    return $arguments
}

function Stop-AllSlots {
    $slots = Get-ModelSlots
    if ($slots.Count -eq 0) { return }
    $arguments = Get-SlotProfileArguments
    $arguments += "stop"
    foreach ($slot in $slots) { $arguments += "vllm-$slot" }
    Invoke-Compose -Arguments $arguments
}

function Assert-NoTargets {
    param([string[]]$Values)

    if ($null -ne $Values -and $Values.Count -gt 0) {
        throw "Command '$Action' does not accept arguments."
    }
}

function Test-ComposeProfile {
    param([Parameter(Mandatory = $true)][string]$Profile)

    $result = Invoke-DockerCapture -Arguments @("compose", "config", "--profiles")
    if ($result.ExitCode -ne 0) {
        throw "docker compose config --profiles failed: $($result.Output -join [Environment]::NewLine)"
    }
    return $result.Output -contains $Profile
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

# Перезаписывает NAME=value прямо в .env, чтобы последующий обычный
# 'docker compose up' сохранил выбранный здесь режим. UTF-8 без BOM: BOM сломал
# бы первый ключ и для docker compose, и для model.sh.
function Set-DotEnvSetting {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $result = New-Object System.Collections.Generic.List[string]
    $replaced = $false
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        if ($line.TrimStart().StartsWith("$Name=")) {
            if (-not $replaced) {
                $result.Add("$Name=$Value")
                $replaced = $true
            }
        }
        else {
            $result.Add($line)
        }
    }
    if (-not $replaced) {
        $result.Add("$Name=$Value")
    }
    [IO.File]::WriteAllLines($Path, $result.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
}

function Test-CaddyConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][hashtable]$FileSettings
    )

    $version = Get-Setting -Name "CADDY_VERSION" -FileSettings $FileSettings
    if ([string]::IsNullOrWhiteSpace($version)) { $version = "2.10.2-alpine" }

    $certsDir = Get-Setting -Name "TLS_CERTS_DIR" -FileSettings $FileSettings
    if ([string]::IsNullOrWhiteSpace($certsDir)) { $certsDir = "./secrets/caddy" }
    if (-not [IO.Path]::IsPathRooted($certsDir)) {
        $certsDir = Join-Path $PSScriptRoot $certsDir
    }

    $arguments = @("run", "--rm")
    foreach ($name in @("PUBLIC_API_HOST", "PUBLIC_CHAT_HOST",
            "OLD_PUBLIC_API_HOST", "OLD_PUBLIC_CHAT_HOST",
            "TLS_CERT_FILE", "TLS_KEY_FILE")) {
        $value = Get-Setting -Name $name -FileSettings $FileSettings
        if ($null -eq $value) { $value = "" }
        $arguments += @("-e", "$name=$value")
    }
    # Монтируем ту же раскладку, что использует compose. Если смонтировать весь
    # каталог caddy как read-only, вложенную точку /etc/caddy/certs создать
    # невозможно, и docker завершится с ошибкой ещё до разбора конфигурации Caddy.
    $arguments += @("-v", "$(Join-Path $PSScriptRoot "caddy\Caddyfile.$Mode"):/etc/caddy/Caddyfile:ro")
    $arguments += @("-v", "$(Join-Path $PSScriptRoot 'caddy\routes.caddy'):/etc/caddy/routes.caddy:ro")
    if (Test-Path -LiteralPath $certsDir -PathType Container) {
        $arguments += @("-v", "${certsDir}:/etc/caddy/certs:ro")
    }
    $arguments += @("caddy:$version", "caddy", "validate",
        "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile")

    $result = Invoke-DockerCapture -Arguments $arguments
    if ($result.ExitCode -ne 0) {
        throw ("caddy/Caddyfile.$Mode did not pass 'caddy validate'. The gateway was not changed.`n" +
            ($result.Output -join [Environment]::NewLine))
    }
}

$script:PreflightFailures = 0

function Write-CheckOk { param([string]$Message) Write-Host "  [ ok ] $Message" }
function Write-CheckWarn { param([string]$Message) Write-Host "  [warn] $Message" }
function Write-CheckFail {
    param([string]$Message)
    Write-Host "  [FAIL] $Message"
    $script:PreflightFailures = $script:PreflightFailures + 1
}

function Test-PreflightGpu {
    $info = Invoke-DockerCapture -Arguments @("info", "--format", "{{json .Runtimes}}")
    if ($info.ExitCode -ne 0 -or (($info.Output -join "") -notmatch "nvidia")) {
        Write-CheckFail "NVIDIA runtime is not registered in Docker. Check Docker Desktop GPU support and the Windows NVIDIA driver."
        return
    }
    Write-CheckOk "NVIDIA runtime is registered in Docker."
    $probe = Invoke-DockerCapture -Arguments @(
        "run", "--rm", "--gpus", "all",
        "nvidia/cuda:12.9.0-base-ubuntu22.04", "nvidia-smi")
    if ($probe.ExitCode -eq 0) {
        Write-CheckOk "A container can reach the GPU."
    }
    else {
        Write-CheckFail "'docker run --gpus all ... nvidia-smi' failed. vLLM will not start until this works."
    }
}

function Test-PreflightDisk {
    try {
        $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($PSScriptRoot))
        $availableGb = [math]::Floor($drive.AvailableFreeSpace / 1GB)
    }
    catch {
        Write-CheckWarn "Free disk space could not be determined."
        return
    }
    if ($availableGb -lt 20) {
        Write-CheckFail "Only $availableGb GiB free. Images and one model cache need far more."
    }
    elseif ($availableGb -lt 60) {
        Write-CheckWarn "$availableGb GiB free. 60 GiB is recommended for images, model cache and telemetry."
    }
    else {
        Write-CheckOk "$availableGb GiB free on the stack drive."
    }
}

function Test-PreflightPort {
    param([Parameter(Mandatory = $true)][hashtable]$FileSettings)

    $port = Get-Setting -Name "PUBLIC_HTTPS_PORT" -FileSettings $FileSettings
    if ([string]::IsNullOrWhiteSpace($port)) { $port = "443" }

    $running = Invoke-DockerCapture -Arguments @(
        "compose", "--profile", "gateway", "ps", "--status", "running", "caddy")
    if ($running.ExitCode -eq 0 -and (($running.Output -join "`n") -match "caddy")) {
        Write-CheckOk "Port $port is held by this stack's Caddy."
        return
    }
    try {
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort ([int]$port) -ErrorAction Stop)
    }
    catch {
        Write-CheckWarn "Port $port was not checked (Get-NetTCPConnection is unavailable)."
        return
    }
    if ($listeners.Count -gt 0) {
        Write-CheckFail "Port $port is already in use. Free it or change PUBLIC_HTTPS_PORT."
    }
    else {
        Write-CheckOk "Port $port is free."
    }
}

function Test-PreflightHostnames {
    param([Parameter(Mandatory = $true)][hashtable]$FileSettings)

    foreach ($name in @("PUBLIC_API_HOST", "PUBLIC_CHAT_HOST")) {
        $value = Get-Setting -Name $name -FileSettings $FileSettings
        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-CheckFail "$name is empty."
            continue
        }
        try {
            [void][Net.Dns]::GetHostAddresses($value)
            Write-CheckOk "$name=$value resolves."
        }
        catch {
            Write-CheckWarn "$name=$value does not resolve yet. Add DNS or hosts entries before client testing."
        }
    }
}

function Test-PreflightModes {
    param([Parameter(Mandatory = $true)][hashtable]$FileSettings)

    $gatewayMode = Get-Setting -Name "GATEWAY_MODE" -FileSettings $FileSettings
    if ($gatewayMode -in @("external", "migration")) {
        try {
            Assert-TlsFiles -FileSettings $FileSettings
            Write-CheckOk "TLS certificate and key for gateway mode '$gatewayMode' are present."
        }
        catch {
            Write-CheckFail "GATEWAY_MODE=$gatewayMode but the files from TLS_CERTS_DIR are missing."
        }
    }

    $observabilityMode = Get-Setting -Name "OBSERVABILITY_MODE" -FileSettings $FileSettings
    if ($observabilityMode -eq "remote") {
        $missing = 0
        foreach ($name in @("REMOTE_METRICS_URL", "REMOTE_LOKI_URL", "REMOTE_TEMPO_ENDPOINT",
                "REMOTE_METRICS_TOKEN", "REMOTE_LOKI_TOKEN", "REMOTE_TEMPO_TOKEN")) {
            if ([string]::IsNullOrWhiteSpace((Get-Setting -Name $name -FileSettings $FileSettings))) {
                Write-CheckFail "OBSERVABILITY_MODE=remote but $name is empty."
                $missing = $missing + 1
            }
        }
        if ($missing -eq 0) {
            Write-CheckOk "Remote observability endpoints and tokens are set."
        }
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

if ((Invoke-DockerCapture -Arguments @("compose", "version")).ExitCode -ne 0) {
    throw "Docker Compose v2 is required ('docker compose')."
}

Push-Location $PSScriptRoot
try {
    switch ($Action) {
        "preflight" {
            Assert-NoTargets -Values $Targets
            Write-Host "Host preflight for the AI vLLM stack`n"
            Write-CheckOk "Docker CLI and Compose v2 are available."
            Write-CheckOk ".env exists and contains no CHANGE_ME placeholders."
            Test-PreflightGpu
            Test-PreflightDisk
            Test-PreflightPort -FileSettings $fileSettings
            Test-PreflightHostnames -FileSettings $fileSettings
            Test-PreflightModes -FileSettings $fileSettings
            Write-Host ""
            if ($script:PreflightFailures -gt 0) {
                throw "$($script:PreflightFailures) preflight check(s) failed. See docs/troubleshooting.md."
            }
            Write-Host "Preflight passed. Nothing was changed on the host."
        }

        "start" {
            Assert-Targets -Values $Targets -Minimum 1 -Maximum 1
            $slot = $Targets[0]
            Stop-AllSlots
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
            Assert-Targets -Values $Targets -Minimum 2 -Maximum 0
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
            Stop-AllSlots
            Write-Host "All vLLM slots are stopped. The rest of the stack is still running."
        }

        "status" {
            Assert-NoTargets -Values $Targets
            $statusArguments = Get-SlotProfileArguments
            $statusArguments += @(
                "--profile", "gpu-metrics",
                "--profile", "gateway",
                "--profile", "local-observability",
                "--profile", "telemetry",
                "ps"
            )
            Invoke-Compose -Arguments $statusArguments
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
            Test-CaddyConfig -Mode $mode -FileSettings $fileSettings
            $env:GATEWAY_MODE = $mode
            $env:CADDY_CONFIG_FILE = "./caddy/Caddyfile.$mode"
            Invoke-Compose -Arguments @("--profile", "gateway", "up", "-d", "caddy")
            Set-DotEnvSetting -Path $envPath -Name "GATEWAY_MODE" -Value $mode
            Set-DotEnvSetting -Path $envPath -Name "CADDY_CONFIG_FILE" -Value "./caddy/Caddyfile.$mode"
            Write-Host "Gateway mode '$mode' is active and recorded in .env."
        }

        "observability" {
            if ($null -eq $Targets -or $Targets.Count -ne 1 -or
                $Targets[0] -notin @("local", "remote", "off")) {
                throw "Usage: model.ps1 observability <local|remote|off>"
            }
            $mode = $Targets[0]
            if ($mode -eq "off") {
                Invoke-Compose -Arguments @(
                    "--profile", "local-observability",
                    "stop", "prometheus", "loki", "tempo", "grafana"
                )
                Invoke-Compose -Arguments @("--profile", "telemetry", "stop", "alloy")
                Set-DotEnvSetting -Path $envPath -Name "OBSERVABILITY_MODE" -Value "off"
                Write-Host "Telemetry is stopped. ALLOY_CONFIG_FILE was left unchanged."
                Write-Host "Applications keep serving and will log OTLP export errors until Alloy returns."
                Write-Host "Resume with: model.ps1 observability local|remote"
                break
            }
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
                $alloyConfig = "./observability/config.alloy"
                $env:ALLOY_CONFIG_FILE = $alloyConfig
                Invoke-Compose -Arguments @(
                    "--profile", "local-observability", "--profile", "telemetry", "up", "-d")
            }
            else {
                $remoteConfig = Join-Path $PSScriptRoot "observability\config.remote.alloy"
                if (-not (Test-Path -LiteralPath $remoteConfig -PathType Leaf)) {
                    throw "Remote observability requires observability/config.remote.alloy."
                }
                $alloyConfig = "./observability/config.remote.alloy"
                $env:ALLOY_CONFIG_FILE = $alloyConfig
                Invoke-Compose -Arguments @(
                    "--profile", "local-observability",
                    "stop", "prometheus", "loki", "tempo", "grafana"
                )
                Invoke-Compose -Arguments @("--profile", "telemetry", "up", "-d", "alloy")
            }
            Set-DotEnvSetting -Path $envPath -Name "OBSERVABILITY_MODE" -Value $mode
            Set-DotEnvSetting -Path $envPath -Name "ALLOY_CONFIG_FILE" -Value $alloyConfig
            Write-Host "Observability mode '$mode' is active and recorded in .env."
            Write-Host "Base services (postgres, litellm, open-webui, alloy) are up. Start a model next."
        }
    }
}
finally {
    Pop-Location
}
