@echo off
setlocal EnableExtensions EnableDelayedExpansion

if "%~1"=="" goto usage

set "BASE_DIR=%CD%"

set "PATTERN=%~1"
set "PATTERN=%PATTERN:/=\%"

set "TARGET="
set "TARGET_ABS="

set "KEEP_EXTS=cpp h lib dll pdf tex txt md zip png jpg jpeg obj mtl bat"

set "DELETED_COUNT=0"
set "REMOVED_DIR_COUNT=0"
set "BUILD_DIR_COUNT=0"
set "BUILD_OUTPUT_HEADER_SHOWN=0"

set "DELETE_STATS_FILE=%TEMP%\erase_stats_!RANDOM!_!RANDOM!.txt"
set "SORTED_STATS_FILE=%TEMP%\erase_stats_sorted_!RANDOM!_!RANDOM!.txt"

shift


rem ============================================================
rem Options
rem ============================================================

:collect_options

if "%~1"=="" goto find_target


if /i "%~1"=="-a" (

    if "%~2"=="" (
        echo Error: -a requires an extension.
        goto usage
    )

    call :add_keep_extension "%~2"

    if errorlevel 1 (
        exit /b 1
    )

    shift
    shift
    goto collect_options
)


echo Error: Unknown option: %~1
goto usage



rem ============================================================
rem Find target directory
rem
rem A single dot selects the current directory.
rem The path is resolved one directory component at a time.
rem Each component is treated as a regular expression.
rem ============================================================

:find_target

if "%PATTERN%"=="." (
    set "TARGET=."
    set "TARGET_ABS=%BASE_DIR%"
    goto display_target
)

set "SEARCH_PATH=."
set "REMAINING=%PATTERN%"


:find_next_part

for /f "tokens=1,* delims=\" %%A in ("!REMAINING!") do (
    set "PART=%%A"
    set "REMAINING=%%B"
)

set "FOUND="

for /f "delims=" %%D in ('
    dir /b /ad "!SEARCH_PATH!" 2^>nul ^| findstr /r /x /c:"!PART!"
') do (
    if not defined FOUND set "FOUND=%%D"
)

if not defined FOUND goto usage

if "!SEARCH_PATH!"=="." (
    set "SEARCH_PATH=!FOUND!"
) else (
    set "SEARCH_PATH=!SEARCH_PATH!\!FOUND!"
)

if defined REMAINING goto find_next_part


set "TARGET=!SEARCH_PATH!"

for %%D in ("!TARGET!") do (
    set "TARGET_ABS=%%~fD"
)



rem ============================================================
rem Display target
rem ============================================================

:display_target

echo Directory: !TARGET!
echo.



rem ============================================================
rem Default cleanup
rem
rem Recursively cleans the selected directory.
rem
rem Preserved by default:
rem   .cpp .h .lib .dll .pdf .tex .txt .md .zip .png .jpg .jpeg .obj .mtl .bat
rem
rem Additional extensions can be preserved with -a.
rem
rem Debug and Release are treated as build-output directories:
rem their entire directory trees are removed regardless of file
rem extension.
rem
rem Other deleted files are summarized by extension instead of
rem being printed one by one.
rem
rem Finally, empty directories are removed deepest-first.
rem The selected root directory itself is never removed.
rem ============================================================

type nul > "!DELETE_STATS_FILE!"


rem Remove Debug and Release build-output trees completely.
rem Each removed build directory is shown with its file count.

call :purge_build_output_dirs "!TARGET_ABS!"


rem Delete every remaining file except preserved extensions.
rem Hidden/system files are included.
rem Successful deletions are counted by extension, not printed.

for /f "delims=" %%F in ('dir /s /b /a-d "!TARGET!" 2^>nul') do (
    call :sweep_file "%%~fF"
)


rem Remove empty subdirectories strictly bottom-up.
rem Individual empty-directory removals are not printed.

call :remove_empty_subdirectories "!TARGET_ABS!"


rem Print extension-based deletion statistics for ordinary files.

call :print_extension_summary



if exist "!DELETE_STATS_FILE!" del /q "!DELETE_STATS_FILE!" >nul 2>&1
if exist "!SORTED_STATS_FILE!" del /q "!SORTED_STATS_FILE!" >nul 2>&1

endlocal
exit /b 0



rem ============================================================
rem Add preserved extension
rem
rem Both forms are accepted:
rem   -a txt
rem   -a .txt
rem
rem -a may be repeated.
rem ============================================================

:add_keep_extension

set "NEW_EXT=%~1"

if "!NEW_EXT:~0,1!"=="." (
    set "NEW_EXT=!NEW_EXT:~1!"
)

if not defined NEW_EXT (
    echo Error: Invalid extension.
    exit /b 1
)


for %%E in (!KEEP_EXTS!) do (
    if /i "%%E"=="!NEW_EXT!" (
        exit /b 0
    )
)

set "KEEP_EXTS=!KEEP_EXTS! !NEW_EXT!"

exit /b 0



rem ============================================================
rem Find and purge Debug / Release directory trees
rem
rem Any child directory named exactly Debug or Release is removed
rem as a whole. Other directories are traversed recursively so
rem nested build-output directories are also found.
rem ============================================================

:purge_build_output_dirs

for /f "delims=" %%D in ('dir /b /a:d "%~f1\*" 2^>nul') do (

    if /i "%%D"=="Debug" (

        call :remove_directory_tree "%~f1\%%D"

    ) else if /i "%%D"=="Release" (

        call :remove_directory_tree "%~f1\%%D"

    ) else (

        call :purge_build_output_dirs "%~f1\%%D"
    )
)

