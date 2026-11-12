# ESP32 RECEIVER: контроль трьох меж BLE без додаткового обладнання

Наступний, окремо погоджений етап —
[BTC destination після deep-copy](BTC_DEEP_COPY_EXPERIMENT.md), schema=2,
збірка `--btc-copy`. Ця інструкція описує попередній API-entry probe (schema=1).

Дата: 2026-11-10. Це діагностичний патч, а не виправлення встановленої причини.
Пристрої під час реалізації не прошивалися; фізичний запис ще не виконаний.

## Межі вимірювання

Діагностика вимкнена у звичайній збірці (`RECEIVER_BLE_TRACE=0`). У спеціальній
збірці один короткий RAM-запис автоматично починається після увімкнення **обох**
CCCD FF11/FF12. Межа — 12 секунд або фактично виділена місткість, що настане раніше.
Максимум 512 повідомлень; за браку heap місткість зменшується до 256/128/64.
Її фактичне значення видно у header, причину завершення — у footer.

Для одного `id` фіксуються п'ять незалежних знімків:

| Індекс | Місце | Що перевіряється |
|---|---|---|
| 0 | BLE task одразу після dequeue, до setValue | Власна копія WireMessage.bytes із явною довжиною |
| 1 | Одразу після setValue | Власна String-копія getValue(), потім незалежний byte snapshot |
| 2 | Фактичний esp_ble_gatts_send_indicate | Саме передані notify аргументи: handle, length, bytes, gatts_if, conn_id, need_confirm |
| 3 | Сусідня характеристика перед setValue | Незалежний знімок peer FF12 для FF11 і навпаки |
| 4 | Сусідня характеристика після setValue | Побайтова перевірка, чи запис target змінив peer |

Етап 2 тут — **вхід реального send API перед його BTC deep-copy chain**.
Linker `--wrap=esp_ble_gatts_send_indicate` перехоплює виклик із бібліотеки BLE
та передає **оригінальні аргументи без змін** у реальну функцію. Не підміняється
payload безпечнішою копією і не додається затримка доставки. Дані всередині вже
скопійованої BT-черги та ефірні пакети цим патчем не спостерігаються.

На встановлених Arduino-ESP32/BLE **3.3.10**, ESP-IDF **5.5.4** між цим входом
і постановкою BT-події працює синхронний `btc_transfer_context` deep copy.
Точна реалізація та локальний libbt.a описані у
[попередньому аудиті](ESP32_RECEIVER_BLE_AUDIT.md). Compile guards не дозволяють
тихо зібрати інший SDK. Build tool додатково перевіряє дизасемблювання кінцевого
ELF: `BLECharacteristic::notify -> wrapper -> real API`. SDK/cache не редагуються.

Для всіх повідомлень експортуються довжини та перші 128 біт SHA-256 кожного
snapshot. На пристрої target/peer/API зіставляються **повністю побайтово**,
не лише за fingerprint. Для перших двох повідомлень із розбіжностями/помилками
залишаються також повні п'ять snapshots; наступні випадки рахуються у
`faultOverflow`. Це обмежений діагностичний запис, не повний raw-журнал на 5 хвилин.

Тип FF11/FF12 задає вибрана BLE-черга, а не JSON prefix. Тому FF12 зі вмістом
FF11 не буде помилково переозначений як FF11. `sourceKey` (seq/uptime) — лише
допоміжний ключ пошуку; байтовий fingerprint лишається основою порівняння.

## Продуктивність і цілісність

BLE task виконує обмежені memcpy, побайтові порівняння, SHA та `xQueueSend(...,0)`.
Serial/filesystem I/O, очікування вільного місця в діагностичній черзі та друку
payload у ньому немає. Черга містить 16 compact records; інший task переносить
їх у RAM. Snapshot buffers мають власне володіння; mutable pointers не
передаються worker. Перехоплення send API не утримує pointer після повернення.

Додаткові getValue()/SHA/copies та пам'ять впливають на таймінги. Це обмеження
експерименту; відсутність аномалій у короткому вікні не доводить виправлення.
`getValue()` сам створює String-копію: перша розбіжність після setValue локалізує
межу setValue/readback, але не доводить дефект саме всередині setValue.

Counter-и: `messages`, `queued`, `stored`, `dropped`, `setChanged`, `apiChanged`,
`peerChanged`, `invalidSnapshots`, `apiMissing`, `apiErrors`, `outsideApi`,
`faults`, `faultOverflow`, `writeErrors`. Штатне завершення обмеженого вікна
(`reason=window/capacity`) не маскується під втрату черги; реальні queue drops
окремо інвалідують повноту. Якщо RAM/task allocation не вдалася, експортується
явний стан або утиліта завершується timeout, а не успішним порожнім записом.

