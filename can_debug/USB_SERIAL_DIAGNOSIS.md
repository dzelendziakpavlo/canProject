# USB Serial: діагностика COM1 / COM4

Дата: 2026-11-05. Користувач підтвердив приймання CAN-кадрів і телеметрії в оновленому Windows UI на COM4 / 115200: «USB RX і stats зростають». Базовий сценарій приймання підтверджено. Наведені нижче числа стосуються окремих обмежених діагностичних вимірів; тривале приймання, overload та одночасний BLE+USB цим підтвердженням не охоплені.

## Причина відтвореного збою

У цьому сеансі COM1 — `Communications Port`, `ACPI\PNP0501\0`, native/RS232. Після підключення RECEIVER з'явився окремий `USB-SERIAL CH340 (COM4)`, USB VID `1a86`, PID `7523`.

На COM1 читач запускався, отримував ACK і опитував Windows, але вхідна черга порту залишалася порожньою. Отже, нульові кадри в цьому відтворенні виникали ДО isolate delivery/JSON/Monitor: було вибрано інший порт. Незалежний `.NET SerialPort` на COM1 теж отримав 0 байтів із DTR/RTS off; перевірки DTR on/RTS off і DTR on/RTS on також не дали даних.

Перша спроба відкриття COM4 не пройшла: порт був зайнятий Serial Monitor. Незалежний Windows SerialPort повернув `Access to the port 'COM4' is denied`. Після підтвердження користувача про закриття Monitor той самий Dart-транспорт почав отримувати JSON на COM4.

Це висновок для фактичної конфігурації цього сеансу. Номер порту може змінитися; він не встановлює, який номер ESP32 мав під час попередніх підключень чи на іншому ПК. Спочатку звіряйте порт USB-адаптера, його опис та VID/PID.

## Локалізація тракту

| Етап | Спостереження |
|---|---|
| COM1 open/config | Відкривався на 115200, 8N1, none; це ACPI-порт |
| COM1 reader/ACK | `readerStarted=true`, 263 polls, 1 ACK, `awaitingAck=false`, `bytesWaiting=0` за 5 с |
| COM1 bytes | 0 через Dart і незалежний .NET reader |
| COM4 open, коли зайнятий | Відмова в доступі; помилка не є CAN-помилкою |
| COM4 bytes/isolate | Дані надходять; ACK не блокує читання |
| COM4 decoder | Реальні `f` та `s` прийняті без зміни схеми й прошивки |
| Source → models → journal | Детермінований тест із реальними isolates і дисковим журналом пройдено |
| Monitor subscriptions | Widget-тести кадрів/stats, resize та збереження пройдено; користувач підтвердив зростання USB RX і stats у реальному Windows UI |

У першому 8-секундному COM4-вимірі отримано 25324 байти, 210 читань, 299 завершених рядків, 290 кадрів, 8 stats, 0 read errors, 1 rejected. Одне відхилення на початку можливе при відкритті посеред рядка безперервного потоку; воно не прирівнюється до CAN-помилки.

Повторний 5-секундний вимір:

| Лічильник | Значення |
|---|---:|
| bytesRead | 15866 |
| readOperations | 134 |
| readErrors | 0 |
| completedLines | 185 |
| decodedFrames | 180 |
| decodedStats | 5 |
| rejected | 0 |
| incompleteLineBytes | 0 |

Native reader і host отримали однакові остаточні bytesRead/readOperations. Порт закрито після виміру. Дані не надсилалися в UART, прошивка не змінювалася. JSON-звіт зі зразками: `build/validation/serial_com4_verified.json`. Початковий COM1-звіт: `build/validation/serial_before_fix.json`; перевірка reader/ACK COM1: `build/validation/serial_native_diagnostics.json`.

Реальна stats-телеметрія мала schema v2, `fw=can-monitor-telemetry-v2`, `bitrate=500000`, `state=RUNNING`, `txe=0`, `rxe=0`, усі чинні hardware/transport counters. Її без змін прийняв наявний JSON-декодер. Не було потреби змінювати RECEIVER.

## Зміни

