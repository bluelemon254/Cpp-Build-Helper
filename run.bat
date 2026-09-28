@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul

if "%~1"=="" goto usage

set "RUNBAT_SELF=%~f0"
set "RUNBAT_SELECTOR=%~1"
set "RUNBAT_RUN=0"
set "RUNBAT_GCC=0"
set "RUNBAT_EXTRA="
set "RUNBAT_EXCLUDES="
shift

:collect_options
if "%~1"=="" goto launch

if /i "%~1"=="-r" (
    set "RUNBAT_RUN=1"
    shift
    goto collect_options
)

if /i "%~1"=="-g" (
    set "RUNBAT_GCC=1"
    shift
    goto collect_options
)

if /i "%~1"=="-i" (
    if "%~2"=="" (
        echo Error: -i requires a file.
        goto usage
    )
    set "RUNBAT_EXTRA=%RUNBAT_EXTRA%|%~2"
    shift
    shift
    goto collect_options
)

rem For compatibility with the original interface, bare arguments exclude sources.
set "RUNBAT_EXCLUDES=%RUNBAT_EXCLUDES%|%~1"
shift
goto collect_options

:launch
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$c=[IO.File]::ReadAllText($env:RUNBAT_SELF);$m=':__POWERSHELL__';$i=$c.LastIndexOf($m,[StringComparison]::Ordinal);if($i-lt 0){throw 'Embedded runner was not found.'};$s=$c.Substring($i+$m.Length).TrimStart([char]13,[char]10);&([scriptblock]::Create($s))"
set "RUNBAT_EXIT=%ERRORLEVEL%"
endlocal & exit /b %RUNBAT_EXIT%

:usage
echo Usage:
echo   run.bat TARGET [-r] [-g] [-i FILE] [SOURCE_TO_EXCLUDE ...]
echo.
echo TARGET may be a directory, C/C++ source, .vcxproj, or .sln.
echo A non-literal path is resolved one component at a time as a regex.
echo.
echo Options:
echo   -r          Run the executable after a successful build
echo   -g          Use MinGW g++ instead of MSVC/MSBuild
echo   -i FILE     Add a source, object, or library to a direct build
echo.
echo Examples:
echo   run.bat .*1 -r
echo   run.bat .*1 -r -g -i a.c
endlocal
exit /b 1

:__POWERSHELL__
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$script:BaseDirectory = [IO.Path]::GetFullPath((Get-Location).Path)
$script:RunAfterBuild = $env:RUNBAT_RUN -eq '1'
$script:UseGcc = $env:RUNBAT_GCC -eq '1'
$script:SourceExtensions = @('.c', '.cc', '.cpp', '.cxx')
$script:HeaderExtensions = @('.h', '.hh', '.hpp', '.hxx')
$script:IgnoredDirectoryNames = @('.git', '.vs', 'Debug', 'Release', 'x64', 'Win32')
$script:VsInstallation = $null
$script:MSBuildPath = $null
$consoleWidth = 80
try {
    $detectedWidth = [Console]::WindowWidth
    if ($detectedWidth -gt 0) { $consoleWidth = $detectedWidth }
} catch {
    # Keep the 80-column fallback when no interactive console is attached.
}
$script:Separator = '=' * $consoleWidth

# Some launchers provide both PATH and Path entries. Newer MSBuild rejects that
# duplicate environment block when it starts cl.exe, so normalize it once.
$initialPath = [Environment]::GetEnvironmentVariable('PATH', 'Process')
[Environment]::SetEnvironmentVariable('Path', $null, 'Process')
[Environment]::SetEnvironmentVariable('PATH', $null, 'Process')
[Environment]::SetEnvironmentVariable('PATH', $initialPath, 'Process')