Вивантаження проходить **після завершення моніторингу**, через той самий USB-UART.
У спеціальній збірці команда обслуговування `BLE_DIAG_DUMP` змушує наявний USB
writer завершити поточний JSON-рядок і підтвердити паузу. Лише після цього worker
друкує RAM-журнал. Продуктивні FF11/FF12, USB CAN/stats JSON та їх поля не
змінені; застосунки нового типу запису не отримують. У звичайній збірці немає
навіть обробника цієї команди. FNV-1a32 у footer покриває точні байти експорту
від header до останнього message/fault, включно з переносами рядків.

Після dump пристрій лишається у режимі обслуговування, USB CAN output не
відновлюється автоматично. Наступний експеримент потребує reset. **До dump
не натискай EN/Reset і не від'єднуй живлення RECEIVER: журнал лише у RAM.**

## Одна контрольна спроба

Всі PowerShell-команди нижче — з `D:\KNUO_term_paper\can_debug`.
SENDER лишається SEND_MODE=1, CAN 500 kbit/s. Його перепрошивати не потрібно.
Телефон використовує вже встановлений debug APK із native snapshot patch.

### 1. Зібрати діагностичний RECEIVER

```powershell
Set-Location D:\KNUO_term_paper\can_debug
python tool/build_receiver_ble_trace.py
```

Результат: `build/receiver_ble_trace/receiver_ble.ino.bin`, `build_manifest.json`,
`compile.log`, `link_check.txt`. Скрипт лише компілює, COM-портів не відкриває.
Звичайна кнопка Upload в Arduino IDE **не вмикає** цей trace: потрібні спеціальні
compile/link flags, які встановлює скрипт.

Перед прошиванням заверши старі сесії, закрий Windows застосунок і Serial Monitor.
Перевір поточний порт RECEIVER; у попередній спробі був COM5. Прошиває користувач:

```powershell
$receiverPort = 'COM5'
$arduinoCli = 'D:\ArduinoIDE\Arduino IDE\resources\app\lib\backend\resources\arduino-cli.exe'
& $arduinoCli upload --config-file "$env:USERPROFILE\.arduinoIDE\arduino-cli.yaml" --fqbn esp32:esp32:esp32 --port $receiverPort --input-dir .\build\receiver_ble_trace ..\arduino\receiver_ble
```

### 2. Запустити USB раніше BLE

```powershell
$runTag = Get-Date -Format 'yyyyMMdd_HHmmss'
$bleAdb = 'D:\devSdk\Android\Sdk\platform-tools\adb.exe'
& $bleAdb devices
& .\build\windows\x64\runner\Release\can_debug.exe
```

На Windows вибери USB Serial / порт RECEIVER / **460800**, почни моніторинг
і переконайся, що кадри та stats надходять. Раніше цього BLE не підключай.

```powershell
python tool/ble_native_trace.py --adb "$bleAdb" --device 93e1c8bd start
```

Після підтвердження нового native run підключи RECEIVER на Android і почни BLE
моніторинг. Записуй **20–30 секунд**. RAM-вікно почнеться, коли ввімкнуться обидві
підписки, і самостійно завершиться; решта звичайного моніторингу продовжується.
Не змінюй режими, не роби hot restart, не перезавантажуй RECEIVER.

### 3. Завершити обидва журнали

На Android натисни Stop і дочекайся збереження. За можливості експортуй повний
JSON сесії. Потім:

```powershell
python tool/ble_native_trace.py --adb "$bleAdb" --device 93e1c8bd stop
```

Дочекайся `status=closed`. На Windows натисни Stop, дочекайся закриття USB
manifest і **закрий Windows застосунок**, щоб звільнити COM-порт. Живлення
RECEIVER залиш увімкненим.

```powershell
python tool/ble_native_trace.py --adb "$bleAdb" --device 93e1c8bd pull --output "build/ble_receiver_trace_$runTag"
```

### 4. Витягнути RAM-журнал через наявний USB

Для цієї команди потрібен лише Python-пакет pyserial (не залежність Flutter):

```powershell
python -m pip install pyserial==3.5
python tool/receiver_ble_trace.py dump --port $receiverPort --output "build/receiver_trace_$runTag.jsonl"
```

Утиліта відкриває порт із DTR/RTS вимкненими **до open**, надсилає команду
обслуговування і чекає footer. На окремих драйверах open може все ж дати імпульс
reset: тоді запис буде порожній/`not_started` і перевірка його відхилить.
Автоматичного reset, повторного прошивання чи стирання flash у ній немає.
При timeout збережи отриманий файл; не вважай його повним. Існуючий output
утиліта не перезаписує. Після успішного dump файл уже на диску ПК.

### 5. Автоматично порівняти

