# Android BLE native snapshot: патч і контрольний експеримент

Дата: 2026-11-09. Оновлений стан: отримано й перевірено контрольний запис
користувача. **Аномалії після патчу залишилися; зміни оригінального byte[]
між entry snapshot і UI probe не виявлено.** Детальний результат наведено
в кінці документа. Під час самої реалізації новий APK на телефон не
встановлювався; контрольний запис пізніше виконав користувач. Подальші
роботи вирішуємо окремо; ESP32/HCI tracing автоматично не запускається.

## Що реалізовано

- Локальна копія `flutter_blue_plus_android 7.0.4` у `third_party/`,
  dependency override і відносний шлях у lock. Parent plugin залишається
  `flutter_blue_plus 1.36.8`. Глобальний Pub cache не змінювався.
- Перевірено API 33+ callbacks із value та legacy callbacks із getValue().
  У кожному callback перша операція з value — незалежна копія. Modern та
  legacy шляхи обробляються окремо, без подвійної обробки через делегування.
- Підключений телефон `93e1c8bd` повернув Android 11 / SDK 30 через getprop.
  Для нього потрібен legacy шлях. Фактично викликаний callback у новому
  експерименті фіксується полем `callback_kind`, а SDK — `sdk_int`.
- MethodChannel отримує snapshot, а не оригінальний масив. Це діє також
  при вимкненій діагностиці або помилці raw-журналу.
- Коли trace увімкнений, оригінальне посилання зберігається тільки до
  відкладеного UI runnable для одноразового порівняння з entry snapshot.
  Перед channel encode воно звільняється. На dispatch створюється ще одна
  копія оригіналу для узгоджених bytes/hash доказів. Посилання на mutable
  оригінал не передається файловому writer і не зберігається після probe.
- Raw-журнал: один worker, черга 1024 immutable JSON strings, nonblocking
  offer. Callback не створює файлів, не записує й не очікує disk I/O.
  `droppedRecords` і `writeErrors` видимі в manifest. Overflow втрачає лише
  діагностичний запис; відповідний MethodChannel event усе одно передається.
- Журнал зберігає повні FF11/FF12 bytes у hex, довжину, callback number,
  monotonic timestamps, wall time, callback kind/thread, GATT status,
  snapshot SHA-256 та результат порівняння оригіналу. При мутації також
  зберігається незалежний dispatch-time hex. Тільки FF10/FF11/FF12.
- За замовчуванням raw trace вимкнений. Приватний marker вмикає його при
  старті engine. Окремий stop marker закриває writer без закриття застосунку.
- Verbose-консоль вимкнено за замовчуванням; за потреби її можна ввімкнути
  через `--dart-define=BLE_VERBOSE_LOG=true`. Для контрольного запису це
  не потрібно: довгі FF12 більше не залежать від logcat.

Формат FF11/FF12, SQLite, Windows USB Serial і firmware не змінювались.
Нових Android permissions або публічних receivers немає. Деталі upstream
і ліцензія збережені в `third_party/flutter_blue_plus_android/`.

## Збірка та встановлення

У PowerShell із кореня Flutter-проєкту:

```powershell
Set-Location D:\KNUO_term_paper\can_debug
flutter pub get --offline
flutter build apk --debug --no-pub
$bleAdb = 'D:\devSdk\Android\Sdk\platform-tools\adb.exe'
& $bleAdb devices
& $bleAdb -s 93e1c8bd install -r .\build\app\outputs\flutter-apk\app-debug.apk
```

Використовується debug APK, бо `run-as` потребує debuggable застосунку.
`install -r` оновлює застосунок зі збереженням даних. Перед початком
заверши попередню сесію й дочекайся збереження. Команда start нижче
перезапускає застосунок; її не слід виконувати посеред активної сесії.
Якщо підключений інший телефон, підстав його serial замість `93e1c8bd`.
На іншому ПК без завантаженого кешу залежностей виконай `flutter pub get`
без `--offline`; локальний override однаково братиметься з репозиторію.

## Контрольний запис

1. Увімкнути native trace й запустити застосунок:

```powershell
python tool/ble_native_trace.py --adb "$bleAdb" --device 93e1c8bd start
```

