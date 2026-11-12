# CAN Debug Pro: Windows USB Serial

Реалізація від 2026-11-05. USB використовує Classic Monitor (`CanFrameSource` → `MonitorScreen`); Pro Monitor не змінено. Android продовжує використовувати BLE. Приймання TWAI, BLE та USB у RECEIVER працюють у незалежних задачах із кінцевими чергами. Фізична CAN-схема, GPIO5/GPIO4, 500 кбіт/с та UUID FF10/FF11/FF12 збережені.

## Запуск Windows

Перевірено з Flutter 3.44.2 / Dart 3.12.2, Windows 10 x64, Visual Studio Build Tools 2026. Потрібні C++ desktop toolchain і Windows SDK. Залежності зафіксовані в `pubspec.lock`: flutter_libserialport 0.6.0, libserialport 0.3.0+1, sqflite_common_ffi 2.4.5, sqlite3 3.5.2.

У каталозі `can_debug`:

```powershell
flutter pub get
flutter doctor -v
flutter devices
flutter build windows
flutter run -d windows
```

Поширювати потрібно весь каталог `build/windows/x64/runner/Release`, включно з DLL і `data`, а не лише `can_debug.exe`. `serialport.dll` та `sqlite3.dll` включаються засобами Flutter/CMake. Локальний `NuGet.Config` дозволяє завантаження CppWinRT через nuget.org без зміни глобальних налаштувань NuGet.

1. Прошити RECEIVER відповідно до своєї плати; SENDER залишити у штатному `SEND_MODE=1`.
2. Підключити RECEIVER кабелем USB з передаванням даних; визначити COM-порт у Windows Device Manager.
3. Закрити Arduino Serial Monitor та інші програми, які займають цей порт.
4. У Dashboard відкрити Real Stand, вибрати актуальний COM-порт і UART baud rate, натиснути Connect.
5. У Classic Monitor з'являться CAN-кадри, TWAI-лічильники, Health Score та стан експериментального журналу.
6. Кнопка Disconnect & Save закриває порт, дописує журнал і зберігає сеанс. Повторне Connect / Start відкриває новий журнал. Для іншого COM-порту повернутися на екран підключення й оновити список.

Автоматичного перепідключення USB немає. Після від'єднання збережені на диск дані залишаються доступними; потрібно зупинити поточний моніторинг і підключитися вручну. Відсутній/зайнятий порт показує помилку; чужі процеси не закриваються.

Порт налаштовується на 8N1, flow control none, RTS/DTR off. Відкриття порту все одно може спричинити короткий reset конкретного DevKit через поведінку драйвера. Стартові не-JSON повідомлення не вважаються CAN-кадрами, вони враховуються як відхилені рядки. Не змінюйте лінії reset/boot без перевірки плати.

## RECEIVER

Основний файл: `../arduino/receiver_ble/receiver_ble.ino`.

```cpp
#define CAN_SERIAL_JSON 1
constexpr uint32_t SERIAL_BAUD = 115200;
```

`CAN_SERIAL_JSON=1` означає JSON_STREAM (типово); `0` — HUMAN_READABLE. Для зміни UART швидкості встановити однакове значення `SERIAL_BAUD` у прошивці та на екрані підключення. CAN bitrate при цьому залишається 500000.

Приклад перевірки без прошивання (з установленим Arduino CLI/core):

```powershell
arduino-cli compile --fqbn esp32:esp32:esp32 ../arduino/receiver_ble
arduino-cli compile --fqbn esp32:esp32:esp32 --build-property compiler.cpp.extra_flags=-DCAN_SERIAL_JSON=0 ../arduino/receiver_ble
```

Компіляцію перевірено для ESP32 Dev Module, Arduino ESP32 core 3.3.10. Вибір FQBN під час реального прошивання має відповідати фізичній платі. У межах цієї роботи плата не прошивалася.

Структура задач і черг:

| Вузол | Межа | Поведінка при насиченні |
|---|---:|---|
| TWAI → serializer | 64 кадри | Відкидає новий кадр із `queuedrop`; приймання TWAI не очікує UART/BLE |
| serializer → USB | 32 повідомлення | Відкидає нове повідомлення з `serialdrop` |
| serializer → BLE | 32 повідомлення | Відкидає нове повідомлення з `bledrop` |
| Stats mailboxes | 1 знімок на кожному етапі | Зберігає найновіший; заміни обліковуються окремо |
| Одне wire-повідомлення | 640 байтів | Відхилення з `toolong` |

