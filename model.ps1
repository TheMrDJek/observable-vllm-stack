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
# когда программа вернула код 0. Утилиты вроде 'nginx -t' пишут в stderr
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
    # Обёртка @() обязательна: конвейер из одного элемента возвращает скаляр, а
    # не массив, и обращение к .Count на строке под Set-StrictMode -Version
    # Latest завершается PropertyNotFoundStrict. Это ломало любой 'start <слот>'
    # с одним аргументом, то есть основной сценарий.
    if (@($Values | Select-Object -Unique).Count -ne @($Values).Count) {
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

    $directory = Get-CertsDirectory -FileSettings $FileSettings
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

# Повторяет значения по умолчанию из compose.yaml. Валидация обязана видеть ту
# же конфигурацию, что и запуск, иначе .env без новых ключей прошёл бы nginx -t
# с пустыми путями к сертификату и упал уже на старте контейнера.
function Get-SettingOrDefault {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$FileSettings,
        [Parameter(Mandatory = $true)][string]$Default
    )

    $value = Get-Setting -Name $Name -FileSettings $FileSettings
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value
}

function Get-NginxImage {
    param([Parameter(Mandatory = $true)][hashtable]$FileSettings)

    $version = Get-SettingOrDefault -Name "NGINX_VERSION" -FileSettings $FileSettings -Default "1.29-alpine"
    return "nginxinc/nginx-unprivileged:$version"
}

function Get-GatewayTemplate {
    param([Parameter(Mandatory = $true)][string]$Mode)

    return "./nginx/templates/gateway.$Mode.conf.template"
}

function Get-CertsDirectory {
    param([Parameter(Mandatory = $true)][hashtable]$FileSettings)

    $certsDir = Get-SettingOrDefault -Name "TLS_CERTS_DIR" -FileSettings $FileSettings -Default "./secrets/tls"
    if (-not [IO.Path]::IsPathRooted($certsDir)) {
        $certsDir = Join-Path $PSScriptRoot $certsDir
    }
    return $certsDir
}

# У nginx нет аналога директивы 'tls internal' прежнего Caddy, поэтому
# сертификат локального CA выпускается здесь. Ключ CA переиспользуется, пока
# файл на месте: его смена обесценила бы trust store всех клиентов.
# Leaf покрывает все заполненные имена сразу, включая OLD_PUBLIC_*, — тогда
# переключение internal -> migration не требует отдельного выпуска.
function New-InternalCertificate {
    param([Parameter(Mandatory = $true)][hashtable]$FileSettings)

    $certsDir = Get-CertsDirectory -FileSettings $FileSettings
    if (-not (Test-Path -LiteralPath $certsDir -PathType Container)) {
        New-Item -ItemType Directory -Path $certsDir -Force | Out-Null
    }

    $names = @()
    foreach ($name in @("PUBLIC_API_HOST", "PUBLIC_CHAT_HOST",
            "OLD_PUBLIC_API_HOST", "OLD_PUBLIC_CHAT_HOST")) {
        $value = Get-Setting -Name $name -FileSettings $FileSettings
        if (-not [string]::IsNullOrWhiteSpace($value)) { $names += $value }
    }
    if ($names.Count -eq 0) {
        throw "No hostnames are set. The internal certificate cannot be issued."
    }

    $opensslVersion = Get-SettingOrDefault -Name "OPENSSL_VERSION" -FileSettings $FileSettings -Default "3.5.4"
    $arguments = @(
        "run", "--rm",
        "-e", "SAN_NAMES=$($names -join ' ')",
        "-e", "CERT_FILE=$(Get-SettingOrDefault -Name 'TLS_INTERNAL_CERT_FILE' -FileSettings $FileSettings -Default 'internal.crt')",
        "-e", "KEY_FILE=$(Get-SettingOrDefault -Name 'TLS_INTERNAL_KEY_FILE' -FileSettings $FileSettings -Default 'internal.key')",
        "-v", "${certsDir}:/certs",
        "-v", "$(Join-Path $PSScriptRoot 'nginx\internal-ca.sh'):/internal-ca.sh:ro",
        "--entrypoint", "/bin/sh",
        "alpine/openssl:$opensslVersion", "/internal-ca.sh"
    )

    $result = Invoke-DockerCapture -Arguments $arguments
    if ($result.ExitCode -ne 0) {
        throw ("Issuing the internal certificate failed. The gateway was not changed.`n" +
            ($result.Output -join [Environment]::NewLine))
    }
    Write-Host ($result.Output -join [Environment]::NewLine)
}

# nginx работает под UID 101 и читает ключ сам. Проверка вынесена отдельно от
# nginx -t только ради понятного сообщения: иначе оператор получил бы
# 'cannot load certificate key ... Permission denied' без объяснения причины.
function Assert-KeyReadableByNginx {
    param([Parameter(Mandatory = $true)][hashtable]$FileSettings)

    $certsDir = Get-CertsDirectory -FileSettings $FileSettings
    $keyFile = Get-Setting -Name "TLS_KEY_FILE" -FileSettings $FileSettings
    if ([string]::IsNullOrWhiteSpace($keyFile)) {
        throw "Missing required setting TLS_KEY_FILE."
    }

    $result = Invoke-DockerCapture -Arguments @(
        "run", "--rm", "--user", "101:101",
        "-v", "${certsDir}:/certs:ro",
        "--entrypoint", "/bin/sh",
        (Get-NginxImage -FileSettings $FileSettings),
        "-c", "test -r /certs/$keyFile"
    )
    if ($result.ExitCode -ne 0) {
        throw ("$keyFile is not readable by UID 101, under which nginx runs.`n" +
            "On Linux: sudo chown 0:101 '$certsDir/$keyFile' && sudo chmod 0640 '$certsDir/$keyFile'")
    }
}