function Split-List([string] $Value) {
    if ([string]::IsNullOrEmpty($Value)) { return @() }
    return @($Value.Split('|') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

$script:ExtraArguments = @(Split-List $env:RUNBAT_EXTRA)
$script:ExcludeArguments = @(Split-List $env:RUNBAT_EXCLUDES)

function Get-ItemKind([IO.FileSystemInfo] $Item) {
    if ($Item.PSIsContainer) { return 'Directory' }
    switch ($Item.Extension.ToLowerInvariant()) {
        '.c'       { return 'Source' }
        '.cc'      { return 'Source' }
        '.cpp'     { return 'Source' }
        '.cxx'     { return 'Source' }
        '.vcxproj' { return 'Project' }
        '.sln'     { return 'Solution' }
        default    { return 'Unsupported' }
    }
}

function Resolve-Target([string] $Selector) {
    $literal = $null
    try {
        $literal = if ([IO.Path]::IsPathRooted($Selector)) {
            [IO.Path]::GetFullPath($Selector)
        } else {
            [IO.Path]::GetFullPath((Join-Path $script:BaseDirectory $Selector))
        }
    } catch [ArgumentException] {
        # Regex selectors can contain characters which are illegal in literal paths.
    }

    if ($literal -and (Test-Path -LiteralPath $literal)) {
        $item = Get-Item -LiteralPath $literal -Force
        if ((Get-ItemKind $item) -eq 'Unsupported') {
            throw "Unsupported target type: $($item.FullName)"
        }
        return $item
    }

    $parts = @($Selector.Replace('/', '\').Split('\') | Where-Object { $_ -ne '' })
    if ($parts.Count -eq 0) { throw 'The target is empty.' }

    $current = Get-Item -LiteralPath $script:BaseDirectory
    for ($index = 0; $index -lt $parts.Count; $index++) {
        try {
            $regex = New-Object Text.RegularExpressions.Regex(
                ('^(?:' + $parts[$index] + ')$'),
                [Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
        } catch {
            throw "Invalid regex component '$($parts[$index])': $($_.Exception.Message)"
        }

        $last = $index -eq ($parts.Count - 1)
        $matches = @(Get-ChildItem -LiteralPath $current.FullName -Force | Where-Object {
            ($_.PSIsContainer -or ($last -and (Get-ItemKind $_) -ne 'Unsupported')) -and
            $regex.IsMatch($_.Name)
        })

        if ($matches.Count -eq 0) {
            throw "No target matches '$($parts[$index])' under '$($current.FullName)'."
        }
        if ($matches.Count -gt 1) {
            $names = ($matches | ForEach-Object Name | Sort-Object) -join ', '
            throw "Target component '$($parts[$index])' is ambiguous under '$($current.FullName)': $names"
        }
        $current = $matches[0]
    }
    return $current
}

function Test-IgnoredPath([string] $Root, [string] $Path) {
    $relative = $Path.Substring($Root.TrimEnd('\').Length).TrimStart('\')
    if ($relative -eq '') { return $false }
    $segments = @($relative.Split('\'))
    for ($i = 0; $i -lt $segments.Count - 1; $i++) {
        if ($script:IgnoredDirectoryNames -icontains $segments[$i]) { return $true }
    }
    return $false
}

function Get-FilesByExtension([string] $Root, [string[]] $Extensions) {
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Where-Object {
        ($Extensions -icontains $_.Extension) -and -not (Test-IgnoredPath $Root $_.FullName)
    })
}

function Get-DisplayPath([string] $Root, [string] $Path) {
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($fullPath -ieq $fullRoot) { return '.' }

    $rootPrefix = $fullRoot + '\'
    if ($fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath.Substring($rootPrefix.Length)
    }

    $base = $script:BaseDirectory.TrimEnd('\')
    $basePrefix = $base + '\'
    if ($fullPath.StartsWith($basePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath.Substring($basePrefix.Length)
    }
    return $fullPath
}

function Write-DisplayList([object[]] $Items, [string] $Root) {
    $paths = @($Items | ForEach-Object {
        if ($_ -is [IO.FileSystemInfo]) {
            $_.FullName
        } elseif ($null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string] $_)) {
            [IO.Path]::GetFullPath([string] $_)
        }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

    if ($paths.Count -eq 0) {
        Write-Host '  [none]'
        return
    }
    foreach ($path in $paths) {
        Write-Host ('  ' + (Get-DisplayPath $Root $path))
    }
}

function Write-BuildLayout(
    [string] $Root,
    [string] $Compiler,
    [object[]] $Sources,
    [object[]] $Headers,
    [object[]] $Projects,
    [string] $Solution,
    [object[]] $Libraries
) {
    Write-Host ('Directory: ' + (Get-DisplayPath $script:BaseDirectory $Root))
    Write-Host "Compiler: $Compiler"

    Write-Host ''
    Write-Host 'Sources:'
    Write-DisplayList $Sources $Root

    Write-Host ''
    Write-Host 'Headers:'
    Write-DisplayList $Headers $Root

    Write-Host ''
    Write-Host 'Visual Studio projects:'
    Write-DisplayList $Projects $Root

    Write-Host ''
    Write-Host 'Visual Studio solution:'
    if ([string]::IsNullOrWhiteSpace($Solution)) {
        Write-Host '  [none]'
    } else {
        Write-Host ('  ' + (Get-DisplayPath $Root $Solution))
    }

    Write-Host ''
    Write-Host 'Libraries:'
    Write-DisplayList $Libraries $Root
    Write-Host ''
}

function Test-IsExcluded([IO.FileInfo] $File, [string] $Root) {
    foreach ($exclude in $script:ExcludeArguments) {
        $normalized = $exclude.Replace('/', '\').TrimStart('.', '\')
        $relative = $File.FullName.Substring($Root.TrimEnd('\').Length).TrimStart('\')
        if ($File.Name -ieq $exclude -or $relative -ieq $normalized -or $File.FullName -ieq $exclude) {
            return $true
        }
    }
    return $false
}

function Test-HasEntryPoint([IO.FileInfo] $File) {
    $text = [IO.File]::ReadAllText($File.FullName)
    $text = [Text.RegularExpressions.Regex]::Replace($text, '(?s)/\*.*?\*/', ' ')
    $text = [Text.RegularExpressions.Regex]::Replace($text, '(?m)//.*$', ' ')
    return [Text.RegularExpressions.Regex]::IsMatch(
        $text,
        '(?<![A-Za-z0-9_])(?:main|wmain|WinMain|wWinMain)\s*\('
    )
}

function Resolve-AdditionalFile([string] $Value, [string] $SelectedRoot) {
    $candidates = @()
    if ([IO.Path]::IsPathRooted($Value)) {
        $candidates += $Value
    } else {
        $candidates += (Join-Path $script:BaseDirectory $Value)
        if ($SelectedRoot -ine $script:BaseDirectory) {
            $candidates += (Join-Path $SelectedRoot $Value)
        }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return Get-Item -LiteralPath $candidate
        }
    }
    throw "Additional file does not exist: $Value"
}

function Get-ProjectType([string] $ProjectPath) {
    try {
        [xml] $xml = [IO.File]::ReadAllText($ProjectPath)
        $values = @($xml.SelectNodes("//*[local-name()='ConfigurationType']") | ForEach-Object InnerText)
        if ($values -icontains 'Application') { return 'Application' }
        if ($values -icontains 'StaticLibrary') { return 'StaticLibrary' }
        if ($values.Count -gt 0) { return $values[0] }
    } catch {
        throw "Could not read Visual Studio project '$ProjectPath': $($_.Exception.Message)"
    }
    return ''
}

function Test-IsRunBatGeneratedProject([string] $ProjectPath) {
    try {
        [xml] $document = [IO.File]::ReadAllText($ProjectPath)
        $node = @($document.SelectNodes("//*[local-name()='RunBatGenerated']"))[0]
        return $node -and $node.InnerText -ieq 'true'
    } catch {
        return $false
    }
}

function Add-ProjectElement(
    [Xml.XmlDocument] $Document,
    [Xml.XmlElement] $Parent,
    [string] $Name,
    [AllowNull()] [string] $Value
) {
    $element = $Document.CreateElement($Name, $Document.DocumentElement.NamespaceURI)
    if ($null -ne $Value) { $element.InnerText = $Value }
    [void] $Parent.AppendChild($element)
    return $element
}

function Get-RelativeProjectPath([string] $BaseDirectory, [string] $Path) {
    $fullBase = [IO.Path]::GetFullPath($BaseDirectory).TrimEnd('\')
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($fullPath -ieq $fullBase) { return '.' }
    $base = $fullBase + '\'
    $baseUri = New-Object Uri($base)
    $pathUri = New-Object Uri($fullPath)
    return [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($pathUri).ToString()).Replace('/', '\')
}

function New-RunBatProject(
    [string] $ProjectPath,
    [object[]] $Sources,
    [object[]] $Headers,
    [object[]] $IncludeDirectories,
    [object[]] $LinkFiles,
    [bool] $UsesFreeglut,
    [bool] $NeedsFreeglutAdapter,
    $MsysFreeglut
) {
    $projectDirectory = [IO.Path]::GetDirectoryName($ProjectPath)
    $projectName = [IO.Path]::GetFileNameWithoutExtension($ProjectPath)
    $projectGuid = if (Test-Path -LiteralPath $ProjectPath) {
        Get-ProjectGuidForSolution $ProjectPath
    } else {
        [guid]::NewGuid().ToString('B').ToUpperInvariant()
    }
    $namespace = 'http://schemas.microsoft.com/developer/msbuild/2003'
    $document = New-Object Xml.XmlDocument
    $declaration = $document.CreateXmlDeclaration('1.0', 'utf-8', $null)
    [void] $document.AppendChild($declaration)
    $project = $document.CreateElement('Project', $namespace)
    $project.SetAttribute('DefaultTargets', 'Build')
    $project.SetAttribute('ToolsVersion', 'Current')
    [void] $document.AppendChild($project)

    $configurations = Add-ProjectElement $document $project 'ItemGroup' $null
    $configurations.SetAttribute('Label', 'ProjectConfigurations')
    foreach ($configuration in @('Debug', 'Release')) {
        $item = Add-ProjectElement $document $configurations 'ProjectConfiguration' $null
        $item.SetAttribute('Include', "$configuration|x64")
        [void] (Add-ProjectElement $document $item 'Configuration' $configuration)
        [void] (Add-ProjectElement $document $item 'Platform' 'x64')
    }

    $globals = Add-ProjectElement $document $project 'PropertyGroup' $null
    $globals.SetAttribute('Label', 'Globals')
    [void] (Add-ProjectElement $document $globals 'Keyword' 'Win32Proj')
    [void] (Add-ProjectElement $document $globals 'ProjectGuid' $projectGuid)
    [void] (Add-ProjectElement $document $globals 'RootNamespace' $projectName)
    [void] (Add-ProjectElement $document $globals 'RunBatGenerated' 'true')

    $import = Add-ProjectElement $document $project 'Import' $null
    $import.SetAttribute('Project', '$(VCTargetsPath)\Microsoft.Cpp.Default.props')

    foreach ($configuration in @('Debug', 'Release')) {
        $condition = [string]::Format("'{0}'=='{1}|x64'", '$(Configuration)|$(Platform)', $configuration)
        $properties = Add-ProjectElement $document $project 'PropertyGroup' $null
        $properties.SetAttribute('Condition', $condition)
        $properties.SetAttribute('Label', 'Configuration')
        [void] (Add-ProjectElement $document $properties 'ConfigurationType' 'Application')
        [void] (Add-ProjectElement $document $properties 'UseDebugLibraries' $(if ($configuration -eq 'Debug') { 'true' } else { 'false' }))
        [void] (Add-ProjectElement $document $properties 'WholeProgramOptimization' 'false')
        [void] (Add-ProjectElement $document $properties 'PlatformToolset' '$(DefaultPlatformToolset)')
        [void] (Add-ProjectElement $document $properties 'CharacterSet' 'Unicode')
        if ($UsesFreeglut -and $MsysFreeglut) {
            [void] (Add-ProjectElement $document $properties 'LocalDebuggerEnvironment' ('PATH=' + $MsysFreeglut.Bin + ';$(PATH)'))
            [void] (Add-ProjectElement $document $properties 'DebuggerFlavor' 'WindowsLocalDebugger')
        }
    }

    $import = Add-ProjectElement $document $project 'Import' $null
    $import.SetAttribute('Project', '$(VCTargetsPath)\Microsoft.Cpp.props')
    $extensionSettings = Add-ProjectElement $document $project 'ImportGroup' $null
    $extensionSettings.SetAttribute('Label', 'ExtensionSettings')
    $shared = Add-ProjectElement $document $project 'ImportGroup' $null
    $shared.SetAttribute('Label', 'Shared')
    foreach ($configuration in @('Debug', 'Release')) {
        $condition = [string]::Format("'{0}'=='{1}|x64'", '$(Configuration)|$(Platform)', $configuration)
        $propertySheets = Add-ProjectElement $document $project 'ImportGroup' $null
        $propertySheets.SetAttribute('Label', 'PropertySheets')
        $propertySheets.SetAttribute('Condition', $condition)
        $sheet = Add-ProjectElement $document $propertySheets 'Import' $null
        $sheet.SetAttribute('Project', '$(UserRootDir)\Microsoft.Cpp.$(Platform).user.props')
        $sheet.SetAttribute('Condition', 'exists(''$(UserRootDir)\Microsoft.Cpp.$(Platform).user.props'')')
        $sheet.SetAttribute('Label', 'LocalAppDataPlatform')
    }
    $userMacros = Add-ProjectElement $document $project 'PropertyGroup' $null
    $userMacros.SetAttribute('Label', 'UserMacros')

    $outputProperties = Add-ProjectElement $document $project 'PropertyGroup' $null
    [void] (Add-ProjectElement $document $outputProperties 'OutDir' '$(ProjectDir)')
    [void] (Add-ProjectElement $document $outputProperties 'IntDir' '$(LOCALAPPDATA)\runbat\$(ProjectGuid)\$(Configuration)\')

    $includeValues = New-Object 'Collections.Generic.List[string]'
    foreach ($directory in @($IncludeDirectories | Select-Object -Unique)) {
        if ($null -eq $directory) { continue }
        $fullDirectory = [IO.Path]::GetFullPath([string] $directory)
        if ($fullDirectory.StartsWith($projectDirectory.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $fullDirectory -ieq $projectDirectory) {
            $includeValues.Add((Get-RelativeProjectPath $projectDirectory $fullDirectory))
        } else {
            $includeValues.Add($fullDirectory)
        }
    }
    if ($NeedsFreeglutAdapter) { $includeValues.Insert(0, '$(IntDir)runbat_include') }
    $includeValues.Add('%(AdditionalIncludeDirectories)')

    $dependencies = New-Object 'Collections.Generic.List[string]'
    foreach ($file in @($LinkFiles | Select-Object -Unique)) {
        if ($null -eq $file) { continue }
        $filePath = if ($file -is [IO.FileSystemInfo]) { $file.FullName } else { [string] $file }
        $dependencies.Add([IO.Path]::GetFullPath($filePath))
    }
    if ($UsesFreeglut) {
        $dependencies.Add('opengl32.lib')
        $dependencies.Add('glu32.lib')
        $dependencies.Add('gdi32.lib')
        $dependencies.Add('winmm.lib')
        $dependencies.Add('user32.lib')
    }
    $dependencies.Add('%(AdditionalDependencies)')

    foreach ($configuration in @('Debug', 'Release')) {
        $condition = [string]::Format("'{0}'=='{1}|x64'", '$(Configuration)|$(Platform)', $configuration)
        $definitions = Add-ProjectElement $document $project 'ItemDefinitionGroup' $null
        $definitions.SetAttribute('Condition', $condition)
        $compile = Add-ProjectElement $document $definitions 'ClCompile' $null
        [void] (Add-ProjectElement $document $compile 'WarningLevel' 'Level3')
        [void] (Add-ProjectElement $document $compile 'SDLCheck' 'true')
        [void] (Add-ProjectElement $document $compile 'ConformanceMode' 'true')
        [void] (Add-ProjectElement $document $compile 'ExceptionHandling' 'Sync')
        [void] (Add-ProjectElement $document $compile 'LanguageStandard' 'stdcpp17')
        [void] (Add-ProjectElement $document $compile 'AdditionalOptions' '/utf-8 %(AdditionalOptions)')
        [void] (Add-ProjectElement $document $compile 'AdditionalIncludeDirectories' ($includeValues -join ';'))
        [void] (Add-ProjectElement $document $compile 'RuntimeLibrary' $(if ($configuration -eq 'Debug') { 'MultiThreadedDebugDLL' } else { 'MultiThreadedDLL' }))
        if ($UsesFreeglut) {
            [void] (Add-ProjectElement $document $compile 'PreprocessorDefinitions' 'FREEGLUT_LIB_PRAGMAS=0;%(PreprocessorDefinitions)')
        }
        $link = Add-ProjectElement $document $definitions 'Link' $null
        [void] (Add-ProjectElement $document $link 'SubSystem' 'Console')
        [void] (Add-ProjectElement $document $link 'GenerateDebugInformation' 'true')
        [void] (Add-ProjectElement $document $link 'ProgramDatabaseFile' '$(IntDir)$(TargetName).pdb')
        [void] (Add-ProjectElement $document $link 'AdditionalOptions' '/ILK:"$(IntDir)$(TargetName).ilk" %(AdditionalOptions)')
        [void] (Add-ProjectElement $document $link 'AdditionalDependencies' ($dependencies -join ';'))
    }

    $sourceGroup = Add-ProjectElement $document $project 'ItemGroup' $null
    foreach ($source in @($Sources | Sort-Object FullName -Unique)) {
        $item = Add-ProjectElement $document $sourceGroup 'ClCompile' $null
        $item.SetAttribute('Include', (Get-RelativeProjectPath $projectDirectory $source.FullName))
    }
    if (@($Headers).Count -gt 0) {
        $headerGroup = Add-ProjectElement $document $project 'ItemGroup' $null
        foreach ($header in @($Headers | Sort-Object FullName -Unique)) {
            $item = Add-ProjectElement $document $headerGroup 'ClInclude' $null
            $item.SetAttribute('Include', (Get-RelativeProjectPath $projectDirectory $header.FullName))
        }
    }

    $import = Add-ProjectElement $document $project 'Import' $null
    $import.SetAttribute('Project', '$(VCTargetsPath)\Microsoft.Cpp.targets')
    if ($NeedsFreeglutAdapter -and $MsysFreeglut) {
        $adapterTarget = Add-ProjectElement $document $project 'Target' $null
        $adapterTarget.SetAttribute('Name', 'RunBatFreeglutCompatibility')
        $adapterTarget.SetAttribute('BeforeTargets', 'ClCompile')
        $freeglutHeaderPath = $MsysFreeglut.Header.FullName.Replace('\', '/')
        $glutHeaderPath = (Join-Path $MsysFreeglut.Header.Directory.FullName 'glut.h').Replace('\', '/')
        foreach ($layout in @('freeglut', 'GL')) {
            $adapterDirectory = '$(IntDir)runbat_include\' + $layout
            $makeDirectory = Add-ProjectElement $document $adapterTarget 'MakeDir' $null
            $makeDirectory.SetAttribute('Directories', $adapterDirectory)
            $freeglutHeader = Add-ProjectElement $document $adapterTarget 'WriteLinesToFile' $null
            $freeglutHeader.SetAttribute('File', $adapterDirectory + '\freeglut.h')
            $freeglutHeader.SetAttribute('Lines', ('#include "' + $freeglutHeaderPath + '"'))
            $freeglutHeader.SetAttribute('Overwrite', 'true')
            $glutHeader = Add-ProjectElement $document $adapterTarget 'WriteLinesToFile' $null
            $glutHeader.SetAttribute('File', $adapterDirectory + '\glut.h')
            $glutHeader.SetAttribute('Lines', ('#include "' + $glutHeaderPath + '"'))
            $glutHeader.SetAttribute('Overwrite', 'true')
        }
    }
    $extensionTargets = Add-ProjectElement $document $project 'ImportGroup' $null
    $extensionTargets.SetAttribute('Label', 'ExtensionTargets')

    $settings = New-Object Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.Encoding = New-Object Text.UTF8Encoding($false)
    $writer = [Xml.XmlWriter]::Create($ProjectPath, $settings)
    try { $document.Save($writer) } finally { $writer.Dispose() }
    return [pscustomobject]@{ Path = $ProjectPath; Guid = $projectGuid }
}

function Get-ProjectGuidForSolution([string] $ProjectPath) {
    try {
        [xml] $document = [IO.File]::ReadAllText($ProjectPath)
        $node = @($document.SelectNodes("//*[local-name()='ProjectGuid']"))[0]
        $parsedGuid = [guid]::Empty
        if ($node -and [guid]::TryParse($node.InnerText, [ref] $parsedGuid)) {
            return ([guid] $node.InnerText).ToString('B').ToUpperInvariant()
        }
    } catch {
        throw "Could not read Visual Studio project '$ProjectPath': $($_.Exception.Message)"
    }
    return [guid]::NewGuid().ToString('B').ToUpperInvariant()
}

function Get-SolutionProjectMapping([string] $ProjectPath, [string] $Configuration) {
    [xml] $document = [IO.File]::ReadAllText($ProjectPath)
    $pairs = @($document.SelectNodes("//*[local-name()='ProjectConfiguration']") | ForEach-Object {
        $_.GetAttribute('Include')
    } | Where-Object { $_ -match '\|' } | Select-Object -Unique)
    if ($pairs.Count -eq 0) { return "$Configuration|x64" }
    $mapping = @($pairs | Where-Object { $_ -ieq "$Configuration|x64" })[0]
    if (-not $mapping) { $mapping = @($pairs | Where-Object { $_ -imatch ('^' + [regex]::Escape($Configuration) + '\|') })[0] }
    if (-not $mapping) { $mapping = @($pairs | Where-Object { $_ -imatch '\|x64$' })[0] }
    if (-not $mapping) { $mapping = $pairs[0] }
    return $mapping
}

function New-RunBatSolution([string] $SolutionPath, [object[]] $Projects) {
    $solutionDirectory = [IO.Path]::GetDirectoryName($SolutionPath)
    $items = @($Projects | Sort-Object FullName -Unique | ForEach-Object {
        [pscustomobject]@{
            Name = $_.BaseName
            Path = (Get-RelativeProjectPath $solutionDirectory $_.FullName)
            Guid = (Get-ProjectGuidForSolution $_.FullName)
            FullName = $_.FullName
        }
    })
    $builder = New-Object Text.StringBuilder
    [void] $builder.AppendLine('Microsoft Visual Studio Solution File, Format Version 12.00')
    [void] $builder.AppendLine('# Visual Studio Version 17')
    [void] $builder.AppendLine('VisualStudioVersion = 17.0.31903.59')
    [void] $builder.AppendLine('MinimumVisualStudioVersion = 10.0.40219.1')
    $cppProjectType = '{8BC9CEB8-8B4A-11D0-8D11-00A0C91BC942}'
    foreach ($item in $items) {
        [void] $builder.AppendLine(('Project("' + $cppProjectType + '") = "' + $item.Name + '", "' + $item.Path + '", "' + $item.Guid + '"'))
        [void] $builder.AppendLine('EndProject')
    }
    [void] $builder.AppendLine('Global')
    [void] $builder.AppendLine('    GlobalSection(SolutionConfigurationPlatforms) = preSolution')
    foreach ($configuration in @('Debug', 'Release')) {
        [void] $builder.AppendLine("        $configuration|x64 = $configuration|x64")
    }
    [void] $builder.AppendLine('    EndGlobalSection')
    [void] $builder.AppendLine('    GlobalSection(ProjectConfigurationPlatforms) = postSolution')
    foreach ($item in $items) {
        foreach ($configuration in @('Debug', 'Release')) {
            $mapping = Get-SolutionProjectMapping $item.FullName $configuration
            [void] $builder.AppendLine("        $($item.Guid).$configuration|x64.ActiveCfg = $mapping")
            [void] $builder.AppendLine("        $($item.Guid).$configuration|x64.Build.0 = $mapping")
        }
    }
    [void] $builder.AppendLine('    EndGlobalSection')
    [void] $builder.AppendLine('EndGlobal')
    [IO.File]::WriteAllText($SolutionPath, $builder.ToString(), (New-Object Text.UTF8Encoding($false)))
}

function Ensure-VisualStudioArtifacts(
    [string] $Root,
    [object[]] $Sources,
    [object[]] $Headers,
    [object[]] $IncludeDirectories,
    [object[]] $LinkFiles,
    [bool] $UsesFreeglut,
    [bool] $NeedsFreeglutAdapter,
    $MsysFreeglut
) {
    $projects = @(Get-FilesByExtension $Root @('.vcxproj'))
    $applications = @($projects | Where-Object { (Get-ProjectType $_.FullName) -eq 'Application' })
    $generatedApplications = @($applications | Where-Object { Test-IsRunBatGeneratedProject $_.FullName })
    if ($generatedApplications.Count -gt 0) {
        [void] (New-RunBatProject $generatedApplications[0].FullName $Sources $Headers $IncludeDirectories $LinkFiles $UsesFreeglut $NeedsFreeglutAdapter $MsysFreeglut)
        $projects = @(Get-FilesByExtension $Root @('.vcxproj'))
    } elseif ($applications.Count -eq 0) {
        $rootName = Split-Path -Leaf ($Root.TrimEnd('\'))
        if ([string]::IsNullOrWhiteSpace($rootName)) { $rootName = 'Application' }
        $projectPath = Join-Path $Root ($rootName + '.vcxproj')
        if (Test-Path -LiteralPath $projectPath) {
            $projectPath = Join-Path $Root ($rootName + '.Application.vcxproj')
        }
        [void] (New-RunBatProject $projectPath $Sources $Headers $IncludeDirectories $LinkFiles $UsesFreeglut $NeedsFreeglutAdapter $MsysFreeglut)
        $projects = @(Get-FilesByExtension $Root @('.vcxproj'))
    }

    $solutions = @(Get-ChildItem -LiteralPath $Root -File -Filter '*.sln' -ErrorAction SilentlyContinue | Sort-Object FullName)
    if ($solutions.Count -eq 0 -and $projects.Count -gt 0) {
        $rootName = Split-Path -Leaf ($Root.TrimEnd('\'))
        if ([string]::IsNullOrWhiteSpace($rootName)) { $rootName = 'Application' }
        $solutionPath = Join-Path $Root ($rootName + '.sln')
        New-RunBatSolution $solutionPath $projects
        $solutions = @(Get-Item -LiteralPath $solutionPath)
    }
    $solution = if ($solutions.Count -gt 0) { $solutions[0].FullName } else { $null }
    return [pscustomobject]@{
        Projects = @(Get-FilesByExtension $Root @('.vcxproj'))
        Solution = $solution
    }
}

function Select-BuildMode([IO.FileSystemInfo] $Target) {
    $kind = Get-ItemKind $Target
    if ($kind -eq 'Project' -or $kind -eq 'Solution') {
        if ($script:UseGcc) {
            throw "-g cannot build a $kind file. Select its source directory instead."
        }
        if ($script:ExtraArguments.Count -gt 0 -or $script:ExcludeArguments.Count -gt 0) {
            throw '-i and source exclusions apply only to direct source builds.'
        }
        return [pscustomobject]@{ Mode = $kind; Path = $Target.FullName; Root = $Target.Directory.FullName }
    }

    $root = if ($kind -eq 'Directory') { $Target.FullName } else { $Target.Directory.FullName }
    if (-not $script:UseGcc -and $kind -eq 'Directory' -and
        $script:ExtraArguments.Count -eq 0 -and $script:ExcludeArguments.Count -eq 0) {
        $solutions = @(Get-ChildItem -LiteralPath $root -File -Filter '*.sln')
        if ($solutions.Count -eq 1) {
            $solutionProjects = @(Get-SolutionProjects $solutions[0].FullName)
            $hasGeneratedProject = @($solutionProjects | Where-Object { Test-IsRunBatGeneratedProject $_ }).Count -gt 0
            if (-not $hasGeneratedProject) {
                return [pscustomobject]@{ Mode = 'Solution'; Path = $solutions[0].FullName; Root = $root }
            }
        }
        if ($solutions.Count -gt 1) {
            throw "More than one solution exists in '$root'; select the intended .sln explicitly."
        }

        $projects = @(Get-ChildItem -LiteralPath $root -File -Filter '*.vcxproj')
        $applications = @($projects | Where-Object {
            -not (Test-IsRunBatGeneratedProject $_.FullName) -and (Get-ProjectType $_.FullName) -eq 'Application'
        })
        if ($applications.Count -eq 1) {
            return [pscustomobject]@{ Mode = 'Project'; Path = $applications[0].FullName; Root = $root }
        }
        if ($applications.Count -gt 1) {
            throw "More than one application project exists in '$root'; select a .vcxproj explicitly."
        }
        $userProjects = @($projects | Where-Object { -not (Test-IsRunBatGeneratedProject $_.FullName) })
        if ($userProjects.Count -eq 1) {
            return [pscustomobject]@{ Mode = 'Project'; Path = $userProjects[0].FullName; Root = $root }
        }
    }

    return [pscustomobject]@{ Mode = 'Source'; Path = $Target.FullName; Root = $root }
}

function Find-VisualStudio {
    if ($script:VsInstallation) { return $script:VsInstallation }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) {
        throw 'vswhere.exe was not found. Install Visual Studio with the C++ workload.'
    }
    $installation = @(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)[0]
    if ([string]::IsNullOrWhiteSpace($installation)) {
        throw 'Visual Studio C++ build tools were not found.'
    }
    $script:VsInstallation = $installation.Trim()
    return $script:VsInstallation
}

function Find-MSBuild {
    if ($script:MSBuildPath) { return $script:MSBuildPath }
    $command = Get-Command msbuild.exe -ErrorAction SilentlyContinue
    if ($command) {
        $script:MSBuildPath = $command.Source
        return $script:MSBuildPath
    }
    $candidate = Join-Path (Find-VisualStudio) 'MSBuild\Current\Bin\MSBuild.exe'
    if (-not (Test-Path -LiteralPath $candidate)) { throw 'MSBuild.exe was not found.' }
    $script:MSBuildPath = $candidate
    return $script:MSBuildPath
}

function Find-MsysFreeglut {
    $prefixes = New-Object 'Collections.Generic.List[string]'
    $gxx = Get-Command g++.exe -ErrorAction SilentlyContinue
    if ($gxx) {
        $prefixes.Add((Split-Path -Parent (Split-Path -Parent $gxx.Source)))
    }
    $prefixes.Add('C:\msys64\ucrt64')
    $prefixes.Add('C:\msys64\mingw64')
    foreach ($prefix in @($prefixes | Select-Object -Unique)) {
        $header = Join-Path $prefix 'include\GL\freeglut.h'
        $importLibrary = Join-Path $prefix 'lib\libfreeglut.dll.a'
        $dll = Join-Path $prefix 'bin\libfreeglut.dll'
        if ((Test-Path -LiteralPath $header) -and
            (Test-Path -LiteralPath $importLibrary) -and
            (Test-Path -LiteralPath $dll)) {
            return [pscustomobject]@{
                Header = (Get-Item -LiteralPath $header)
                ImportLibrary = (Get-Item -LiteralPath $importLibrary)
                Dll = (Get-Item -LiteralPath $dll)
                Bin = [IO.Path]::GetDirectoryName($dll)
            }
        }
    }
    return $null
}

function Find-InstalledToolset([string] $Platform) {
    if ($Platform -inotmatch '^(x64|Win32)$') { return $null }
    $pattern = Join-Path (Find-VisualStudio) "MSBuild\Microsoft\VC\v*\Platforms\$Platform\PlatformToolsets\v*"
    $sets = @(Get-ChildItem -Path $pattern -Directory -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^v\d+$'
    } | Sort-Object { [int]($_.Name.Substring(1)) } -Descending)
    if ($sets.Count -eq 0) { return $null }
    return $sets[0].Name
}

function Import-MsvcEnvironment {
    if (Get-Command cl.exe -ErrorAction SilentlyContinue) { return }
    $vcvars = Join-Path (Find-VisualStudio) 'VC\Auxiliary\Build\vcvars64.bat'
    if (-not (Test-Path -LiteralPath $vcvars)) { throw 'vcvars64.bat was not found.' }
    $command = 'call "' + $vcvars + '" >nul && set'
    $lines = @(& $env:ComSpec /d /s /c $command)
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the MSVC environment.' }
    $seenVariables = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $lines) {
        $equals = $line.IndexOf('=')
        if ($equals -gt 0) {
            $name = $line.Substring(0, $equals)
            if ($seenVariables.Add($name)) {
                [Environment]::SetEnvironmentVariable($name, $line.Substring($equals + 1), 'Process')
            }
        }
    }
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) { throw 'cl.exe could not be initialized.' }
}

function Get-BuildSettings([string] $Path, [string] $Mode) {
    $pairs = @()
    if ($Mode -eq 'Project') {
        [xml] $xml = [IO.File]::ReadAllText($Path)
        $pairs = @($xml.SelectNodes("//*[local-name()='ProjectConfiguration']") | ForEach-Object {
            $_.GetAttribute('Include')
        })
    } else {
        $inside = $false
        foreach ($line in [IO.File]::ReadLines($Path)) {
            if ($line -match '^\s*GlobalSection\(SolutionConfigurationPlatforms\)') { $inside = $true; continue }
            if ($inside -and $line -match '^\s*EndGlobalSection') { break }
            if ($inside -and $line -match '^\s*([^=]+?)\s*=') { $pairs += $matches[1].Trim() }
        }
    }
    $pairs = @($pairs | Where-Object { $_ -match '\|' } | Select-Object -Unique)
    if ($pairs.Count -eq 0) { throw "No build configurations were found in '$Path'." }

    $chosen = @($pairs | Where-Object { $_ -ieq 'Debug|x64' })[0]
    if (-not $chosen) { $chosen = @($pairs | Where-Object { $_ -imatch '^Debug\|' })[0] }
    if (-not $chosen) { $chosen = @($pairs | Where-Object { $_ -imatch '\|x64$' })[0] }
    if (-not $chosen) { $chosen = $pairs[0] }
    $split = $chosen.Split('|', 2)
    return [pscustomobject]@{ Configuration = $split[0]; Platform = $split[1] }
}

function Get-SolutionProjects([string] $SolutionPath) {
    $projects = @()
    foreach ($line in [IO.File]::ReadLines($SolutionPath)) {
        if ($line -match '^Project\("[^"]+"\)\s*=\s*"[^"]+",\s*"([^"]+\.vcxproj)"') {
            $path = $matches[1].Replace('\', [IO.Path]::DirectorySeparatorChar)
            if (-not [IO.Path]::IsPathRooted($path)) {
                $path = Join-Path ([IO.Path]::GetDirectoryName($SolutionPath)) $path
            }
            if (Test-Path -LiteralPath $path) { $projects += (Get-Item -LiteralPath $path).FullName }
        }
    }
    return @($projects | Select-Object -Unique)
}

function Get-SolutionProjectSettings([string] $SolutionPath, [string] $ProjectPath, $SolutionSettings) {
    [xml] $xml = [IO.File]::ReadAllText($ProjectPath)
    $guidNode = @($xml.SelectNodes("//*[local-name()='ProjectGuid']"))[0]
    if (-not $guidNode) { return $SolutionSettings }
    $solutionPair = "$($SolutionSettings.Configuration)|$($SolutionSettings.Platform)"
    $prefix = [Text.RegularExpressions.Regex]::Escape($guidNode.InnerText + '.' + $solutionPair + '.ActiveCfg')
    foreach ($line in [IO.File]::ReadLines($SolutionPath)) {
        if ($line -match ('^\s*' + $prefix + '\s*=\s*(.+?)\s*$')) {
            $mapped = $matches[1].Split('|', 2)
            if ($mapped.Count -eq 2) {
                return [pscustomobject]@{ Configuration = $mapped[0]; Platform = $mapped[1] }
            }
        }
    }
    return $SolutionSettings
}

function Get-ProjectTargetPath([string] $Project, $Settings, [string] $Toolset) {
    $msbuild = Find-MSBuild
    $arguments = @(
        $Project, '/nologo', '-getProperty:TargetPath',
        "/p:Configuration=$($Settings.Configuration)",
        "/p:Platform=$($Settings.Platform)"
    )
    if ($Toolset) { $arguments += "/p:PlatformToolset=$Toolset" }
    $output = @(& $msbuild @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw (($output | ForEach-Object ToString) -join [Environment]::NewLine) }
    $lines = @($output | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -ne '' })
    if ($lines.Count -eq 0) { throw "MSBuild did not report TargetPath for '$Project'." }
    $path = $lines[$lines.Count - 1]
    if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path ([IO.Path]::GetDirectoryName($Project)) $path }
    return [IO.Path]::GetFullPath($path)
}

function Add-RuntimeDirectories([string] $SearchRoot, [string] $Executable) {
    $directories = New-Object 'Collections.Generic.List[string]'
    $directories.Add([IO.Path]::GetDirectoryName($Executable))
    foreach ($root in @($SearchRoot, $script:BaseDirectory) | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($dll in @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.dll' -ErrorAction SilentlyContinue)) {
            if (-not (Test-IgnoredPath $root $dll.FullName)) { $directories.Add($dll.Directory.FullName) }
        }
    }
    $msysFreeglut = Find-MsysFreeglut
    if ($msysFreeglut) { $directories.Add($msysFreeglut.Bin) }
    $unique = @($directories | Select-Object -Unique)
    $env:Path = ($unique + $env:Path) -join ';'
}

function Invoke-Program([string] $Executable, [string] $WorkingDirectory, [string] $SearchRoot) {
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
        throw "The build succeeded, but its executable was not found: $Executable"
    }
    $runtimeBridge = $null
    try {
        Add-RuntimeDirectories $SearchRoot $Executable
        $workspaceDll = @(Get-ChildItem -LiteralPath $script:BaseDirectory -Recurse -File -Filter 'freeglut.dll' -ErrorAction SilentlyContinue)[0]
        $msysFreeglut = Find-MsysFreeglut
        $executableText = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($Executable))
        $importsMicrosoftNamedFreeglut = $executableText -match '(?i)(?<![A-Za-z0-9_])freeglut\.dll'
        if ($importsMicrosoftNamedFreeglut -and -not $workspaceDll -and $msysFreeglut) {
            $runtimeBridge = Join-Path ([IO.Path]::GetTempPath()) ('runbat_dll_' + [guid]::NewGuid().ToString('N'))
            [void] [IO.Directory]::CreateDirectory($runtimeBridge)
            Copy-Item -LiteralPath $msysFreeglut.Dll.FullName -Destination (Join-Path $runtimeBridge 'freeglut.dll')
            $env:Path = ($runtimeBridge, $env:Path) -join ';'
        }
        Write-Host ''
        Write-Host $script:Separator
        Write-Host 'Program output:'
        Write-Host $script:Separator
        $process = Start-Process -FilePath $Executable -WorkingDirectory $WorkingDirectory -NoNewWindow -Wait -PassThru
        $code = $process.ExitCode
        Write-Host ''
        Write-Host $script:Separator
        Write-Host "Program finished. Exit code: $code"
        Write-Host $script:Separator
        return $code
    } finally {
        if ($runtimeBridge -and (Test-Path -LiteralPath $runtimeBridge)) {
            Remove-Item -LiteralPath $runtimeBridge -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-ProjectSourcePaths([object[]] $Projects) {
    $paths = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($project in $Projects) {
        try {
            [xml] $document = [IO.File]::ReadAllText([string] $project)
            $projectDirectory = [IO.Path]::GetDirectoryName([string] $project)
            foreach ($node in @($document.SelectNodes("//*[local-name()='ClCompile']"))) {
                $include = $node.GetAttribute('Include')
                if ([string]::IsNullOrWhiteSpace($include) -or $include.Contains('$(')) { continue }
                $path = if ([IO.Path]::IsPathRooted($include)) {
                    $include
                } else {
                    Join-Path $projectDirectory $include
                }
                [void] $paths.Add([IO.Path]::GetFullPath($path))
            }
        } catch {
            throw "Could not inspect Visual Studio project '$project': $($_.Exception.Message)"
        }
    }
    return ,$paths
}

function Build-AutomaticDynamicLibraries(
    [string] $Root,
    [object[]] $Projects,
    [string] $OutputDirectory,
    $Settings
) {
    $ownedSources = Get-ProjectSourcePaths $Projects
    $sources = @(Get-FilesByExtension $Root $script:SourceExtensions | Where-Object {
        -not $ownedSources.Contains($_.FullName) -and -not (Test-HasEntryPoint $_)
    })
    if ($sources.Count -eq 0) { return @() }

    $headers = @(Get-FilesByExtension $Root $script:HeaderExtensions)
    $includeDirectories = @(
        @($headers | ForEach-Object { $_.Directory.FullName }) +
        @($sources | ForEach-Object { $_.Directory.FullName }) +
        $Root | Select-Object -Unique
    )
    $plans = New-Object 'Collections.Generic.List[object]'

    foreach ($group in @($sources | Group-Object { $_.Directory.FullName })) {
        $groupDirectory = [string] $group.Name
        $groupHeaders = @($headers | Where-Object { $_.Directory.FullName -ieq $groupDirectory })
        if ($groupHeaders.Count -eq 0) { continue }

        $headerText = ($groupHeaders | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
        $exportMatch = [Text.RegularExpressions.Regex]::Match(
            $headerText,
            '(?m)^\s*#\s*(?:ifdef\s+|if\s+defined\s*\(?\s*)([A-Za-z_][A-Za-z0-9_]*_EXPORTS)\b'
        )
        if (-not $exportMatch.Success) { continue }

        $name = Split-Path -Leaf $groupDirectory
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $plans.Add([pscustomobject]@{
            Name = $name
            ExportMacro = $exportMatch.Groups[1].Value
            Sources = @($group.Group)
        })
    }

    if ($plans.Count -eq 0) { return @() }

    Import-MsvcEnvironment
    [void] [IO.Directory]::CreateDirectory($OutputDirectory)
    $generatedLibraries = New-Object 'Collections.Generic.List[IO.FileInfo]'

    foreach ($plan in $plans) {
        $intermediateDirectory = Join-Path $OutputDirectory ('runbat\' + $plan.Name)
        [void] [IO.Directory]::CreateDirectory($intermediateDirectory)
        $dll = Join-Path $OutputDirectory ($plan.Name + '.dll')
        $library = Join-Path $OutputDirectory ($plan.Name + '.lib')
        $linkPdb = Join-Path $intermediateDirectory ($plan.Name + '.pdb')
        $compilePdb = Join-Path $intermediateDirectory ($plan.Name + '.compile.pdb')
        $runtime = if ($Settings.Configuration -imatch '^Debug') { '/MDd' } else { '/MD' }
        $arguments = @('/nologo', '/LD', '/EHsc', '/std:c++17', '/utf-8', $runtime, ('/D' + $plan.ExportMacro))
        foreach ($directory in $includeDirectories) { $arguments += ('/I' + $directory) }
        $arguments += @($plan.Sources | ForEach-Object FullName)
        $arguments += ('/Fo' + $intermediateDirectory + '\')
        $arguments += ('/Fd' + $compilePdb)
        $arguments += @('/link', ('/OUT:' + $dll), ('/IMPLIB:' + $library), ('/PDB:' + $linkPdb))

        $compileOutput = @(& cl.exe @arguments 2>&1)
        $compileExitCode = $LASTEXITCODE
        if ($compileExitCode -ne 0) {
            $compileOutput | ForEach-Object { Write-Host $_.ToString() }
            throw "Automatic DLL build for '$($plan.Name)' failed with exit code $compileExitCode."
        }
        $generatedLibraries.Add((Get-Item -LiteralPath $library))
    }

    return @($generatedLibraries)
}

function Build-VisualStudio([string] $Path, [string] $Mode, [string] $Root) {
    if ($Mode -eq 'Project') {
        $existingSolutions = @(Get-ChildItem -LiteralPath $Root -File -Filter '*.sln' -ErrorAction SilentlyContinue)
        $existingProjects = @(Get-FilesByExtension $Root @('.vcxproj'))
        if ($existingSolutions.Count -eq 0 -and $existingProjects.Count -gt 0) {
            $rootName = Split-Path -Leaf ($Root.TrimEnd('\'))
            if ([string]::IsNullOrWhiteSpace($rootName)) { $rootName = 'Application' }
            New-RunBatSolution (Join-Path $Root ($rootName + '.sln')) $existingProjects
        }
    }
    $msbuild = Find-MSBuild
    $settings = Get-BuildSettings $Path $Mode
    $toolset = Find-InstalledToolset $settings.Platform
    $sources = @(Get-FilesByExtension $Root $script:SourceExtensions)
    $headers = @(Get-FilesByExtension $Root $script:HeaderExtensions)
    $projects = @(Get-FilesByExtension $Root @('.vcxproj'))
    $selectedProjects = if ($Mode -eq 'Project') { @($Path) } else { @(Get-SolutionProjects $Path) }
    $applications = @($selectedProjects | Where-Object { (Get-ProjectType $_) -eq 'Application' })
    $generatedLibraries = @()
    if ($applications.Count -eq 1) {
        $applicationSettings = if ($Mode -eq 'Solution') {
            Get-SolutionProjectSettings $Path $applications[0] $settings
        } else {
            $settings
        }
        $applicationToolset = Find-InstalledToolset $applicationSettings.Platform
        $applicationTarget = Get-ProjectTargetPath $applications[0] $applicationSettings $applicationToolset
        $generatedLibraries = @(Build-AutomaticDynamicLibraries $Root $selectedProjects ([IO.Path]::GetDirectoryName($applicationTarget)) $applicationSettings)
    }
    $solution = if ($Mode -eq 'Solution') {
        $Path
    } else {
        @(Get-FilesByExtension $Root @('.sln') | Sort-Object FullName | Select-Object -First 1).FullName
    }
    $libraries = @(Get-FilesByExtension $Root @('.lib', '.a')) + $generatedLibraries
    Write-BuildLayout $Root 'msvc' $sources $headers $projects $solution $libraries

    $arguments = @(
        $Path, '/nologo', '/m', '/v:minimal',
        "/p:Configuration=$($settings.Configuration)",
        "/p:Platform=$($settings.Platform)",
        '/p:LanguageStandard=stdcpp17'
    )
    if ($toolset) { $arguments += "/p:PlatformToolset=$toolset" }
    $previousTrailingClOptions = [Environment]::GetEnvironmentVariable('_CL_', 'Process')
    $previousTrailingLinkOptions = [Environment]::GetEnvironmentVariable('_LINK_', 'Process')
    $includeOptions = @($headers | ForEach-Object { '/I"' + $_.Directory.FullName + '"' } | Select-Object -Unique)
    $linkOptions = @($libraries | Where-Object { $_.Extension -ieq '.lib' } | ForEach-Object { '"' + $_.FullName + '"' } | Select-Object -Unique)
    $env:_CL_ = (@($previousTrailingClOptions, '/std:c++17 /utf-8') + $includeOptions | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    }) -join ' '
    $env:_LINK_ = (@($previousTrailingLinkOptions) + $linkOptions | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    }) -join ' '
    try {
        $buildOutput = @(& $msbuild @arguments 2>&1)
        $buildExitCode = $LASTEXITCODE
    } finally {
        [Environment]::SetEnvironmentVariable('_CL_', $previousTrailingClOptions, 'Process')
        [Environment]::SetEnvironmentVariable('_LINK_', $previousTrailingLinkOptions, 'Process')
    }
    if ($buildExitCode -ne 0) {
        $buildOutput | ForEach-Object { Write-Host $_.ToString() }
        throw "MSBuild failed with exit code $buildExitCode."
    }

    if (-not $script:RunAfterBuild) { return 0 }
    $projects = $selectedProjects
    $applications = @($projects | Where-Object { (Get-ProjectType $_) -eq 'Application' })
    if ($applications.Count -eq 0) { throw 'The selected project/solution has no executable C++ project to run.' }
    if ($applications.Count -gt 1) {
        throw 'The solution has multiple executable projects. Select the intended .vcxproj when using -r.'
    }
    $projectSettings = if ($Mode -eq 'Solution') {
        Get-SolutionProjectSettings $Path $applications[0] $settings
    } else {
        $settings
    }
    $projectToolset = Find-InstalledToolset $projectSettings.Platform
    $executable = Get-ProjectTargetPath $applications[0] $projectSettings $projectToolset
    return Invoke-Program $executable ([IO.Path]::GetDirectoryName($applications[0])) $Root
}

function Add-UniquePath($List, [string] $Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (@($List) -icontains $full)) { [void] $List.Add($full) }
}

function Build-Source([IO.FileSystemInfo] $Target, [string] $Root) {
    $allSources = @(Get-FilesByExtension $Root $script:SourceExtensions | Where-Object {
        -not (Test-IsExcluded $_ $Root)
    })

    $targetKind = Get-ItemKind $Target
    $explicitEntry = $null
    if ($targetKind -eq 'Source') {
        $explicitEntry = [IO.FileInfo] $Target
        if (-not (Test-HasEntryPoint $explicitEntry)) {
            throw "The selected source has no executable entry point: $($explicitEntry.FullName)"
        }
        $allSources = @($allSources | Where-Object { $_.FullName -ieq $explicitEntry.FullName -or -not (Test-HasEntryPoint $_) })
        if (-not (@($allSources | ForEach-Object FullName) -icontains $explicitEntry.FullName)) { $allSources += $explicitEntry }
    }

    $extraObjects = New-Object 'Collections.Generic.List[IO.FileInfo]'
    $extraLibraries = New-Object 'Collections.Generic.List[IO.FileInfo]'
    $extraHeaders = New-Object 'Collections.Generic.List[IO.FileInfo]'
    foreach ($value in $script:ExtraArguments) {
        $file = Resolve-AdditionalFile $value $Root
        if ($script:SourceExtensions -icontains $file.Extension) {
            if (-not (@($allSources | ForEach-Object FullName) -icontains $file.FullName)) { $allSources += $file }
        } elseif ($script:HeaderExtensions -icontains $file.Extension) {
            $extraHeaders.Add($file)
        } elseif ($file.Extension -iin @('.obj', '.o')) {
            $extraObjects.Add($file)
        } elseif ($file.Extension -iin @('.lib', '.a')) {
            $extraLibraries.Add($file)
        } else {
            throw "Unsupported -i file type: $($file.FullName)"
        }
    }

    if ($allSources.Count -eq 0) { throw "No C/C++ source files were found under '$Root'." }
    $entrySources = @($allSources | Where-Object { Test-HasEntryPoint $_ })
    if ($explicitEntry) { $entrySources = @($explicitEntry) }
    if ($entrySources.Count -eq 0) { throw "No executable entry point was found under '$Root'." }
    if ($entrySources.Count -gt 1) {
        $list = ($entrySources | ForEach-Object FullName) -join [Environment]::NewLine
        throw "Multiple executable entry points were found. Select a source file explicitly:`n$list"
    }

    $entry = $entrySources[0]
    $workingDirectory = $entry.Directory.FullName
    $outputName = Split-Path -Leaf $workingDirectory
    if ([string]::IsNullOrWhiteSpace($outputName)) { $outputName = $entry.BaseName }
    $executable = Join-Path $workingDirectory ($outputName + '.exe')

    $includeDirectories = New-Object 'Collections.Generic.List[string]'
    Add-UniquePath $includeDirectories $workingDirectory
    Add-UniquePath $includeDirectories $Root
    foreach ($source in $allSources) { Add-UniquePath $includeDirectories $source.Directory.FullName }
    $headers = @(Get-FilesByExtension $Root $script:HeaderExtensions) + @($extraHeaders)
    foreach ($header in $headers) { Add-UniquePath $includeDirectories $header.Directory.FullName }
    Add-UniquePath $includeDirectories $script:BaseDirectory

    $combinedSource = ($allSources | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
    $workspaceHeaders = @(Get-FilesByExtension $script:BaseDirectory $script:HeaderExtensions)
    $includeMatches = [Text.RegularExpressions.Regex]::Matches(
        $combinedSource,
        '(?m)^\s*#\s*include\s*[<"]([^>"]+)[>"]'
    )
    foreach ($match in $includeMatches) {
        $includeName = $match.Groups[1].Value.Replace('/', '\')
        $suffix = '\' + $includeName
        foreach ($candidate in $workspaceHeaders) {
            if ($candidate.FullName.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) {
                $includeRoot = $candidate.FullName.Substring(0, $candidate.FullName.Length - $suffix.Length)
                Add-UniquePath $includeDirectories $includeRoot
            }
        }
    }
    $usesFreeglut = $combinedSource -match '(?i)(?:freeglut|[<"]GL[/\\]glut\.h[>"])'
    $usesGlLayout = $combinedSource -match '(?i)[<"]GL[/\\](?:freeglut|glut)\.h[>"]'
    $usesLegacyFreeglutLayout = $combinedSource -match '(?i)[<"]freeglut[/\\](?:freeglut|glut)\.h[>"]'

    $localLibraries = @(Get-FilesByExtension $Root @('.lib', '.a') | Where-Object {
        $_.Name -inotmatch '^freeglutd?\.lib$'
    }) + @($extraLibraries)
    $localLibraries = @($localLibraries | Sort-Object FullName -Unique)

    $msysFreeglut = Find-MsysFreeglut
    $legacyHeaderResolved = @($includeDirectories | Where-Object {
        Test-Path -LiteralPath (Join-Path $_ 'freeglut\freeglut.h')
    }).Count -gt 0
    $usesGlFreeglutInclude = $combinedSource -match '(?i)[<"]GL[/\\]freeglut\.h[>"]'
    $usesGlGlutInclude = $combinedSource -match '(?i)[<"]GL[/\\]glut\.h[>"]'
    $glFreeglutResolved = -not $usesGlFreeglutInclude -or @($includeDirectories | Where-Object {
        Test-Path -LiteralPath (Join-Path $_ 'GL\freeglut.h')
    }).Count -gt 0
    $glGlutResolved = -not $usesGlGlutInclude -or @($includeDirectories | Where-Object {
        Test-Path -LiteralPath (Join-Path $_ 'GL\glut.h')
    }).Count -gt 0
    $glHeaderResolved = $glFreeglutResolved -and $glGlutResolved
    $needsFreeglutAdapter = ($usesLegacyFreeglutLayout -and -not $legacyHeaderResolved) -or
        ($usesGlLayout -and -not $glHeaderResolved)
    if ($needsFreeglutAdapter -and -not $msysFreeglut) {
        throw 'freeglut headers were not found in the workspace or MSYS2.'
    }

    $projectLinkFiles = @($localLibraries) + @($extraObjects | Where-Object { $_.Extension -ieq '.obj' })
    if ($usesFreeglut) {
        if ($msysFreeglut) {
            $projectLinkFiles += $msysFreeglut.ImportLibrary
        } else {
            $workspaceFreeglut = @(Get-ChildItem -LiteralPath $script:BaseDirectory -Recurse -File -Filter 'freeglut.lib' |
                Where-Object { -not (Test-IgnoredPath $script:BaseDirectory $_.FullName) } |
                Sort-Object { $_.FullName.Length })[0]
            if ($workspaceFreeglut) { $projectLinkFiles += $workspaceFreeglut }
        }
    }
    $artifacts = Ensure-VisualStudioArtifacts $Root $allSources $headers $includeDirectories $projectLinkFiles $usesFreeglut $needsFreeglutAdapter $msysFreeglut
    $projects = @($artifacts.Projects)
    $solution = $artifacts.Solution
    $compilerDisplay = if ($script:UseGcc) { 'g++' } else { 'msvc' }
    Write-BuildLayout $Root $compilerDisplay $allSources $headers $projects $solution $localLibraries

    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('runbat_' + [guid]::NewGuid().ToString('N'))
    [void] [IO.Directory]::CreateDirectory($temporaryRoot)
    try {
        if ($usesLegacyFreeglutLayout) {
            if (-not $legacyHeaderResolved) {
                $legacyBridge = Join-Path $temporaryRoot 'freeglut'
                [void] [IO.Directory]::CreateDirectory($legacyBridge)
                $headerPath = $msysFreeglut.Header.FullName.Replace('\', '/')
                [IO.File]::WriteAllText((Join-Path $legacyBridge 'freeglut.h'), ('#include "' + $headerPath + '"'))
                [IO.File]::WriteAllText((Join-Path $legacyBridge 'glut.h'), ('#include "' + (Join-Path $msysFreeglut.Header.Directory.FullName 'glut.h').Replace('\', '/') + '"'))
                $includeDirectories.Insert(0, $temporaryRoot)
            }
        }
        if ($script:UseGcc) {
            $compiler = Get-Command g++.exe -ErrorAction SilentlyContinue
            if (-not $compiler) {
                foreach ($candidate in @('C:\msys64\ucrt64\bin\g++.exe', 'C:\msys64\mingw64\bin\g++.exe')) {
                    if (Test-Path -LiteralPath $candidate) { $compiler = Get-Item -LiteralPath $candidate; break }
                }
            }
            if (-not $compiler) { throw 'g++.exe was not found. Install MSYS2 UCRT64 GCC or add it to PATH.' }
            if (@($localLibraries | Where-Object Extension -IEQ '.lib').Count -gt 0) {
                throw 'This target contains an MSVC .lib. MinGW cannot reliably link MSVC C++ libraries; run without -g.'
            }
            $arguments = @('-std=c++17', '-finput-charset=UTF-8', '-fexec-charset=UTF-8')
            foreach ($directory in $includeDirectories) { $arguments += ('-I' + $directory) }
            $arguments += @($allSources | ForEach-Object FullName)
            $arguments += @($extraObjects | ForEach-Object FullName)
            $arguments += @($localLibraries | Where-Object Extension -IEQ '.a' | ForEach-Object FullName)
            if ($usesFreeglut) { $arguments += @('-lfreeglut', '-lopengl32', '-lglu32', '-lgdi32', '-lwinmm') }
            $arguments += @('-o', $executable)
            $compileOutput = @(& $compiler.Source @arguments 2>&1)
            $compileExitCode = $LASTEXITCODE
            if ($compileExitCode -ne 0) {
                $compileOutput | ForEach-Object { Write-Host $_.ToString() }
                throw "g++ failed with exit code $compileExitCode."
            }
            $env:Path = ((Split-Path -Parent $compiler.Source), $env:Path) -join ';'
        } else {
            Import-MsvcEnvironment
            if ($usesGlLayout) {
                $nativeHeader = @(Get-ChildItem -LiteralPath $script:BaseDirectory -Recurse -File -Filter 'freeglut.h' |
                    Where-Object { $_.Directory.Name -ieq 'freeglut' } | Sort-Object { $_.FullName.Length })[0]
                if (-not $nativeHeader -and $msysFreeglut) { $nativeHeader = $msysFreeglut.Header }
                if (-not $nativeHeader) {
                    throw 'A source includes GL/freeglut.h, but no MSVC-compatible freeglut headers exist in the workspace.'
                }
                $bridge = Join-Path $temporaryRoot 'GL'
                [void] [IO.Directory]::CreateDirectory($bridge)
                [IO.File]::WriteAllText((Join-Path $bridge 'freeglut.h'), ('#include "' + $nativeHeader.FullName.Replace('\', '/') + '"'))
                [IO.File]::WriteAllText((Join-Path $bridge 'glut.h'), ('#include "' + (Join-Path $nativeHeader.Directory.FullName 'glut.h').Replace('\', '/') + '"'))
                $includeDirectories.Insert(0, $temporaryRoot)
            }

            $objectDirectory = Join-Path $temporaryRoot 'obj'
            [void] [IO.Directory]::CreateDirectory($objectDirectory)
            $arguments = @('/nologo', '/EHsc', '/std:c++17', '/utf-8', '/MD')
            foreach ($directory in $includeDirectories) { $arguments += ('/I' + $directory) }
            if ($usesFreeglut) { $arguments += '/DFREEGLUT_LIB_PRAGMAS=0' }
            $arguments += @($allSources | ForEach-Object FullName)
            $arguments += @($extraObjects | ForEach-Object FullName)
            $arguments += ('/Fo' + $objectDirectory + '\')
            $arguments += ('/Fe:' + $executable)
            $arguments += '/link'
            $arguments += @($localLibraries | ForEach-Object FullName)
            if ($usesFreeglut) {
                if ($msysFreeglut) {
                    $arguments += $msysFreeglut.ImportLibrary.FullName
                    $env:Path = ($msysFreeglut.Bin, $env:Path) -join ';'
                } else {
                    $freeglutLibrary = @(Get-ChildItem -LiteralPath $script:BaseDirectory -Recurse -File -Filter 'freeglut.lib' |
                        Where-Object { -not (Test-IgnoredPath $script:BaseDirectory $_.FullName) } |
                        Sort-Object { $_.FullName.Length })[0]
                    if (-not $freeglutLibrary) { throw 'freeglut import library was not found in the workspace or MSYS2.' }
                    $arguments += $freeglutLibrary.FullName
                }
                $arguments += @('opengl32.lib', 'glu32.lib', 'gdi32.lib', 'winmm.lib', 'user32.lib')
            }
            $compileOutput = @(& cl.exe @arguments 2>&1)
            $compileExitCode = $LASTEXITCODE
            if ($compileExitCode -ne 0) {
                $compileOutput | ForEach-Object { Write-Host $_.ToString() }
                throw "MSVC cl failed with exit code $compileExitCode."
            }
        }
    } finally {
        if (Test-Path -LiteralPath $temporaryRoot) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($script:RunAfterBuild) { return Invoke-Program $executable $workingDirectory $Root }
    return 0
}

try {
    Write-Host $script:Separator
    $target = Resolve-Target $env:RUNBAT_SELECTOR
    $selection = Select-BuildMode $target
    $exitCode = if ($selection.Mode -eq 'Source') {
        Build-Source $target $selection.Root
    } else {
        Build-VisualStudio $selection.Path $selection.Mode $selection.Root
    }
    exit $exitCode
} catch {
    Write-Host ''
    Write-Host ('Error: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
