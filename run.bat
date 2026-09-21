@echo off
chcp 65001 >nul
setlocal EnableExtensions EnableDelayedExpansion

if "%~1"=="" goto usage


rem ============================================================
rem Base
rem ============================================================

set "BASE_DIR=%CD%"

set "PLATFORM_TOOLSET=v145"
set "WINDOWS_SDK_VERSION=10.0"
set "VC_PROJECT_VERSION=16.0"


rem ============================================================
rem Separator
rem ============================================================

set "CONSOLE_WIDTH=80"

for /f %%W in ('powershell -NoProfile -Command "[Console]::WindowWidth" 2^>nul') do (
    set "CONSOLE_WIDTH=%%W"
)

set "SEPARATOR="

for /l %%I in (1,1,!CONSOLE_WIDTH!) do (
    set "SEPARATOR=!SEPARATOR!="
)

echo !SEPARATOR!


rem ============================================================
rem Arguments
rem ============================================================

set "PATTERN=%~1"
set "PATTERN=%PATTERN:/=\%"

set "COMPILER=msvc"
set "RUN=0"

set "EXCLUDES="
set "EXTRA_FILES="

set "REQUEST_ROOT="
set "TARGET_ROOT="
set "TARGET_NAME="
set "BUILD_ROOT="

set "SOURCES="
set "DEPENDENCY_SOURCES="

set "MSVC_INCLUDE_FLAGS="
set "GCC_INCLUDE_FLAGS="
set "VCX_INCLUDE_DIRS="

set "AUTO_LIB_FILES="
set "VCX_LINK_FILES="

set "NEED_COMPAT=0"
set "VCX_COUNT=0"

set "MSBUILD_EXE="

shift


rem ============================================================
rem Options
rem ============================================================

:collect_options

if "%~1"=="" goto find_request_root


if /i "%~1"=="-r" (
    set "RUN=1"
    shift
    goto collect_options
)


if /i "%~1"=="-g" (
    set "COMPILER=g++"
    shift
    goto collect_options
)


if /i "%~1"=="-i" (

    if "%~2"=="" (
        echo Error: -i requires a file.
        goto usage
    )

    set "INCLUDE_FILE=%~2"
    set "INCLUDE_FILE=!INCLUDE_FILE:/=\!"

    set EXTRA_FILES=!EXTRA_FILES! "!INCLUDE_FILE!"

    shift
    shift
    goto collect_options
)


set EXCLUDES=!EXCLUDES! "%~1"

shift
goto collect_options



rem ============================================================
rem Find requested directory
rem ============================================================

:find_request_root

set "SEARCH_PATH=."
set "REMAINING=%PATTERN%"


:find_next_part

for /f "tokens=1,* delims=\" %%A in ("!REMAINING!") do (
    set "PART=%%A"
    set "REMAINING=%%B"
)

set "FOUND="

for /f "delims=" %%D in ('dir /b /ad "!SEARCH_PATH!" 2^>nul ^| findstr /r /x /c:"!PART!"') do (
    if not defined FOUND set "FOUND=%%D"
)

if not defined FOUND goto usage


if "!SEARCH_PATH!"=="." (
    set "SEARCH_PATH=!FOUND!"
) else (
    set "SEARCH_PATH=!SEARCH_PATH!\!FOUND!"
)


if defined REMAINING goto find_next_part


for %%D in ("!SEARCH_PATH!") do (
    set "REQUEST_ROOT=%%~fD"
)



rem ============================================================
rem Determine TARGET
rem ============================================================

set "HAS_DIRECT_CPP=0"

for /f "delims=" %%F in ('dir /b /a-d "!REQUEST_ROOT!\*.cpp" 2^>nul') do (
    set "HAS_DIRECT_CPP=1"
)


if "!HAS_DIRECT_CPP!"=="1" (

    set "TARGET_ROOT=!REQUEST_ROOT!"

) else (

    call :choose_target_under_root "!REQUEST_ROOT!"

    if errorlevel 1 (
        endlocal
        exit /b 1
    )
)


for %%D in ("!TARGET_ROOT!") do (
    set "TARGET_NAME=%%~nxD"
)



rem ============================================================
rem Determine BUILD_ROOT
rem ============================================================

if /i not "!REQUEST_ROOT!"=="!TARGET_ROOT!" (

    set "BUILD_ROOT=!REQUEST_ROOT!"

) else (

    set "BUILD_ROOT=!TARGET_ROOT!"

    for %%D in ("!TARGET_ROOT!") do (
        set "TARGET_LEAF=%%~nxD"
    )

    if /i "!TARGET_LEAF!"=="App" (

        for %%P in ("!TARGET_ROOT!\..") do (
            set "BUILD_ROOT=%%~fP"
        )
    )
)



rem ============================================================
rem Display layout
rem ============================================================

set "REQUEST_DISPLAY=!REQUEST_ROOT!"
set "REQUEST_DISPLAY=!REQUEST_DISPLAY:%BASE_DIR%\=!"

echo Directory: !REQUEST_DISPLAY!
echo Compiler: !COMPILER!


rem ============================================================
rem Enter target
rem ============================================================

pushd "!TARGET_ROOT!"

if errorlevel 1 (
    echo Error: Cannot enter target directory.
    endlocal
    exit /b 1
)



rem ============================================================
rem Collect TARGET cpp files
rem ============================================================

for /f "delims=" %%F in ('dir /b /a-d "*.cpp" 2^>nul') do (
    call :add_source "%%F" !EXCLUDES!
)

for /f "delims=" %%F in ('dir /b /a-d "*.cc" 2^>nul') do (
    call :add_source "%%F" !EXCLUDES!
)

for /f "delims=" %%F in ('dir /b /a-d "*.cxx" 2^>nul') do (
    call :add_source "%%F" !EXCLUDES!
)



rem ============================================================
rem Explicit -i files
rem ============================================================

if defined EXTRA_FILES (

    for %%F in (!EXTRA_FILES!) do (

        if not exist "%%~F" (
            echo.
            echo Error: Included file does not exist: %%~F
            popd
            endlocal
            exit /b 1
        )


        if /i "%%~xF"==".cpp" (
            findstr /m /c:"freeglut/freeglut.h" "%%~F" >nul 2>&1
            if not errorlevel 1 set "NEED_COMPAT=1"
        )

        if /i "%%~xF"==".cc" (
            findstr /m /c:"freeglut/freeglut.h" "%%~F" >nul 2>&1
            if not errorlevel 1 set "NEED_COMPAT=1"
        )

        if /i "%%~xF"==".cxx" (
            findstr /m /c:"freeglut/freeglut.h" "%%~F" >nul 2>&1
            if not errorlevel 1 set "NEED_COMPAT=1"
        )


        if /i "%%~xF"==".lib" (
            for %%A in ("%%~F") do (
                call :add_vcx_link_file "%%~fA"
            )
        )


        if /i "%%~xF"==".obj" (
            for %%A in ("%%~F") do (
                call :add_vcx_link_file "%%~fA"
            )
        )
    )
)


