# Android: достовірність діагностики та збереження

Дата аудиту: 2026-11-08. Контрольні тести використовують синтетичні дані; вони не є вимірюваннями стенду. Окремо досліджено дані фізичного Redmi Note 8T, доступного через ADB.

Оновлення щодо Android-експорту: проблему нульових документів, відновлення реальних файлів і новий механізм запису після завершення процесу описано в [ANDROID_EXPORT_FIX.md](ANDROID_EXPORT_FIX.md). Наведені нижче результати основного аудиту є історичним станом до цього виправлення.

## 1. Фактична архітектура до виправлення

`BleCanSource` приймав FF11/FF12 → `MonitorScreen` накопичував кадри до наступного UI-оновлення → залишав останні 100 → передавав саме цей список до `CanSessionService`. Завершені сесії серіалізувалися одним JSON-масивом у SharedPreferences (`can_sessions`). Активна сесія перебувала в оперативній пам'яті до завершення. `app.db` з `DatabaseHelper` містить користувачів, а не CAN-кадри.

Автоматичний CSV/JSONL-журнал був реалізований для Windows USB Serial. Android BLE його не створював. Старі CSV/JSON/PDF-експорти записувалися у приватний Documents-каталог застосунку.

## 2. Пакет і перевірені шляхи на Redmi

`applicationId = com.example.can_debug` підтверджено Gradle-конфігурацією та `dumpsys package`.

| Дані | Шлях |
|---|---|
| Корінь приватних даних | `/data/user/0/com.example.can_debug` |
| Старі сесії | `shared_prefs/FlutterSharedPreferences.xml`, ключ `flutter.can_sessions` |
| Користувачі | `app_flutter/app.db` |
| Старі експорти | `app_flutter/Schema_47_20261108_171956.json` та інші CSV/PDF |
| Нові потокові BLE-сесії | `databases/can_capture.db` |
| Тимчасовий файл нового експорту | `cache/export_...`, видаляється після завершення/скасування експорту |
| Доступний користувачу новий експорт | Документ, вибраний у системному діалозі; UI показує ім'я і `content://` URI |

`Android/data/can_debug` не є місцем збереження цих сесій: це неправильне ім'я пакета, а самі дані знаходяться у приватному внутрішньому сховищі. Відсутність видимих файлів у файловому менеджері не доводить відсутність записів. Для експорту використано Android Storage Access Framework / `ACTION_CREATE_DOCUMENT`, без root і дозволу на доступ до всіх файлів. [Офіційна документація Android](https://developer.android.com/training/data-storage/shared/documents-files).

## 3. Доказ причини розбіжності Schema 47

Прочитано оригінальний експорт `app_flutter/Schema_47_20261108_171956.json` з телефона. Початковий файл не змінювався.

| Поле оригінального експорту | Значення |
|---|---:|
| session.id | `1794150653183` |
| session.totalFrames | 6820 |
| session.frames.length | 100 |
| session.errorFrames | 0 |
| session.errorStats | усі типи = 0 |
| Збережені frame.errors | відсутні |
| Останні TEC / REC / buserr | 0 / 0 / 0 |
| analytics.errorStats.stuffingError | 2 |
| analytics.errorStats.formatError | 1 |
| analytics.errorStats.ackError | 1 |

Це одна й та сама сесія в одному експорті. `SessionAnalyticsBuilder` повторно викликав `CanErrorChecker.analyzeFrame`, який містить детермінований генератор симульованих помилок. Генератор використовує ID, DLC, DATA і timestamp, тому відтворював хибні значення під час кожного відкриття. Випадковість тут детермінована; кеш не потрібний для відтворення проблеми. Експорт CSV і вікно деталей також запускали цей генератор. `SessionSummaryBuilder` повторно аналізував кадри для нетрункованих сесій, але для Schema 47 брав агрегати з усієї сесії, тому summary залишався нульовим.

Друга розбіжність області підрахунку: Live Monitor рахував усі 6820 кадрів, а графіки аналізували лише останні 100. Це не слід виправляти штучною зміною апаратних лічильників.

## 4. Підтверджені дефекти й межі доказів

Підтверджено кодом та даними телефона:

