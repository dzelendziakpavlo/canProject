# BTC queue → btc_gatts_call_handler: один вхідний snapshot

Дата: 2026-11-10. Лише діагностика. Нового фізичного експерименту ще немає;
пристрої під час реалізації не прошивалися. Buffer reuse не встановлений як причина.

## Що вимірюється

Попередній schema=2 експеримент мав 128 узгоджених post-copy snapshots та дві
пошкоджені Android-позиції. Новий schema=3 залишає ці етапи й додає **одну** точку:
копію байтів/length на вході `btc_gatts_call_handler()`, до виклику оригіналу.

У pinned ESP-IDF 5.5.4 / commit 735507283d:

- [btc_task.c](https://github.com/espressif/esp-idf/blob/735507283d/components/bt/common/btc/core/btc_task.c):
  `profile_tab[BTC_PID_GATTS].btc_call` адресує handler; GATTS profile=2,
  розмір entry=8 bytes, offset потрібного function pointer=16.
- [btc_gatts.c](https://github.com/espressif/esp-idf/blob/735507283d/components/bt/host/bluedroid/btc/profile/std/gatt/btc_gatts.c#L618):
  handler читає `msg->arg` (offset 4) і для SEND_INDICATE викликає
  `BTA_GATTS_HandleValueIndication(...)`, далі звільняє arg payload.

ABI й hash `libbt.a` ті самі, що у [post-copy аудиті](BTC_DEEP_COPY_EXPERIMENT.md).
Невідомий SDK або непідтверджений function pointer зупиняє build tool.

Linker `--wrap=btc_gatts_call_handler` додає snapshot і викликає оригінальний
handler **рівно один раз із незмінним message pointer**. Перевіряється саме
function pointer у кінцевому `profile_tab`, а не тільки запитані linker flags.
SDK, BLE implementation, msg/arg/payload і порядок оригінальних викликів не редагуються.

## Як передається token через асинхронну чергу

Post-copy callback реєструє у чотирьох власних RAM slots:

`живий btc_msg address → message.id + copyToken + власні post-copy bytes/length`.

Реєстрація публікується до оригінального `btc_task_post`. Handler може прийти
раніше, ніж BLE-task запише основний diagnostic record — це враховано.
Вхідний hook знаходить запис за адресою ще живого BTC msg, атомарно забирає
slot і передає до worker його незмінні ID/token разом зі своїм snapshot.
Порівняння на ПК приєднує записи за **ID + token**, не за порядком рядків,
wire seq чи схожістю JSON. Зіставляються також адреса msg, pointer payload,
connection, handle, confirm, length і вміст.

Додатковий `--wrap=btc_gatts_arg_deep_free` — лише guard lifetime, **без нової
точки snapshot**: при невдалому post реєстрація прибирається до оригінального
free. Це не дає пізніше прив'язати нову allocation за повторно використаною
адресою до старого token. Оригінальний free також викликається рівно один раз.
Його callback pointer у send API перевіряється у кінцевому ELF.

Після успішного handler snapshot slot більше не використовує SDK memory.
Власні копії можна читати після того, як оригінал handler звільнить BTC payload.
Числові адреси в журналі — ключі/метадані, а не відкладені mutable references.

## Робота в BT-task і межі безпеки

На BT hot path є лише bounded metadata reads, memcpy/memcmp (до 640 bytes),
aligned word loads/stores та native CAS. Немає SHA, allocation, Serial,
filesystem, mutex, spinlock, RTOS queue або очікування вільного slot.
Чотири slots перевіряються по одному разу. Оновлення counters має максимум
8 CAS-спроб; невдача ставить `handlerAtomicFailure` і забороняє довіряти результату.

GCC `__atomic` RMW у встановленому toolchain **не гарантовано lock-free**.
Початкова захисна збірка це виявила. Замість прихованого lock fallback
використовується перевірений SDK
[xt_utils_compare_and_set](https://github.com/espressif/esp-idf/blob/735507283d/components/xtensa/include/xt_utils.h#L217):
тільки native `XCHAL_HAVE_S32C1I=1` шлях із memory fences, для внутрішньої DRAM.
IRQ fallback заборонений compile guard. Хеші HAL/core-ISA headers pinned;
ELF hot path перевіряється на S32C1I, відсутність IRQ masking/очікування,
блокувальних API й runtime atomic fallback. Байти реальної прошивки під час
inspection не змінюються. SDK source/cache не патчаться.

Якщо handler pointer не дорівнює зареєстрованому payload pointer, hook **не
слідує невідомій адресі**. Якщо length більший за відомий розмір allocation,
байти теж не читаються. Реальна pointer/length metadata зберігається, snapshot
позначається invalid; утиліта не видає це за повне порівняння payload.
Оригінальний handler викликається зі своїми аргументами без підміни.

Worker рахує fingerprints і переносить metadata у bounded RAM storage.
При підтвердженій різниці зберігаються **обидві повні копії**: post-copy та
handler input. Slot залишається FROZEN до dump; це лише власні копії,
не утримання BTC resources. Усі підтверджені аномалії зареєстрованого cohort
мають повні пари; їх не викидають заради нових пакетів. Коли всі чотири slots
зайняті аномаліями, нові реєстрації відхиляються з `handlerRegisterDropped`,
і весь запис не видається за повний. Нормальні повідомлення
мають length і 128-бітний SHA-256 fingerprint. Повне memcmp робиться у hook.

Нове спостереження потребує додаткової RAM; фактичне вікно може бути коротшим
за попередні 3,42 s. Максимум — 12 секунд або фактична capacity. Headroom для
SDK не зменшували. Невдала allocation — явна помилка/порожній невалідний запис.
Діагностика впливає на таймінги; чисте коротке вікно не доводить виправлення.

## Одна контрольна спроба

PowerShell. Заверши старі сесії. Закрий Windows app та Arduino Serial Monitor.
SENDER лишається SEND_MODE=1; Android APK і Windows EXE ті самі.

### 1. Діагностична збірка та прошивання користувачем

```powershell
cd D:\KNUO_term_paper\can_debug
python tool/build_receiver_ble_trace.py --btc-handler
```

Результат — **`build/receiver_btc_handler_trace`**, окремо від schema=1/2.
Build manifest повинен містити `btcHandlerProbe=true`,
`btcHandlerTableAndOriginalVerified=true`,
`btcFailureFreeCallbackAndOriginalVerified=true`,
`handlerNativeCasAndDramVerified=true`, `verification=compile_and_link_only`.
При STOP/помилці не обходь guard і не прошивай непідтверджений бінарник.

Якщо RECEIVER досі COM5 (інакше заміни порт у всіх кроках):

```powershell
& 'D:\ArduinoIDE\Arduino IDE\resources\app\lib\backend\resources\arduino-cli.exe' upload --config-file "$env:USERPROFILE\.arduinoIDE\arduino-cli.yaml" --fqbn esp32:esp32:esp32 --port COM5 --input-dir .\build\receiver_btc_handler_trace ..\arduino\receiver_ble
```

Автор патчу цю upload-команду не запускав. Звичайний Upload в Arduino IDE
не вмикає необхідні діагностичні compile/link flags.

### 2. USB раніше BLE

```powershell
& .\build\windows\x64\runner\Release\can_debug.exe
```

На Windows почни USB Serial / RECEIVER / **460800**. Перевір кадри й stats.
Потім увімкни Android journal:

```powershell
python tool/ble_native_trace.py --adb 'D:\devSdk\Android\Sdk\platform-tools\adb.exe' --device 93e1c8bd start
```

Дочекайся нового native run. Підключи BLE на телефоні, почни моніторинг.
Один BLE-клієнт, **20–30 секунд**, без hot restart, reboot чи зміни режимів.
RAM-вікно починається після обох CCCD і закривається автоматично.

### 3. Зупинка і збереження

На телефоні Stop, дочекайся збереження. Потім:

```powershell
python tool/ble_native_trace.py --adb 'D:\devSdk\Android\Sdk\platform-tools\adb.exe' --device 93e1c8bd stop
```

Після native `closed` зупини USB-моніторинг, дочекайся закритого Windows
manifest і закрий Windows app. **RECEIVER не від'єднуй і Reset не натискай.**

```powershell
python tool/ble_native_trace.py --adb 'D:\devSdk\Android\Sdk\platform-tools\adb.exe' --device 93e1c8bd pull --output build/ble_btc_handler_1
python tool/receiver_ble_trace.py dump --port COM5 --output build/receiver_btc_handler_1.jsonl
```

Для dump потрібен уже використаний pyserial 3.5; за відсутності:
`python -m pip install pyserial==3.5`. У header має бути **schema=3**, hook
`api-btc-copy-and-handler-entry`. Schema=2 не вимірює handler.
Worker дочікується handler-ів до 3 секунд; timeout/pending не маскуються під
успішний повний запис. Утиліта може timeout без footer, якщо безпечно закрити
snapshot ще неможливо. Отриманий файл тоді неповний — збережи його й вивід.

### 4. Порівняння

```powershell
cd D:\KNUO_term_paper\can_debug
$bleRun = Get-ChildItem .\build\ble_btc_handler_1 -Directory -Filter 'run_*' | Sort-Object Name | Select-Object -Last 1
$usbRun = Get-ChildItem "$env:USERPROFILE\Documents\CAN_Debug_Pro\experiments" -Directory -Filter 'capture_*' | Sort-Object Name | Select-Object -Last 1
$bleRun.FullName
$usbRun.FullName
```

Перевір щойно створені каталоги, тоді:

```powershell
python tool/receiver_ble_trace.py compare --trace build/receiver_btc_handler_1.jsonl --usb "$($usbRun.FullName)\capture.jsonl" --ble "$($bleRun.FullName)\notifications.jsonl" --out build/receiver_btc_handler_comparison_1.json
```

Dump/report не перезаписують існуючі файли. Якщо `_1` зайнятий, використовуй
новий суфікс у всіх командах. Передай comparison, RAM JSONL, native/USB JSONL
із manifests та build_manifest.json. До успішного dump живлення не вимикай.

## Що саме вирішує звіт

Для висновку потрібні `traceCompleteAndConsistent`, `usbCompleteAndConsistent`,
`nativeCompleteAndConsistent`, `btcCopyObservationComplete` та
**`handlerObservationComplete=true`**.

- `handlerDifferences` показує зміну байтів/length/metadata між post-copy і
  початком handler. `handlerFaultSnapshots` містить повні expected/actual hex
  для підтверджених аномалій; invalid pointer/oversize ніколи не називаються
  повністю знятим payload.
- `missingHandlerMessages`, register drops, pending, cancellations, counter
  failure чи faultOverflow роблять спостереження неповним. Token/address
  mismatch не виправляється евристикою за JSON.
- `handlerUntrackedCalls` сам по собі не означає втрату: це може бути трафік
  перед/після обмеженого cohort. Для повноти перевіряються саме очікувані
  зареєстровані ID/token та їх fingerprints/повні fault bytes.
- `handlerPayloadChanged=false` можна читати як відсутність зміни тільки
  разом із complete=true. При неповному вимірюванні значення null.
- Якщо handler input незмінний, але `handlerVsNativeDifferences` ненульовий,
  наступна **ще не виміряна** межа — вхід handler → вхід
  `BTA_GATTS_HandleValueIndication`. Далі лишаються BTU/controller/radio та
  Android/GATT до native entry. Цей патч їх не інструментує.

Навіть розбіжність на queue → handler не доводить конкретний buffer reuse;
потрібні відповідні байти, metadata й повне зіставлення. Нових hooks, HCI чи
функціонального виправлення після цього експерименту автоматично не додаємо.

## Перевірки і резервна копія

```powershell
python -m unittest discover -s tool -p test_btc_handler_trace.py -v
python -m unittest discover -s tool -p test_receiver_ble_trace.py -v
python -m unittest discover -s tool -p test_build_receiver_ble_trace.py -v
```

Нові offline cases: handler раніше parent record; перестановка rows; різні
generations за тією самою адресою; хибний token; повні raw-анomalies; overflow;
late/missing/cancelled message; metadata; unsafe pointer/length; atomic failure;
правильний handler із поганим Android. Фізичної перевірки нового hook ще немає.

Пройшли **48 offline-тестів**: 18 нових handler cases, 27 попередніх trace cases,
3 build guards. Обидва надані фізичні comparison schema=1/2 відтворюються точно;
хеші їхніх inputs збережені. Успішні компіляції schema=3, schema=2 і звичайного
RECEIVER. Новий BIN: **1 115 915 bytes flash**, **61 024 bytes globals**;
це не включає динамічні RAM records/queue/task stacks. Звичайна збірка має
1 105 483 / 41 296 bytes і не містить trace hooks. Висновків про нову фізичну
поведінку ці перевірки не дають.

Перед редагуванням 73 поточні файли та Git-стан збережено у
`../.work_backups/btc_handler_before_20261110_184145.zip`.
Зміни — лише diagnostic helpers/build/compare/tests/docs. Продуктивний скетч,
SDK, FF11/FF12, Android, Windows, SQLite, SENDER, NO_ACK/recovery не редагувалися.