if not defined SOURCES if not defined EXTRA_FILES (
    echo.
    echo Error: No target source files found.
    popd
    endlocal
    exit /b 1
)



rem ============================================================
rem Include directories
rem ============================================================

set MSVC_INCLUDE_FLAGS=/I"!TARGET_ROOT!"
set GCC_INCLUDE_FLAGS=-I"!TARGET_ROOT!"
set "VCX_INCLUDE_DIRS=!TARGET_ROOT!"


if exist "!BUILD_ROOT!\*.h" (
    call :add_include_directory "!BUILD_ROOT!"
)

if exist "!BUILD_ROOT!\*.hpp" (
    call :add_include_directory "!BUILD_ROOT!"
)


for /f "delims=" %%D in ('dir /s /b /ad "!BUILD_ROOT!" 2^>nul') do (

    set "HAS_HEADER=0"

    if exist "%%D\*.h" set "HAS_HEADER=1"
    if exist "%%D\*.hpp" set "HAS_HEADER=1"
    if exist "%%D\*.hh" set "HAS_HEADER=1"
    if exist "%%D\*.hxx" set "HAS_HEADER=1"

    if "!HAS_HEADER!"=="1" (
        call :add_include_directory "%%D"
    )
)



rem ============================================================
rem freeglut detection
rem ============================================================

for /f "delims=" %%H in ('dir /s /b /a-d "!BUILD_ROOT!\*.h" 2^>nul') do (

    findstr /m /c:"freeglut/freeglut.h" "%%H" >nul 2>&1

    if not errorlevel 1 (
        set "NEED_COMPAT=1"
    )
)



rem ============================================================
rem Create missing Visual Studio projects
rem ============================================================

if /i "!COMPILER!"=="msvc" (

    call :ensure_vcx_projects

    if errorlevel 1 (
        popd
        endlocal
        exit /b 1
    )
)



rem ============================================================
rem Setup MSVC
rem ============================================================

if /i "!COMPILER!"=="msvc" (

    call :setup_msvc

    if errorlevel 1 (
        popd
        endlocal
        exit /b 1
    )
)



rem ============================================================
rem Patch + synchronize every vcxproj
rem
rem Important:
rem
rem   - retarget old toolsets to v145
rem   - C++17
rem   - UTF-8
rem   - synchronize ALL cpp/h files with disk
rem ============================================================

if /i "!COMPILER!"=="msvc" (

    for /f "delims=" %%P in ('dir /s /b /a-d "!BUILD_ROOT!\*.vcxproj" 2^>nul') do (

        for %%Q in ("%%~dpP.") do (
            set "PROJECT_DIR=%%~fQ"
        )


        set "RUNBAT_VCXPROJ=%%~fP"
        set "RUNBAT_VCX_INCLUDES=!VCX_INCLUDE_DIRS!"
        set "RUNBAT_VCX_LIBS="
        set "RUNBAT_VCX_IS_TARGET=0"
        set "RUNBAT_BUILD_ROOT=!BUILD_ROOT!"

        if /i "!PROJECT_DIR!"=="!TARGET_ROOT!" (
            set "RUNBAT_VCX_IS_TARGET=1"
        )


        call :patch_vcxproj

        if errorlevel 1 (
            echo Warning: Failed to update %%~fP
        )
    )
)



rem ============================================================
rem Project references
rem ============================================================

if /i "!COMPILER!"=="msvc" (

    call :add_static_project_references

    if errorlevel 1 (
        popd
        endlocal
        exit /b 1
    )
)



rem ============================================================
rem Create Visual Studio solution
rem ============================================================

if /i "!COMPILER!"=="msvc" (

    call :ensure_solution

    if errorlevel 1 (
        popd
        endlocal
        exit /b 1
    )
)



rem ============================================================
rem Build StaticLibrary projects
rem ============================================================

if /i "!COMPILER!"=="msvc" (

    call :build_static_libraries

    if errorlevel 1 (
        popd
        endlocal
        exit /b 1
    )
)



rem ============================================================
rem Find libraries
rem ============================================================

