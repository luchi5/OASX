param([Parameter(Mandatory)][string]$Archive)
$ErrorActionPreference = 'Stop'
# This fixture runs only on a disposable Actions runner, with no OAS backend.
if ($env:GITHUB_ACTIONS -ne 'true' -or !$env:RUNNER_TEMP) { throw 'Native smoke test requires an isolated GitHub Actions runner' }
$scratch = Join-Path $env:RUNNER_TEMP ('oasx-smoke-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
Expand-Archive -LiteralPath $Archive -DestinationPath $scratch
$folders = @(Get-ChildItem -LiteralPath $scratch -Directory)
if ($folders.Count -ne 1) { throw 'Archive must contain one portable directory' }
$portable = $folders[0].FullName
$exe = Join-Path $portable 'app/oasx.exe'
$profile = Join-Path $portable 'profile-oasx/GetStorage.gs'
$stdout = Join-Path $scratch 'startup-stdout.txt'
$stderr = Join-Path $scratch 'startup-stderr.txt'
$process = $null
try {
    $process = Start-Process -FilePath $exe -ArgumentList '--skip-parent-console' -WorkingDirectory $portable -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    $started = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $process.Refresh()
        if ($process.HasExited) { throw "Client exited during startup: $($process.ExitCode)" }
        if ($process.MainWindowHandle -ne 0 -and (Test-Path -LiteralPath $profile)) { $started = $true; break }
    }
    if (!$started) {
        Write-Output "Window handle: $($process.MainWindowHandle); title: $($process.MainWindowTitle); expected profile exists: $(Test-Path -LiteralPath $profile)"
        Get-ChildItem -LiteralPath $scratch -File -Recurse | Where-Object { $_.Name -match '\.(gs|bak|txt)$' } | ForEach-Object { Write-Output $_.FullName }
        foreach ($capture in @($stdout, $stderr)) {
            if (Test-Path -LiteralPath $capture) { Get-Content -LiteralPath $capture -Tail 60 | Write-Output }
        }
        throw 'Client did not create a native window and fresh profile within 45 seconds'
    }
    Start-Sleep -Seconds 3
    $process.Refresh()
    if ($process.HasExited) { throw 'Client exited after startup' }
    $settings = Get-Content -LiteralPath $profile -Raw | ConvertFrom-Json
    if ($settings.address -ne '127.0.0.1:22289') { throw 'Unexpected default backend' }
    foreach ($key in @('autoDeploy', 'autoLoginAfterDeploy', 'launchAtStartup')) {
        if ($settings.$key -ne $false) { throw "Unsafe initial setting: $key" }
    }
    if (@($settings.autoScriptList).Count -ne 0) { throw 'Default profile starts tasks' }
    if ($settings.username -or $settings.password -or $settings.rootPathServer) { throw 'Default profile contains private connection data' }
    if ($settings.stopBackendOnExit -eq $true) { throw 'Backend shutdown must default off' }
    @{
        passed = $true
        native_window_created = $true
        fresh_profile_created = $true
        credentials_empty = $true
        automatic_actions_disabled = $true
        backend = 'none (disposable CI runner)'
        executable_version = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path (Split-Path -Parent $Archive) 'smoke-result.json') -Encoding utf8
} finally {
    if ($process -and !$process.HasExited) {
        $process.Refresh()
        if ($process.Path -ne $exe) { throw 'Refusing to stop a process outside this smoke fixture' }
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit()
    }
}