- `Schema 47`: збережено 100 із 6820 підрахованих кадрів. Наявна `Schema 50`: 100 із 5118, 141 знімок телеметрії та 1674 події.
- Старий Android-запис не був потоковим; активна сесія могла загубитися до Stop & Save.
- Помилки SharedPreferences перехоплювалися і лише друкувалися; успішне завершення не означало підтвердженого запису.
- BLE декодував notification як повний JSON і мовчки відкидав помилки. Не зберігалися `seq` і час RECEIVER.
- Зміни TWAI-лічильників породжували штучні кадри ID 0, включно з необґрунтованими ACK/Stuffing/Form-класифікаціями; арбітраж також помилково представлявся Form-помилкою.
- У вузьких макетах переповнювалися легенда, заголовки, дії та вікно деталей. Автоматичні tooltip/підписи осей додавали зайві числа.

Не встановлено: пошкодження початкової SQLite-бази, втрату даних через Scoped Storage або дефект фізичної CAN-шини. Відсутні раніше кадри неможливо відновити з їхніх агрегатних лічильників.

## 5. Зміни в збереженні та життєвому циклі

Нові Android BLE-сесії записуються у **окрему** SQLite-базу `can_capture.db`, schema version 1. Таблиця `captures` містить метадані; `capture_records` — впорядковані записи `frames`, `statsSnapshots`, `events`. Первинний ключ `(session_id, ordinal)` запобігає повторному запису того самого пакета під час повторного flush.

Прийнятий кадр ставиться в чергу збереження до обмеження UI. Транзакція атомарно записує записи, кількості та метадані. Поріг пакета — 128 записів, інтервал запиту checkpoint — 250 ms, гранична черга — 8192 записи. Переповнення або помилка диска видимі; монітор зупиняє джерело й позначає неповноту запису. Інтервал 250 ms **не є гарантією максимального часу втрати** при повільному диску або зависанні процесу.

Stop & Save зупиняє джерело, дренує доставлені повідомлення і очікує запису перед оголошенням завершення. Lifecycle checkpoint зменшує незаписаний хвіст. Після аварійного припинення відновлюються тільки завершені транзакції; сесія позначається `interrupted`, кінцевий хвіст RAM невідомий. Безумовне завершення процесу не викликає надійний `dispose`, тому гарантії збереження всіх останніх повідомлень немає.

Списки UI залишаються обмеженими (100 кадрів, 600 stats, 2000 подій). Analytics, Replay із відкритої сесії та експорт завантажують повні збережені записи. Існуючі сесії SharedPreferences залишені; автоматичного переписування чи видалення немає. CAN-модель отримала schema version 3 з необов'язковими метаданими; старі JSON читаються. Пакет, база користувачів, Android BLE UUID, прошивки та Windows-формат журналів не змінювалися.

## 6. Достовірність і облік

`recordedFrameErrors` читає збережені типізовані помилки. Симулятор більше не викликається під час Analytics, фільтрації чи експорту. Старий `isCorrupted` без деталей представляється як симульований прапорець, а не виміряний wire CRC. Старі конкретні hardware-класифікації без джерела `wire_error_capture` показуються як inferred; початкові файли при цьому не переписуються.

`TelemetryDiagnostics` реєструє зміни загальних лічильників і стану. `buserr`, `txfail`, `arb`, demo/noack-прапорці не визначають конкретний CRC/ACK/Stuffing/Form і не прив'язуються до CAN ID. Повторний незмінний stats не додає нову подію зміни. Зменшення uptime/лічильників починає нову baseline, а не від'ємну кількість помилок.

Для подій зберігається `evidence`: `telemetry`, `inferred`, `simulated`, `legacyUnknown`. Програмні висновки health/anomaly залишаються оцінками. Error Frames — кількість кадрів із записаними ознаками, розподіл типів — кількість записаних класифікацій (у кадрі може бути декілька). Графік частки помилок кадрів не називається виміряним Bit Error Ratio.

| Етап | Що можна перевірити |
|---|---|
| TWAI RX | `stats.rx`, lifetime приймання RECEIVER до черг транспорту |
| Успішно поставлено в BLE-чергу | поточний FF12 цього лічильника не містить; невідомо |
| Android прийняв | `androidAcceptedFrames`, окремо notifications, stats, rejects та incomplete |
| SQLite підтвердила | `committedFrames`, `committedStats`, `committedEvents`, SQL COUNT |
| Експорт | `counts` JSON та рядки record_type у CSV, перевірені проти збережених кількостей |

