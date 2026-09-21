# C++ Build Helper

Windows에서 간단한 C++ 프로젝트를 명령줄에서 빌드하고 실행하기 위한
배치 스크립트입니다.

## Files

- `run.bat` — C++ 소스 빌드 및 실행
- `erase.bat` — 생성된 실행 파일 / 빌드 결과 삭제

## Prerequisites

### 공통

### `run.bat`
- **Windows `cmd.exe` 환경**
- **PowerShell**
- **C++17 컴파일러** 중 하나

#### 기본: MSVC
- Visual Studio 또는 **Visual Studio Build Tools + C++ workload**
- 필요 도구:
  - `cl.exe`
  - `vcvars64.bat`
  - `vswhere.exe` (환경이 이미 잡혀 있지 않을 때)
  - `MSBuild.exe` (Static Library 프로젝트 빌드 시)
- 스크립트가 프로젝트를 다음 값으로 retarget함:
  - `PlatformToolset = v145`
  - `WindowsTargetPlatformVersion = 10.0`
  - `C++17`

#### `-g`: MinGW g++
- `g++`가 `PATH`에 있어야 함
- **freeglut 개발 파일** 필요
  - `GL/freeglut.h`
  - `libfreeglut` (`-lfreeglut`로 링크 가능해야 함)

### `erase.bat`
- **Windows `cmd.exe` 환경**
