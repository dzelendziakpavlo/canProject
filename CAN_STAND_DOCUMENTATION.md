# CAN Debug Pro — Документація стенду

**Магістерська робота | КНУО | Спеціальність: КСА**  
Тема: Аналізатор помилок CAN-шини з демонстрацією на апаратному стенді

---

## Зміст

1. [Загальний опис системи](#1-загальний-опис-системи)
2. [Апаратна частина](#2-апаратна-частина)
3. [Протокол CAN — теоретична база](#3-протокол-can--теоретична-база)
4. [Прошивка RECEIVER](#4-прошивка-receiver)
5. [Прошивка SENDER](#5-прошивка-sender)
6. [BLE-протокол між ESP32 і Android](#6-ble-протокол-між-esp32-і-android)
7. [Flutter-застосунок](#7-flutter-застосунок)
8. [Каталог помилок — всі 11 типів](#8-каталог-помилок--всі-11-типів)
9. [Проведення експериментів](#9-проведення-експериментів)

---

## 1. Загальний опис системи

Система складається з трьох частин:

```
┌─────────────┐    CAN bus (CANH/CANL)    ┌─────────────────┐
│   SENDER    │◄─────────────────────────►│    RECEIVER     │
│   ESP32     │      500 kbit/s           │    ESP32        │
│  sender.ino │                           │ receiver_ble.ino│
└─────────────┘                           └────────┬────────┘
                                                   │ BLE (GATT NOTIFY)
                                                   │ JSON пакети
                                                   ▼
                                          ┌─────────────────┐
                                          │  Android-телефон│
                                          │  Flutter App    │
                                          │  CAN Debug Pro  │
                                          └─────────────────┘
```

**SENDER** генерує CAN-трафік у різних режимах (нормальний, overload, speed mismatch, RTR, extended ID).

**RECEIVER** отримує фрейми через CAN, зчитує апаратну статистику помилок з контролера TWAI і надсилає все через Bluetooth Low Energy на телефон.

**Flutter App** на Android приймає дані, класифікує помилки, відображає у реальному часі у вигляді списку фреймів, графіку частоти помилок і статусних банерів.

---

## 2. Апаратна частина

### Компоненти

| Вузол | МК | Трансивер | USB-порт |
|---|---|---|---|
| RECEIVER | ESP32 DevKit v1 | SN65HVD230 (VP230) | Serial monitor + прошивка |
| SENDER | ESP32 DevKit v1 | SN65HVD230 (VP230) | Тільки живлення або Serial |

### Схема підключення кожного вузла

```
       ESP32                      SN65HVD230 (VP230)
  ┌──────────┐                   ┌────────────────┐
  │  GPIO5   │──── TX ──────────►│ RX             │
  │  (UART TX)│                  │                │        ┌─────────┐
  │  GPIO4   │◄─── RX ──────────│ TX             │        │  CAN    │
  │  (UART RX)│                  │                │        │  BUS    │
  │          │                   │ CANH ──────────┼───────►│  CANH   │
  │  3.3V    │──────────────────►│ VCC            │        │         │
  │  GND     │──────────────────►│ GND            │        │  CANL   │
  └──────────┘                   │ CANL ──────────┼───────►│         │
                                 └────────────────┘        └─────────┘
```

> **Важливо:** Підключення GPIO5→RX і GPIO4→TX є навмисно перехресним відносно написів на платі VP230. На цих конкретних модулях написи відповідають стороні ESP32, а не стороні шини CAN.

### Елементи VP230-модуля

- **SMD-резистор `121`** — термінатор 120 Ом, припаяний постійно на кожному модулі
- **Жовтий джампер** — це pin `Rs` (slope control, 10 кОм). **Не термінатор.** Видалення джампера вимикає мікросхему VP230.

---

## 3. Протокол CAN — теоретична база

### Формат стандартного фрейму (11-bit ID)

```
SOF │ ID (11 bit) │ RTR │ IDE │ r0 │ DLC (4) │ Data (0–64 bit) │ CRC (15) │ CRC Del │ ACK │ ACK Del │ EOF │
```

### Формат розширеного фрейму (29-bit ID, Extended)

```
SOF │ ID-A (11) │ SRR │ IDE=1 │ ID-B (18) │ RTR │ r1 │ r0 │ DLC (4) │ Data │ CRC │ ACK │ EOF │
```

Розширений формат використовується в SAE J1939 (вантажівки, автобуси). IDE=1 сигналізує приймачам що ID — 29-бітний.

### Bit Stuffing

Після 5 однакових послідовних бітів передавач автоматично вставляє біт протилежної полярності. Якщо приймач бачить 6 однакових бітів поспіль — це `stuffingError`.

### ACK-механізм

Після поля даних і CRC передавач відпускає шину (рецесивний біт). Будь-який вузол, який правильно прийняв фрейм, домінантним бітом підтверджує (ACK). Якщо передавач не бачить домінантного ACK — він фіксує `ackError` і збільшує TEC на 8.

### Лічильники помилок і стани вузла

Кожен вузол підтримує два лічильники:
- **TEC** (Transmit Error Counter) — помилки при передачі
- **REC** (Receive Error Counter) — помилки при прийомі

```
TEC/REC = 0–96:     Error Active  — нормальна робота
TEC/REC = 97–127:   Error Warning — деградований стан, ще активний
TEC/REC = 128–254:  Error Passive — надсилає passive error frame (не dominant)
TEC = 255:          Bus-Off       — вузол фізично відключається від шини
```

Правила зміни (ISO 11898-1 §6.15):
- Передавач: **+8** за кожну помилку, **-1** за успішний фрейм
- Приймач: **+1** за більшість помилок, **+8** за bit error в ACK/EOF, **-1** за успішний фрейм

> **Особливість TWAI (ESP32):** Контролер TWAI залишає `state = RUNNING` навіть при Error Passive. Стан змінюється на `BUS_OFF` лише при TEC > 255. Тому застосунок перевіряє значення TEC і REC напряму, а не тільки поле `state`.

### Bus-Off і автовідновлення

Після Bus-Off вузол може відновитися, відрахувавши 128 послідовностей з 11 рецесивних бітів на шині. У прошивці RECEIVER це реалізовано автоматично:

```cpp
if (status.state == TWAI_STATE_BUS_OFF) {
    twai_initiate_recovery();
}
```

---

## 4. Прошивка RECEIVER

**Файл:** `arduino/receiver_ble/receiver_ble.ino`

### Загальна логіка

```
setup():
  1. BLE init ("CAN-Monitor", MTU 256)
  2. Створити GATT server + service FF10
  3. Додати characteristics FF11 (frames NOTIFY) + FF12 (stats NOTIFY)
  4. Почати рекламування
  5. TWAI init (GPIO5/GPIO4, 500kbps, NO_ACK або NORMAL залежно від define)

loop():
  1. twai_receive() з таймаутом 10 мс
     → якщо прийшов фрейм: totalRx++, buildFrameJson(), notify FF11
  2. twai_get_status_info() → перевірка стану
     → якщо BUS_OFF: twai_initiate_recovery()
  3. Кожну секунду: buildStatsJson(), notify FF12
  4. Якщо BLE відключився: перезапустити рекламування
```

### Флаги режимів (задаються до прошивки)

```cpp
#define NO_ACK_MODE 0
```
- `0` → `TWAI_MODE_NORMAL` — RECEIVER відправляє ACK-біти на всі правильно прийняті фрейми
- `1` → `TWAI_MODE_NO_ACK` — RECEIVER ігнорує ACK slot, не підтверджує фрейми. SENDER не отримує ACK → його TEC росте → SENDER іде в BUS-OFF. Демонстрація **ACK Error**.

```cpp
#define SPEED_MISMATCH_DEMO 0
```
- `0` → нормально
- `1` → включається разом із SENDER `SEND_MODE 3`. RECEIVER залишається на 500 kbps, але Flutter-застосунок знає що зараз активний сценарій speed mismatch і класифікує помилки як `stuffingError` + `formatError`.

### JSON фрейму (Characteristic FF11)

Надсилається при кожному отриманому CAN-фреймі:

```json
// Звичайний фрейм
{"t":"f","id":192,"dlc":8,"data":[10,20,30,40,50,60,70,80],"ts":12345}

// RTR фрейм (data порожній, навіть якщо DLC > 0)
{"t":"f","id":192,"dlc":8,"data":[],"ts":12346,"rtr":1}

// Extended (29-bit ID) фрейм
{"t":"f","id":418120705,"dlc":8,"data":[1,2,3,4,5,6,7,8],"ts":12347,"extd":1}
```

| Поле | Завжди? | Опис |
|---|---|---|
| `t` | так | завжди `"f"` |
| `id` | так | числовий CAN ID (до 536870911 для 29-bit) |
| `dlc` | так | 0–8 |
| `data` | так | масив байтів (порожній для RTR) |
| `ts` | так | `millis()` мікроконтролера |
| `rtr` | тільки для RTR | `1` |
| `extd` | тільки для 29-bit | `1` |

### JSON статистики (Characteristic FF12)

Надсилається раз на секунду:

```json
{
  "t":      "s",
  "rx":     1234,
  "txe":    8,
  "rxe":    0,
  "state":  "RUNNING",
  "missed": 0,
  "buserr": 6,
  "arb":    0,
  "txfail": 0,
  "ovr":    0,
  "noack":  0,
  "sdemo":  0
}
```

| Поле | Джерело | Опис |
|---|---|---|
| `rx` | `totalRx` (змінна) | Загальна кількість отриманих фреймів |
| `txe` | `tx_error_counter` | TEC |
| `rxe` | `rx_error_counter` | REC |
| `state` | `twai_state_t` | `RUNNING` / `BUS_OFF` / `RECOVERING` / `STOPPED` |
| `missed` | `rx_missed_count` | Фрейми відкинуті через переповнення програмної черги |
| `buserr` | `bus_error_count` | Кумулятивна сума всіх помилок шини (bit+stuff+CRC+form+ACK) |
| `arb` | `arb_lost_count` | Кількість програних арбітражів |
| `txfail` | `tx_failed_count` | TX-повідомлення скасовані після вичерпання ліміту помилок |
| `ovr` | `rx_overrun_count` | Переповнення на рівні апаратного буфера TWAI |
| `noack` | `NO_ACK_MODE` define | 1 якщо прошивка скомпільована з NO_ACK_MODE=1 |
| `sdemo` | `SPEED_MISMATCH_DEMO` define | 1 якщо активний сценарій розбіжності швидкостей |

#### Telemetry v2

Починаючи з telemetry schema `v=2`, пакет FF12 також містить метадані вузла:

```json
{
  "t": "s", "v": 2, "node": "receiver",
  "fw": "can-monitor-telemetry-v2", "uptime": 123456,
  "bitrate": 500000, "reason": "ok",
  "rx": 1234, "txe": 0, "rxe": 0, "state": "RUNNING"
}
```

| Поле | Опис |
|---|---|
| `v` | Версія telemetry-схеми; відсутнє поле трактують як v1 |
| `node` | Назва вузла, наприклад `receiver` |
| `fw` | Версія прошивки |
| `uptime` | Час роботи receiver у мілісекундах |
| `bitrate` | Налаштована швидкість CAN у bit/s |
| `reason` | Найважливіша причина стану: `ok`, `bus_error`, `rx_missed`, `rx_overrun`, `error_warning`, `error_passive`, `recovering`, `bus_off` |

Старі версії Flutter-клієнта можуть ігнорувати ці поля: базові `rx`, `txe`, `rxe`, `state` та інші лічильники залишаються сумісними.

### Повний код `buildFrameJson` та `buildStatsJson`

```cpp
String buildFrameJson(const twai_message_t& msg) {
  String s;
  s.reserve(100);
  s  = "{\"t\":\"f\",\"id\":";
  s += msg.identifier;
  s += ",\"dlc\":";
  s += msg.data_length_code;
  s += ",\"data\":[";
  if (!msg.rtr) {                           // RTR не має payload
    for (uint8_t i = 0; i < msg.data_length_code; i++) {
      if (i) s += ',';
      s += msg.data[i];
    }
  }
  s += "],\"ts\":";
  s += millis();
  if (msg.rtr)  s += ",\"rtr\":1";
  if (msg.extd) s += ",\"extd\":1";
  s += '}';
  return s;
}

String buildStatsJson(const twai_status_info_t& st) {
  String s;
  s.reserve(130);
  s  = "{\"t\":\"s\",\"rx\":";   s += totalRx;
  s += ",\"txe\":";              s += st.tx_error_counter;
  s += ",\"rxe\":";              s += st.rx_error_counter;
  s += ",\"state\":\"";          s += busStateName(st.state);
  s += "\",\"missed\":";         s += st.rx_missed_count;
  s += ",\"buserr\":";           s += st.bus_error_count;
  s += ",\"arb\":";              s += st.arb_lost_count;
  s += ",\"txfail\":";           s += st.tx_failed_count;
  s += ",\"ovr\":";              s += st.rx_overrun_count;
  s += ",\"noack\":";            s += NO_ACK_MODE ? 1 : 0;
  s += ",\"sdemo\":";            s += SPEED_MISMATCH_DEMO ? 1 : 0;
  s += '}';
  return s;
}
```

---

## 5. Прошивка SENDER

**Файл:** `arduino/sender_can/sender_can.ino`

### Сигнали (MODE 1, 3, 4, 5)

8 автомобільних сигналів з різною частотою оновлення:

| CAN ID | Сигнал | Частота |
|---|---|---|
| `0x0C0` | EngineRPM | 10 Hz (кожні 100 мс) |
| `0x0C8` | VehicleSpeed | 10 Hz |
| `0x0D0` | ThrottlePosition | 5 Hz (кожні 200 мс) |
| `0x0D8` | CoolantTemperature | 5 Hz |
| `0x1A0` | BrakePressure | 2 Hz (кожні 500 мс) |
| `0x1A8` | SteeringAngle | 2 Hz |
| `0x2B0` | BatteryVoltage | 1 Hz (кожну 1000 мс) |
| `0x2B8` | OilPressure | 1 Hz |

Дані в кожному фреймі: `data[0]` = лічильник відправлень, `data[1]` = лічильник×3, решта нулі.

### MODE 1 — Normal (500 kbps)

Стандартний автомобільний трафік. 8 сигналів на своїх інтервалах. Використовується для базових демонстрацій і як "нормальний стан" перед будь-яким експериментом.

```cpp
for (int i = 0; i < NUM_SIGNALS; i++) {
    if (now - lastSent[i] >= signals[i].intervalMs) {
        sendFrame(signals[i].id, signals[i].dlc, signals[i].data);
    }
}
```

### MODE 2 — Overload (500 kbps, без затримок)

Надсилає фрейми без жодної затримки між ними. На 500 kbps стандартний фрейм з 8 байтами займає ~130 мкс, тобто теоретичний максимум ~7700 фреймів/сек. На практиці виходить ~3000–5000.

```cpp
// TX черга збільшена до 32 слотів (g.tx_queue_len = 32)
sendFrame(signals[idx].id, 8, data);   // без затримки
idx = (idx + 1) % NUM_SIGNALS;
val++;
```

RECEIVER не встигає обробляти: `rx_missed_count` (програмна черга = 5 слотів за замовчуванням) і `rx_overrun_count` (апаратний буфер) починають рости.

### MODE 3 — Speed Mismatch (250 kbps)

Той самий патерн що MODE 1, але TWAI ініціалізується на 250 kbps:

```cpp
#if SEND_MODE == 3
  twai_timing_config_t t = TWAI_TIMING_CONFIG_250KBITS();
#else
  twai_timing_config_t t = TWAI_TIMING_CONFIG_500KBITS();
#endif
```

RECEIVER очікує бітовий інтервал 2 мкс (500 kbps), але отримує 4 мкс (250 kbps). Результат:
- **Stuffing Error** — RECEIVER бачить >5 однакових бітів там де не очікує (bit stuffing правила порушені через інший тайминг)
- **Format Error** — фіксовані поля фрейму (EOF, CRC delimiter) знаходяться не там де очікує RECEIVER

### MODE 4 — RTR Demo (500 kbps)

Нормальні 8 сигналів + кожні 2 секунди RTR-фрейм:

```cpp
twai_message_t rtr = {};
rtr.identifier       = 0x0C0;   // запит на EngineRPM
rtr.data_length_code = 8;       // очікуваний розмір відповіді
rtr.rtr  = 1;                   // Remote Transmission Request flag
rtr.extd = 0;
twai_transmit(&rtr, pdMS_TO_TICKS(5));
```

RTR = Remote Transmission Request. Вузол не надсилає дані, а запитує їх від іншого вузла, якому "належить" цей ID. Корисно для опитування по запиту (polling on demand).

### MODE 5 — Extended ID Demo (500 kbps)

Нормальні 8 сигналів + кожну секунду 3 фрейми з 29-bit ID у стилі SAE J1939:

```cpp
const uint32_t extIds[] = { 0x18FF0001, 0x18FEE300, 0x0CF00400 };
for (int i = 0; i < 3; i++) {
    twai_message_t ext = {};
    ext.identifier       = extIds[i];
    ext.data_length_code = 8;
    ext.extd = 1;   // ← 29-bit extended frame
    ext.rtr  = 0;
    twai_transmit(&ext, pdMS_TO_TICKS(5));
}
```

J1939 ID структура: `[Priority 3bit][Reserved 1bit][DP 1bit][PGN 18bit][SA 8bit]`

| ID | Декодування |
|---|---|
| `0x18FF0001` | PGN FF00 (Proprietary A) від адреси 0x01 |
| `0x18FEE300` | PGN FEE3 (Engine Temperature) |
| `0x0CF00400` | PGN F004 (Electronic Engine Controller 1) |

---

## 6. BLE-протокол між ESP32 і Android

### GATT layout

```
Device name:  "CAN-Monitor"
MTU:          256 байт

Service:    0000FF10-0000-1000-8000-00805F9B34FB
  ├── Char: 0000FF11-0000-1000-8000-00805F9B34FB  [NOTIFY]  CAN frames
  └── Char: 0000FF12-0000-1000-8000-00805F9B34FB  [NOTIFY]  TWAI stats
```

### Процес підключення (Flutter)

```
1. Scan  → BleConnectScreen показує список пристроїв (sorted by RSSI)
2. Tap   → BleCanSource.start()
3. Connect → requestMtu(247)
4. discoverServices() → знаходить FF10
5. setNotifyValue(true) на FF11 і FF12
6. Emit SourceState.streaming
7. При відключенні: exponential backoff reconnect (4→8→16→32→32 сек)
```

### Парсинг на Flutter-стороні

```dart
// FF11 — фрейм
void _onFrameBytes(List<int> bytes) {
  final json = jsonDecode(String.fromCharCodes(bytes));
  if (json['t'] != 'f') return;
  final frame = CanFrame.create(
    id:         json['id']  as int,
    dlc:        json['dlc'] as int,
    data:       List<int>.from(json['data']),
    isRtr:      (json['rtr']  as int?) == 1,
    isExtended: (json['extd'] as int?) == 1,
  );
  _frameCtrl.add(frame);
}

// FF12 — статистика
void _onStatsBytes(List<int> bytes) {
  final json = jsonDecode(String.fromCharCodes(bytes));
  if (json['t'] != 's') return;
  final stats = CanStats.fromJson(json);
  _statsCtrl.add(stats);
}
```

---

## 7. Flutter-застосунок

### Архітектура

```
lib/
├── domain/
│   ├── models/
│   │   ├── can_frame.dart       — модель одного CAN-фрейму
│   │   └── can_stats.dart       — модель TWAI-статистики (1/сек від ESP32)
│   ├── source/
│   │   ├── can_frame_source.dart     — абстрактний інтерфейс (Stream-based)
│   │   ├── ble_can_source.dart       — BLE реалізація (ESP32 стенд)
│   │   └── can_frame_simulator.dart  — симулятор (без заліза)
│   └── detection/
│       └── can_error_checker.dart    — enum CanErrorType, CanErrorInfo
└── presentation/
    └── screens/
        └── monitor_screen.dart       — головний екран моніторингу
```

### Модель CanFrame

```dart
class CanFrame {
  final int id;            // CAN ідентифікатор
  final int dlc;           // Data Length Code (0–8)
  final List<int> data;    // байти даних
  final int crc;           // XOR-CRC (для відображення)
  final DateTime timestamp;
  final bool isCorrupted;  // симулятор навмисно зіпсував CRC
  final bool isRtr;        // Remote Transmission Request
  final bool isExtended;   // 29-bit extended ID
  final List<dynamic> errors; // список CanErrorInfo (порожній для OK фреймів)
}

// Геттери
String get status    // 'ERROR' | 'RTR' | 'EXT' | 'OK'
String get idHex     // '0x0C0' (11-bit) або '0x18FF0001' (29-bit, 8 цифр)
String get dataHex   // 'AA BB CC DD EE FF 00 01'
```

**Фрейм рахується як помилка** якщо `isCorrupted == true` АБО `errors.isNotEmpty`.
RTR і Extended фрейми — нормальні типи протоколу, **не помилки**.

### Модель CanStats

```dart
class CanStats {
  final int rxTotal;           // загальна кількість прийнятих фреймів
  final int txErrorCounter;    // TEC
  final int rxErrorCounter;    // REC
  final String busState;       // 'RUNNING'|'BUS_OFF'|'RECOVERING'|'STOPPED'
  final int rxMissed;          // rx_missed_count
  final int busErrorCount;     // bus_error_count (кумулятивний)
  final int arbLostCount;
  final int txFailedCount;
  final int rxOverrunCount;
  final bool isNoAckMode;          // прошивка з NO_ACK_MODE=1
  final bool isSpeedMismatchDemo;  // прошивка з SPEED_MISMATCH_DEMO=1
  final DateTime timestamp;

  // Геттери стану
  bool get isBusOff       => busState == 'BUS_OFF';
  bool get isRecovering   => busState == 'RECOVERING';
  bool get isErrorPassive => txErrorCounter > 127 || rxErrorCounter > 127;
  bool get isErrorWarning => !isErrorPassive &&
                             (txErrorCounter > 96 || rxErrorCounter > 96);
}
```

### Буферизація фреймів (frame batching)

CAN-шина може надсилати 200+ фреймів/сек. Якщо кожен фрейм викликає `setState()`, UI "заморожується". Рішення:

```dart
// Фрейми накопичуються в буфері
_subscription = _source.frameStream.listen(_pendingFrames.add);

// Таймер 50 мс скидає буфер одним setState()
_uiTimer = Timer.periodic(Duration(milliseconds: 50), (_) => _flushPending());

void _flushPending() {
  if (_pendingFrames.isEmpty) return;
  final batch = List<CanFrame>.of(_pendingFrames);
  _pendingFrames.clear();
  setState(() {
    for (final frame in batch) { /* обробка */ }
  });
}
```

Це дає ~20 оновлень UI на секунду незалежно від темпу шини.

### Обробка stats-пакету

При кожному новому `CanStats` обчислюються дельти відносно попереднього пакету:

```dart
final errorDelta  = stats.busErrorCount  - prev.busErrorCount;
final tecDelta    = stats.txErrorCounter - prev.txErrorCounter;
final recDelta    = stats.rxErrorCounter - prev.rxErrorCounter;
final arbDelta    = stats.arbLostCount   - prev.arbLostCount;
final txFailDelta = stats.txFailedCount  - prev.txFailedCount;
final ovrDelta    = stats.rxOverrunCount - prev.rxOverrunCount;
final missedDelta = stats.rxMissed       - prev.rxMissed;
```

На основі дельт оновлюється графік і вставляються синтетичні фрейми-маркери в список.

### Синтетичний фрейм-маркер помилки

Коли TWAI фіксує помилку (росте `busErrorCount`), Flutter вставляє в список синтетичний фрейм:
- `id = 0x000` (цей ID не використовується жодним реальним сигналом MODE 1)
- `dlc = 0`, `data = []`
- `isCorrupted = false`
- `errors = [CanErrorInfo(type: ..., description: "...", severity: 1–5)]`

Наявність непорожнього `errors` → фрейм відображається червоним і рахується як помилка.

### Пріоритети класифікації при появі нових помилок

```
1. stats.isErrorWarning && !prev.isErrorWarning  → Error Warning (перехід через 96)
2. txFailDelta > 0                               → ACK Error (точний сигнал tx_failed_count)
3. ovrDelta > 0                                  → Overload HW (апаратне переповнення)
4. missedDelta > 0                               → Overload SW (черга переповнена)
5. isNoAckMode && residual > 0                   → ACK Error (no-ack режим)
6. isSpeedMismatchDemo && residual > 0           → StuffingError + FormatError (по одному кожного)
7. residual > 0 (звичайний)                      → heuristic за TEC/REC delta (таблиця нижче)
8. arbDelta > 0                                  → Arbitration Lost
```

де `residual = errorDelta - txFailDelta`

### Heuristic класифікація (звичайний режим)

| TEC delta | REC delta | Стан | Тип помилки |
|---|---|---|---|
| будь-який | будь-який | `isBusOff` | `busOffError` |
| будь-який | будь-який | `isErrorPassive` | `passiveError` |
| > 0 | = 0 | нормальний | `ackError` — RECEIVER надіслав error flag (проблема TX) |
| = 0 | > 0 | нормальний | `crcError` — RECEIVER виявив помилку в прийнятому фреймі |
| > 0 | > 0 | нормальний | `activeError` — обидва вузли обмінюються error flags |
| інше | інше | нормальний | `activeError` — загальна помилка |

### Графік помилок (hardware mode)

```dart
final total = errorDelta + rxDelta;           // всього подій за секунду
final hwRate = total > 0
    ? (errorDelta / total) * 100.0            // % помилок
    : 0.0;
_errorRateHistory.add(hwRate.clamp(0.0, 100.0));
```

Зберігаються останні 50 точок (50 секунд при 1 stats/сек).

---

## 8. Каталог помилок — всі 11 типів

### Помилки протоколу (рахуються в статистику)

---

#### 1. CRC / Receive Error — `crcError`

**Умова:** `recDelta > 0` і `tecDelta == 0`  
**Фізична причина:** Від'єднаний CANH або CANL — RECEIVER отримує пошкоджені фрейми, які не проходять перевірку CRC або форматних полів. REC росте, TEC залишається 0 (RECEIVER не надсилає error flag, тільки рахує).  
**Відображення:** Червоний рядок у списку, ID `0x000`, статус ERROR  
**Опис у фреймі:** `"TWAI: +N err | REC↑N — CRC/form/stuff error in received frame | TEC 0 REC N | RUNNING"`

---

#### 2. Active Error Flag — `activeError`

**Умова:** `tecDelta > 0` і `recDelta > 0`  
**Фізична причина:** Обидва вузли виявляють помилку одночасно і надсилають error flags. TEC і REC ростуть. Типово при коротко замкнутих резисторах або сильних перешкодах.  
**Відображення:** Червоний рядок  
**Опис:** `"TWAI: +N err | TEC↑N REC↑N — active error flag exchange | TEC N REC N | RUNNING"`

---

#### 3. Error Passive — `passiveError`

**Умова:** `stats.isErrorPassive` (TEC > 127 або REC > 127)  
**Причина:** Вузол перейшов у Error Passive стан. Надсилає passive error frame (6 рецесивних бітів замість домінантних), який фактично не впливає на шину.  
**Відображення:** Червоний рядок + **бурштиновий банер** зверху  
**Банер:** `"Error Passive — TEC N / REC N > 127. Approaching bus-off."`

---

#### 4. Bus-Off — `busOffError`

**Умова:** `stats.isBusOff` (TEC > 255)  
**Причина:** Вузол вичерпав ліміт помилок, фізично відключився від шини. TWAI state = `BUS_OFF`.  
**Відображення:** Червоний рядок + **червоний банер** зверху  
**Банер:** `"BUS-OFF — TX error limit reached (TEC > 255). Recovery in progress…"`  
**Примітка:** RECEIVER автоматично запускає `twai_initiate_recovery()`, після чого state = `RECOVERING`.

---

#### 5. ACK Error — `ackError`

Два сценарії:

**5a. No-ACK mode (`isNoAckMode == true`)**  
RECEIVER прошитий з `NO_ACK_MODE 1` → не надсилає ACK-біти. SENDER не отримує підтвердження → TEC росте.  
**Опис:** `"No-ACK mode: RECEIVER not sending ACK bits — SENDER TEC↑N | +N err | RUNNING"`  
**Індикатор:** Червоний чіп **NO-ACK** у TWAI-панелі

**5b. Точний сигнал `txFailedCount` (`txFailDelta > 0`)**  
`tx_failed_count` у TWAI росте коли TX-повідомлення скасоване через вичерпання ліміту помилок.  
**Опис:** `"TWAI: TX failed ×N — no ACK received (receiver absent or dominant bit error) | TEC N"`

---

#### 6. Overload Error — `overloadError`

Два рівні:

**6a. Апаратне переповнення (`rx_overrun_count`)**  
Апаратний RX-буфер TWAI переповнений. Фрейм відкинутий до потрапляння в програмну чергу.  
**Опис:** `"TWAI: HW RX overrun ×N — frame(s) dropped at hardware level (bus rate > processing rate) | missed N"`

**6b. Програмне переповнення (`rx_missed_count`)**  
Програмна черга TWAI (за замовчуванням 5 слотів) переповнена. Flutter не встиг вичитати.  
**Опис:** `"TWAI: RX queue overflow — N frame(s) dropped (bus rate > processing rate) | total missed: N"`

---

#### 7. Stuffing Error — `stuffingError`

**Умова:** `stats.isSpeedMismatchDemo == true` і `errorDelta > 0`  
**Причина:** SENDER відправляє на 250 kbps, RECEIVER очікує 500 kbps. Різний тайминг → RECEIVER бачить >5 однакових бітів там де не очікує → порушення правила bit stuffing.  
**Відображення:** Червоний рядок + жовтий чіп **250k≠500k**  
**Опис:** `"Speed mismatch: bit stuffing violation — SENDER 250k ≠ RECEIVER 500k | +N err | REC N"`

---

#### 8. Format Error — `formatError`

**Умова:** `stats.isSpeedMismatchDemo == true` і `errorDelta > 1` (вставляється разом із stuffingError)  
**Причина:** Той самий сценарій 250k/500k. Фіксовані поля фрейму (EOF = 7 рецесивних бітів, CRC delimiter, ACK delimiter) знаходяться не на тих позиціях, що очікує RECEIVER.  
**Опис:** `"Speed mismatch: frame format error — EOF/delimiter bits at wrong positions | SENDER 250k ≠ RECEIVER 500k | REC N"`

---

#### 11. Error Warning (перехід) — `activeError` severity 2

**Умова:** `stats.isErrorWarning && !prev.isErrorWarning` (TEC або REC щойно перетнув 96)  
**Причина:** Вузол увійшов у попереджувальний стан ISO 11898-1. Ще Error Active, але наближається до порогу 127.  
**Відображення:** Червоний рядок (одноразово при переході) + **жовтий банер**  
**Банер:** `"Error Warning — TEC N / REC N > 96. Monitor bus quality."`  
**Опис у фреймі:** `"Error Warning: TEC N / REC N exceeded 96 — approaching error-passive threshold (127)"`

---

### Спеціальні типи фреймів (НЕ помилки)

---

#### 9. RTR Frame

**Умова:** `frame.isRtr == true`  
**Що це:** Remote Transmission Request — запит даних від іншого вузла. Немає payload, DLC вказує очікуваний розмір відповіді.  
**Відображення:** **Жовтий** рядок, `data` = `—`, статус `RTR`  
**Рахується?** ❌ Не помилка, нормальний тип протоколу

---

#### 10. Extended Frame (29-bit ID)

**Умова:** `frame.isExtended == true`  
**Що це:** Фрейм з 29-бітним ідентифікатором (IDE=1). Використовується в SAE J1939.  
**Відображення:** **Зелений** рядок, ID відображається як 8 hex-цифр (`0x18FF0001`)  
**Рахується?** ❌ Не помилка, розширений формат протоколу

---

### Банери на головному екрані

Пріоритет (вищий перекриває нижчий):

```
1. BUS-OFF       → 🔴 червоний  "BUS-OFF — TX error limit reached"
2. RECOVERING    → 🟠 бурштиновий "Recovering from bus-off…"
3. Bus Silent    → 🟠 помаранчевий "CAN bus silent — no frames for 3 s"
4. Error Passive → 🟠 бурштиновий "Error Passive — TEC N / REC N > 127"
5. Error Warning → 🟡 жовтий     "Error Warning — TEC N / REC N > 96"
6. (нічого)      → банер прихований
```

Додаткові чіпи в TWAI-панелі (не банери, а теги):
- **NO-ACK** (червоний) — коли `stats.isNoAckMode`
- **250k≠500k** (жовтий) — коли `stats.isSpeedMismatchDemo`

---

## 9. Проведення експериментів

### Конфігурація прошивок

```
Сценарій               SENDER define      RECEIVER define
──────────────────────────────────────────────────────────
Нормальна робота       SEND_MODE 1        NO_ACK_MODE 0, SPEED_MISMATCH_DEMO 0
Overload               SEND_MODE 2        NO_ACK_MODE 0
Speed Mismatch         SEND_MODE 3        SPEED_MISMATCH_DEMO 1
RTR Demo               SEND_MODE 4        NO_ACK_MODE 0
Extended ID Demo       SEND_MODE 5        NO_ACK_MODE 0
ACK Error / No-ACK     SEND_MODE 1        NO_ACK_MODE 1
```

### Фізичні дії та очікуваний результат

| Дія | Що видно в застосунку |
|---|---|
| Від'єднати CANH (або CANL) | REC росте → `crcError` фрейми. Через 3 сек: банер "Bus Silent". При великому REC: банер "Error Warning", потім "Error Passive" |
| Замкнути CANH і CANL через резистор ~50 Ом | `bus_error_count` стрибає → `activeError` фрейми. TEC і REC ростуть. Можливий "Error Passive" і "BUS-OFF" |
| Від'єднати SENDER (RECEIVER NO_ACK_MODE 1) | Маси `ackError` фреймів, TEC SENDER 0→128→255, BUS-OFF, авто-відновлення, повтор |
| SENDER MODE 2 (max швидкість) | `rx_missed_count` росте → `overloadError` фрейми, лічильник MISS у TWAI-панелі |
| SENDER MODE 3 + RECEIVER SPEED_MISMATCH_DEMO 1 | `stuffingError` і `formatError` фрейми, чіп "250k≠500k" |
| SENDER MODE 4 | Кожні 2 сек жовтий RTR рядок `0x0C0 RTR` |
| SENDER MODE 5 | Кожну сек три зелені EXT рядки `0x18FF0001`, `0x18FEE300`, `0x0CF00400` |
| Тримати будь-яку помилку до TEC/REC 97–127 | Жовтий банер "Error Warning" + один запис у списку |
| Тримати до TEC/REC > 127 | Бурштиновий банер "Error Passive" |
| Тримати до TEC > 255 | Червоний банер "BUS-OFF", авто-відновлення через ~130 мс |

### Перевірка через nRF Connect (без Android-застосунку)

1. Встановити nRF Connect (Android/iOS)
2. Scan → знайти "CAN-Monitor"
3. Connect → Services → `FF10`
4. Subscribe на `FF11` і `FF12`
5. Бачити сирий JSON stream у реальному часі

Serial Monitor (115200 baud) на RECEIVER паралельно виводить:
```
RX,0x0C0,8,0A,1E,00,00,00,00,00,00
STATS,12345,1234,0,0,RUNNING,0,0,0
ALERT,BUS_STATE_CHANGE,BUS_OFF
ALERT,INITIATING_RECOVERY
```
