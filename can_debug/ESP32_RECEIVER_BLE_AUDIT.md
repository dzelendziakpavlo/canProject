# Вузький аудит ESP32 RECEIVER: FF11/FF12 та lifetime

Дата: 2026-11-09. Це статичний аудит коду, залежностей і вже наданих даних.
Прошивка й Android не змінювались; компіляцію, перепрошивання, HCI та нові
фізичні експерименти не запускали.

**Висновок:** конкретного дефекту в поточному скетчі, який доведено породжує
ці пошкодження, не знайдено. Звичайне повторне використання локального
`WireMessage` після `notify()` не є таким дефектом для перевіреної версії
бібліотеки: обидві межі API роблять копію. Водночас для FF12 №3035
встановлено точне побайтове накладання нового FF11 на старіший FF12.
Нижче відокремлено цей факт від однієї перевірюваної гіпотези про його причину.

## 1. Яку версію вдалося перевірити

Локально встановлено Arduino-ESP32 **3.3.10**, bundled library **BLE 3.3.10**:

```text
C:\Users\Admin\AppData\Local\Arduino15\packages\esp32\hardware\esp32\3.3.10
```

`tools/esp32-libs/3.3.10/versions.txt` задає **ESP-IDF v5.5.4, commit 735507283d**.
SDK config має `CONFIG_BT_BLUEDROID_ENABLED=y`, NimBLE вимкнений.
Отже, перевірявся Bluedroid `notify()` на рядку 829, а не альтернативна
NimBLE-реалізація на рядку 1061 того самого файла.

`AppData\Local\arduino\sketches\9633527D48326EE3918EEFAD283C3FA1\build.options.json`
і `libraries.cache` посилаються на цю core/BLE та `esp32:esp32:esp32`.
**Проте cached receiver_ble.ino.cpp застарів:** він не містить seq та нових
FreeRTOS tasks, на відміну від поточного скетча й записаного потоку.
Тому він не засвідчує, чим зібрана саме прошивка контрольного експерименту.
Для остаточної прив'язки версії потрібен актуальний compile log/build-options
або ELF саме тієї збірки. Самі `fw=can-monitor-telemetry-v2` та UART 460800
не ідентифікують версію BLE/IDF.

Подальші твердження про API копіювання підтверджені для **перевіреної
встановленої 3.3.10/5.5.4**, а не є безумовною атестацією невідомого
прошитого бінарника. SHA-256 скетча:
`b785b9500b35354cffd0c439ac15debaace66787bc6e3f5cec6e37a23c7c2ddc`.

## 2. Буфери, tasks і формування JSON

Рядки в таблиці — у `arduino/receiver_ble/receiver_ble.ino`.

| Рядки / функція | Висновок |
|---|---|
| 275–282, canReceiveTask | Один task після успішного TWAI receive заповнює frame/ts/seq. Seq присвоюється тут, до вихідних черг. |
| 342–347, xQueueCreate | Черги зберігають CapturedFrame/StatsSnapshot/WireMessage **за значенням**, не вказівники на String або стек. Item sizes відповідають типам receive/send. |
| 103–125, buildFrameJson | Локальний String; ID/data/ts/seq взяті з конкретного CapturedFrame. RTR payload порожній. Спільного статичного JSON-буфера немає. |
| 140–170, buildStatsJson | Окремий локальний String із snapshot. `reserve(220)` є резервуванням capacity, не межею довжини: String може вирости. |
| 229–272, serializationTask | Єдиний серіалізатор. Для CAN один і той самий const String копіюється в BLE та USB queues. Для stats BLE має базовий JSON, USB — його копію з додатковими counters. |
| 180–190, enqueueJson | memcpy копіює рівно json.length() байтів у WireMessage; xQueueSend/Overwrite копіює весь item до повернення. Знищення локального json після enqueue не залишає висячого payload pointer. |
| 193–212, serialOutputTask | Власний WireMessage на власному task stack. Додавання newline змінює лише USB-копію. |
| 215–226, bleOutputTask | Інший локальний WireMessage. Один task вибирає FF11 або FF12 та послідовно виконує setValue/notify. Його wire повторно використовується, але API копіює payload. |
| 173–176, notifyString | Невикористаний helper: у скетчі немає його викликів. Другого активного BLE writer він не створює. |
| 351–354, xTaskCreate | CAN RX priority 2; JSON/BLE/USB priority 1. Tasks не pinned. Від цього один task не виконує дві свої ітерації одночасно. |