Утиліта створює private marker, перезапускає застосунок і чекає появи
**нового** active run. Вона не приймає старий journal за новий. Назва
`run_...` друкується в терміналі. Якщо старий APK ще встановлений або
worker не запустився, команда повідомить помилку.

2. На ПК запустити Windows CAN Debug Pro:

```powershell
& .\build\windows\x64\runner\Release\can_debug.exe
```

Вибрати **USB Serial**, поточний порт RECEIVER (у попередньому записі COM5),
**460800**, Connect і почати моніторинг. Arduino Serial Monitor закрити,
щоб він не займав порт. Повний journal автоматично пишеться в
`Documents\CAN_Debug_Pro\experiments\capture_...` незалежно від UI-буфера.
Firmware залишити як під час попереднього запису: RECEIVER 460800 /
CAN_SERIAL_JSON=1, SENDER SEND_MODE=1. У цьому етапі його не перепрошиваємо.

3. Після старту USB-запису підключити RECEIVER через BLE на телефоні й
записати 3–5 хвилин. `flutter run` та logcat не потрібні. Під час одного
контрольного run не виконувати hot restart, reboot RECEIVER або зміну режимів.

4. На телефоні натиснути **Stop**, дочекатися завершення збереження сесії.
Експортувати її повний JSON. Потім закрити raw trace, залишивши апку живою:

```powershell
python tool/ble_native_trace.py --adb "$bleAdb" --device 93e1c8bd stop
```

Команда чекає `status=closed` і друкує manifest. Не force-stop застосунок
до завершення цієї команди. У worker є до 3 секунд на вже спостережені,
але ще не dispatched callbacks; незавершений хвіст явно позначається.

5. Зупинити Windows-моніторинг, дочекатися закриття USB manifest. Отже,
USB має покривати весь період BLE. Витягнути поточний native journal:

```powershell
python tool/ble_native_trace.py --adb "$bleAdb" --device 93e1c8bd pull --output build/ble_native_capture
```

Файли на телефоні:
`/data/user/0/com.example.can_debug/files/ble_native_trace/run_.../notifications.jsonl`
і `manifest.json`. Команда витягує лише останній native trace через binary
tar, не читає Downloads, чужі застосунки або загальну приватну БД CAN Debug.
На ПК результат: `build\ble_native_capture\run_...\` і tar поруч.
PowerShell-перенаправлення binary tar вручну не використовувати.

## Порівняння

Наступні команди обирають останні каталоги. Переконайся, що це саме
два поточні записи, якщо паралельно створювалися інші експерименти.

```powershell
$bleRun = Get-ChildItem .\build\ble_native_capture -Directory -Filter 'run_*' |
    Sort-Object Name | Select-Object -Last 1
$usbRun = Get-ChildItem "$env:USERPROFILE\Documents\CAN_Debug_Pro\experiments" -Directory -Filter 'capture_*' |
    Sort-Object Name | Select-Object -Last 1