`seq` зберігається разом з ID/DLC/DATA, extd/rtr, UTC-часом приймання і окремим `receiverTimestampMs`. Обліковуються пропуски, дублікати, out-of-order і перезапуски; дублікати не приховуються і не видаляються автоматично. Пропуск seq не локалізує втрату між TWAI, чергою ESP32, GATT та Android. Перший/останній невидимий хвіст без контрольного пакета також невідомий.

FF11 та FF12 мають окремі обмежені реасемблери JSON (2048 bytes, timeout/reset, UTF-8 validation, перевірка очікуваного типу). Залишок не переноситься через reconnect. Прошивка зараз робить один `notify()` на JSON; вона не має протоколу нумерованих фрагментів чи підтвердження доставки. Реасемблер не може відновити байти, відрізані через ATT MTU. Мінімальне майбутнє розширення — явні message/fragment IDs, total length, transport counters у FF12, контрольний кінцевий seq. Прошивка в цьому завданні не редагувалася.

## 7. Експорт

У збереженій сесії доступні Export CSV і Export JSON. Експортуються всі збережені записи сесії незалежно від фільтрів графіка. Назва містить ім'я, ID сесії та час експорту.

JSON version 2 зберігає повну сесію та кількості записів. CSV має стовпець `record_type`: `metadata`, `frame`, `stats`, `event`; зберігає всі діагностичні дані у коректно екранованому `payload_json`, окремо TEC/REC, seq та часові позначки. Кількість рядків типу frame потрібно порівнювати з `committedFrames`, а не з усіма рядками CSV. Джерело даних не змінюється. Невідповідність кількостей, відмова provider або частковий запис дають помилку, а не повідомлення про успіх.

## 8. Файли реалізації

| Файли | Призначення |
|---|---|
| `lib/data/ble_capture_database.dart` (новий) | транзакційні записи, checkpoint, recovery, повне читання |
| `lib/domain/services/can_session_service.dart` | об'єднання старих сесій із новими BLE-записами; очікування запису |
| `lib/domain/source/ble_message_decoder.dart` (новий), `ble_can_source.dart` | FF11/FF12, валідація, реасембляція, облік seq |
| `lib/domain/models/can_frame.dart`, `can_stats.dart`, `can_session.dart`, `can_session_event.dart` | збереження wire-полів, походження і метаданих |
| `lib/domain/source/serial_json_decoder.dart` | додаткове збереження необов'язкових wire-полів у спільній моделі |
| `lib/domain/detection/can_error_checker.dart` | безпечне читання legacy origin без зміни генератора симуляції |
| `pubspec.yaml`, `pubspec.lock` | явна залежність intl ^0.19.0 для DateFormat, сумісна із Syncfusion 24.x; версія пакета залишилася попередньою |
| `lib/domain/services/recorded_frame_errors.dart`, `telemetry_diagnostics.dart` (нові) | записані ознаки окремо від агрегатної телеметрії |
| `lib/domain/services/session_analytics.dart`, `session_summary_builder.dart` | агрегація без генерації помилок |
| `lib/domain/services/session_export.dart`, `lib/core/session_file_saver.dart` (нові) | повний CSV/JSON та Android save picker |
| `android/app/src/main/kotlin/com/example/can_debug/MainActivity.kt` | ACTION_CREATE_DOCUMENT, запис і повернення URI/помилок |
| `lib/presentation/screens/monitor_screen.dart` | приймання до UI-буфера, зупинка/збереження, лічильники |
| `lib/presentation/screens/session_analytics_detail_screen.dart` | читання повної сесії, області підрахунку, експорт |
| `lib/presentation/widgets/professional_charts.dart`, `session_analytics_widgets.dart` | адаптивна легенда/заголовки, підписи, tooltip |
| `test/diagnostic_evidence_test.dart`, `ble_capture_persistence_test.dart`, `analytics_layout_test.dart` (нові) | контрольні дані, транзакції, повнота, вузькі макети |

## 9. Перевірки та фізичні сценарії

Фінальна перевірка: **80 тестів пройшли**, включно з reconnect/ізоляцією сесій, конкурентними checkpoint, недостовірними legacy hardware-мітками, Windows USB Monitor та журналюванням. Макети: 320/360/393/600/1280 logical px, text scale 1.0/1.5, окремо вузький details sheet. Android debug і Windows Release зібрано. `flutter analyze`: немає компіляційних помилок; старі warnings/infos аналізуються окремо від нових змін.