CAN-кадр отримує `ts` і `seq` безпосередньо при прийманні. Серіалізатор формує JSON один раз для обох каналів. Базова TWAI-статистика також формується одним `buildStatsJson`; лише USB додає поля стану транспортних черг, щоб не збільшувати наявний BLE stats payload.

UART-задача передає частини завершеного рядка відповідно до `availableForWrite`; BLE notify виконується в іншій задачі. Повільний UART не блокує BLE-задачу чи `twai_receive`. Це забезпечення незалежності задач, а не гарантія відсутності втрат на довільній інтенсивності CAN.

Обмеження 115200, 8N1: теоретично 11520 байт/с; фактична кількість кадрів/с залежить від довжини JSON, телеметрії та накладних витрат. Під час overload потрібно вимірювати втрати, за потреби підвищувати UART baud, але не CAN bitrate.

## Протокол і журнал

Один JSON-об'єкт UTF-8 на рядок; приймач підтримує LF/CRLF, фрагментацію і кілька повідомлень у читанні. Ліміт рядка типово 2048 байтів (`maxMessageBytes`). Після перевищення ліміту декодер відкидає рядок до наступного LF.

```json
{"t":"f","id":192,"dlc":2,"data":[1,255],"ts":123456,"seq":42}
{"t":"f","id":192,"dlc":8,"data":[],"ts":123457,"seq":43,"rtr":1}
```

Extended ID позначається `extd:1`. Для data-кадру кількість байтів має дорівнювати DLC; для RTR data порожній, а DLC може бути 0–8. Некоректні ID, DLC, байти, типи, прапорці, JSON/UTF-8 і невідомі типи повідомлень відхиляються окремо від CAN-помилок. У десеріалізації немає випадкових помилок чи симуляції. Поле `crc` існуючої моделі залишається локальним розрахунком застосунку; воно не є виміряним wire CRC фізичної CAN-шини.

Stats зберігають чинні поля `rx/txe/rxe/state/missed/buserr/arb/txfail/ovr/noack/sdemo` і v2-метадані. Додаткові USB-поля:

| Поле | Що вимірює |
|---|---|
| `queuedrop` | Переповнення черги прийнятих кадрів перед JSON-серіалізатором |
| `serialdrop` | Переповнення черги USB-кадрів |
| `bledrop` | Переповнення черги BLE-кадрів при підключеному BLE-клієнті |
| `statdrop` | Заміна очікуваного знімка перед серіалізатором |
| `serialstatdrop` / `blestatdrop` | Заміна очікуваного знімка конкретного транспорту |
| `toolong` | Повідомлення перевищило wire-ліміт |

`seq` — uint32 порядковий номер прийнятого CAN-кадру, а не всіх повідомлень. Stats не витрачають номери. `sequenceGaps` показує розриви між прийнятими frame seq; після зменшення ESP часу/лічильника починається нова база. Перша отримана послідовність не дає оцінки всіх попередніх втрат. Відсутність seq у старій прошивці допускається. Не слід додавати розриви seq до firmware drop counters: вони можуть описувати ті самі втрачені кадри.

Кожне USB-підключення автоматично створює окремий каталог:

```text
Documents/CAN_Debug_Pro/experiments/capture_<UTC timestamp>_<unique>/
  capture.csv
  capture.jsonl
  manifest.json
```

Точний шлях показується кнопкою Experimental recording details у моніторі. Вибір конкретного каталогу також доступний через `SerialCanSource(journalDirectory: ...)`.

Запис отримує всі валідні кадри/телеметрію безпосередньо від джерела ДО UI-буфера. CSV містить hostReceivedAt, espTimestamp, source, type, seq, frameId, dlc, data, RTR/extended, наявні модельні назви TWAI-лічильників, serialParseErrors, serialErrors, sequenceGaps, firmware counters і rawJson. JSONL містить wire-поля, точний початковий JSON у `rawJson` і метадані отримання. Відхилені повідомлення зберігаються як записи `rejected`; для некоректного UTF-8/надмірного рядка зберігається причина без необмеженого raw-буфера.

Обидва файли пишуться асинхронно пакетами до 128 записів із flush після пакета. Черга має 8192 записи плюс один пакет у записі. При переповненні або помилці диска запис/приймання припиняються з видимою помилкою; manifest позначає `incomplete` і кількість незаписаних записів. Це не CAN-помилки. Журнал не вважається повним лише через успішне відкриття COM-порту.

