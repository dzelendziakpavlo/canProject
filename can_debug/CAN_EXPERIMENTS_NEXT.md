# CAN Debug Pro — готовність стенду та програма експериментів 4.3

Дата: 2026-11-10. Статичний аудит поточного репозиторію та встановлених TWAI headers. **Firmware, Android, Windows, SQLite й бібліотеки не редагувалися; експериментів автоматично не запускали.** Підсумок завершеного дослідження BLE — [BLE_FINAL_FINDINGS.md](BLE_FINAL_FINDINGS.md). Нижче наведені очікування і план, а не отримані результати T06–T09.

## 1. Фактичний стан прошивок

### SENDER

Джерело: [sender_can.ino](../arduino/sender_can/sender_can.ino), поточний `SEND_MODE=1` у рядку 39. CAN TX GPIO5, RX GPIO4; `TWAI_MODE_NORMAL`, accept-all filter, `twai_start()` у setup. Позначення RX/TX на конкретних модулях у документації стенду інвертовані; вже перевірене підключення не змінювати за типовою схемою іншої плати.

| SEND_MODE | Реально виконуваний код | Бітрейт / характер потоку |
|---|---|---|
| 1 | Штатні 8 стандартних data frames; data[0] — окремий uint8 counter для кожного ID, data[1]=(counter*3)&255, решта нулі | 500 kbit/s; близько 36 кадрів/с сумарно |
| 2 | Циклічно ті самі ID, data[i]=val+i, без явного delay; `twai_transmit` очікує до 2 мс | 500 kbit/s; насичення залежить від ACK, error/retry, CPU й черг; коментар «3000–5000» не є вимірюванням |
| 3 | Той самий data pattern та інтервали, що mode 1 | **250 kbit/s**; RECEIVER лишається 500 kbit/s |
| 4 | Штатні кадри + RTR ID 0x0C0, DLC=8, rtr=1, кожні 2 с | 500 kbit/s; RTR має запитану довжину, але не data payload; автоматичний responder у RECEIVER не реалізований |
| 5 | Штатні кадри + по одному extended frame 0x18FF0001, 0x18FEE300, 0x0CF00400 кожну секунду | 500 kbit/s; 29-bit ID, data[b]=extVal+b; приблизно 39 frames/s загалом |

Інші значення define потраплять у гілку `#else`, а не в окремий валідований режим. Режим 5 не вмикає mismatch; згадки stuffing/form у його верхньому коментарі — не фактична поведінка перемикача.

Штатні ID та інтервали, рядки 49–58:

| ID | Інтервал, мс | Номінальна частота, Гц |
|---|---:|---:|
| 0x0C0, 0x0C8 | 100 кожний | 10 кожний |
| 0x0D0, 0x0D8 | 200 кожний | 5 кожний |
| 0x1A0, 0x1A8 | 500 кожний | 2 кожний |
| 0x2B0, 0x2B8 | 1000 кожний | 1 кожний |

Назви EngineRPM/Speed тощо в таблиці є демонстраційними: payload — лічильник, а не каліброване фізичне значення датчика. Відповідність `data[1]` дає перевірку тестового pattern, а не CAN CRC.

SENDER Serial: **115200**, текст. На старті `TELEMETRY,v=2,node=sender,fw=can-sender-v2,bitrate=...,mode=...`. Раз на секунду, рядки 213–223: `SENDER STATS: tx=... tec=... state=RUNNING|BUS_OFF|OTHER`. `totalTx` збільшується за успішного **виклику `twai_transmit`**, тобто прийняття запиту драйвером; це не незалежний лічильник успішно підтверджених на шині кадрів. REC, bus_error_count та окремі TX failures у цей Serial output не включено. `OTHER` не розрізняє STOPPED і RECOVERING.

### RECEIVER

Джерело: [receiver_ble.ino](../arduino/receiver_ble/receiver_ble.ino).