```powershell
$bleRun = Get-ChildItem ".\build\ble_receiver_trace_$runTag" -Directory -Filter 'run_*' | Sort-Object Name | Select-Object -Last 1
$usbRun = Get-ChildItem "$env:USERPROFILE\Documents\CAN_Debug_Pro\experiments" -Directory -Filter 'capture_*' | Sort-Object Name | Select-Object -Last 1
$bleRun.FullName
$usbRun.FullName
```

Перевір, що це **поточна** пара записів. Порівняння не потребує pyserial:

```powershell
python tool/receiver_ble_trace.py compare --trace "build/receiver_trace_$runTag.jsonl" --usb "$($usbRun.FullName)\capture.jsonl" --ble "$($bleRun.FullName)\notifications.jsonl" --out "build/receiver_trace_comparison_$runTag.json"
```

Передай звіт, RAM JSONL, native notifications.jsonl + manifest, USB capture.jsonl
+ manifest та build_manifest.json. Старі файли та попередні comparison не
перезаписуються. Це одна спроба; інші види tracing автоматично не додаються.

## Як читати результат

Спочатку перевіряються checksum експорту, message IDs, queue/storage counters,
повні fault bytes проти fingerprint, native journal hash/length/counters та
USB seq/manifest. `traceCompleteAndConsistent`, `usbCompleteAndConsistent` і
`nativeCompleteAndConsistent` повинні бути true. `bothCharacteristicsMeasured`
має бути true; `missingApiMessages`, `multipleApiMessages`, `apiErrors`
потребують окремого пояснення. Один контрольний клієнт — передумова однозначного
одного API snapshot на повідомлення. API без виклику (наприклад, disconnect)
ніколи не видається за успішне відправлення порожнього payload.

- `dequeueWithoutExactUsbMatch`: етап 0 відрізняється від USB. Якщо є USB
  candidate з тим самим seq/uptime і підтверджене покриття, перша спостережена
  розбіжність уже на вході BLE task. За відсутності candidate спочатку
  перевіряється покриття, а не оголошується пошкодження.
- `stageDifferences`: перша відмінність dequeue -> setValue/readback або
  readback -> actual API arguments. Peer mismatch виділений окремо.
- `characteristicContinuityDifferences`: peer уже змінився між попереднім
  знімком і наступним setValue; це не приписується поточному setValue.
- `usbVsDequeueOrderDifferences`: повтори, перестановки або пропуски вже на
  dequeue, навіть якщо окремий повторений JSON точно є в USB. FF11/FF12 тут
  зіставляються окремо, оскільки між вихідними workers їх чергування може різнитися.
- `longFf12ThenShortFf11`: кількість реально перевірених переходів із довшого
  FF12 на коротший FF11 та їх розбіжності. `handles` підтверджує різні handles.
- `apiVsNativeDifferences`: фактичні API payload проти Android entry snapshots.
  Порівнюються channel + fingerprint у початковому порядку. Вікно обмежується
  збігами-якорями; у групі замін/вставок/пропусків не вигадується відповідність
  «один до одного». `alignedWindow` показує фактичне зіставлене покриття.

Якщо всі ESP32 межі рівні USB, але між збігами-якорями вже є погані Android
snapshots, межа звужується до ділянки **після API entry і до Android snapshot**.
Це ще не розрізняє BT deep copy, controller/radio та Android/GATT. Якщо аномалії
не потрапили у коротке RAM-вікно, спроба просто не локалізувала проблему.
Buffer reuse не вважається доведеною причиною за жодним лише зовнішнім симптомом.

## Перевірки реалізації

```powershell
python -m unittest discover -s tool -p test_receiver_ble_trace.py -v
```

Пройшли 16 тестів. Вони охоплюють правильний потік різних довжин, обидві межі
пошкодження, peer overwrite і зміни між повідомленнями, already-bad dequeue,
повтор повного JSON, FF11 усередині FF12, queue/fault overflow, FNV експорту,
неповний footer, пропущений API, неузгоджені byte-comparison flags та пошкоджений
diagnostic JSON. Це штучні offline fixtures, не фізичний тест.

Діагностична збірка: 1 110 943 bytes flash, 51 432 bytes globals. Звичайна
збірка: 1 105 483 bytes flash, 41 296 bytes globals; у її ELF відсутній wrapper
і receiverTraceBegin. Обидві компіляції успішні. RAM storage/queue/task stacks
виділяються додатково під час запуску; реальна місткість підтверджується header.
SHA-256 перевірених BLECharacteristic/BLEValue/WString/libbt.a збігаються з аудитом.

Змінені лише RECEIVER diagnostic hooks, два нові firmware helper files,
build/export/compare tools, їх тести та ця інструкція. Android, Windows,
SQLite, SENDER, NO_ACK і BUS-OFF recovery в цьому етапі не редагувалися.
Перед змінами Git-стан і 63 поточні файли збережено у
`../.work_backups/receiver_diag_before_20261110_170426.zip`.
