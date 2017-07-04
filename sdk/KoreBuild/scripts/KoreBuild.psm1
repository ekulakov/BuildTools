#requires -version 4

Set-StrictMode -Version 2

if (Get-Command 'dotnet' -ErrorAction Ignore) {
    $global:dotnet = (Get-Command 'dotnet').Path
}

function Join-Paths($path, $childPaths) {
    $childPaths | ForEach-Object { $path = Join-Path $path $_ }
    return $path
}

### constants
Set-Variable 'IS_WINDOWS' -Scope Script -Option Constant -Value $((Get-Variable -Name IsWindows -ValueOnly -ErrorAction Ignore) -or !(Get-Variable -Name IsCoreClr -ValueOnly -ErrorAction Ignore))
Set-Variable 'EXE_EXT' -Scope Script -Option Constant -Value $(if ($IS_WINDOWS) { '.exe' } else { '' })

<#
.SYNOPSIS
Builds a repository

.DESCRIPTION
Invokes the default MSBuild lifecycle on a repostory. This will download any required tools.

.PARAMETER Path
The path to the repository to be compiled

.PARAMETER MSBuildArgs
Arguments to be passed to the main MSBuild invocation

.EXAMPLE
Invoke-RepositoryBuild $PSScriptRoot /p:Configuration=Release /t:Verify