for /f "delims=" %%L in ('dir /s /b /a-d "!BUILD_ROOT!\*.lib" 2^>nul') do (

    set "LIB_CANDIDATE=%%~fL"
    set "SKIP_LIB=0"

    echo(!LIB_CANDIDATE!| findstr /i /c:"\Debug\" >nul
    if not errorlevel 1 set "SKIP_LIB=1"

    echo(!LIB_CANDIDATE!| findstr /i /c:"\Win32\" >nul
    if not errorlevel 1 set "SKIP_LIB=1"

    if "!SKIP_LIB!"=="0" (
        call :add_library "%%~fL"
    )
)



rem ============================================================
rem Dependency source fallback
rem ============================================================

if /i not "!BUILD_ROOT!"=="!TARGET_ROOT!" (

    for /f "delims=" %%S in ('dir /s /b /a-d "!BUILD_ROOT!\*.cpp" 2^>nul') do (

        set "ABS_DEP_SOURCE=%%~fS"
        set "OUTSIDE_CHECK=!ABS_DEP_SOURCE:%TARGET_ROOT%\=!"

        if "!OUTSIDE_CHECK!"=="!ABS_DEP_SOURCE!" (
            call :add_dependency_source "%%~fS"
        )
    )
)



rem ============================================================
rem g++ freeglut compatibility
rem ============================================================

if /i "!COMPILER!"=="g++" (

    if "!NEED_COMPAT!"=="1" (

        if not exist "%BASE_DIR%\compat\freeglut" (
            mkdir "%BASE_DIR%\compat\freeglut"
        )

        if not exist "%BASE_DIR%\compat\freeglut\freeglut.h" (
            > "%BASE_DIR%\compat\freeglut\freeglut.h" echo #include ^<GL/freeglut.h^>
        )

        set GCC_INCLUDE_FLAGS=!GCC_INCLUDE_FLAGS! -I"%BASE_DIR%\compat"
    )
)



rem ============================================================
rem Re-patch target with libraries
rem ============================================================

if /i "!COMPILER!"=="msvc" (

    for /f "delims=" %%P in ('dir /b /a-d "!TARGET_ROOT!\*.vcxproj" 2^>nul') do (

        set "RUNBAT_VCXPROJ=!TARGET_ROOT!\%%P"
        set "RUNBAT_VCX_INCLUDES=!VCX_INCLUDE_DIRS!"
        set "RUNBAT_VCX_LIBS=!VCX_LINK_FILES!"
        set "RUNBAT_VCX_IS_TARGET=1"
        set "RUNBAT_BUILD_ROOT=!BUILD_ROOT!"

        call :patch_vcxproj

        if errorlevel 1 (
            echo Warning: Failed to update !TARGET_ROOT!\%%P
        )
    )
)



rem ============================================================
rem Count projects
rem ============================================================

set "VCX_COUNT=0"

for /f "delims=" %%P in ('dir /s /b /a-d "!BUILD_ROOT!\*.vcxproj" 2^>nul') do (
    set /a VCX_COUNT+=1
)



rem ============================================================
rem Display
rem ============================================================

echo.
echo Sources:
set "DISPLAY_FOUND=0"
for %%E in (cpp cc cxx) do (
    for /f "delims=" %%F in ('dir /s /b /a-d "!BUILD_ROOT!\*.%%E" 2^>nul') do (
        call :make_relative_to_request "%%~fF" DISPLAY_ITEM
        echo   !DISPLAY_ITEM!
        set "DISPLAY_FOUND=1"
    )
)
if "!DISPLAY_FOUND!"=="0" echo   [none]

echo.
echo Headers:
set "DISPLAY_FOUND=0"
for %%E in (h hpp hh hxx) do (
    for /f "delims=" %%F in ('dir /s /b /a-d "!BUILD_ROOT!\*.%%E" 2^>nul') do (
        call :make_relative_to_request "%%~fF" DISPLAY_ITEM
        echo   !DISPLAY_ITEM!
        set "DISPLAY_FOUND=1"
    )
)
if "!DISPLAY_FOUND!"=="0" echo   [none]

echo.
echo Visual Studio projects:
set "DISPLAY_FOUND=0"
for /f "delims=" %%P in ('dir /s /b /a-d "!BUILD_ROOT!\*.vcxproj" 2^>nul') do (
    call :make_relative_to_request "%%~fP" DISPLAY_ITEM
    echo   !DISPLAY_ITEM!
    set "DISPLAY_FOUND=1"
)
if "!DISPLAY_FOUND!"=="0" echo   [none]

echo.
echo Visual Studio solution:
if defined SOLUTION_FILE (
    call :make_relative_to_request "!SOLUTION_FILE!" DISPLAY_ITEM
    echo   !DISPLAY_ITEM!
) else (
    echo   [none]
)

echo.
echo Libraries:
if defined AUTO_LIB_FILES (
    for %%L in (!AUTO_LIB_FILES!) do (
        call :make_relative_to_request "%%~fL" DISPLAY_ITEM
        echo   !DISPLAY_ITEM!
    )
) else (
    echo   [none]
)

echo.


rem ============================================================
rem Direct MSVC build
rem ============================================================

if /i "!COMPILER!"=="msvc" (

    set "MSVC_OBJ_DIR=%TEMP%\runbat_!RANDOM!_!RANDOM!"

    mkdir "!MSVC_OBJ_DIR!" >nul 2>&1

    set "CL_LOG=%TEMP%\runbat_cl_!RANDOM!_!RANDOM!.log"

    cl /nologo /EHsc /std:c++17 /utf-8 /MD !MSVC_INCLUDE_FLAGS! !SOURCES! !DEPENDENCY_SOURCES! !EXTRA_FILES! !AUTO_LIB_FILES! /Fo"!MSVC_OBJ_DIR!\\" /Fe:"!TARGET_NAME!.exe" /link opengl32.lib glu32.lib gdi32.lib winmm.lib >"!CL_LOG!" 2>&1

    set "BUILD_EXIT_CODE=!ERRORLEVEL!"

    if not "!BUILD_EXIT_CODE!"=="0" (
        type "!CL_LOG!"
    )

    del /q "!CL_LOG!" >nul 2>&1

    if exist "!MSVC_OBJ_DIR!" (
        rmdir /s /q "!MSVC_OBJ_DIR!" >nul 2>&1
    )

    if not "!BUILD_EXIT_CODE!"=="0" (
        popd
        endlocal
        exit /b 1
    )
)



rem ============================================================
rem g++
rem ============================================================

if /i "!COMPILER!"=="g++" (

    g++ -std=c++17 -finput-charset=UTF-8 -fexec-charset=UTF-8 !GCC_INCLUDE_FLAGS! !SOURCES! !DEPENDENCY_SOURCES! !EXTRA_FILES! !AUTO_LIB_FILES! -lfreeglut -lopengl32 -lglu32 -lgdi32 -lwinmm -o "!TARGET_NAME!.exe"

    if errorlevel 1 (
        popd
        endlocal
        exit /b 1
    )
)



rem ============================================================
rem Run
rem ============================================================

if "!RUN!"=="1" (

    echo.
    echo !SEPARATOR!
    echo Program output:
    echo !SEPARATOR!

    "!TARGET_NAME!.exe"

    set "PROGRAM_EXIT_CODE=!ERRORLEVEL!"

    echo.
    echo !SEPARATOR!
    echo Program finished. Exit code: !PROGRAM_EXIT_CODE!
    echo !SEPARATOR!

    popd

    endlocal & exit /b !PROGRAM_EXIT_CODE!
)


popd
endlocal
exit /b 0



rem ============================================================
rem Display path relative to Directory
rem ============================================================

:make_relative_to_request

set "REL_INPUT=%~f1"
set "REL_OUTPUT=!REL_INPUT!"

if /i "!REL_INPUT!"=="!REQUEST_ROOT!" (
    set "REL_OUTPUT=."
) else (
    set "REL_TEST=!REL_INPUT:%REQUEST_ROOT%\=!"

    if /i not "!REL_TEST!"=="!REL_INPUT!" (
        set "REL_OUTPUT=!REL_TEST!"
    ) else (
        set "REL_TEST=!REL_INPUT:%BUILD_ROOT%\=!"

        if /i not "!REL_TEST!"=="!REL_INPUT!" (
            if /i "!REQUEST_ROOT!"=="!BUILD_ROOT!" (
                set "REL_OUTPUT=!REL_TEST!"
            ) else (
                for %%R in ("!REQUEST_ROOT!\..") do (
                    if /i "%%~fR"=="!BUILD_ROOT!" set "REL_OUTPUT=..\!REL_TEST!"
                )
            )
        )
    )
)

set "%~2=!REL_OUTPUT!"
exit /b 0



rem ============================================================
rem Choose executable target
rem ============================================================

:choose_target_under_root

set "ROOT=%~f1"
set "TARGET_ROOT="


rem Prefer App

if exist "!ROOT!\App\*.cpp" (
    set "TARGET_ROOT=!ROOT!\App"
    exit /b 0
)


rem Unique main.cpp

set "MAIN_COUNT=0"
set "MAIN_DIR="

for /d %%D in ("!ROOT!\*") do (

    if exist "%%~fD\main.cpp" (
        set /a MAIN_COUNT+=1
        set "MAIN_DIR=%%~fD"
    )
)


if "!MAIN_COUNT!"=="1" (
    set "TARGET_ROOT=!MAIN_DIR!"
    exit /b 0
)


rem Existing Application project

set "APP_COUNT=0"
set "APP_DIR="

for /d %%D in ("!ROOT!\*") do (

    for %%P in ("%%~fD\*.vcxproj") do (

        if exist "%%~fP" (

            findstr /i /c:"<ConfigurationType>Application</ConfigurationType>" "%%~fP" >nul 2>&1

            if not errorlevel 1 (

                if exist "%%~fD\*.cpp" (
                    set /a APP_COUNT+=1
                    set "APP_DIR=%%~fD"
                )
            )
        )
    )
)


if "!APP_COUNT!"=="1" (
    set "TARGET_ROOT=!APP_DIR!"
    exit /b 0
)


rem Only cpp child

set "CPP_CHILD_COUNT=0"
set "CPP_CHILD_DIR="

for /d %%D in ("!ROOT!\*") do (

    if exist "%%~fD\*.cpp" (
        set /a CPP_CHILD_COUNT+=1
        set "CPP_CHILD_DIR=%%~fD"
    )
)


if "!CPP_CHILD_COUNT!"=="1" (
    set "TARGET_ROOT=!CPP_CHILD_DIR!"
    exit /b 0
)


echo.
echo Error: Could not determine executable target under:
echo   !ROOT!
echo.

echo Candidate directories:

for /d %%D in ("!ROOT!\*") do (

    if exist "%%~fD\*.cpp" (
        echo   %%~nxD
    )
)

exit /b 1



rem ============================================================
rem Add source
rem ============================================================

:add_source

set "FILE=%~1"
shift


:check_exclude

if "%~1"=="" goto include_source

if /i "%FILE%"=="%~1" (
    goto :eof
)

shift
goto check_exclude


:include_source

set SOURCES=!SOURCES! "%FILE%"

findstr /m /c:"freeglut/freeglut.h" "%FILE%" >nul 2>&1

if not errorlevel 1 (
    set "NEED_COMPAT=1"
)

goto :eof



rem ============================================================
rem Add include directory
rem ============================================================

:add_include_directory

set "INC_DIR=%~f1"

if /i "!INC_DIR!"=="!TARGET_ROOT!" goto :eof


if defined VCX_INCLUDE_DIRS (

    echo(!VCX_INCLUDE_DIRS!| findstr /i /l /c:"!INC_DIR!" >nul

    if not errorlevel 1 (
        goto :eof
    )
)


set MSVC_INCLUDE_FLAGS=!MSVC_INCLUDE_FLAGS! /I"!INC_DIR!"
set GCC_INCLUDE_FLAGS=!GCC_INCLUDE_FLAGS! -I"!INC_DIR!"

if defined VCX_INCLUDE_DIRS (
    set "VCX_INCLUDE_DIRS=!VCX_INCLUDE_DIRS!|!INC_DIR!"
) else (
    set "VCX_INCLUDE_DIRS=!INC_DIR!"
)

goto :eof



rem ============================================================
rem Add linker file
rem ============================================================

:add_vcx_link_file

set "LINK_FILE=%~f1"


if defined VCX_LINK_FILES (

    echo(!VCX_LINK_FILES!| findstr /i /l /c:"!LINK_FILE!" >nul

    if not errorlevel 1 (
        goto :eof
    )
)


if defined VCX_LINK_FILES (
    set "VCX_LINK_FILES=!VCX_LINK_FILES!|!LINK_FILE!"
) else (
    set "VCX_LINK_FILES=!LINK_FILE!"
)

goto :eof



rem ============================================================
rem Add library
rem ============================================================

:add_library

set "LIB_FILE=%~f1"


if defined AUTO_LIB_FILES (

    echo(!AUTO_LIB_FILES!| findstr /i /l /c:"!LIB_FILE!" >nul

    if not errorlevel 1 (
        goto :eof
    )
)


set AUTO_LIB_FILES=!AUTO_LIB_FILES! "!LIB_FILE!"

call :add_vcx_link_file "!LIB_FILE!"

goto :eof



rem ============================================================
rem Dependency source
rem ============================================================

:add_dependency_source

set "DEP_SOURCE=%~f1"


for %%D in ("!DEP_SOURCE!") do (
    set "DEP_DIR=%%~dpD"
    set "DEP_NAME=%%~nxD"
)


for %%E in (!EXCLUDES!) do (

    if /i "!DEP_NAME!"=="%%~E" (
        goto :eof
    )
)


if /i "!COMPILER!"=="msvc" (

    for %%P in ("!DEP_DIR!*.vcxproj") do (

        if exist "%%~fP" (

            findstr /i /c:"<ConfigurationType>StaticLibrary</ConfigurationType>" "%%~fP" >nul 2>&1

            if not errorlevel 1 (
                goto :eof
            )
        )
    )


    for /f "delims=" %%L in ('dir /s /b /a-d "!DEP_DIR!*.lib" 2^>nul') do (
        goto :eof
    )
)


set DEPENDENCY_SOURCES=!DEPENDENCY_SOURCES! "!DEP_SOURCE!"

goto :eof



rem ============================================================
rem Ensure vcxproj
rem ============================================================

:ensure_vcx_projects


call :ensure_project_for_dir "!TARGET_ROOT!" Application

if errorlevel 1 (
    exit /b 1
)


if /i not "!BUILD_ROOT!"=="!TARGET_ROOT!" (

    for /d %%D in ("!BUILD_ROOT!\*") do (

        if /i not "%%~fD"=="!TARGET_ROOT!" (

            if exist "%%~fD\*.cpp" (

                call :ensure_project_for_dir "%%~fD" StaticLibrary

                if errorlevel 1 (
                    exit /b 1
                )
            )
        )
    )
)

exit /b 0



rem ============================================================
rem Ensure project for directory
rem ============================================================

:ensure_project_for_dir

set "PROJECT_DIR=%~f1"
set "PROJECT_TYPE=%~2"

set "FOUND_PROJECT=0"


for %%P in ("!PROJECT_DIR!\*.vcxproj") do (

    if exist "%%~fP" (
        set "FOUND_PROJECT=1"
    )
)


if "!FOUND_PROJECT!"=="1" (
    exit /b 0
)


for %%D in ("!PROJECT_DIR!") do (
    set "PROJECT_NAME=%%~nxD"
)


set "PROJECT_FILE=!PROJECT_DIR!\!PROJECT_NAME!.vcxproj"

set "RUNBAT_CREATE_DIR=!PROJECT_DIR!"
set "RUNBAT_CREATE_NAME=!PROJECT_NAME!"
set "RUNBAT_CREATE_TYPE=!PROJECT_TYPE!"
set "RUNBAT_CREATE_FILE=!PROJECT_FILE!"

set "RUNBAT_TOOLSET=!PLATFORM_TOOLSET!"
set "RUNBAT_SDK=!WINDOWS_SDK_VERSION!"
set "RUNBAT_VCPROJ_VERSION=!VC_PROJECT_VERSION!"


call :create_vcxproj


if errorlevel 1 (

    echo.
    echo Error: Could not create:
    echo   !PROJECT_FILE!

    exit /b 1
)


exit /b 0



rem ============================================================
rem Create vcxproj
rem ============================================================

:create_vcxproj

powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop';$dir=$env:RUNBAT_CREATE_DIR;$name=$env:RUNBAT_CREATE_NAME;$type=$env:RUNBAT_CREATE_TYPE;$path=$env:RUNBAT_CREATE_FILE;$toolset=$env:RUNBAT_TOOLSET;$sdk=$env:RUNBAT_SDK;$vcver=$env:RUNBAT_VCPROJ_VERSION;$ns='http://schemas.microsoft.com/developer/msbuild/2003';$d=New-Object System.Xml.XmlDocument;$decl=$d.CreateXmlDeclaration('1.0','utf-8',$null);[void]$d.AppendChild($decl);$p=$d.CreateElement('Project',$ns);$p.SetAttribute('DefaultTargets','Build');[void]$d.AppendChild($p);function N($par,$n,$txt){$e=$d.CreateElement($n,$ns);if($null -ne $txt){$e.InnerText=$txt};[void]$par.AppendChild($e);return $e};$cfgs=@(@('Debug','Win32'),@('Release','Win32'),@('Debug','x64'),@('Release','x64'));$ig=N $p 'ItemGroup' $null;$ig.SetAttribute('Label','ProjectConfigurations');foreach($cfg in $cfgs){$c=$cfg[0];$plat=$cfg[1];$pc=N $ig 'ProjectConfiguration' $null;$pc.SetAttribute('Include',$c+'|'+$plat);[void](N $pc 'Configuration' $c);[void](N $pc 'Platform' $plat)};$globals=N $p 'PropertyGroup' $null;$globals.SetAttribute('Label','Globals');[void](N $globals 'VCProjectVersion' $vcver);[void](N $globals 'Keyword' 'Win32Proj');[void](N $globals 'ProjectGuid' ([guid]::NewGuid().ToString('B')));[void](N $globals 'RootNamespace' $name);[void](N $globals 'WindowsTargetPlatformVersion' $sdk);$imp=N $p 'Import' $null;$imp.SetAttribute('Project','$(VCTargetsPath)\Microsoft.Cpp.Default.props');$apos=[char]39;foreach($cfg in $cfgs){$c=$cfg[0];$plat=$cfg[1];$cond=$apos+'$(Configuration)|$(Platform)'+$apos+'=='+$apos+$c+'|'+$plat+$apos;$g=N $p 'PropertyGroup' $null;$g.SetAttribute('Condition',$cond);$g.SetAttribute('Label','Configuration');[void](N $g 'ConfigurationType' $type);if($c -eq 'Debug'){[void](N $g 'UseDebugLibraries' 'true')}else{[void](N $g 'UseDebugLibraries' 'false');if($type -eq 'StaticLibrary'){[void](N $g 'WholeProgramOptimization' 'false')}else{[void](N $g 'WholeProgramOptimization' 'true')}};[void](N $g 'PlatformToolset' $toolset);[void](N $g 'CharacterSet' 'Unicode')};$imp=N $p 'Import' $null;$imp.SetAttribute('Project','$(VCTargetsPath)\Microsoft.Cpp.props');$g=N $p 'PropertyGroup' $null;$g.SetAttribute('Label','UserMacros');foreach($cfg in $cfgs){$c=$cfg[0];$plat=$cfg[1];$cond=$apos+'$(Configuration)|$(Platform)'+$apos+'=='+$apos+$c+'|'+$plat+$apos;$idg=N $p 'ItemDefinitionGroup' $null;$idg.SetAttribute('Condition',$cond);$cl=N $idg 'ClCompile' $null;[void](N $cl 'WarningLevel' 'Level3');[void](N $cl 'SDLCheck' 'true');[void](N $cl 'ConformanceMode' 'true');[void](N $cl 'LanguageStandard' 'stdcpp17');[void](N $cl 'AdditionalOptions' '/utf-8 %%(AdditionalOptions)');if($c -eq 'Debug'){[void](N $cl 'RuntimeLibrary' 'MultiThreadedDebugDLL')}else{[void](N $cl 'RuntimeLibrary' 'MultiThreadedDLL')};if($type -eq 'Application'){$link=N $idg 'Link' $null;[void](N $link 'SubSystem' 'Console');[void](N $link 'GenerateDebugInformation' 'true')}};$imp=N $p 'Import' $null;$imp.SetAttribute('Project','$(VCTargetsPath)\Microsoft.Cpp.targets');$d.Save($path)"

exit /b !ERRORLEVEL!



rem ============================================================
rem Add StaticLibrary ProjectReference
rem ============================================================

:add_static_project_references

set "TARGET_PROJECT="


for %%P in ("!TARGET_ROOT!\*.vcxproj") do (

    if exist "%%~fP" (

        if not defined TARGET_PROJECT (
            set "TARGET_PROJECT=%%~fP"
        )
    )
)


if not defined TARGET_PROJECT (
    exit /b 0
)


set "RUNBAT_TARGET_PROJECT=!TARGET_PROJECT!"
set "RUNBAT_BUILD_ROOT=!BUILD_ROOT!"


powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop';$target=$env:RUNBAT_TARGET_PROJECT;$root=$env:RUNBAT_BUILD_ROOT;$d=New-Object System.Xml.XmlDocument;$d.PreserveWhitespace=$true;$d.Load($target);$ns=$d.DocumentElement.NamespaceURI;$tdir=Split-Path -Parent $target;function Rel($base,$path){$b=[IO.Path]::GetFullPath($base).TrimEnd('\')+'\';$u1=New-Object System.Uri($b);$u2=New-Object System.Uri([IO.Path]::GetFullPath($path));return [Uri]::UnescapeDataString($u1.MakeRelativeUri($u2).ToString()).Replace('/','\')};function Child($parent,$name,$value){$c=@($parent.ChildNodes)|Where-Object{$_.LocalName -eq $name}|Select-Object -First 1;if(-not $c){$c=$d.CreateElement($name,$ns);[void]$parent.AppendChild($c)};if($null -ne $value){$c.InnerText=$value};return $c};$existing=@{};foreach($e in @($d.GetElementsByTagName('ProjectReference'))){try{$f=[IO.Path]::GetFullPath((Join-Path $tdir $e.GetAttribute('Include')));$existing[$f.ToLowerInvariant()]=$e;[void](Child $e 'LinkLibraryDependencies' 'true')}catch{}};$group=$null;$refs=@(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.vcxproj' -File -ErrorAction SilentlyContinue);foreach($r in $refs){if($r.FullName -ieq $target){continue};$rd=New-Object System.Xml.XmlDocument;$rd.Load($r.FullName);$isStatic=$false;foreach($ct in @($rd.GetElementsByTagName('ConfigurationType'))){if($ct.InnerText -eq 'StaticLibrary'){$isStatic=$true;break}};if(-not $isStatic){continue};$key=$r.FullName.ToLowerInvariant();if($existing.ContainsKey($key)){continue};if(-not $group){$group=$d.CreateElement('ItemGroup',$ns);$targetImport=@($d.DocumentElement.ChildNodes)|Where-Object{$_.LocalName -eq 'Import' -and $_.GetAttribute('Project') -like '*Microsoft.Cpp.targets'}|Select-Object -First 1;if($targetImport){[void]$d.DocumentElement.InsertBefore($group,$targetImport)}else{[void]$d.DocumentElement.AppendChild($group)}};$pr=$d.CreateElement('ProjectReference',$ns);$pr.SetAttribute('Include',(Rel $tdir $r.FullName));$guid=@($rd.GetElementsByTagName('ProjectGuid'))|Select-Object -First 1;if($guid){$gn=$d.CreateElement('Project',$ns);$gn.InnerText=$guid.InnerText;[void]$pr.AppendChild($gn)};[void](Child $pr 'LinkLibraryDependencies' 'true');[void]$group.AppendChild($pr);$existing[$key]=$pr};$d.Save($target)"

exit /b !ERRORLEVEL!



rem ============================================================
rem Ensure Visual Studio solution
rem ============================================================

:ensure_solution

set "SOLUTION_FILE="

for %%S in ("!BUILD_ROOT!\*.sln") do (
    if exist "%%~fS" (
        if not defined SOLUTION_FILE set "SOLUTION_FILE=%%~fS"
    )
)

if defined SOLUTION_FILE (
    exit /b 0
)

for %%D in ("!BUILD_ROOT!") do (
    set "SOLUTION_NAME=%%~nxD"
)

set "SOLUTION_FILE=!BUILD_ROOT!\!SOLUTION_NAME!.sln"
set "RUNBAT_SOLUTION_FILE=!SOLUTION_FILE!"
set "RUNBAT_SOLUTION_ROOT=!BUILD_ROOT!"
set "RUNBAT_SOLUTION_TARGET=!TARGET_ROOT!"

powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop';$out=$env:RUNBAT_SOLUTION_FILE;$root=$env:RUNBAT_SOLUTION_ROOT;$targetDir=$env:RUNBAT_SOLUTION_TARGET;function Rel($base,$path){$b=[IO.Path]::GetFullPath($base).TrimEnd('\')+'\';$u1=New-Object System.Uri($b);$u2=New-Object System.Uri([IO.Path]::GetFullPath($path));return [Uri]::UnescapeDataString($u1.MakeRelativeUri($u2).ToString()).Replace('/','\')};$items=@();foreach($f in @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.vcxproj' -File -ErrorAction SilentlyContinue)){try{$d=New-Object System.Xml.XmlDocument;$d.Load($f.FullName);$g=@($d.GetElementsByTagName('ProjectGuid'))|Select-Object -First 1;if(-not $g){continue};$name=[IO.Path]::GetFileNameWithoutExtension($f.Name);$isTarget=((Split-Path -Parent $f.FullName) -ieq $targetDir);$items+=[pscustomobject]@{Name=$name;Path=(Rel $root $f.FullName);Guid=$g.InnerText.ToUpperInvariant();Target=$isTarget}}catch{}};$items=@($items|Sort-Object @{Expression='Target';Descending=$true},Name);$cppType='{8BC9CEB8-8B4A-11D0-8D11-00A0C91BC942}';$q=[char]34;$sb=New-Object Text.StringBuilder;[void]$sb.AppendLine('Microsoft Visual Studio Solution File, Format Version 12.00');[void]$sb.AppendLine('# Visual Studio Version 17');[void]$sb.AppendLine('VisualStudioVersion = 17.0.31903.59');[void]$sb.AppendLine('MinimumVisualStudioVersion = 10.0.40219.1');foreach($x in $items){[void]$sb.AppendLine(('Project('+$q+$cppType+$q+') = '+$q+$x.Name+$q+', '+$q+$x.Path+$q+', '+$q+$x.Guid+$q));[void]$sb.AppendLine('EndProject')};[void]$sb.AppendLine('Global');[void]$sb.AppendLine('    GlobalSection(SolutionConfigurationPlatforms) = preSolution');[void]$sb.AppendLine('        Debug|x64 = Debug|x64');[void]$sb.AppendLine('        Release|x64 = Release|x64');[void]$sb.AppendLine('    EndGlobalSection');[void]$sb.AppendLine('    GlobalSection(ProjectConfigurationPlatforms) = postSolution');foreach($x in $items){foreach($c in @('Debug','Release')){[void]$sb.AppendLine(('        '+$x.Guid+'.'+$c+'|x64.ActiveCfg = '+$c+'|x64'));[void]$sb.AppendLine(('        '+$x.Guid+'.'+$c+'|x64.Build.0 = '+$c+'|x64'))}};[void]$sb.AppendLine('    EndGlobalSection');[void]$sb.AppendLine('EndGlobal');[IO.File]::WriteAllText($out,$sb.ToString(),(New-Object Text.UTF8Encoding($false)))"

if errorlevel 1 (
    echo Error: Could not create Visual Studio solution.
    exit /b 1
)

exit /b 0



rem ============================================================
rem MSVC setup
rem ============================================================

:setup_msvc

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"


where cl >nul 2>&1

if errorlevel 1 (

    if not exist "!VSWHERE!" (
        echo Error: vswhere.exe was not found.
        exit /b 1
    )


    set "VS_INSTALL="


    for /f "usebackq delims=" %%V in (`"!VSWHERE!" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do (
        if not defined VS_INSTALL set "VS_INSTALL=%%V"
    )


    if not defined VS_INSTALL (
        echo Error: Visual Studio C++ tools were not found.
        exit /b 1
    )


    set "VCVARS=!VS_INSTALL!\VC\Auxiliary\Build\vcvars64.bat"


    if not exist "!VCVARS!" (
        echo Error: vcvars64.bat was not found.
        exit /b 1
    )


    call "!VCVARS!" >nul 2>&1
)


where cl >nul 2>&1

if errorlevel 1 (
    echo Error: cl.exe could not be initialized.
    exit /b 1
)


set "MSBUILD_EXE="


for /f "delims=" %%M in ('where msbuild 2^>nul') do (
    if not defined MSBUILD_EXE set "MSBUILD_EXE=%%M"
)


if not defined MSBUILD_EXE (

    if exist "!VSWHERE!" (

        for /f "usebackq delims=" %%M in (`"!VSWHERE!" -latest -products * -find MSBuild\**\Bin\MSBuild.exe`) do (
            if not defined MSBUILD_EXE set "MSBUILD_EXE=%%M"
        )
    )
)

exit /b 0



rem ============================================================
rem Build StaticLibrary projects
rem ============================================================

:build_static_libraries

if not defined MSBUILD_EXE (
    exit /b 0
)


for /f "delims=" %%P in ('dir /s /b /a-d "!BUILD_ROOT!\*.vcxproj" 2^>nul') do (

    for %%Q in ("%%~dpP.") do (
        set "PROJECT_DIR=%%~fQ"
    )


    if /i not "!PROJECT_DIR!"=="!TARGET_ROOT!" (

        findstr /i /c:"<ConfigurationType>StaticLibrary</ConfigurationType>" "%%~fP" >nul 2>&1

        if not errorlevel 1 (

            set "MSBUILD_LOG=%TEMP%\runbat_msbuild_!RANDOM!_!RANDOM!.log"

            "!MSBUILD_EXE!" "%%~fP" /nologo /p:Configuration=Release /p:Platform=x64 /p:WholeProgramOptimization=false /verbosity:quiet >"!MSBUILD_LOG!" 2>&1
            set "MSBUILD_EXIT=!ERRORLEVEL!"

            if not "!MSBUILD_EXIT!"=="0" (
                type "!MSBUILD_LOG!"
                del /q "!MSBUILD_LOG!" >nul 2>&1
                echo Error: Static library project build failed.
                exit /b 1
            )

            del /q "!MSBUILD_LOG!" >nul 2>&1
        )
    )
)

exit /b 0



rem ============================================================
rem Patch / synchronize vcxproj
rem
rem Important:
rem
rem 1. Retargets to v145
rem 2. C++17
rem 3. UTF-8
rem 4. Adds include directories
rem 5. Adds libraries
rem 6. Synchronizes ALL source/header files from disk
rem ============================================================

:patch_vcxproj

set "RUNBAT_TOOLSET=!PLATFORM_TOOLSET!"
set "RUNBAT_SDK=!WINDOWS_SDK_VERSION!"
set "RUNBAT_VCPROJ_VERSION=!VC_PROJECT_VERSION!"


powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop';$p=$env:RUNBAT_VCXPROJ;$toolset=$env:RUNBAT_TOOLSET;$sdk=$env:RUNBAT_SDK;$vcver=$env:RUNBAT_VCPROJ_VERSION;$root=$env:RUNBAT_BUILD_ROOT;$doc=New-Object System.Xml.XmlDocument;$doc.PreserveWhitespace=$true;$doc.Load($p);$ns=$doc.DocumentElement.NamespaceURI;$projectDir=Split-Path -Parent $p;function Child($parent,$name){$c=@($parent.ChildNodes)|Where-Object{$_.LocalName -eq $name}|Select-Object -First 1;if(-not $c){$c=$doc.CreateElement($name,$ns);[void]$parent.AppendChild($c)};return $c};function Rel($base,$path){$b=[IO.Path]::GetFullPath($base).TrimEnd('\')+'\';$u1=New-Object System.Uri($b);$u2=New-Object System.Uri([IO.Path]::GetFullPath($path));$r=[Uri]::UnescapeDataString($u1.MakeRelativeUri($u2).ToString()).Replace('/','\');if([string]::IsNullOrWhiteSpace($r)){return '.'};return $r};$globals=@($doc.DocumentElement.ChildNodes)|Where-Object{$_.LocalName -eq 'PropertyGroup' -and $_.GetAttribute('Label') -eq 'Globals'}|Select-Object -First 1;if(-not $globals){$globals=$doc.CreateElement('PropertyGroup',$ns);$globals.SetAttribute('Label','Globals');[void]$doc.DocumentElement.PrependChild($globals)};(Child $globals 'VCProjectVersion').InnerText=$vcver;(Child $globals 'WindowsTargetPlatformVersion').InnerText=$sdk;$projectTypeNode=@($doc.GetElementsByTagName('ConfigurationType'))|Select-Object -First 1;$projectType=if($projectTypeNode){$projectTypeNode.InnerText}else{''};$configs=@($doc.DocumentElement.ChildNodes)|Where-Object{$_.LocalName -eq 'PropertyGroup' -and $_.GetAttribute('Label') -eq 'Configuration'};foreach($cfg in $configs){(Child $cfg 'PlatformToolset').InnerText=$toolset;if($projectType -eq 'StaticLibrary' -and $cfg.GetAttribute('Condition') -match 'Release'){(Child $cfg 'WholeProgramOptimization').InnerText='false'}};$defs=@($doc.DocumentElement.ChildNodes)|Where-Object{$_.LocalName -eq 'ItemDefinitionGroup'};foreach($idg in $defs){$cond=$idg.GetAttribute('Condition');if($cond){$cl=Child $idg 'ClCompile';(Child $cl 'LanguageStandard').InnerText='stdcpp17';(Child $cl 'AdditionalOptions').InnerText='/utf-8 %%(AdditionalOptions)';if($cond -match 'Debug'){(Child $cl 'RuntimeLibrary').InnerText='MultiThreadedDebugDLL'}else{(Child $cl 'RuntimeLibrary').InnerText='MultiThreadedDLL'}}};$internal=@{};if($root -and (Test-Path -LiteralPath $root)){foreach($rp in @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.vcxproj' -File -ErrorAction SilentlyContinue)){if($rp.FullName -ieq $p){continue};try{$rd=New-Object System.Xml.XmlDocument;$rd.Load($rp.FullName);$isStatic=$false;foreach($ct in @($rd.GetElementsByTagName('ConfigurationType'))){if($ct.InnerText -eq 'StaticLibrary'){$isStatic=$true;break}};if($isStatic){$internal[([IO.Path]::GetFileNameWithoutExtension($rp.Name)+'.lib').ToLowerInvariant()]=$true}}catch{}}};if($env:RUNBAT_VCX_IS_TARGET -eq '1' -and $internal.Count -gt 0){foreach($dn in @($doc.GetElementsByTagName('AdditionalDependencies'))){$keep=@();foreach($part in @($dn.InnerText -split ';')){$v=$part.Trim();if(-not $v){continue};$low=$v.ToLowerInvariant();$drop=$false;foreach($iname in $internal.Keys){if($low -eq $iname -or $low.EndsWith('\'+$iname) -or $low.EndsWith('/'+$iname) -or $low.EndsWith(')'+$iname)){$drop=$true;break}};if($drop){continue};$keep+=$v};$dn.InnerText=$keep -join ';'}};$targetImport=@($doc.DocumentElement.ChildNodes)|Where-Object{$_.LocalName -eq 'Import' -and $_.GetAttribute('Project') -like '*Microsoft.Cpp.targets'}|Select-Object -First 1;$compileGroup=@($doc.DocumentElement.ChildNodes)|Where-Object{$_.LocalName -eq 'ItemGroup' -and @($_.ChildNodes|Where-Object{$_.LocalName -eq 'ClCompile' -and $_.HasAttribute('Include')}).Count -gt 0}|Select-Object -First 1;if(-not $compileGroup){$compileGroup=$doc.CreateElement('ItemGroup',$ns);if($targetImport){[void]$doc.DocumentElement.InsertBefore($compileGroup,$targetImport)}else{[void]$doc.DocumentElement.AppendChild($compileGroup)}};$headerGroup=@($doc.DocumentElement.ChildNodes)|Where-Object{$_.LocalName -eq 'ItemGroup' -and @($_.ChildNodes|Where-Object{$_.LocalName -eq 'ClInclude' -and $_.HasAttribute('Include')}).Count -gt 0}|Select-Object -First 1;if(-not $headerGroup){$headerGroup=$doc.CreateElement('ItemGroup',$ns);if($targetImport){[void]$doc.DocumentElement.InsertBefore($headerGroup,$targetImport)}else{[void]$doc.DocumentElement.AppendChild($headerGroup)}};$existingCpp=@{};foreach($n in @($doc.GetElementsByTagName('ClCompile'))){if($n.HasAttribute('Include')){try{$full=[IO.Path]::GetFullPath((Join-Path $projectDir $n.GetAttribute('Include')));$existingCpp[$full.ToLowerInvariant()]=$true}catch{}}};$existingHdr=@{};foreach($n in @($doc.GetElementsByTagName('ClInclude'))){if($n.HasAttribute('Include')){try{$full=[IO.Path]::GetFullPath((Join-Path $projectDir $n.GetAttribute('Include')));$existingHdr[$full.ToLowerInvariant()]=$true}catch{}}};$cppFiles=@(Get-ChildItem -LiteralPath $projectDir -Recurse -File -ErrorAction SilentlyContinue|Where-Object{$_.Extension.ToLowerInvariant() -in @('.cpp','.cc','.cxx') -and $_.FullName -notmatch '\\(Debug|Release|x64|Win32|\.vs)\\'});foreach($f in $cppFiles){$key=$f.FullName.ToLowerInvariant();if(-not $existingCpp.ContainsKey($key)){$e=$doc.CreateElement('ClCompile',$ns);$e.SetAttribute('Include',(Rel $projectDir $f.FullName));[void]$compileGroup.AppendChild($e);$existingCpp[$key]=$true}};$hdrFiles=@(Get-ChildItem -LiteralPath $projectDir -Recurse -File -ErrorAction SilentlyContinue|Where-Object{$_.Extension.ToLowerInvariant() -in @('.h','.hpp','.hh','.hxx') -and $_.FullName -notmatch '\\(Debug|Release|x64|Win32|\.vs)\\'});foreach($f in $hdrFiles){$key=$f.FullName.ToLowerInvariant();if(-not $existingHdr.ContainsKey($key)){$e=$doc.CreateElement('ClInclude',$ns);$e.SetAttribute('Include',(Rel $projectDir $f.FullName));[void]$headerGroup.AppendChild($e);$existingHdr[$key]=$true}};$group=@($doc.DocumentElement.ChildNodes)|Where-Object{$_.LocalName -eq 'ItemDefinitionGroup' -and $_.GetAttribute('Label') -eq 'RunBatAuto'}|Select-Object -First 1;if(-not $group){$group=$doc.CreateElement('ItemDefinitionGroup',$ns);$group.SetAttribute('Label','RunBatAuto')};if($targetImport){if($group.ParentNode){[void]$group.ParentNode.RemoveChild($group)};[void]$doc.DocumentElement.InsertBefore($group,$targetImport)}elseif(-not $group.ParentNode){[void]$doc.DocumentElement.AppendChild($group)};$cl=Child $group 'ClCompile';(Child $cl 'LanguageStandard').InnerText='stdcpp17';(Child $cl 'AdditionalOptions').InnerText='/utf-8 %%(AdditionalOptions)';$inc=Child $cl 'AdditionalIncludeDirectories';$incs=@();if($env:RUNBAT_VCX_INCLUDES){foreach($ip in @($env:RUNBAT_VCX_INCLUDES -split '\|')){if(-not $ip){continue};if([IO.Path]::IsPathRooted($ip)){$incs+=(Rel $projectDir $ip)}else{$incs+=$ip}}};$incs+='%%(AdditionalIncludeDirectories)';$inc.InnerText=$incs -join ';';if($env:RUNBAT_VCX_IS_TARGET -eq '1'){$link=Child $group 'Link';$deps=Child $link 'AdditionalDependencies';$libs=@();if($env:RUNBAT_VCX_LIBS){foreach($lp in @($env:RUNBAT_VCX_LIBS -split '\|')){if(-not $lp){continue};$leaf=[IO.Path]::GetFileName($lp).ToLowerInvariant();if($internal.ContainsKey($leaf)){continue};if([IO.Path]::IsPathRooted($lp)){$libs+=(Rel $projectDir $lp)}else{$libs+=$lp}}};$libs+='opengl32.lib';$libs+='glu32.lib';$libs+='gdi32.lib';$libs+='winmm.lib';$libs+='%%(AdditionalDependencies)';$deps.InnerText=$libs -join ';'};$doc.Save($p)"

exit /b !ERRORLEVEL!



rem ============================================================
rem Usage
rem ============================================================

:usage

echo Usage:
echo   run.bat [directory regex path] [-r] [-g] [-i FILE] ([files to exclude] ...)
echo.
echo Compiler:
echo   default       MSVC
echo   -g            MinGW g++
echo.
echo Options:
echo   -r            Run after compilation
echo   -g            Use g++
echo   -i FILE       Include file
echo.
echo Examples:
echo.
echo   MSVC:
echo     run.bat top.*/.*/bottom.*1 -r
echo.
echo   g++:
echo     run.bat top.*/.*/bottom.*1 -g -r
echo.
echo   Exclude a source:
echo     run.bat top.*/.*/bottom.*1 A.cpp -r
echo.
echo   Include a source:
echo     run.bat top.*/.*/bottom.*1 -i helper.cpp -r

endlocal
exit /b 1