Фінальний analyzer: 108 зауважень (107 info та один наявний warning про unused import у `test/can_anomaly_analyzer_test.dart`); перевірка не є повністю lint-clean. Native Windows smoke пройдено: завантаження libserialport, перелік портів, відмова для вигаданого порту, закриття worker і SQLite round trip. Реальні COM-порти smoke-тест не відкривав. `git diff --check` пройдено. Хеші підтвердили збереження початкових змін RECEIVER та `.vscode/launch.json`; SENDER, Pro Monitor/BLoC, `serial_connection.dart` і `experiment_journal.dart` відповідають HEAD.

Звіти перевірок у `build/validation/`: `tests_android_audit.txt`, `tests_android_layout.txt`, `analyze_android_audit.txt`, `build_android_audit.txt`, `build_windows_android_audit.txt`, `windows_smoke_android_audit.txt`. Артефакти: `build/app/outputs/flutter-apk/app-debug.apk` і повна папка `build/windows/x64/runner/Release/`.

Фізична інструкція:

1. **P01.** Підключити BLE у Classic Monitor, прийняти понад 100 кадрів, Stop & Save. Зіставити Android RX та SQLite committed, відкрити сесію, експортувати CSV/JSON, звірити кількості й seq.
2. **P02.** Після завершення закрити й перезапустити застосунок. Перевірити ту саму сесію, телеметрію TEC/REC, події, графіки та експорт.
3. **P03.** Створити окрему тестову сесію з фізичного стенду; під час запису виконати force-stop тільки `com.example.can_debug`. Після запуску перевірити `interrupted`, committed-prefix, `lastCommittedAt`, `PRAGMA quick_check`. Кінцевий RAM-хвіст вважати невідомим, а не нульовою втратою.
4. **P04.** Під час окремої сесії розірвати BLE, потім відновити. Перевірити збереження попередніх записів, події стану, seq gaps/reset і відсутність перенесення часткового JSON через reconnect.
5. **P05.** Перевірити ID/DLC/DATA/extd/rtr, UTC timestamp, receiver ms і seq в експорті. Зіставити SQL count для кожного kind; перевірити дублікати seq окремо від дублікатів ordinal.

Debug-пристрій дозволяє read-only копію без root:

```powershell
adb shell run-as com.example.can_debug ls databases
# Бінарну копію SQLite/tar знімати через exec-out зі збереженням байтів,
# не через текстове перенаправлення старого Windows PowerShell.
```

SQL для знятої узгодженої копії:

```sql
PRAGMA quick_check;
SELECT session_id, kind, COUNT(*) FROM capture_records GROUP BY session_id, kind;
SELECT id, metadata FROM captures;
```

Резервні копії перед змінами:

- `.work_backups/android_audit_before_20261108_173924.zip`: Git HEAD, patches, незакомічені робочі файли із SHA-256.
- `.work_backups/android_device_before_20261108_175426.tar`: приватні дані телефона до встановлення оновлення; SHA-256 `2d5e170cd549cc3bc5b0425e63b7940edb16d5e267c72b1172cba1cc327361c4`.

## 10. Обмеження

Немає гарантії безперервного запису у фоні Android без окремої foreground-service архітектури. Завершення процесу може втратити RAM-хвіст. Повне відкриття/експорт великої сесії наразі потребує пам'яті пропорційно історії; запис при цьому має обмежену чергу. ACK-доставки BLE немає, початковий і кінцевий невидимі хвости невідомі. Старі втрачені кадри не відновлюються. TWAI_MODE_NO_ACK, BUS-OFF recovery, фізична шина 500 kbit/s, SENDER та Pro Monitor не змінювалися. Windows USB-файли експериментів не редагувалися.

Фізична перевірка нової реалізації **відкладена за вказівкою користувача**. MIUI двічі відхилив `adb install -r` з `INSTALL_FAILED_USER_RESTRICTED: Install canceled by user`. Нову версію не встановлено; P01–P05 на новій версії не пройдені. Підтверджені на телефоні висновки цього аудиту стосуються оригінальних SharedPreferences/експорту Schema 47 і старих шляхів збереження. Шлях нової БД визначений реалізацією `getDatabasesPath()`; фактичний запис цієї БД на Redmi ще не перевірено.