.NOTES
This is the main function used by most repos.
#>
function Invoke-RepositoryBuild(
    [Parameter(Mandatory = $true)]
    [string] $Path,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $MSBuildArgs) {

    $ErrorActionPreference = 'Stop'

    $verbose = $false
    if ($PSCmdlet.MyInvocation.BoundParameters['Verbose']) {
        $verbose = $PSCmdlet.MyInvocation.BoundParameters['Verbose'].IsPresent
    }
    $Path = Resolve-Path $Path
    Push-Location $Path | Out-Null
    try {
        Write-Verbose "Building $Path"
        Write-Verbose "dotnet = ${global:dotnet}"

        $versionFile = Join-Paths $PSScriptRoot ('..', '.version')
        if (Test-Path $versionFile) {
            Write-Host -ForegroundColor Magenta "Using KoreBuild $(Get-Content $versionFile -Tail 1)"
        }

        # Generate global.json to ensure the repo uses the right SDK version
        "{ `"sdk`": { `"version`": `"$(__get_dotnet_sdk_version)`" } }" | Out-File (Join-Path $Path 'global.json') -Encoding ascii

        $makeFileProj = Join-Paths $PSScriptRoot ('..', 'KoreBuild.proj')
        $msbuildArtifactsDir = Join-Paths $Path ('artifacts', 'msbuild')
        $msBuildResponseFile = Join-Path $msbuildArtifactsDir msbuild.rsp

        $msBuildLogArgument = ""

        if ($verbose -or $env:KOREBUILD_ENABLE_BINARY_LOG -eq "1") {
            Write-Verbose 'Enabling binary logging'
            $msbuildLogFilePath = Join-Path $msbuildArtifactsDir msbuild.binlog
            $msBuildLogArgument = "/bl:$msbuildLogFilePath"
        }

        $msBuildArguments = @"
/nologo
/m
/p:RepositoryRoot="$Path/"
"$msBuildLogArgument"
/clp:Summary
"$makeFileProj"
"@

        $MSBuildArgs | ForEach-Object { $msBuildArguments += "`n`"$_`"" }

        if (!(Test-Path $msbuildArtifactsDir)) {
            New-Item -Type Directory $msbuildArtifactsDir | Out-Null
        }

        $msBuildArguments | Out-File -Encoding ASCII -FilePath $msBuildResponseFile

        __build_task_project $Path

        Write-Verbose "Invoking msbuild with '$(Get-Content $msBuildResponseFile)'"

        __exec $global:dotnet msbuild `@"$msBuildResponseFile"
    }
    finally {
        Pop-Location
    }
}

<#
.SYNOPSIS
Installs tools if required.

.PARAMETER ToolsSource
The base url where build tools can be downloaded.

.PARAMETER DotNetHome
The directory where tools will be stored on the local machine.
#>
function Install-Tools(
    [Parameter(Mandatory = $true)]
    [string]$ToolsSource,
    [Parameter(Mandatory = $true)]
    [string]$DotNetHome) {

    $ErrorActionPreference = 'Stop'
    if (!(Test-Path $DotNetHome)) {
        New-Item -ItemType Directory $DotNetHome | Out-Null
    }

    $DotNetHome = Resolve-Path $DotNetHome
    $installDir = if ($IS_WINDOWS) { Join-Path $DotNetHome 'x64' } else { $DotNetHome }
    $global:dotnet = Join-Path $installDir "dotnet$EXE_EXT"
    $env:PATH = "$(Split-Path -Parent $global:dotnet);$env:PATH"

    if ($env:KOREBUILD_SKIP_RUNTIME_INSTALL -eq "1") {
        Write-Host "Skipping runtime installation because KOREBUILD_SKIP_RUNTIME_INSTALL = 1"
        return
    }

    $scriptPath = `
        if ($IS_WINDOWS) { Join-Path $PSScriptRoot 'dotnet-install.ps1' } `
        else { Join-Path $PSScriptRoot 'dotnet-install.sh' }

    if (!$IS_WINDOWS) {
        & chmod +x $scriptPath
    }

    $channel = "preview"
    $runtimeChannel = "master"
    $version = __get_dotnet_sdk_version
    $runtimeVersion = Get-Content (Join-Paths $PSScriptRoot ('..', 'config', 'runtime.version'))

    if ($env:KOREBUILD_DOTNET_CHANNEL) {
        $channel = $env:KOREBUILD_DOTNET_CHANNEL
    }
    if ($env:KOREBUILD_DOTNET_SHARED_RUNTIME_CHANNEL) {
        $runtimeChannel = $env:KOREBUILD_DOTNET_SHARED_RUNTIME_CHANNEL
    }
    if ($env:KOREBUILD_DOTNET_SHARED_RUNTIME_VERSION) {
        $runtimeVersion = $env:KOREBUILD_DOTNET_SHARED_RUNTIME_VERSION
    }

    # Temporarily install these runtimes to prevent build breaks for repos not yet converted
    # 1.0.5 - for tools
    __install_shared_runtime $scriptPath $installDir -version "1.0.5" -channel "preview"
    # 1.1.2 - for test projects which haven't yet been converted to netcoreapp2.0
    __install_shared_runtime $scriptPath $installDir -version "1.1.2" -channel "release/1.1.0"

    if ($runtimeVersion) {
        __install_shared_runtime $scriptPath $installDir -version $runtimeVersion -channel $runtimeChannel
    }

    # Install the main CLI
    Write-Verbose "Installing dotnet $version to $installDir"
    & $scriptPath -Channel $channel `
        -Version $version `
        -Architecture x64 `
        -InstallDir $installDir

    try {
        # installs KoreBuild.SdkResolver
        # updates to this should be rare. But in the event it needs to change, we should invalidate the resolver with this file
        $bundledResolverVersion = Get-Content (Join-Paths $PSScriptRoot ('..', 'tools', 'KoreBuild.SdkResolver', 'dotnet', 'version.txt')) -ErrorAction Ignore

        if ($bundledResolverVersion) {
            $resolversDir = Join-Paths $installDir ('sdk', $version, 'SdkResolvers', 'KoreBuild.SdkResolver')
            $installedResolverVersion = Get-Content (Join-Path $resolversDir 'version.txt') -ErrorAction Ignore

            if ($installedResolverVersion -ne $bundledResolverVersion) {
                Write-Verbose "Installing KoreBuild SDK resolver $bundledResolverVersion into .NET Core SDK $version"
                New-Item -ItemType Directory $resolversDir -ErrorAction Ignore | Out-Null
                Copy-Item -Recurse (Join-Paths $PSScriptRoot ('..', 'tools', 'KoreBuild.SdkResolver', 'dotnet', '*')) $resolversDir
            }
        }
    } catch {
        Write-Warning "Failed to install the KoreBuild SDK resolver into $installDir."
    }
}

function __install_shared_runtime($installScript, $installDir, [string] $version, [string] $channel) {
    $sharedRuntimePath = Join-Paths $installDir ('shared', 'Microsoft.NETCore.App', $version)
    # Avoid redownloading the CLI if it's already installed.
    if (!(Test-Path $sharedRuntimePath)) {
        Write-Verbose "Installing .NET Core runtime $version"
        & $installScript -Channel $channel `
            -SharedRuntime `
            -Version $version `
            -Architecture x64 `
            -InstallDir $installDir
    }
}

function __get_dotnet_sdk_version {
    if ($env:KOREBUILD_DOTNET_VERSION) {
        return $env:KOREBUILD_DOTNET_VERSION
    }
    return Get-Content (Join-Paths $PSScriptRoot ('..', 'config', 'sdk.version'))
}

function __exec($cmd) {
    $cmdName = [IO.Path]::GetFileName($cmd)

    Write-Host -ForegroundColor Cyan ">>> $cmdName $args"
    $originalErrorPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $cmd @args
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $originalErrorPref
    if ($exitCode -ne 0) {
        Write-Error "$cmdName failed with exit code: $exitCode"
    }
    else {
        Write-Verbose "<<< $cmdName [$exitCode]"
    }
}

function __build_task_project($RepoPath) {
    $taskProj = Join-Paths $RepoPath ('build', 'tasks', 'RepoTasks.csproj')
    $publishFolder = Join-Paths $RepoPath ('build', 'tasks', 'bin', 'publish')

    if (!(Test-Path $taskProj)) {
        return
    }

    if (Test-Path $publishFolder) {
        Remove-Item $publishFolder -Recurse -Force
    }

    __exec $global:dotnet restore $taskProj
    __exec $global:dotnet publish $taskProj --configuration Release --output $publishFolder /nologo
}