`MAX_WIRE_BYTES=640`. Перевірка length на рядку 182 залишає місце для
термінатора та USB newline; переповнення цього масиву для наданих 78/225
байтів не виявлене. Хвіст WireMessage після length може бути неініціалізований,
але setValue та Serial.write використовують явну довжину, а не sizeof(bytes).

FF11 і FF12 мають різні BLECharacteristic і різні `m_value` в бібліотеці.
Назва `wire` у двох task-функціях не означає спільну пам'ять. Вхідні
char arrays не зберігаються у shared String-покажчиках скетча.

Глобальні volatile flags/counters не є загальним mutex за моделлю C++,
але вони не зберігають JSON bytes і не дають показаного механізму накладання
payload. `totalRx` має одного writer; обидва виходи stats використовують
один StatsSnapshot. Навіть неточний момент читання counter не пояснює,
чому USB і BLE мають різний rx при однаковому uptime.

Скетч має одного writer значення кожної characteristic. Бібліотека також
може обробити зовнішній GATT write: BLECharacteristic.cpp:588 перевіряє
attr handle, рядок 619 викликає setValue. Це не те саме, що write CCCD
descriptor. Факту запису клієнтом у FF11/FF12 немає; його не прийнято
за підтверджену причину. Сам mutex навколо setValue/notify без другого
доведеного writer не обґрунтований як виправлення.

## 3. Чи копіюють setValue і notify

Відносні library paths нижче — від core 3.3.10, наведеної в розділі 1.

1. `libraries/BLE/src/BLECharacteristic.cpp:368–382`: setValue бере
   `m_semaphoreSetValue`, викликає BLEValue::setValue, відпускає semaphore.
2. `libraries/BLE/src/BLEValue.cpp:149–150`: створюється
   `String((char*)pData, length)`, а не зберігається pData.
3. `cores/esp32/WString.cpp:40–44,235–243`: конструктор викликає copy,
   reserve та memmove у власний buffer. Це синхронна копія до повернення
   setValue. Оператори copy/move на рядках 276–289 не роблять shallow alias.
4. `BLECharacteristic.cpp:885–886`: notify передає pointer із тимчасового
   `m_value.getValue()` у esp_ble_gatts_send_indicate. Тимчасовий String
   живе до завершення full expression, тобто протягом виклику API.
5. ESP-IDF 5.5.4 `esp_gatts_api.c:253–287` передає deep-copy callback;
   `btc_gatts.c:58–77` виділяє власний value buffer і копіює payload.
   `btc_task.c:335–344` викликає copy_func **до** btc_task_post.
   Це діє і при need_confirm=false — звичайному notify.