| Місце коду | Фактична поведінка |
|---|---|
| Рядки 34–37, 49, 54 | `CAN_SERIAL_JSON=1`, `SERIAL_BAUD=460800`, `NO_ACK_MODE=0`, `SPEED_MISMATCH_DEMO=0` |
| Рядки 340–347 | GPIO5/GPIO4, 500 kbit/s; mode NORMAL або NO_ACK за define; accept-all filter |
| `canReceiveTask`, рядок 289 | `twai_receive`; після успішного приймання timestamp=millis, `sequence=++totalRx`; передавання CapturedFrame у captureQueue без очікування |
| `serializationTask`, рядок 243 | Одна серіалізація кадру для BLE та USB; stats беруться з одного StatsSnapshot |
| `bleOutputTask`, рядок 219 | Один writer вибирає FF11 або FF12, setValue з явною length, потім notify |
| `serialOutputTask`, рядок 194 | Незалежний writer USB з newline, порційним записом за доступністю UART |
| Рядки 356–361 | captureQueue=64, statsQueue=1, USB frames=32/stats=1, BLE frames=32/stats=1; bounded, stats overwrite |
| Рядки 404–406 | Snapshot TWAI стану й лічильників приблизно раз на секунду навіть за відсутності CAN data |

RECEIVER не викликає `twai_transmit()` для data/RTR. Він є приймачем CAN-кадрів та у штатному NORMAL режимі бере участь у протокольному ACK. Наявність поля `txe` не означає, що він передає ті самі data frames, що SENDER.

### Параметри TWAI, які не можна плутати з прикладними чергами

Обидва скетчі використовують legacy API `driver/twai.h`, а не новий `esp_twai_onchip` API. У локальних headers Arduino-ESP32 3.3.10 / ESP-IDF 5.5.4 `TWAI_GENERAL_CONFIG_DEFAULT` задає TX queue=5, RX queue=5, alerts=NONE, interrupt level 1. Лише SENDER mode 2 замінює TX queue на 32 і RX queue на 1. **Прикладна captureQueue=64 у RECEIVER не збільшує драйверну RX queue=5.** `twai_read_alerts()` у скетчах не викликається.