При нормальному Stop/виході з монітора журнал закривається. Windows WM_CLOSE під час USB-моніторингу відкладається до закриття порту, flush журналу й збереження сеансу. Аварійне завершення процесу, вимкнення живлення та збій ОС не можуть гарантувати дописування пакета в пам'яті; manifest може залишитися зі статусом `recording`.

`hostReceivedAt` записується в UTC; `espTimestamp` — ESP millis. Їхня різниця не є наскрізною затримкою. Для дослідження затримки потрібна окрема синхронізація/методика.

## Сеанси й аналіз

Існуючі CanFrame/CanStats/CanSession, аналізатори, походження hardware/inferred/simulated та аналітика збережені. Source/COM/UART і шляхи журналу записуються у події сеансу. Новий DiagnosticCause.transportLoss відокремлює USB від BLE; старі JSON-сеанси читаються як раніше.

Session snapshot залишається коротким: 100 останніх відображених кадрів; для USB обмежено також 600 stats і 2000 подій аналізу. Summary зберігає накопичувальні totals/error metrics, якщо історія кадрів усічена. Top CAN IDs та replay snapshot стосуються збереженої вибірки, а не всього експерименту. Повна історія — у CSV/JSONL; автоматичний імпорт повного журналу в Replay не додано.

UI backlog має межу 4096 кадрів; `UI skipped` показує пропуски відображення. Ця межа не обрізає журнал. Синтетичні діагностичні маркери існуючого монітора не записуються як фізично отримані CAN-кадри в експериментальний журнал.

## Змінені та нові файли

| Файл | Призначення |
|---|---|
| `pubspec.yaml`, `pubspec.lock` | Serial/SQLite залежності, Dart >=3.10; solver також оновив сумісні printing/web/sqflite_common/synchronized залежності |
| `NuGet.Config` | Офіційне NuGet-джерело для Windows CppWinRT |
| `lib/core/dependency_injection.dart` | Windows SQLite FFI, Android factory без заміни |
| `lib/core/windows_capture_guard.dart` | Очікування flush при закритті Windows-вікна |
| `lib/domain/source/serial_connection.dart` | Windows native isolate, bounded ACK читання, UART, перелік портів, cleanup |
| `lib/domain/source/serial_json_decoder.dart` | Обмежений JSON Lines framing і перевірка wire-полів |
| `lib/domain/source/serial_can_source.dart` | Реалізація CanFrameSource, життєвий цикл, counters і передавання в журнал |
| `lib/domain/services/experiment_journal.dart` | Асинхронні CSV/JSONL та manifest незалежно від UI |
| `lib/presentation/screens/serial_connect_screen.dart` | COM/baud, Connect/Disconnect, помилки |
| `lib/screens/dashboard_screen.dart` | Windows USB / Android BLE; приховування непідтримуваного hardware entry |
| `lib/presentation/screens/monitor_screen.dart` | USB-статус, metadata, збереження, bounded backlog, resize, delta baseline після reset |
| `lib/domain/source/ble_can_source.dart`, `lib/presentation/screens/ble_connect_screen.dart` | Платформні guard до звернення до BLE API |
| `lib/domain/detection/can_health_analyzer.dart`, `can_anomaly_analyzer.dart` | Транспортні пояснення reconnect без зміни правил CAN-аналізу |
| `lib/domain/models/can_session_event.dart` | Зворотно сумісна причина transportLoss |
| `lib/domain/services/can_session_service.dart`, `session_summary_builder.dart` | Межі USB snapshot, USB hardware mode, збереження aggregate totals |
| `windows/runner/flutter_window.cpp`, `flutter_window.h` | Native WM_CLOSE → Dart flush → закриття |
| `windows/flutter/generated_plugin_registrant.cc`, `generated_plugins.cmake` | Згенерована Flutter-реєстрація Serial-плагіна |
| `../arduino/receiver_ble/receiver_ble.ino` | Два Serial-режими, незалежні задачі/черги, seq і transport counters |
| `test/serial_json_decoder_test.dart`, `serial_can_source_test.dart` | Framing, валідація, 2000-frame журнал, помилки, lifecycle, overflow |
| `test/serial_monitor_test.dart`, `windows_capture_guard_test.dart` | Resize, >100 кадрів, сесії, очікування flush при закритті |
| `test/can_emulator_test.dart`, `monitor_screen_chart_test.dart` | Виправлення застарілих очікувань і випадкового тесту без зміни production simulator |
| `tool/windows_transport_smoke.dart` | Native DLL/перелік портів/missing-port cleanup і SQLite round trip |
| `README.md`, `USB_SERIAL_GUIDE.md` | Інструкція й результати перевірок |