python tool/ble_native_trace.py compare --ble "$($bleRun.FullName)\notifications.jsonl" --usb "$($usbRun.FullName)\capture.jsonl" --out build/ble_native_comparison.json
```

Додаткова перевірка Android-сесії (підстав шлях саме її експорту):

```powershell
python tool/ble_native_trace.py compare --ble "$($bleRun.FullName)\notifications.jsonl" --usb "$($usbRun.FullName)\capture.jsonl" --android-session 'C:\шлях\до\Schema.json' --out build/ble_native_comparison.json
```

Утиліта перевіряє native lengths/hash, callback numbers, manifest counters,
mutation evidence, послідовності та JSON-поля. USB stats можуть мати
додаткові transport-поля: порівнюються спільні BLE-поля за uptime.
Порядок кадрів зберігається; записи не сортуються за seq й не дедуплікуються.
Повний звіт: `build/ble_native_comparison.json`. Python 3.12+; додаткові
Python-пакети не потрібні.

## Як оцінювати результат

Спочатку перевірити якість самого експерименту:

- Непорожні FF11 та FF12, `journalCompleteAndConsistent=true` і
  `usbJournalCompleteAndConsistent=true` у повному звіті.
- Native manifest: closed, droppedRecords=writeErrors=pendingRecords=
  undispatchedCallbacks=0; observed/dispatched/enqueued/written/flushed
  дорівнюють кількості JSONL records. Файлові помилки або drops роблять
  висновки про відсутні callbacks неповними.
- `uncomparedOriginals=0`, `methodChannelUnavailable=0`, перевірка hash
  без помилок. SDK 30 очікувано дає notification_legacy; це буде факт із
  запису, а не припущення про API за версією залежності.

Далі інтерпретація:

- `originalMutationCount > 0` разом з узгодженим dispatch-time hash/hex
  доводить зміну upstream array між entry snapshot і UI probe. Якщо
  snapshot при цьому збігається з USB, копія захистила ці конкретні events.
- Якщо оригінал не змінювався, а snapshot уже суперечливий або malformed,
  причина залишається вище цієї точки. Надаємо результат і окремо
  ухвалюємо рішення про подальші роботи; ESP32/HCI не чіпаємо автоматично.
- Якщо аномалій немає, це позитивний результат цього run, а не остаточний
  доказ причини. Зміна verbosity і діагностика впливають на таймінги.
  Поле `physicalFixConfirmed` утиліта навмисно не встановлює в true.
- Відсутні seq у журналі не тотожні втратам фізичних CAN-кадрів.
  Межі Android-сесії та native trace можуть відрізнятись на краях;
  нерівність повних масивів сама по собі не доводить зміну payload.

Передати для аналізу: native notifications.jsonl + manifest, Windows
capture.jsonl + manifest, за можливості Android JSON та результат compare.
Повний phone bugreport або загальний дамп даних телефону не потрібні.

Вимкнути створення наступних trace runs після експерименту:

```powershell
python tool/ble_native_trace.py --adb "$bleAdb" --device 93e1c8bd disable
```

Наявні файли зберігаються; snapshot-forwarding продовжує працювати.
Журнал обмежений чергою в RAM, але росте на диску до зупинки. При
force-stop гарантований лише синхронізований префікс; active manifest
не є доказом повного завершення. `build/` і `.work_backups/` ігноруються Git.

## Автоматизовані перевірки

```powershell
flutter test --no-pub
python -m unittest discover -s tool -p test_ble_native_trace.py -v
$env:JAVA_HOME = 'C:\Program Files\Android\Android Studio\jbr'
Push-Location android
.\gradlew.bat :flutter_blue_plus_android:testDebugUnitTest :app:testDebugUnitTest --console=plain
Pop-Location
```

Пройшли 104 Flutter-тести, 6 native snapshot/journal тестів, 4 наявні native
export тести та 6 Python comparison тестів. Native перевіряють незалежність
snapshot, справжнє виявлення штучної мутації, null/disabled probe,
довгий FF12, порядок запису, queue overflow, write error та stop/flush.
Python перевіряє повний FF12, історичний змішаний payload, mutation evidence,
пошкоджений journal, втрати/помилки writer і malformed callback.

Android debug APK і Windows release зібрано. `flutter analyze --no-pub`:
0 errors, 103 info та 1 наявний warning (unused import у
`test/can_anomaly_analyzer_test.dart`). Аналізатор повертає ненульовий код
через зауваження, тому чистим проходженням його не позначено.
`git diff --check` пройшов. Результат пізніше наданого фізичного
контрольного запису наведено нижче.
Перед редагуванням поточні 42 файли й Git-стан збережено в
`../.work_backups/native_ble_patch_before_20261109_171010.zip`.

Зміни цього етапу:

- `pubspec.yaml`, `pubspec.lock` — локальний Android override, без зміни версій інших залежностей.
- `third_party/flutter_blue_plus_android/` — upstream sources/license/hashes,
  callback patch, нові BleValueSnapshot/BleRawJournal, JUnit тести й patch notes.
- `lib/domain/source/ble_can_source.dart` — verbose тепер опційний через dart-define.
- `tool/ble_native_trace.py`, `tool/test_ble_native_trace.py` — контроль trace,
  безпечне binary витягування, порівняння й шість тестів утиліти.
- Ця інструкція та посилання з попереднього звіту.

Логи: `build/native_ble_pub_get.log`, `build/native_ble_junit.log`,
`build/native_ble_flutter_tests.log`, `build/native_ble_analyze.log`,
`build/native_ble_android_build.log`, `build/native_ble_windows_build.log`.

## Результат контрольного запису користувача

Перевірено `build/ble_native_comparison.json`, native run
`run_1794238646989_34105628360216` і USB capture
`capture_1794238732128313_478dda7b`. Обидва вихідні JSONL доступні;
їхні SHA-256 збігаються з inputs у звіті. Повторне виконання поточної
утиліти compare **точно відтворило весь звіт**. Звіт і вихідні файли
не змінювалися. SHA-256 звіту:
`057dba7bd3bbd3a633cd3eb1e07bdb32e62b85dace019e336093a25b58e11395`.

| Перевірка | Результат |
|---|---|
| Native journal | closed; 9049 observed/dispatched/enqueued/written/flushed |
| Dropped records / write errors / pending / undispatched | 0 / 0 / 0 / 0 |
| Номери callbacks і snapshot lengths/hash | усі 1–9049, без повторів і розривів; усі узгоджені |
| Фактичний callback | notification_legacy: 9049; SDK 30 |
| Не порівняні оригінали / недоступний MethodChannel / GATT errors | 0 / 0 / 0 |
| Зміни оригіналу між snapshot і dispatch | **0 із 9049**; обидва записані хеші рівні в кожному event |
| FF11 / FF12 callbacks | 8805 / 244 |
| Синтаксично невалідні JSON callbacks | **41: FF11 — 39, FF12 — 2** |
| CAN JSON, що відрізняються від USB при тому самому seq | **15** |
| Телеметрія, що відрізняється при тому самому uptime | **4**, поле rx |
| USB journal | closed; 9199 записів: 8950 frames + 249 stats; без parse/read/write errors |
| USB seq | 4959–13908, без повторів і пропусків |

`journalCompleteAndConsistent=true` означає цілісність **самого журналу**,
а не коректність BLE payload. Внутрішній interval callback→UI probe мав
медіану 36.419479 мс, максимум 3911.830936 мс. Це різниця двох monotonic
timestamps на Android, не latency від CAN. У цьому вікні мутацій оригіналу
не зафіксовано; даних на підтвердження саме цієї гіпотези немає.

Snapshot уже містить невалідний/суперечливий payload у callback. Наприклад,
FF12 callback №3035 починається CAN-об'єктом `{"t":"f",...}`, після якого
йде хвіст телеметрії. FF11 callback №2249 містить два нульові байти між
`"dlc":8` та `data`. Це повні файлові byte snapshots із перевіреними
length/hash, а не обрізаний verbose/logcat-друк.

8751 CAN-повідомлення повністю збігаються з USB; ще 15 синтаксично валідних
CAN JSON відрізняються. З 242 синтаксично валідних stats 238 збігаються,
4 мають інше rx. Число 41 стосується JSON цілого callback; воно не дорівнює
кількості відхилень Dart reassembler, який може виділити окремий об'єкт
із callback або відкинути partial. Android session JSON до цього звіту
не доданий, тому його SQLite-підрахунки тут не перевірялись.

У діапазоні валідних BLE seq 5081–13886 немає 56 номерів, є 16 повторних
входжень. Це характеристики номерів у payload, а не доказ втрати саме
56 фізичних CAN-кадрів: підміна seq і невалідні повідомлення також дають
такий результат. Повнота native journal усуває втрати **його черги** з
пояснень цього run, але не визначає стан upstream transport.

Висновок: snapshot-forwarding працює за записаним шляхом, проте **не усунув
спостережені аномалії**. Мутація upstream array після entry snapshot не
підтверджена. Це не виключає проблеми до snapshot, зокрема legacy
getValue()/GATT, і не доводить провину ESP32. Функціональних змін після
цього результату не внесено. Подальшу локалізацію погоджуємо окремо.

Підсумок незалежної перевірки:
`build/validation/native_ble_result/verified_summary.json`.
Перед оновленням звітів збережено 60 поточних змінених/нових файлів і
Git-стан у `../.work_backups/native_ble_result_before_20261109_174846.zip`.
