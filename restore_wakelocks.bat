@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul
rem ============================================================================
rem restore_wakelocks.bat: откат запрета вейклоков (WAKE_LOCK), сделанного freeze_wakelocks.bat.
rem Канал: @ByteAutomate_AI (https://t.me/ByteAutomate_AI)
rem
rem   restore_wakelocks.bat               вернуть прежние режимы всем пакетам из wakelock_changes.txt
rem   restore_wakelocks.bat pkg ИМЯ.ПАКЕТА   вернуть права одному приложению (режим default)
rem
rem Нужно: adb в PATH, телефон подключён, «Отладка по USB» включена.
rem ============================================================================

set "STATE=%~dp0wakelock_changes.txt"

where adb >nul 2>&1
if errorlevel 1 (
  echo ОШИБКА: adb не найден в PATH.
  pause
  exit /b 1
)

set "DEVSTATE="
for /f "delims=" %%S in ('adb get-state 2^>nul') do set "DEVSTATE=%%S"
if /i not "!DEVSTATE!"=="device" (
  echo ОШИБКА: телефон не готов ^(adb get-state = "!DEVSTATE!"^).
  pause
  exit /b 1
)

rem Откат одного приложения
if /i "%~1"=="pkg" (
  if "%~2"=="" (
    echo Укажите пакет: restore_wakelocks.bat pkg ИМЯ.ПАКЕТА
    pause
    exit /b 2
  )
  adb shell cmd appops set "%~2" WAKE_LOCK default >nul 2>&1
  if errorlevel 1 (
    echo ОШИБКА: не удалось вернуть права для %~2
    pause
    exit /b 1
  )
  echo Готово: %~2: WAKE_LOCK -^> default
  pause
  exit /b 0
)

rem Откат по журналу
if not exist "%STATE%" (
  echo Журнал wakelock_changes.txt не найден: откатывать нечего.
  pause
  exit /b 1
)
set /a OK=0
set /a FAIL=0
for /f "usebackq tokens=1,2 delims=|" %%A in ("%STATE%") do (
  set "PRV=%%B"
  if "!PRV!"=="" set "PRV=default"
  adb shell cmd appops set %%A WAKE_LOCK !PRV! >nul 2>&1
  if errorlevel 1 (
    echo   ОШИБКА: %%A
    set /a FAIL+=1
  ) else (
    echo   вернул: %%A -^> !PRV!
    set /a OK+=1
  )
)
echo Откат завершён: успешно !OK!, ошибок !FAIL!
if !FAIL! EQU 0 (
  ren "%STATE%" "wakelock_changes.txt.restored"
  echo Журнал сохранён как wakelock_changes.txt.restored
)
pause
exit /b 0