Повний код компонентів міститься у зазначених файлах, без псевдокоду. Pro Monitor/BLoC, Android Manifest і SENDER звірено з початковою резервною копією: вміст збережений.

## Перевірки

Фактично виконано:

- Windows release-збірка з native DLL.
- Android debug APK; збірка завершилася успішно. Є попередження Gradle/Kotlin та fallback після проблеми incremental cache між дисками C: і D:.
- Компіляція RECEIVER у JSON_STREAM та HUMAN_READABLE для esp32:esp32:esp32 / Arduino ESP32 3.3.10; обидві успішні.
- Flutter-тести: 51 успішний, включно з усіма наявними тестами та новими Serial/журнал/resize/close перевірками.
- Native smoke: serialport.dll завантажена, знайдено COM1; жодний наявний порт не відкривався. Відсутній порт коректно відхилено, worker очищено; SQLite FFI round trip успішний.
- `flutter analyze`: немає compiler errors; 118 lint/deprecation зауважень (117 info, 1 warning про unused import у наявному тесті). Нові Serial/journal/Windows guard компоненти без зауважень. Звіт: `build/validation/analyze.txt`.

Команди:

```powershell
flutter test --no-pub --timeout 30s
flutter analyze --no-pub
flutter build windows --no-pub
flutter build apk --debug --no-pub
$env:LIBSERIALPORT_PATH = (Resolve-Path build/windows/x64/runner/Release/serialport.dll).Path
dart run tool/windows_transport_smoke.dart
```

Наведені автоматичні тести використовують контрольоване Serial-з'єднання. Це не підтвердження фізичного BLE/USB приймання зі стенду.

## Ручне приймання — ще не виконано

1. Реальний ESP32 RECEIVER: правильна плата/FQBN, JSON firmware, COM/baud, перші f/s, зростання rx.
2. Одночасні Android BLE та Windows USB: підписка FF11/FF12, ті самі CAN ID/data, незалежна доставка, спостереження transport counters.
3. Зайнятий порт реальним Serial Monitor, фізичний unplug/replug, новий COM-номер, швидкі Connect/Stop, reset ESP32.
4. RTR та extended ID на фізичному стенді; невідома/пошкоджена UART-телеметрія.
5. Тривале приймання (мінімум 30–60 хв): пам'ять, UI, CSV/JSONL, вільне місце, ріст counters і порівняння кількості записів.
6. Overload одночасно на BLE/USB при 115200 та вищій узгодженій швидкості; виміряти TWAI/queue/transport/parse/UI losses, не оголошувати zero-loss без вимірювань.
7. Закрити реальне Windows-вікно під час запису: порт звільнений, manifest closed, сесія збережена, CSV/JSONL відкриваються. Unit-тест протоколу WM_CLOSE вже виконано; цей сценарій зі стендом — ні.
8. Перевірити Android runtime permissions, BLE reconnect та відсутність регресії при одночасному USB-клієнті.

## Окремі задачі та ризики

- `TWAI_MODE_NO_ACK` і BUS-OFF recovery навмисно не виправлялись за уточненням користувача. Їхні наявні обмеження поширюються і на USB-спостереження.
- BLE MTU і розмір наявного v2 stats JSON залишаються окремим ризиком: notify не підтверджує повноту доставки; BLE stats payload не розширено USB transport fields. Фрагментацію BLE у цій інтеграції не додано.
- `flutter doctor` повідомляє про частково неприйняті Android SDK licenses; ліцензії автоматично не приймались. Поточний debug build усе ж успішний на вже встановлених компонентах.
- Залежність flutter_libserialport також збирається для Android. APK з нею перевірено, але реальний BLE runtime потребує ручної регресії.
- Не підтримуються гарантовано всі кадри максимально завантаженої 500-kbit/s CAN при UART 115200, раптове вимкнення живлення і необмежений дисковий простір.

Початкові 54 змінені/незакомічені файли, unstaged/staged patches, HEAD та SHA-256 manifest збережено й перевірено перед редагуванням у `../.work_backups/usb_serial_before_20261105_151226.zip`.
