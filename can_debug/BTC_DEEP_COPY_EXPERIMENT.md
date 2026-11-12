# ESP32: snapshot фактичного BTC destination після deep-copy

Наступний окремо погоджений етап —
[BTC queue → handler entry](BTC_HANDLER_EXPERIMENT.md), збірка `--btc-handler`,
schema=3. Нижче збережена інструкція попереднього post-copy probe (schema=2).

Дата: 2026-11-10. Діагностична збірка; фізичний тест нового hook ще не проведено.
Root cause не встановлений. Пристрої під час реалізації не прошивалися.

## Перевірена точна реалізація

Встановлений SDK: Arduino-ESP32/BLE 3.3.10, ESP-IDF 5.5.4, commit
`735507283d`. У `versions.txt` саме цей commit. SHA-256 встановленого `libbt.a`:
`d500529efd1d391492a4e5798f39f722e3bf0bbc359ff7c819bce56b1ca7141f`.

Перевірено джерела **цього commit**, їх збіг із tag v5.5.4 та інструкції й
релокації локальних esp_gatts_api.c.obj / btc_gatts.c.obj / btc_task.c.obj:

- [btc_gatts.c, рядки 64–89](https://github.com/espressif/esp-idf/blob/735507283d/components/bt/host/bluedroid/btc/profile/std/gatt/btc_gatts.c#L64):
  для SEND_INDICATE оригінал виділяє destination buffer і виконує memcpy із source.
- [btc_task.c, рядки 328–356](https://github.com/espressif/esp-idf/blob/735507283d/components/bt/common/btc/core/btc_task.c#L328):
  callback викликається синхронно на рядку 352; btc_task_post — лише на рядку 356.
- [esp_gatts_api.c](https://github.com/espressif/esp-idf/blob/735507283d/components/bt/host/bluedroid/api/esp_gatts_api.c):
  send API передає саме btc_gatts_arg_deep_copy як callback.

Приватний ABI не вгадується. Read-only view у `BtcCopyAbi.h` відповідає
[btc_gatts.h](https://github.com/espressif/esp-idf/blob/735507283d/components/bt/host/bluedroid/btc/profile/std/include/btc_gatts.h)
і [btc_task.h](https://github.com/espressif/esp-idf/blob/735507283d/components/bt/common/btc/include/btc/btc_task.h):

| Об'єкт/поле | Перевірений offset |
|---|---:|
| btc_msg: sig / pid / act | 0 / 2 / 3 |
| message header size | 4 |
| SEND_INDICATE sig / pid / act | 0 / 2 / 10 |
| send_ind: conn / handle / confirm | 0 / 2 / 4 |
| send_ind: length / value pointer | 6 / 8 |
| read-only send_ind view size | 12 |

У встановленому машинному коді branch act=10 завантажує length із offset 6,
source pointer із 8, записує новий pointer у destination+8, викликає memcpy
і повертається. API формує 32-byte union, тому 12-byte view входить у нього.
Connection кодується як `(uint8_t(conn_id) << 8) | uint8_t(gatts_if)`.

Offsets/версії/хеші джерел зафіксовано у `tool/btc_copy_abi.json`. Повні upstream
файли для аудиту — в ігнорованому `build/validation/btc_copy_audit/`.
Ліцензія на ABI-джерела збережена поруч із helper як `BTC_COPY_ABI_LICENSE.txt`.

## Чому hook не потребує зміни логіки stack

Діагностичний link додає `--wrap=btc_gatts_arg_deep_copy`:

1. Власний snapshot source знімається **перед** оригінальним callback.
2. `__real_btc_gatts_arg_deep_copy` викликається рівно один раз з незмінними args.
   Це виконується для всіх actions, навіть тих, що не журналюються.
3. Одразу після повернення знімається **незалежна копія destination bytes/length**.
4. Hook повертається; лише тепер оригінальний btc_transfer_context може post-ити
   подію у BTC-task. Знімок не читає buffer після post/free.

SDK, libbt.a, BLE-бібліотека та продуктивні аргументи не патчаться. Hook не
підміняє source власною копією, не звільняє й не утримує destination для пізнішого
читання. У RAM лишаються owned bytes/fingerprints та **числові** адреси для
перевірки незалежності буферів. Немає Serial/file I/O або очікування місця
в діагностичній черзі; використовуються попередні RAM worker і zero-timeout queue.
Оригінальні SDK allocation/copy/error paths залишаються чинними.

Build tool відмовляється застосовувати hook, якщо libbt.a має інший hash.
Також діють version/layout static_asserts. У фінальному ELF перевіряється
фактичний callback pointer send API -> wrapper та виклик wrapper -> оригінал.
Для objdump створюється лише inspection-копія ELF без `.xt.prop/.xt.lit`, бо
змішані metadata SDK/скетча можуть показувати код як data. Всі allocated bytes
inspection-копії звіряються з оригіналом. ELF/BIN для прошивання не змінюються.
Невдала перевірка зупиняє скрипт; її не можна обходити іншими compile flags.

## Зіставлення та RAM

Попередні п'ять snapshots збережено. У schema=2 додаються:

| Індекс у lengths/hashes/fault snapshots | Значення |
|---|---|
| 0 / 1 / 2 | dequeue / setValue readback / send API entry |
| 3 / 4 | peer до / після setValue |
| 5 | source безпосередньо перед оригінальним deep-copy |
| 6 | destination після оригінального deep-copy, перед BTC post |

`message.id` — внутрішній діагностичний номер, `sourceKey` — wire seq/uptime.
Кожний scoped API-виклик отримує окремий `apiToken`. Copy hook перевіряє task,
активний API scope та message ID, зберігає `copyToken`, порівнює pointers,
connection/handle/confirm/length і **повні байти**. Token-и повинні збігатися.
Не використовується евристика «останнє повідомлення» або лише однаковий seq.

Для перевіреного SDK callback синхронний; асинхронна доставка починається пізніше.
Якщо hook приходить в іншому task/поза scope, він не прикріплюється до довільного
повідомлення: `copyUnmatched`/`copyMissing` показують неповне спостереження.
Порівняння працює за ID/token навіть при іншому порядку рядків експорту. Native
callbacks зіставляються окремо через content/channel anchors, без вигаданих
пар усередині груп вставок/пропусків/перестановок.

Нові counters: `copyCallbacks`, `copyMissing`, `copyUnmatched`,
`copySourceChanged`, `copyDestChanged`, `copyMetadataChanged`, `copyAlias`.
Повторні callbacks/API-виклики теж позначаються; їх другий payload не видається
за повністю досліджений перший. Queue drops, RAM capacity, faultOverflow і
цілісність вивантаження перевіряються, як у попередньому патчі.

Додаткові snapshots збільшують RAM-витрати. Фактична capacity може бути меншою
за 256 із попереднього тесту. Вікно — до 12 секунд або capacity, що настане
раніше. Нормальні записи зберігають довжини й 128-бітні SHA-256 fingerprints;
на пристрої застосовується повне memcmp. Повні 7 snapshots зберігаються для
перших двох повідомлень із flags; надлишок явно позначений `faultOverflow`.
Це не повний raw-журнал усіх ESP32-пакетів на диску під час приймання.

## Одна коротка контрольна спроба

Нижче команди для **PowerShell**; ADB вказаний повним шляхом, без `$bleAdb`.
SENDER лишається SEND_MODE=1. Поточні Android APK/Windows EXE залишаються.
Заверши попередні сесії до прошивання; Serial Monitor і Windows app закрий.

### 1. Зібрати та прошити користувачем

```powershell
cd D:\KNUO_term_paper\can_debug
python tool/build_receiver_ble_trace.py --btc-copy
```

У `build/receiver_btc_trace/build_manifest.json` повинні бути:
`verification=compile_and_link_only`, `btcCopyProbe=true`,
`btcCallbackPointerAndOriginalVerified=true`. Попередня збірка лишається
в іншому каталозі `build/receiver_ble_trace`.

Якщо поточний RECEIVER — COM5:

```powershell
& 'D:\ArduinoIDE\Arduino IDE\resources\app\lib\backend\resources\arduino-cli.exe' upload --config-file "$env:USERPROFILE\.arduinoIDE\arduino-cli.yaml" --fqbn esp32:esp32:esp32 --port COM5 --input-dir .\build\receiver_btc_trace ..\arduino\receiver_ble
```

Для іншого порту заміни COM5 у прошиванні, Windows UI та dump. Звичайний Upload
в Arduino IDE не вмикає цей hook. Автор патчу цю команду upload не запускав.

### 2. USB, потім BLE

```powershell
cd D:\KNUO_term_paper\can_debug
& .\build\windows\x64\runner\Release\can_debug.exe
```

Почни Windows USB-моніторинг RECEIVER на **460800**; перевір кадри та stats.
До цього Android BLE не підключай. Потім у терміналі:

```powershell
& 'D:\devSdk\Android\Sdk\platform-tools\adb.exe' devices
python tool/ble_native_trace.py --adb 'D:\devSdk\Android\Sdk\platform-tools\adb.exe' --device 93e1c8bd start
```

Дочекайся нового native run, на телефоні підключи BLE і почни моніторинг.
Один BLE-клієнт, **20–30 секунд**, без reboot/hot restart/зміни режимів.
Тільки після обох CCCD починається RAM-вікно; далі воно самостійно запечатується.

### 3. Зупинити й витягнути

На Android натисни Stop і дочекайся збереження. Потім:

```powershell
python tool/ble_native_trace.py --adb 'D:\devSdk\Android\Sdk\platform-tools\adb.exe' --device 93e1c8bd stop
```

Після `closed` зупини Windows-моніторинг, дочекайся закритого USB manifest
і закрий Windows app, щоб звільнити COM5. **Живлення RECEIVER не від'єднуй,
Reset не натискай — діагностика в RAM.**

```powershell
python tool/ble_native_trace.py --adb 'D:\devSdk\Android\Sdk\platform-tools\adb.exe' --device 93e1c8bd pull --output build/ble_btc_copy_1
python -m pip install pyserial==3.5
python tool/receiver_ble_trace.py dump --port COM5 --output build/receiver_btc_copy_1.jsonl
```

У RAM-файлі header має **schema=2**, hook=`api-and-btc-deep-copy-return`.
Якщо schema=1 — прошито попередню діагностичну збірку, цей файл не підтверджує
post-copy. Якщо порожньо/timeout — не вважай спробу успішною; збережи вивід.
Pyserial відкриває DTR/RTS вимкненими; драйверний reset усе ж можливий і
знищить RAM-запис, що буде видно за порожнім журналом/новим boot.

### 4. Порівняти

```powershell
cd D:\KNUO_term_paper\can_debug
$bleRun = Get-ChildItem .\build\ble_btc_copy_1 -Directory -Filter 'run_*' | Sort-Object Name | Select-Object -Last 1
$usbRun = Get-ChildItem "$env:USERPROFILE\Documents\CAN_Debug_Pro\experiments" -Directory -Filter 'capture_*' | Sort-Object Name | Select-Object -Last 1
$bleRun.FullName
$usbRun.FullName
```

Перевір, що це саме щойно записана пара, тоді:

```powershell
python tool/receiver_ble_trace.py compare --trace build/receiver_btc_copy_1.jsonl --usb "$($usbRun.FullName)\capture.jsonl" --ble "$($bleRun.FullName)\notifications.jsonl" --out build/receiver_btc_copy_comparison_1.json
```

Утиліта не перезаписує існуючі dump/report. Якщо імена `_1` уже зайняті,
обери новий однаковий суфікс у командах; попередні файли не видаляй.
Передай comparison, RAM JSONL, native/USB JSONL з manifests та build_manifest.
Це одна контрольна спроба; автоматично інший tracing не запускається.

## Інтерпретація

Спочатку `traceCompleteAndConsistent`, `usbCompleteAndConsistent`,
`nativeCompleteAndConsistent` і **`btcCopyObservationComplete`** мають бути true.
Окремо дивись bothCharacteristicsMeasured, coverage anchors та counters.
Повний diagnostic journal не означає правильний payload.

- API правильний, source перед copy неправильний: зміна **між входом API та
  pre-copy**, а не доказ пошкодження саме в memcpy.
- Source перед copy правильний, destination одразу після оригіналу інший:
  розбіжність локалізована **на цьому інтервалі копіювання**. Це ще не root
  cause: source міг змінюватися конкурентно; NULL destination може означати
  allocation failure. Знімків/пам'яті треба достатньо для наступного висновку.
- Destination правильний та збігається з USB, але Android між anchors уже
  інший: спостережена зміна **після post-copy snapshot і до Android entry**.
  Це не розділяє пізні BTC/Bluetooth/controller/radio та Android/GATT.
- Missing/unmatched/multiple callbacks або неузгоджені tokens: межу не
  встановлено; відповідність повідомлень не вгадується за сусідством.
- Немає аномалії у RAM-вікні: ця коротка спроба її не локалізувала.

`btcCopyDifferences` містить pre/post boundaries; `btcVsNativeDifferences` —
post-copy проти Android. Для порівняння лишається й `apiVsNativeDifferences`.
`physicalFixConfirmed` завжди false: це діагностика, функціонального фіксу немає.

## Перевірки та збереження

```powershell
python -m unittest discover -s tool -p test_receiver_ble_trace.py -v
python -m unittest discover -s tool -p test_build_receiver_ble_trace.py -v
```

Покриті попередні 16 сценаріїв та BTC source/destination corruption, правильний
BTC з поганим Android, tokens, пропущені/чужі/повторні callbacks, перестановка
експорту, alias/metadata та відмова збірки на невідомому libbt.a. Всі — offline.
Попередній фізичний comparison №193/seq604 відтворюється точно без змін.

Пройшли **30 тестів** (27 порівняння/журнал + 3 build/ELF guards).
Успішно зібрані: BTC schema=2, попередній API-only schema=1 та звичайний
RECEIVER з вимкненими trace flags. BTC-збірка: **1 112 443 bytes flash,
55 512 bytes globals**. RAM pool/queue/task stacks додаються під час запуску;
фактичну місткість ще має показати фізичний header. У звичайному ELF відсутні
обидва wrapper hooks. У фінальному BTC ELF callback pointer і original call
перевірені; хеші джерел/SDK/BIN записані в `build_manifest.json`.

Перед редагуванням 68 поточних файлів і Git-стан збережено у
`../.work_backups/btc_copy_before_20261110_175543.zip`.
Новий hook у helper; наявні Arduino/SDK callbacks і транспортний протокол не
переписувалися. Android, Windows, SQLite, SENDER і NO_ACK/recovery не змінені.