# Прогоняется тот же образ, entrypoint, пользователь и раскладка томов, что и в
# compose, поэтому проверка ловит не только синтаксис, но и нечитаемые
# сертификаты. tmpfs на conf.d обязателен: туда entrypoint рендерит шаблоны.
function Test-NginxConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][hashtable]$FileSettings
    )

    $certsDir = Get-CertsDirectory -FileSettings $FileSettings

    $arguments = @(
        "run", "--rm", "--user", "101:101",
        "--tmpfs", "/etc/nginx/conf.d:mode=1777",
        "--tmpfs", "/tmp:mode=1777"
    )
    foreach ($name in @("PUBLIC_API_HOST", "PUBLIC_CHAT_HOST",
            "OLD_PUBLIC_API_HOST", "OLD_PUBLIC_CHAT_HOST")) {
        $value = Get-Setting -Name $name -FileSettings $FileSettings
        if ($null -eq $value) { $value = "" }
        $arguments += @("-e", "$name=$value")
    }
    $defaults = @{
        TLS_CERT_FILE             = "server.crt"
        TLS_KEY_FILE              = "server.key"
        TLS_INTERNAL_CERT_FILE    = "internal.crt"
        TLS_INTERNAL_KEY_FILE     = "internal.key"
        NGINX_CLIENT_MAX_BODY_SIZE = "0"
    }
    foreach ($name in $defaults.Keys) {
        $value = Get-SettingOrDefault -Name $name -FileSettings $FileSettings -Default $defaults[$name]
        $arguments += @("-e", "$name=$value")
    }
    $arguments += @("-e", 'NGINX_ENVSUBST_FILTER=^(PUBLIC_|OLD_PUBLIC_|TLS_|NGINX_CLIENT_)')
    $arguments += @("-v", "$(Join-Path $PSScriptRoot 'nginx\templates\common.conf.template'):/etc/nginx/templates/00-common.conf.template:ro")
    $arguments += @("-v", "$(Join-Path $PSScriptRoot "nginx\templates\gateway.$Mode.conf.template"):/etc/nginx/templates/10-gateway.conf.template:ro")
    $arguments += @("-v", "$(Join-Path $PSScriptRoot 'nginx\routes'):/etc/nginx/routes:ro")
    if (Test-Path -LiteralPath $certsDir -PathType Container) {
        $arguments += @("-v", "${certsDir}:/etc/nginx/certs:ro")
    }
    $arguments += @((Get-NginxImage -FileSettings $FileSettings), "nginx", "-t")

    $result = Invoke-DockerCapture -Arguments $arguments
    if ($result.ExitCode -ne 0) {
        throw ("$(Get-GatewayTemplate -Mode $Mode) did not pass 'nginx -t'. The gateway was not changed.`n" +
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
        "compose", "--profile", "gateway", "ps", "--status", "running", "nginx")
    if ($running.ExitCode -eq 0 -and (($running.Output -join "`n") -match "nginx")) {
        Write-CheckOk "Port $port is held by this stack's nginx."
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
                Invoke-Compose -Arguments @("--profile", "gateway", "ps", "nginx")
                break
            }
            if ($mode -in @("migration", "external")) {
                Assert-TlsFiles -FileSettings $fileSettings
                Assert-KeyReadableByNginx -FileSettings $fileSettings
            }
            if ($mode -eq "migration") {
                foreach ($name in @("OLD_PUBLIC_API_HOST", "OLD_PUBLIC_CHAT_HOST", "PUBLIC_API_HOST", "PUBLIC_CHAT_HOST")) {
                    Assert-NonEmptySetting -Name $name -FileSettings $fileSettings
                }
            }
            $template = Get-GatewayTemplate -Mode $mode
            $configPath = Join-Path $PSScriptRoot "nginx\templates\gateway.$mode.conf.template"
            if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
                throw "Missing nginx template for gateway mode '$mode': $configPath"
            }
            if (-not (Test-ComposeProfile -Profile "gateway")) {
                throw "compose.yaml does not define the expected 'gateway' profile."
            }
            # Выпуск сертификата идёт до валидации: в режимах internal и
            # migration nginx -t не пройдёт, пока файлов локального CA нет.
            if ($mode -in @("internal", "migration")) {
                New-InternalCertificate -FileSettings $fileSettings
            }
            Test-NginxConfig -Mode $mode -FileSettings $fileSettings
            $env:GATEWAY_MODE = $mode
            $env:NGINX_CONFIG_FILE = $template
            Invoke-Compose -Arguments @("--profile", "gateway", "up", "-d", "nginx")
            Set-DotEnvSetting -Path $envPath -Name "GATEWAY_MODE" -Value $mode
            Set-DotEnvSetting -Path $envPath -Name "NGINX_CONFIG_FILE" -Value $template
            Write-Host "Gateway mode '$mode' is active and recorded in .env."
            if ($mode -in @("internal", "migration")) {
                $certsDir = Get-SettingOrDefault -Name "TLS_CERTS_DIR" -FileSettings $fileSettings -Default "./secrets/tls"
                Write-Host "Install this root certificate into every client trust store: $certsDir/internal-ca.crt"
            }
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
