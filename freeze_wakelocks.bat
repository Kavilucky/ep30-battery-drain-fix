@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul
rem ============================================================================
rem freeze_wakelocks.bat: запрет вейклоков (WAKE_LOCK) сторонним приложениям Android через adb, без Root.
rem Канал: @ByteAutomate_AI (https://t.me/ByteAutomate_AI)
rem
rem   freeze_wakelocks.bat          проверка: показывает, что изменится, НИЧЕГО не меняет
rem   freeze_wakelocks.bat apply    применить: adb shell cmd appops set ПАКЕТ WAKE_LOCK ignore
rem   restore_wakelocks.bat         откат (рядом лежит второй файл)
rem
rem Нужно: adb в PATH (платформенные инструменты Android), на телефоне включена «Отладка по USB»,
rem ключ подтверждён на экране телефона. Системные пакеты скрипт не трогает.
rem Исключения: впишите пакеты в skip_packages.txt (по одному в строке) ДО режима apply.
rem Журнал изменений: wakelock_changes.txt (пакет|прежний режим), по нему работает откат.
rem Автор скрипт на живом телефоне не прогонял: первый запуск только в режиме проверки.
rem Перед экспериментами сделайте резервную копию данных телефона (правило 3-2-1).
rem ============================================================================

set "STATE=%~dp0wakelock_changes.txt"
set "SKIP=%~dp0skip_packages.txt"
set "MODE=dry"
if /i "%~1"=="apply" set "MODE=apply"
if /i "%~1"=="--apply" set "MODE=apply"

where adb >nul 2>&1
if errorlevel 1 (
  echo ОШИБКА: adb не найден в PATH.
  echo Установите платформенные инструменты Android и добавьте папку platform-tools в PATH.
  pause
  exit /b 1
)

set "DEVSTATE="
for /f "delims=" %%S in ('adb get-state 2^>nul') do set "DEVSTATE=%%S"
if /i not "!DEVSTATE!"=="device" (
  echo ОШИБКА: телефон не готов ^(adb get-state = "!DEVSTATE!"^).
  echo Проверьте кабель, «Отладку по USB» и подтвердите ключ на экране телефона.
  pause
  exit /b 1
)

echo Телефон на связи, режим: !MODE!
set /a TOTAL=0
set /a SKIPPED=0
set /a ALREADY=0
set /a CHANGED=0
set /a FAILED=0

rem Список сторонних пакетов: exec-out отдаёт строки без лишних CR
for /f "tokens=2 delims=:" %%P in ('adb exec-out pm list packages -3 2^>nul') do (
  set "PKG=%%P"
  call :process
)

echo ----
echo Сторонних пакетов: !TOTAL!, в исключениях: !SKIPPED!, уже запрещено: !ALREADY!, ошибок: !FAILED!
if /i "!MODE!"=="dry" (
  echo Будет изменено: !CHANGED!. Это была ПРОВЕРКА, ничего не изменено.
  echo Для применения запустите: freeze_wakelocks.bat apply
) else (
  echo Изменено: !CHANGED!. Откат: restore_wakelocks.bat ^(журнал: wakelock_changes.txt^)
  echo Проверьте уведомления важных приложений; при задержке: restore_wakelocks.bat pkg ИМЯ.ПАКЕТА
)
pause
exit /b 0

:process
set /a TOTAL+=1
set "SKIPIT="
if exist "%SKIP%" (
  findstr /x /c:"!PKG!" "%SKIP%" >nul 2>&1
  if not errorlevel 1 set "SKIPIT=1"
)
if defined SKIPIT (
  echo   пропуск ^(skip_packages.txt^): !PKG!
  set /a SKIPPED+=1
  exit /b 0
)
set "PREV=default"
for /f "tokens=2 delims=: " %%M in ('adb exec-out cmd appops get !PKG! WAKE_LOCK 2^>nul ^| findstr /b "WAKE_LOCK"') do set "PREV=%%M"
set "PREV=!PREV:;=!"
if /i "!PREV!"=="ignore" (
  set /a ALREADY+=1
  exit /b 0
)
if /i "!MODE!"=="dry" (
  echo   [проверка] !PKG!: WAKE_LOCK=!PREV! -^> ignore
  set /a CHANGED+=1
  exit /b 0
)
rem Режим apply: сначала пишем прежний режим в журнал, потом меняем
echo !PKG!^|!PREV!>>"%STATE%"
adb shell cmd appops set !PKG! WAKE_LOCK ignore >nul 2>&1
if errorlevel 1 (
  echo   ОШИБКА: !PKG!
  set /a FAILED+=1
) else (
  echo   запрещено: !PKG! ^(было: !PREV!^)
  set /a CHANGED+=1
)
exit /b 0
