#!/usr/bin/env bash
# freeze_wakelocks.sh: запрет вейклоков (WAKE_LOCK) для сторонних приложений Android через adb, без Root.
# Канал: @ByteAutomate_AI (https://t.me/ByteAutomate_AI)
#
# Что делает:
#   1) проверяет, что adb установлен и телефон виден (adb get-state = device);
#   2) берёт список сторонних пакетов (pm list packages -3), системные пакеты НЕ трогает;
#   3) по умолчанию только ПОКАЗЫВАЕТ, что изменится (режим проверки, ничего не меняет);
#   4) с флагом --apply выполняет: adb shell cmd appops set <пакет> WAKE_LOCK ignore
#      и записывает прежний режим каждого пакета в файл wakelock_changes.txt (для отката);
#   5) с флагом --restore возвращает прежние режимы из этого файла;
#      с флагом --restore-pkg <пакет> возвращает режим одному приложению (режим default).
#
# Запуск (Linux, macOS, Termux):
#   chmod +x freeze_wakelocks.sh
#   ./freeze_wakelocks.sh                    # проверка, ничего не меняется
#   ./freeze_wakelocks.sh --apply            # применить
#   ./freeze_wakelocks.sh --restore          # откат всех изменений
#   ./freeze_wakelocks.sh --restore-pkg org.example.messenger
#   ./freeze_wakelocks.sh --device 1234ABCD  # если подключено несколько устройств
#   ./freeze_wakelocks.sh --dns-status       # показать текущий Private DNS
#
# Подготовка телефона: Настройки -> О телефоне -> 7 раз нажать «Номер сборки» -> Для разработчиков ->
# включить «Отладка по USB» -> подтвердить ключ на экране телефона при подключении кабеля.
# Termux на самом телефоне: pkg install android-tools; включить «Беспроводную отладку» (Android 11+),
# adb pair <адрес:порт> с кодом, затем adb connect <адрес:порт>, после этого запускать скрипт.
#
# ВАЖНО: на некоторых прошивках запрет вейклоков сбрасывается после перезагрузки или обновления;
# у части приложений (мессенджеры, будильники, навигация) могут задержаться уведомления.
# Такие приложения впишите в skip_packages.txt (по одному имени пакета в строке) ДО режима --apply.
# Автор скрипт на живом телефоне не прогонял: первый запуск только в режиме проверки.
# Перед экспериментами сделайте резервную копию данных телефона (правило 3-2-1).

set -u

STATE_FILE="${STATE_FILE:-./wakelock_changes.txt}"   # журнал: пакет|прежний режим
SKIP_FILE="${SKIP_FILE:-./skip_packages.txt}"        # исключения: пакеты, которым ничего не запрещаем
SERIAL=""
MODE="dry"                                           # dry | apply | restore | restore-pkg | dns
ONE_PKG=""

usage() {
  sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'
}

# ---- разбор аргументов ----
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)       MODE="apply" ;;
    --restore)     MODE="restore" ;;
    --restore-pkg) MODE="restore-pkg"; shift; ONE_PKG="${1:-}" ;;
    --device)      shift; SERIAL="${1:-}" ;;
    --dns-status)  MODE="dns" ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "Неизвестный аргумент: $1 (см. --help)" >&2; exit 2 ;;
  esac
  shift
done

# ---- проверки окружения ----
if ! command -v adb >/dev/null 2>&1 </dev/null; then
  echo "ОШИБКА: adb не найден в PATH." >&2
  echo "  Linux: sudo apt install adb; macOS: brew install android-platform-tools; Termux: pkg install android-tools" >&2
  exit 1
fi

ADB=(adb)
if [ -n "$SERIAL" ]; then
  ADB=(adb -s "$SERIAL")
fi

DEV_STATE="$("${ADB[@]}" get-state 2>/dev/null | tr -d '\r')"
if [ "$DEV_STATE" != "device" ]; then
  echo "ОШИБКА: телефон не готов (adb get-state = '${DEV_STATE:-нет устройства}')." >&2
  echo "  Проверьте кабель, «Отладку по USB» и подтвердите ключ на экране телефона." >&2
  echo "  Несколько устройств: используйте --device <серийный номер> (adb devices)." >&2
  exit 1
fi

SDK="$("${ADB[@]}" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
if [ -n "$SDK" ] && [ "$SDK" -lt 24 ] 2>/dev/null; then
  echo "ПРЕДУПРЕЖДЕНИЕ: Android со SDK $SDK (< 24): команда cmd appops может не поддерживаться." >&2
fi
echo "Устройство на связи, SDK: ${SDK:-неизвестно}, режим: $MODE"

# ---- вспомогательные функции ----
# Во всех вызовах adb внутри циклов stdin перенаправлен в /dev/null: иначе adb shell съедает список пакетов цикла.
# Текущий режим операции WAKE_LOCK для пакета (allow, ignore, deny, default, foreground)
get_mode() {
  local out
  out="$("${ADB[@]}" shell cmd appops get "$1" WAKE_LOCK 2>/dev/null </dev/null | tr -d '\r')"
  out="$(printf '%s\n' "$out" | sed -n 's/^WAKE_LOCK: *\([a-z_]*\).*/\1/p' | head -n 1)"
  if [ -z "$out" ]; then out="default"; fi
  printf '%s' "$out"
}