| Файл | Зміна |
|---|---|
| `lib/domain/source/serial_connection.dart` | USB/native позначки, VID/PID; початковий пріоритет USB; reader/ACK/byte/error diagnostics раз на секунду; діагностичні карти не змішуються з data/error events |
| той самий файл | Виправлено володіння `port.config`; додатково перевірено ACK при pause/resume та недублювання дозволу читання |
| той самий файл | Невдале відкриття з утраченим native errno=0 більше не описується як успішна операція; показується перевірка зайнятості порту |
| `lib/domain/source/serial_can_source.dart` | bytes/read/line/error counters на вході, діагностика в manifest, збереження фінальних native counters після close |
| `lib/domain/source/serial_json_decoder.dart` | completedLines; правила валідації JSON/CanFrame/CanStats не змінено |
| `lib/presentation/screens/serial_connect_screen.dart` | Зрозумілі дескриптори, USB як початковий вибір, попередження про native/RS232; явний чинний вибір користувача зберігається |
| `lib/presentation/screens/monitor_screen.dart` | Лічильники байтів/читань/рядків і native reader у Recording details |
| `test/serial_can_source_test.dart` | Перевірки bytesRead/readOperations/completedLines/readErrors |
| `test/serial_worker_test.dart` | Реальні isolates: listener/ACK, partial JSON, pause/resume, errors, source/models/journal, вибір USB замість legacy COM1 |
| `tool/windows_serial_capture.dart` | Окремий обмежений smoke-test того самого транспорту й декодера без Flutter UI |
| `USB_SERIAL_GUIDE.md`, цей файл | Оновлені кроки вибору порту, результати та статус приймання |

Окремо виправлений дефект ресурсів: у встановленому `libserialport 0.3.0+1` setter `port.config` зберігає конфігурацію, а `port.dispose()` звільняє її. Старий `finally { config.dispose(); }` після setter створював ризик повторного звільнення. Тепер використовується конфігурація, якою володіє порт, із одним звільненням разом із портом. Цей дефект не видається за доведену причину нульових байтів COM1.

Прошивки RECEIVER/SENDER, CAN bitrate, Android BLE, CanFrameSource API, Pro Monitor і експериментальний журнал збережені. Перед редагуванням створено й перевірено архів усіх 34 поточних незакомічених файлів: `../.work_backups/usb_serial_diagnosis_before_20261105_170443.zip`.

## Повторна перевірка

1. Закрити Arduino Serial Monitor та інші клієнти цього порту.
2. Запустити оновлений `build/windows/x64/runner/Release/can_debug.exe` у його каталозі з усіма DLL/data.
3. У Real Stand вибрати **USB-SERIAL CH340 (COM4)**, **115200**. Якщо номер змінився, визначити його через unplug/replug; не покладатися лише на COM-номер.
4. Натиснути Connect. Перевірити ріст USB RX, stats, bytes, reads та lines. У Recording details доступні `readerStarted`, polls, ACKs, bytesWaiting і помилки.
5. Disconnect & Save: перевірити manifest/CSV/JSONL та звільнення порту. Підтвердити отримання кадрів і stats у Windows UI користувачеві/в чаті.

Визначення етапу за лічильниками:

- reader не запущений — помилка відкриття/config/старту;
- `awaitingAck=true`, ACKs=0 — немає дозволу від підписника; перевірити підписку;
- reader працює, ACK отримано, `bytesWaiting=0`, bytesRead=0 — Windows не бачить вхідних даних цього порту;
- native bytesRead > host bytesRead — перевірити доставка/паузу/закриття (live snapshot може відставати до секунди);
- bytesRead > 0, lines=0 — неповний рядок, відсутній LF або UART/дані;
- lines > 0, rejected росте — UTF-8/JSON/схема, подивитися причину;
- decodedFrames/Stats ростуть, UI не оновлюється — досліджувати підписки/рендер.

Незалежний тест (обов'язково з вільним портом):

```powershell
cd D:\KNUO_term_paper\can_debug
$env:LIBSERIALPORT_PATH = (Resolve-Path build/windows/x64/runner/Release/serialport.dll).Path
dart run tool/windows_serial_capture.dart --port COM4 --baud 115200 --seconds 8 --report build/validation/serial_local.json
```

`--port` обов'язковий; інтервал 1–60 секунд. Виводиться один рядок counters на секунду та максимум 3 f/2 s зразки. Звіт формується після закриття порту, щоб native counters були остаточними; `readerStarted=false` у фінальному звіті означає нормальне завершення читача. Це тестова вибірка, а не заміна повного експериментального журналу застосунку.

## Автоматичні перевірки

- Повний Flutter test: 56 tests passed.
- Serial-група до додавання останнього pipeline-тесту: 18 tests passed; останній pipeline-тест входить у повний прогін.
- Windows release build і Android debug APK зібрані.
- `flutter analyze` не має compiler errors; загальний аналіз містить наявні lint/deprecation зауваження. Звіт: `build/validation/analyze_serial_diagnosis.txt`.

Базове апаратне приймання кадрів і телеметрії в Windows UI підтверджено користувачем 2026-11-05. Фізичне збереження/закриття сеансу, тривалий тест, overload і одночасний BLE+USB після цих змін залишаються окремими непідтвердженими сценаріями.
