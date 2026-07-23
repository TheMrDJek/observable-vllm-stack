[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet("start", "stop", "status")]
    [string]$Action,

    [Parameter(Position = 1)]
    [ValidateSet("main", "alt")]
    [string]$Slot,

    [switch]$GpuMetrics
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Compose {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    & docker compose @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "docker compose failed with exit code $LASTEXITCODE."
    }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker CLI was not found in PATH."
}

$envPath = Join-Path $PSScriptRoot ".env"
if (-not (Test-Path $envPath)) {
    throw "Missing .env. Copy .env.example to .env and replace every CHANGE_ME value."
}

if ((Get-Content -Raw $envPath) -match "(?m)^[^#\r\n]*CHANGE_ME") {
    throw "The .env file still contains CHANGE_ME placeholders."
}

Push-Location $PSScriptRoot
try {
    switch ($Action) {
        "start" {
            if (-not $Slot) {
                throw "Specify a slot for start: main or alt."
            }

            Invoke-Compose -Arguments @(
                "--profile", "main",
                "--profile", "alt",
                "stop",
                "vllm-main",
                "vllm-alt"
            )

            $arguments = @("--profile", $Slot)
            if ($GpuMetrics) {
                $arguments += @("--profile", "gpu-metrics")
            }
            $arguments += @("up", "-d")

            Invoke-Compose -Arguments $arguments
            Write-Host "Model slot '$Slot' is starting in the background."
            Write-Host "Follow progress: docker compose --profile $Slot logs -f vllm-$Slot"
        }

        "stop" {
            Invoke-Compose -Arguments @(
                "--profile", "main",
                "--profile", "alt",
                "stop",
                "vllm-main",
                "vllm-alt"
            )
            Write-Host "Both vLLM slots are stopped. The rest of the stack is still running."
        }

        "status" {
            Invoke-Compose -Arguments @(
                "--profile", "main",
                "--profile", "alt",
                "--profile", "gpu-metrics",
                "ps"
            )
        }
    }
}
finally {
    Pop-Location
}