is_skipped() {
  [ -f "$SKIP_FILE" ] || return 1
  grep -v '^[[:space:]]*#' "$SKIP_FILE" | tr -d '\r' | grep -Fxq "$1"
}

# ---- режим: статус Private DNS ----
if [ "$MODE" = "dns" ]; then
  echo "private_dns_mode:      $("${ADB[@]}" shell settings get global private_dns_mode | tr -d '\r')"
  echo "private_dns_specifier: $("${ADB[@]}" shell settings get global private_dns_specifier | tr -d '\r')"
  echo "(mode=hostname и имя узла означают, что Private DNS включён; off или opportunistic: не включён вручную)"
  exit 0
fi

# ---- режим: откат одного пакета ----
if [ "$MODE" = "restore-pkg" ]; then
  if [ -z "$ONE_PKG" ]; then echo "Укажите пакет: --restore-pkg <имя.пакета>" >&2; exit 2; fi
  if "${ADB[@]}" shell cmd appops set "$ONE_PKG" WAKE_LOCK default >/dev/null 2>&1 </dev/null; then
    echo "Готово: $ONE_PKG: WAKE_LOCK -> default"
    exit 0
  fi
  echo "ОШИБКА: не удалось вернуть права для $ONE_PKG" >&2
  exit 1
fi

# ---- режим: откат по журналу ----
if [ "$MODE" = "restore" ]; then
  if [ ! -f "$STATE_FILE" ]; then
    echo "Журнал $STATE_FILE не найден: откатывать нечего." >&2
    exit 1
  fi
  OK=0; FAIL=0
  while IFS='|' read -r PKG PREV; do
    [ -z "$PKG" ] && continue
    PREV="$(printf '%s' "$PREV" | tr -d '\r')"
    [ -z "$PREV" ] && PREV="default"
    if "${ADB[@]}" shell cmd appops set "$PKG" WAKE_LOCK "$PREV" >/dev/null 2>&1 </dev/null; then
      echo "  вернул: $PKG -> $PREV"; OK=$((OK + 1))
    else
      echo "  ОШИБКА: $PKG" >&2; FAIL=$((FAIL + 1))
    fi
  done < "$STATE_FILE"
  echo "Откат завершён: успешно $OK, ошибок $FAIL"
  [ "$FAIL" -eq 0 ] && mv "$STATE_FILE" "${STATE_FILE}.restored" && echo "Журнал сохранён как ${STATE_FILE}.restored"
  exit 0
fi

# ---- режимы dry / apply ----
PKGS="$("${ADB[@]}" shell pm list packages -3 2>/dev/null | tr -d '\r' | sed 's/^package://' | sort)"
if [ -z "$PKGS" ]; then
  echo "Сторонние пакеты не найдены (или pm недоступен)." >&2
  exit 1
fi

TOTAL=0; SKIPPED=0; CHANGED=0; FAILED=0; ALREADY=0
while IFS= read -r PKG; do
  [ -z "$PKG" ] && continue
  TOTAL=$((TOTAL + 1))
  if is_skipped "$PKG"; then
    echo "  пропуск (skip_packages.txt): $PKG"; SKIPPED=$((SKIPPED + 1)); continue
  fi
  PREV="$(get_mode "$PKG")"
  if [ "$PREV" = "ignore" ]; then
    ALREADY=$((ALREADY + 1)); continue
  fi
  if [ "$MODE" = "dry" ]; then
    echo "  [проверка] $PKG: WAKE_LOCK=$PREV -> ignore"; CHANGED=$((CHANGED + 1)); continue
  fi
  # режим apply: сначала записываем прежний режим в журнал, потом меняем
  printf '%s|%s\n' "$PKG" "$PREV" >> "$STATE_FILE"
  if "${ADB[@]}" shell cmd appops set "$PKG" WAKE_LOCK ignore >/dev/null 2>&1 </dev/null; then
    echo "  запрещено: $PKG (было: $PREV)"; CHANGED=$((CHANGED + 1))
  else
    echo "  ОШИБКА: $PKG" >&2; FAILED=$((FAILED + 1))
  fi
done <<EOF
$PKGS
EOF

echo "----"
echo "Сторонних пакетов: $TOTAL, в исключениях: $SKIPPED, уже запрещено: $ALREADY, ошибок: $FAILED"
if [ "$MODE" = "dry" ]; then
  echo "Будет изменено: $CHANGED. Это была ПРОВЕРКА, ничего не изменено. Для применения: $0 --apply"
else
  echo "Изменено: $CHANGED. Откат: $0 --restore (журнал: $STATE_FILE)"
  echo "Проверьте уведомления важных приложений; при задержке: $0 --restore-pkg <пакет>"
fi
exit 0