goto :eof



rem ============================================================
rem Remove one Debug / Release directory tree completely
rem
rem The number of contained files is counted before deletion.
rem Build-output directories are shown individually because they
rem are intentionally removed as complete trees.
rem ============================================================

:remove_directory_tree

set "TREE=%~f1"
set "TREE_FILE_COUNT=0"


for /f "delims=" %%F in ('dir /s /b /a-d "!TREE!" 2^>nul') do (
    set /a TREE_FILE_COUNT+=1
)


rd /s /q "!TREE!" >nul 2>&1


if not exist "!TREE!\" (

    set /a BUILD_DIR_COUNT+=1

    if "!BUILD_OUTPUT_HEADER_SHOWN!"=="0" (
        echo Removed build directories:
        set "BUILD_OUTPUT_HEADER_SHOWN=1"
    )

    set "DISPLAY=!TREE!"
    set "DISPLAY=!DISPLAY:%TARGET_ABS%\=!"

    echo   !DISPLAY! ^(!TREE_FILE_COUNT! files^)

) else (

    set "DISPLAY=!TREE!"
    set "DISPLAY=!DISPLAY:%TARGET_ABS%\=!"

    echo Failed to remove build directory: !DISPLAY!
)

goto :eof



rem ============================================================
rem Sweep one ordinary file
rem
rem Files are preserved only when their extension appears in
rem KEEP_EXTS. Files with no extension are deleted.
rem
rem Successful deletions are recorded in a temporary statistics
rem file so they can later be grouped by extension.
rem ============================================================

:sweep_file

set "FILE=%~f1"
set "EXT=%~x1"

if defined EXT (
    set "EXT=!EXT:~1!"
)

set "KEEP=0"

for %%E in (!KEEP_EXTS!) do (
    if /i "!EXT!"=="%%E" (
        set "KEEP=1"
    )
)

if "!KEEP!"=="1" (
    goto :eof
)


del /f /q /a "!FILE!" >nul 2>&1

if not exist "!FILE!" (

    set /a DELETED_COUNT+=1

    if defined EXT (
        >> "!DELETE_STATS_FILE!" echo .!EXT!
    ) else (
        >> "!DELETE_STATS_FILE!" echo [no extension]
    )

) else (

    set "DISPLAY=!FILE!"
    set "DISPLAY=!DISPLAY:%TARGET_ABS%\=!"

    echo Failed to delete: !DISPLAY!
)

goto :eof



rem ============================================================
rem Print ordinary-file deletion counts grouped by extension
rem ============================================================

:print_extension_summary

if "!BUILD_OUTPUT_HEADER_SHOWN!"=="1" (
    echo.
)


for %%S in ("!DELETE_STATS_FILE!") do (
    if %%~zS==0 (
        echo Deleted files by extension:
        echo   [none]
        echo.
        goto :eof
    )
)


sort "!DELETE_STATS_FILE!" /o "!SORTED_STATS_FILE!" >nul


echo Deleted files by extension:

set "LAST_EXT="
set "EXT_COUNT=0"


for /f "usebackq delims=" %%E in ("!SORTED_STATS_FILE!") do (

    if not defined LAST_EXT (

        set "LAST_EXT=%%E"
        set "EXT_COUNT=1"

    ) else if /i "%%E"=="!LAST_EXT!" (

        set /a EXT_COUNT+=1

    ) else (

        echo   !LAST_EXT!: !EXT_COUNT!

        set "LAST_EXT=%%E"
        set "EXT_COUNT=1"
    )
)


if defined LAST_EXT (
    echo   !LAST_EXT!: !EXT_COUNT!
)

echo.

goto :eof



rem ============================================================
rem Remove empty subdirectories recursively
rem
rem Each child is processed before its parent, guaranteeing
rem deepest-first deletion.
rem
rem Individual removed directories are intentionally not printed.
rem
rem rd without /s succeeds only when the directory is empty.
rem The selected root directory is never removed.
rem ============================================================

:remove_empty_subdirectories

for /f "delims=" %%D in ('dir /b /a:d "%~f1\*" 2^>nul') do (
    if exist "%~f1\%%D\" (
        call :remove_empty_subdirectories "%~f1\%%D"
    )
)


if /i "%~f1"=="!TARGET_ABS!" goto :eof


rd "%~f1" >nul 2>&1

if not exist "%~f1\" (
    set /a REMOVED_DIR_COUNT+=1
)

goto :eof



rem ============================================================
rem Usage
rem ============================================================

:usage

echo Usage:
echo   erase.bat [directory regex path]
echo   erase.bat [directory regex path] [-a EXT] ...
echo.
echo Default behavior:
echo   Recursively cleans the selected directory.
echo   Keeps:
echo                   .cpp .h .lib .dll .pdf .tex .txt .md
echo                   .zip .png .jpg .jpeg .obj .mtl .bat
echo   Debug and Release directories are removed completely
echo   regardless of file extension.
echo   Other deleted files are summarized by extension and count.
echo   Empty subdirectories are removed deepest-first.
echo.
echo Options:
echo   -a EXT        Preserve one additional extension.
echo                 May be repeated. Leading dot is optional.
echo.
echo Examples:
echo   erase.bat top.*/.*/bottom.*1
echo   erase.bat top.*/.*/bottom.*1 -a c

endlocal
exit /b 1