Перевірені первинні джерела ESP-IDF:
[API](https://github.com/espressif/esp-idf/blob/v5.5.4/components/bt/host/bluedroid/api/esp_gatts_api.c#L253),
[deep copy](https://github.com/espressif/esp-idf/blob/v5.5.4/components/bt/host/bluedroid/btc/profile/std/gatt/btc_gatts.c#L58),
[копіювання перед постановкою в чергу](https://github.com/espressif/esp-idf/blob/v5.5.4/components/bt/common/btc/core/btc_task.c#L318).

Додатково розібрано **локальний** `libbt.a`: релокації
esp_gatts_api.c.obj містять btc_gatts_arg_deep_copy/deep_free і
btc_transfer_context; btc_gatts.c.obj містить allocation/memcpy;
btc_task.c.obj викликає переданий copy callback перед osi_thread_post.
Дизасемблювання збережене в артефактах. Отже, висновок не спирається лише
на загальний опис API або іншу версію бібліотеки.

Асинхронним лишається саме передавання/доставка, а не володіння початковим
буфером caller. Заміна wire на static або два окремі arrays для FF11/FF12
за цієї реалізації не має доведеної підстави як фікс.

У бібліотеці notify не бере semaphore setValue на весь процес читання;
це могло б бути проблемою за другого writer. У показаному скетчі другого
активного writer немає. Факт такого race у записі не встановлений.

## 4. Фрагментація та точний FF12 overlay

Скетч не розбиває JSON: на кожний dequeue викликає один notify.
`BLEDevice::setMTU(256)` задає локальний maximum; у попередньому raw-логу
фактично узгоджений ATT MTU 247. При ньому payload limit — 244 байти.
Приклад нижче має 225 байтів і вміщується в один ATT notification.
Нижчі L2CAP/Link Layer фрагменти обробляє stack; їх тут не трасували.
Самого факту MTU недостатньо для виключення будь-якого нижнього stack bug.

Для native callback **3035, characteristic FF12** виконано точну перевірку:

```text
observed_raw = usb_FF11(seq=8033)[0:78]
             + usb_base_FF12(uptime=220570, rx=7890)[78:225]
```

Обидві частини зіставлені побайтово. Не лише ID чи значення data.
FF12 з USB береться без додаткових transport fields — як його формує
buildStatsJson для BLE. Довжина observed_raw=225; перші 78 байтів — повний
новіший CAN JSON, останні 147 — незмінений хвіст старішого stats JSON.

```text
{"t":"f","id":192,"dlc":8,"data":[234,190,0,0,0,0,0,0],"ts":224541,"seq":8033}70,"bitrate":500000,...,"rx":7890,...
```

Це не результат дописування одного notification після іншого у Dart:
накладений вміст міститься в одному entry snapshot FF12, із правильними
record length/hash та original_matches_snapshot=true. Native recorder
після entry не створив такого змішування. Сам факт snapshot не доводить,
що накладання виникло саме на ESP32: лишається Android/GATT до getValue.

Схожі приклади до патчу: FF11 з ID/data/ts USB seq=16480, але seq=16478;
у поточному run — FF12 rx від попереднього snapshot при новішому uptime.
Ці факти узгоджуються зі збереженням частини старого вмісту. Вони не
встановлюють, який саме memory buffer був перезаписаний.

## 5. Одна перевірювана гіпотеза й межа мінімального патчу

**Гіпотеза:** у BLE-шляху до entry snapshot коротший payload перезаписує
початок раніше зайнятого довшого буфера, тоді як довжина/хвіст лишаються
від старого повідомлення. FF12 №3035 є точним прикладом очікуваного образу
пам'яті для такого механізму. Локалізація **на ESP32** поки не доведена.

Важливо: це не твердження, що caller wire живе недостатньо довго.
Цей конкретний варіант суперечить перевіреному synchronous copy chain.
Не доведені також String heap failure, stack overflow або зовнішній write;
перелік можливих причин не підміняє встановлений root cause.

Мінімальна перевірка цієї гіпотези на ESP32, **лише як пропозиція**:
зафіксувати type/len/bytes або digest на межах enqueue → dequeue →
після setValue → точні args esp_ble_gatts_send_indicate. Для короткого
першого probe достатньо readback одразу після receiver_ble.ino:222:

```cpp
// Діагностичний кандидат, НЕ застосований і НЕ функціональний фікс.
const String stored = characteristic->getValue();
const bool same = stored.length() == wire.length &&
    memcmp(stored.c_str(), wire.bytes, wire.length) == 0;
// Зберегти same/type/length у приватному RAM diagnostic state.
// Не друкувати сторонній текст у чинний USB JSON stream.
```

Якщо wire/readback уже різняться — проблема на цій межі або в allocation
readback; це потребуватиме точного розмежування. Якщо вони правильні,
перевіряються фактичні args нижнього send API. Коректні args проти
зіпсованого Android snapshot відсувають межу нижче цього API; вони не
дають підстав «виправляти» JSON builder. Жодна з цих перевірок не виконана
на пристрої та не додана до коду в цьому аудиті.

**Підтвердженого функціонального дефекту коду немає — отже, немає й
доказового функціонального патчу, який можна чесно назвати виправленням.**
Формат FF11/FF12, Android та firmware залишені незмінними. Збільшення
delay, mutex, static buffers, зміна BLE stack або протоколу зараз були б
експериментальними змінами, а не виправленням підтвердженого дефекту.

## Артефакти та збереження

`build/validation/receiver_audit/summary.json` містить точний overlay,
versions, hashes і явний runtimeBinaryLibraryVersionProven=false.
Поруч збережені три object files, витягнуті з локального libbt.a, та
дизасемблювання esp_ble_gatts_send_indicate, btc_transfer_context,
btc_gatts_arg_deep_copy. Це читання готових артефактів, не збірка й не
новий експеримент на пристрої.

Перед записом звіту 60 поточних змінених/нових файлів і Git-стан збережено
в `../.work_backups/receiver_audit_before_20261109_180317.zip`.
Початкові JSONL/звіт comparison, скетчі, SDK, Pub cache і Android не змінено.
