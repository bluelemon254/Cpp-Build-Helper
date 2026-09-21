# C++ Build Helper

Windows `cmd`에서 C++ 프로젝트를 간단하게 빌드하고 실행하기 위한 배치 스크립트입니다.

## Files

* `run.bat` — 빌드 및 실행
* `erase.bat` — 생성된 실행 파일과 빌드 파일 삭제

## Prerequisites

### MSVC 사용 시

* Visual Studio 또는 Visual Studio Build Tools
* C++ 개발 도구 설치

### `-g` 옵션으로 g++ 사용 시

* `g++`가 `PATH`에 등록되어 있어야 함
* OpenGL 프로젝트라면 freeglut도 설치되어 있어야 함

## Visual Studio 프로젝트

`run.bat`은 `.vcxproj`를 자동으로 생성할 수 있습니다.

Visual Studio 버전이나 Windows SDK 버전은 직접 고정하지 않고,
**현재 컴퓨터에 설치된 기본값을 사용합니다.**

따라서 다른 컴퓨터에서도 해당 컴퓨터의 Visual Studio 환경에 맞게 빌드됩니다.

대신 다음 항목은 프로젝트마다 달라지지 않도록 `run.bat`이 직접 지정합니다.

* C++17
* x64
* UTF-8
* Console Application
* Debug: `/MDd`
* Release: `/MD`
* 예외 처리: `/EHsc`
* OpenGL 프로젝트의 필요한 라이브러리

즉,

**Visual Studio 기본값 사용**

* MSVC toolset 버전 (`v143`, `v145` 등)
* Windows SDK 버전

**`run.bat`이 지정**

* C++17
* x64
* UTF-8
* Debug / Release 설정
* 출력 위치
* OpenGL / freeglut 설정

## freeglut

OpenGL 프로젝트에서는 freeglut 설치 위치를 자동으로 찾아 사용합니다.

MSYS2를 사용한다면 보통 다음 위치에 있습니다.

`C:\msys64\ucrt64`

컴퓨터를 옮겼다면 경로가 달라질 수 있으므로
**새 컴퓨터에서 `run.bat`을 한 번 실행하면 됩니다.**