У перевірених headers `TWAI_TIMING_CONFIG_500KBITS()` для ESP32 APB-гілки задає quanta resolution 8 MHz, tseg1=11, tseg2=4, sjw=2, triple_sampling=false (16 tq/bit, sample point 75%); 250KBITS — 4 MHz із тими самими сегментами. Перемикання UART baud не змінює CAN bitrate. Первинне джерело — [timing macros ESP-IDF 5.5.4](https://github.com/espressif/esp-idf/blob/v5.5.4/components/hal/include/hal/twai_types_deprecated.h#L73).

Локальний SDK має ввімкнені TWAI errata workarounds BUS_OFF_REC, TX_INTR_LOST, RX_FRAME_INVALID, RX_FIFO_CORRUPT, LISTEN_ONLY_DOM; `CONFIG_FREERTOS_HZ=1000`. Це характеристики перевіреної toolchain, а не доказ відсутності помилок чи атестація довільного раніше прошитого binary.

## 2. Які дані доходять до Android і Windows

### FF11 та USB frame JSON

`buildFrameJson()`, рядки 104–125: `t=f`, `id`, `dlc`, `data`, `ts`, `seq`; опціонально `rtr=1`, `extd=1`. У RTR data порожній попри ненульовий DLC. Це **прийняті драйвером CAN-повідомлення**, а не сирі електричні samples, error frames або кадри з доступним оригінальним CRC. Зіпсовані на шині кадри не надходять сюди як звичайні frames із «поганим CRC».

`seq` присвоєний RECEIVER після `twai_receive()`. Пропуск кадру до цього місця може не створити seq gap. Навпаки, переповнення capture/output queues після присвоєння seq може дати gap. Тому неперервний seq не засвідчує приймання всіх спроб SENDER, а gap сам не визначає фізичну причину втрати.

### FF12 і базові USB stats

`buildStatsJson()`, рядки 141–171:

| Wire поле | Джерело / значення |
|---|---|
| `rx` | `totalRx` — успішні виклики `twai_receive` RECEIVER, не SENDER TX |
| `txe`, `rxe` | TEC і REC **RECEIVER** |
| `state` | STOPPED/RUNNING/BUS_OFF/RECOVERING/UNKNOWN RECEIVER |
| `buserr` | Сукупний `bus_error_count`; немає розподілу CRC/Bit/Form/Stuff/ACK |
| `missed` | `rx_missed_count`: драйверна RX queue full та можливі втрати через активні errata workarounds |
| `ovr` | `rx_overrun_count`: переповнення апаратного RX FIFO |
| `txfail`, `arb` | `tx_failed_count`, `arb_lost_count` RECEIVER; за відсутності прикладних TX не є лічильниками передач SENDER |
| `v`, `node`, `fw`, `uptime`, `bitrate` | v=2, node=receiver, firmware label, millis snapshot, bitrate=500000 |
| `reason` | Похідний пріоритетний опис за станом/лічильниками; не незалежне вимірювання фізичного subtype |
| `noack`, `sdemo` | Compile-time flags; не доказ ACK error або stuffing/form error |

Ці поля однакові для Android BLE та Windows USB за задумом серіалізації. Окремі BLE bytes, як встановлено у 4.2, можуть бути пошкоджені. Відібраний для 4.3 канал — USB із перевіркою manifest і rawJson.

Windows USB додатково отримує `serialdrop`, `bledrop`, `queuedrop`, `toolong`, `serialstatdrop`, `blestatdrop`, `statdrop`. Це переповнення/відкидання прикладних черг або серіалізації, **не фізичні CAN-помилки**. `bledrop=0` не гарантує доставки кожного notify до Android. Драйверні `msgs_to_tx` та `msgs_to_rx` доступні через status API, але скетч їх не серіалізує. Значення лічильників описані в [legacy twai_status_info_t](https://github.com/espressif/esp-idf/blob/v5.5.4/components/driver/twai/include/driver/twai.h#L123).

### Доступність SENDER та інтерпретація у застосунку

Застосунок отримує **лише telemetry RECEIVER**. SENDER має власний USB Serial текст TEC/state/tx, який можна дивитися або окремо зберегти на його власному COM-порті наявним Serial terminal. Це не FF12 і не підтримуваний SerialCanSource JSON; підключення застосунку до COM SENDER не перетворить його текст на телеметрію передавача. Підключати два клієнти до одного COM-порту не можна.

Поточний [TelemetryDiagnostics](lib/domain/services/telemetry_diagnostics.dart) формує подію зміни сукупних counters/state з позначенням subtype unavailable, не приписуючи її CAN ID. [CanHealthAnalyzer](lib/domain/detection/can_health_analyzer.dart) оцінює silence, TEC/REC, state та overflow; це похідна оцінка, не вимірювач фізичних причин. У [MonitorScreen](lib/presentation/screens/monitor_screen.dart), рядки 315–325, silence визначається після понад 3 с без кадрів; для USB додатково потрібне повідомлення менш ніж 4 с тому. Це дозволяє перевірити сценарій «stats живі, CAN frames зникли». Застарілі коментарі «BLE only» не звужують фактичну умову коду. Симуляційні enum/checker, старі пояснення й демонстраційні назви помилок не створюють апаратного доказу. `txfail` не дорівнює «точно ACK», `missed/ovr` не доводять CAN Overload Frame, arbitration loss сама по собі є штатною частиною CAN arbitration.

Старі `CAN_STAND_DOCUMENTATION.md`, `CAN_SYSTEM_CONTEXT.md`, `CAN_WORK_REPORT_GUIDE.md` містять описи NO_ACK як listen-only та евристичні класифікації. Для цього плану перевагу мають фактичний код, наведені headers і первинні джерела; старі документи тут не редагувалися.

## 3. ACK: який вузол і що потрібно вимірювати

У штатному потоці **SENDER передає** data/RTR; **RECEIVER підтверджує** правильно прийнятий кадр ACK-бітом у NORMAL режимі. Відсутність ACK виявляє передавач. Тому релевантні TEC, успішність TX і стан саме SENDER; не можна очікувати автоматичного росту TEC RECEIVER або називати його `txfail` статистикою SENDER.

`NO_ACK_MODE=1` у RECEIVER обирає `TWAI_MODE_NO_ACK`. Цей режим знімає потребу підтвердження **для власної передачі контролера**; він не еквівалентний пасивному спостерігачу, що не надсилає ACK. Для незалучення вузла до підтвердження існує інший режим — `TWAI_MODE_LISTEN_ONLY`. Поточний скетч не має перемикача на нього. Отже, запропонований старими коментарями сценарій «поставити NO_ACK_MODE=1 і отримати Missing ACK» не є коректною підготовкою. Це випливає з [визначень режимів ESP-IDF 5.5.4](https://github.com/espressif/esp-idf/blob/v5.5.4/components/hal/include/hal/twai_types_deprecated.h#L90) і [опису legacy режимів](https://docs.espressif.com/projects/esp-idf/en/v5.4.4/esp32/api-reference/peripherals/twai.html#operating-modes); друге посилання використане лише для семантики legacy API.

При фізичному усуненні єдиного іншого вузла SENDER може фіксувати TX-помилки та зростання TEC. **Не гарантувати BUS_OFF:** для error-passive передавача, що не бачить ACK і домінантного біта під час passive error flag, діє виняток із подальшого збільшення TEC. Можливі error-passive, повторні спроби й заповнення TX queue. Немає підстав обіцяти TEC→256 за самою відсутністю ACK. Правило наведене у [ESP32 TRM, розділ 25.3.3.3](https://documentation.espressif.com/esp32_technical_reference_manual_en.pdf#page=532).

Є окреме обмеження відновлення: обидва скетчі викликають `twai_initiate_recovery()` при BUS_OFF, але після закінчення recovery не викликають `twai_start()` повторно. У legacy драйвері завершення recovery переводить контролер у STOPPED. Тому автоматичного повернення data stream після справжнього BUS_OFF не гарантувати; потрібне враховане ручне перезавантаження відповідного вузла. Первинне джерело — [driver recovery transition](https://github.com/espressif/esp-idf/blob/v5.5.4/components/driver/twai/twai.c#L231). Виправлення recovery залишається окремою задачею.

## 4. Мінімальна програма T06–T09

У всіх сценаріях зберігати первинні JSONL/CSV/manifests; зіставляти counters лише всередині однієї uptime-епохи. Прирости buserr/missed/ovr рахувати як різниці snapshots, TEC/REC — як поточний стан/максимум; не складати всі значення кумулятивного counter. Таблиця — оцінка можливостей, не результати проведених тестів.

| ID | Підтримка й налаштування | Фізичні дії / потрібна firmware |
|---|---|---|
| T06 Missing ACK | **Обмежено:** mode 1 SENDER, 500 kbit/s; SENDER TEC/state видно лише в окремому Serial 115200. NO_ACK_MODE=1 RECEIVER не забезпечує відсутність ACK. Повного TX outcome/REC/buserr SENDER у застосунку немає. | Ізолювати SENDER від інших CAN-вузлів, залишивши його живлення та Serial; не відключати його власний transceiver feedback. Для цього фізичного варіанта зміна firmware не потрібна. Варіант із RECEIVER listen-only потребує окремо погодженої зміни/збірки; тут не виконується. |
| T07 Bitrate mismatch | **Підтримано на рівні source:** SENDER SEND_MODE=3 (250 kbit/s), RECEIVER 500 kbit/s, NO_ACK_MODE=0. `sdemo` лише мітка; не потрібна для вимірювання counters. | Залишити CAN wiring справним, змінити режим і перепрошити **SENDER** після окремого погодження. Поточний mode 1 не створює mismatch. Не змінювати RECEIVER лише задля subtype у UI. |
| T08 Контрольоване порушення шини | **Підтримано без зміни firmware:** SENDER mode 1, RECEIVER NORMAL, обидва 500 kbit/s, USB RECEIVER 460800. Обрано двопровідний обрив зв'язку, не коротке замикання чи зняття термінації. | Тимчасово роз'єднати обидві сигнальні лінії CANH/CANL між вузлами, зберегти живлення обох вузлів і спільний GND; потім відновити. Детальна інструкція нижче. |
| T09 BLE disconnect/reconnect | Технічно є серверний disconnect callback і повторне advertising; Android повторно підключає користувач. CAN налаштування штатні, USB увесь час активний. | У разі окремого майбутнього виконання — розірвати BLE в застосунку й знову підключити, не вимикаючи живлення RECEIVER. Firmware не потрібна. Це перевірка доступності каналу, не класифікація CAN-помилки. **Зараз не призначається і не продовжує завершене BLE-дослідження.** |

| ID | Що й де вимірювати | Очікуваний характер реакції та межі висновку |
|---|---|---|
| T06 | Serial **SENDER** TEC/state і рядок режиму; його tx — лише accepted requests. USB RECEIVER — лише допоміжна фіксація rx/silence, не TEC передавача. | У SENDER можливе зростання TEC й error-passive; BUS_OFF не обов'язковий. Receiver counters можуть не зростати. Сам TEC не розрізняє ACK/Bit/Form; фізичне усунення peer задає умову досліду, але точний subtype із поточного output не виміряний. Для повної кількісної діагностики SENDER потрібне окреме погодження telemetry-зміни, а не підміна counters. |
| T07 | USB RECEIVER `rx`, `rxe`, `buserr`, `state`, missed/ovr, транспортні втрати; опціонально Serial SENDER TEC/state | Очікуються порушення приймання/зміни error counters; величина залежить від умов і error confinement. Немає гарантії конкретного співвідношення CRC/Bit/Form/Stuff, TEC RECEIVER чи BUS_OFF. Після повернення bitrate відновлення залежить також від стану контролерів. |
| T08 | USB RECEIVER — наявність stats при припиненні frames, плато rx, тривалість паузи, відновлення потоку; Δbuserr/missed/ovr, TEC/REC/state як супровід. Serial SENDER — опціонально. | Після ізоляції валідні frames на RECEIVER припиняться, локальна stats продовжиться. Buserr/REC можуть змінитися на переході, але можуть лишитися незмінними. Це вимір втрати CAN-зв'язку та реакції монітора, не доказ конкретного subtype або кількості невдалих TX. |
| T09 | Android source connection events, ручні моменти disconnect/connect; USB RECEIVER rx/seq/stats і transport counters; session reconnect count | BLE-пауза не повинна сама змінювати CAN bitrate або зупиняти CAN RX. Відсутні Android frames під час disconnect — доступність BLE, не CAN error. Пошкодження BLE payload і звичайна пауза мають враховуватися окремо; без спільного clock не заявляти точну latency. |

## 5. Один наступний практичний дослід: T08, розрив і відновлення CAN-зв'язку

### Мета та готовність

Виміряти, чи розрізняється **жива телеметрія RECEIVER при зниклому CAN-потоці** від втрати самого USB-каналу, та зафіксувати повернення кадрів після відновлення wiring. Це корисна перевірка виявлення недоступності CAN для 4.3 з наявними двома ESP32/SN65HVD230. Вона не потребує покупки обладнання, зміни програми або участі BLE.

Стенд готовий до цього обмеженого сценарію за умови справного базового потоку. Він не готовий до достовірної subtype-статистики CRC/ACK/Bit/Form/Stuff з поточного FF12. T06 не обрано наступним: доступна лише часткова TX-діагностика SENDER, а UI отримує лише RECEIVER.

### Підготовка

1. Зберегти вже отримані BLE докази. На RECEIVER після RAM dump може залишатися **maintenance pause USB** (`ReceiverBleTrace.cpp`, рядки 237–259, 292–296). Для нового CAN-досліду після збереження dump натиснути Reset RECEIVER **до** початку baseline-запису. Ця дія починає нову uptime-епоху, не є перепрошиванням.
2. Перевірити штатні налаштування: SENDER mode 1 / 500 kbit/s; RECEIVER NO_ACK_MODE=0, SPEED_MISMATCH_DEMO=0 / 500 kbit/s; JSON USB 460800. Поточні source defines саме такі; відповідність прошитої версії перевіряється наявними build records, стартовим SENDER Serial (якщо доступний) та реальним baseline pattern. Якщо невідома або інша конфігурація — не змішувати її з цим дослідом; зупинити підготовку й окремо узгодити потрібну прошивку.
3. Залишити Android BLE від'єднаним; не запускати native trace або новий RAM dump. Діагностична firmware, якщо вже прошита, може використовуватися для цього USB-досліду після reset; її tracing flags відмітити в notes. Заміна на звичайну firmware зараз не вимагається. Build helper `build_receiver_ble_trace.py` призначений для BLE-трасування і для T08 не потрібен.
4. Перевірити CANH↔CANH, CANL↔CANL, спільний GND і окреме стабільне живлення обох вузлів. Вибрати доступну пару сигнальних з'єднань між вузлами, яку можна роз'єднати й повернути на ті самі контакти. Не торкатися USB RECEIVER під час fault-фази.
5. У документації конкретних VP230 модулів зазначені постійні 120-Ом резистори `121`; жовтий Rs-джампер не вважати термінатором. Нічого не випаювати й не міняти. Не замикати CANH/CANL на GND/VCC або між собою. Для цього досліду достатньо обриву сигнальної пари.
6. Закрити Arduino Serial Monitor та інші програми, які можуть займати **COM RECEIVER**. Визначити актуальний порт: COM5 — історичний номер, а не гарантована адреса. На Windows у CAN Debug Pro відкрити Real Stand → USB Serial → порт RECEIVER → **460800** → Connect/Start Monitoring. Орієнтир UI: USB RX/stats зростають; запис незалежний від 100-frame display buffer.
7. Дочекатися щонайменше 5 валідних stats. Перевірити `node=receiver`, bitrate=500000, state=RUNNING, кадри штатних восьми ID й pattern data. На старті TEC/REC, buserr/missed/ovr бажано нульові; якщо ні, зафіксувати baseline та пояснити причину або відкласти тест. Записати точний capture-каталог із «Experimental recording details».

### Послідовність одного контрольного запису

Усі фази зберігаються **в одному USB capture**, без Stop/Connect між фазами. Один цикл, не автоматичне навантажувальне випробування.

| Фаза | Тривалість | Дія |
|---|---:|---|
| Baseline | 30 с після стабілізації | Нічого не перемикати; записувати штатний CAN-потік та stats |
| Розрив | близько 10 с | Від'єднати CANH **і** CANL між вузлами, залишивши GND та живлення обох ESP32. Записати окремо час кожної дії; короткий проміжок між двома від'єднаннями є перехідним станом |
| Відновлення | 30 с | Повернути CANH і CANL на свої місця; записати моменти. Спостерігати повернення frames, stats не зупиняти |

Загалом близько 70 с плюс початкова стабілізація. Не вимикати SENDER замість CAN-розриву: це буде інша умова. Не змінювати SEND_MODE, bitrate, baud або BLE-стан під час запису.

Ручні моменти позначати в окремому текстовому журналі host UTC, наприклад у **другому** PowerShell-терміналі (ці команди виконує користувач під час досліду):

```powershell
cd D:\KNUO_term_paper\can_debug
$t08Notes = Join-Path (Get-Location) ('build\T08_actions_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt')
function Mark-T08([string]$eventName) {
    ('{0} {1}' -f [DateTime]::UtcNow.ToString('o'), $eventName) |
        Add-Content -LiteralPath $t08Notes -Encoding UTF8
}
Mark-T08 'baseline_start'
```

Безпосередньо при кожній відповідній дії: `Mark-T08 'CANH_open'`, `Mark-T08 'CANL_open'`, `Mark-T08 'CANH_restored'`, `Mark-T08 'CANL_restored'`; після 30 с відновлення — `Mark-T08 'observation_end'`. Це ручні мітки з похибкою реакції людини, не вимірювання propagation latency. Зберегти notes разом із capture; цей файл не з'явиться, доки користувач не виконає команди.

### Завершення та штатне повернення

1. Після post-фази натиснути Stop/Disconnect & Save у Windows app і дочекатися закриття журналу. Не завершувати процес примусово як спосіб збереження.
2. Якщо після повернення wiring frames не відновилися за 30 с, зафіксувати **«самостійне відновлення не спостерігалося»**, останні stats/state та завершити цей запис. Не приховувати цей результат reset усередині post-фази.
3. Для повернення до штатної роботи перевірити обидва сигнальні з'єднання та GND; за потреби перезапустити SENDER. Якщо перезапускається RECEIVER — робити це після закриття capture, бо uptime/counters скинуться. Будь-яке ручне відновлення зазначити в notes; воно не підтверджує автоматичного recovery.
4. У новій сесії перевірити звичайні frames/stats та відповідний baud. Reset — лише операційний спосіб повернення стенду; код recovery тут не змінюється.

### Які файли зберегти

- Повний каталог саме цього запуску: `capture.jsonl`, `capture.csv`, `manifest.json`. Типове місце — Windows Documents / `CAN_Debug_Pro/experiments/capture_*`; при перенаправленому Documents точний шлях брати з app.
- Ручні UTC notes, позначення baseline/fault/post, реальні GPIO/підключення, SENDER mode, firmware/build і tracing flags, USB baud/порт, версія застосунку. За можливості — хеші використаних binary/source або копія наявного build manifest.
- За наявного окремого USB-підключення SENDER — його Serial log 115200 для додаткового TEC/state. Це **не обов'язкова** умова T08 і не заміна RECEIVER USB. Не закривати CAN Debug Pro заради відкриття того самого RECEIVER COM у terminal.
- Не використовувати JSON/PDF session export або screenshot 100-frame UI як єдиний первинний набір: для підрахунків потрібен повний експериментальний JSONL. Перед `flutter clean` зберегти notes/докази поза `build/`.

### Що обчислити після запису

| Показник | Метод і обмеження |
|---|---|
| Повнота журналу | status=closed, acceptedRecords=writtenRecords=кількість усіх JSONL records; unrecordedRecords=0, failure=null. Окремо порахувати f/s/rejected. Rejected із rawJson=null не «виправляти» нормалізованими полями. CSV data rows мають відповідати JSONL, не рахувати рядок header CSV як повідомлення |
| Справність USB | readErrors/serialErrors/serialParseErrors, наявність послідовних uptime stats у fault-фазі, transport drops. За помилки розділити валідне вікно й дефект, не називати весь capture безпомилковим |
| Приймання CAN | frames/s для кожної фази за ESP ts; Δrx/Δuptime зі stats. Baseline/post орієнтовно 36 frames/s без гарантії точної кількості за ручний інтервал. Не прирівнювати різницю «36×10» до числа доведених загублених або помилкових кадрів |
| Пауза | Останній frame ts перед розривом і перший після відновлення; максимальний міжкадровий інтервал. Плато `rx` на кількох послідовних stats підтверджує відсутність успішних receive, поки USB живий. Seq при цьому може залишатися неперервним |
| Апаратна реакція RECEIVER | Max TEC/REC, state timeline та прирости buserr/missed/ovr/txfail/arb окремо за фазами; перший snapshot — baseline. Кумулятивні counters не сумувати. Snapshot 1 Гц може пропустити короткий пік або перехід |
| Прикладні втрати | Δqueuedrop/serialdrop/serialstatdrop/statdrop/toolong; BLE drops не використовувати як CAN error rate. Uptime/counter reset позначає нову епоху; через неї не рахувати звичайну різницю |
| Сигналізація застосунку | Зафіксувати, чи з'явилась ознака silence та чи зникла після відновлення; timestamps/screenshots — допоміжні дані. Повідомлення UI й health score відрізняти від апаратних лічильників та не називати апаратним subtype |

Host UTC notes зіставляються з `hostReceivedAt` для приблизної прив'язки фізичних фаз; точніша локальна послідовність frame/stats визначається ESP millis. Не віднімати host UTC від uptime як latency. При асинхронній доставці перехідні кілька записів можуть надійти із затримкою; не задавати їх наперед як пошкоджені.

### Критерії успішності та допустимий висновок

Коректно виконаний дослід має: збережений закритий журнал із відомою якістю; штатний baseline; задокументований CAN-розрив без reset/USB disconnect; живу stats під час плато rx; документоване повернення wiring та виміряний результат post-фази. Відновлення потоку без ручного reset є позитивним функціональним результатом; його відсутність також є результатом, а не підставою підмінити файл іншим запуском.

Якщо під час fault одночасно зникли **і** frames, **і** stats, або перезапустився RECEIVER/зламався USB-запис, втрату CAN окремо від втрати каналу не ізольовано: цей висновок не робити. Якщо REC/buserr не зросли, це не провал досліду — повністю ізольований RECEIVER може просто не бачити активності. Не вимагати BUS_OFF чи «ACK/CRC/Stuff errors» як критерію успіху.

Приклад допустимого майбутнього формулювання після підстановки фактичних чисел: «При розриві сигнальної пари CAN приймання валідних кадрів на RECEIVER припинилося на ... с; USB-телеметрія продовжувалася, rx утворив плато; після повернення з'єднання потік [відновився / не відновився без ручної дії]. Δbuserr=..., максимум REC=...». Числа та варіант результату тут навмисно не заповнені. Це не твердження про subtype або причину кожного фізичного error event.

## 6. Підсумкова готовність і виконані перевірки

Поточний стенд придатний до **T08 із USB-контролем** та, після окремо погодженого перемикання SENDER, до агрегатного T07. T06 має описані обмеження режиму й TX-спостереження; повної достовірної таблиці фізичних subtype поточна реалізація не дає. T09 оцінено лише як можливість транспортного disconnect/reconnect, не призначено новим BLE-тестом.

У межах цього завдання прочитано скетчі, trace helpers, telemetry mapper/diagnostics, SerialCanSource/ExperimentJournal та експериментальні reports/manifests. Зіставлено локальні TWAI headers/SDK config з первинними джерелами. Ніяких firmware-фіксів, нових Bluetooth hooks, збірок, прошивання чи фізичних дій не виконано. Git-стан і незакомічені файли перед створенням документації збережені в `../.work_backups/final_findings_before_20261110_200849.zip`.
