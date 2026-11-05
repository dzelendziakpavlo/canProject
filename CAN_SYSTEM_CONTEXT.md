# CAN Debug Pro — повний технічний контекст системи

Документ описує повну архітектуру стенду для демонстрації помилок CAN-шини: апаратна частина (два ESP32), прошивки (Receiver + Sender), BLE-протокол і Flutter-застосунок для Android.

---

## 1. Апаратна частина

### Компоненти стенду

| Вузол | Мікроконтролер | Трансивер | Роль |
|---|---|---|---|
| RECEIVER | ESP32 | SN65HVD230 (VP230) | Приймає фрейми, відправляє через BLE на Android |
| SENDER | ESP32 | SN65HVD230 (VP230) | Генерує CAN-трафік у різних режимах |

### Підключення CAN (обидва вузли однакові)

```
ESP32 GPIO5 (TX) → SN65HVD230 RX pin
ESP32 GPIO4 (RX) → SN65HVD230 TX pin
SN65HVD230 CANH  → шина CANH
SN65HVD230 CANL  → шина CANL
```

**Увага:** Підключення TX→RX і RX→TX є навмисно перехресним — це особливість конкретних модулів VP230, де написи на платі відповідають стороні ESP32, а не стороні шини.

### Термінатори

На кожному модулі VP230 є SMD-резистор `121` (120 Ом), припаяний постійно. Жовтий джампер на платі — це pin `Rs` (slope control, 10 кОм), **не термінатор**. Видалення жовтого джампера вимикає мікросхему VP230.

### Швидкість шини

500 kbit/s (за замовчуванням). SENDER MODE 3 переходить на 250 kbit/s.

---

## 2. CAN-контролер ESP32 — TWAI

ESP32 має вбудований CAN-контролер під назвою **TWAI** (Two-Wire Automotive Interface), сумісний з ISO 11898-1. Використовується через IDF-драйвер `driver/twai.h`.

### Стани шини (twai_state_t)

```
TWAI_STATE_STOPPED    — контролер зупинено
TWAI_STATE_RUNNING    — нормальна робота
TWAI_STATE_BUS_OFF    — TEC перевищив 255, вузол відключений від шини
TWAI_STATE_RECOVERING — автовідновлення після BUS_OFF (128 пауз між фреймами)
```

### Лічильники помилок (twai_status_info_t)

```c
uint32_t tx_error_counter;  // TEC — лічильник помилок передачі
uint32_t rx_error_counter;  // REC — лічильник помилок прийому
uint32_t rx_missed_count;   // скільки фреймів програмна черга відкинула (переповнення)
uint32_t rx_overrun_count;  // переповнення на рівні апаратного буфера TWAI
uint32_t arb_lost_count;    // скільки разів вузол програв арбітраж
uint32_t bus_error_count;   // кумулятивна сума всіх помилок шини (bit/stuff/CRC/form/ACK)
uint32_t tx_failed_count;   // TX-повідомлення, скасовані після вичерпання ліміту помилок
```

### Правила зміни TEC/REC (ISO 11898-1)

- **Передавач** (TEC): +8 за кожну помилку, -1 за кожний успішний фрейм
- **Приймач** (REC): +1 за більшість помилок, +8 за bit error в ACK/EOF, -1 за успішний фрейм
- TEC або REC > 127 → **Error Passive** (вузол надсилає passive error frame замість active)
- TEC або REC > 96 → **Error Warning** (попереджувальний рівень, вузол ще active)
- TEC > 255 → **BUS-OFF** (вузол фізично відключається від шини)
- **TWAI особливість:** `state` залишається `RUNNING` при Error Passive, змінюється на `BUS_OFF` тільки при TEC > 255. Тому застосунок перевіряє лічильники напряму.

---

## 3. Прошивка RECEIVER (`arduino/receiver_ble/receiver_ble.ino`)

### Призначення

RECEIVER — основний вузол моніторингу. Він:
1. Приймає CAN-фрейми з шини через TWAI
2. Зчитує статистику помилок з TWAI кожну секунду
3. Відправляє всі дані через BLE GATT NOTIFY на Android

### Флаги режимів (компілюються в прошивку)

```cpp
#define NO_ACK_MODE 0
// 0 = нормальний режим (TWAI_MODE_NORMAL), RECEIVER відправляє ACK-біти
// 1 = беззвучний режим (TWAI_MODE_NO_ACK), RECEIVER НЕ відправляє ACK
//     → SENDER не отримує підтвердження → його TEC росте → SENDER іде в BUS-OFF
//     → Демонструє ACK Error

#define SPEED_MISMATCH_DEMO 0
// 0 = нормально
// 1 = позначає в stats JSON що зараз SENDER надсилає на 250kbps
//     → Flutter класифікує помилки як stuffingError + formatError
```

### BLE GATT-сервер

```
BLE device name:  "CAN-Monitor"
MTU:              256 байт
Service UUID:     0000FF10-0000-1000-8000-00805F9B34FB
  Char FF11 (NOTIFY): CAN frames — надсилається при кожному отриманому фреймі
  Char FF12 (NOTIFY): TWAI stats — надсилається раз на секунду
```

### JSON формат фрейму (Char FF11)

```json
{"t":"f","id":192,"dlc":8,"data":[10,20,30,40,50,60,70,80],"ts":12345}
{"t":"f","id":192,"dlc":8,"data":[],"ts":12346,"rtr":1}
{"t":"f","id":100663297,"dlc":8,"data":[1,2,3,4,5,6,7,8],"ts":12347,"extd":1}
```

| Поле | Тип | Опис |
|---|---|---|
| `t` | string | завжди `"f"` (frame) |
| `id` | int | CAN ID (11-bit: 0–2047, 29-bit: до 536870911) |
| `dlc` | int | Data Length Code, 0–8 |
| `data` | array | байти даних (порожній для RTR) |
| `ts` | int | `millis()` на момент отримання |
| `rtr` | int? | `1` якщо Remote Transmission Request, відсутній якщо ні |
| `extd` | int? | `1` якщо 29-bit extended ID, відсутній якщо ні |

### JSON формат статистики (Char FF12)

```json
{"t":"s","rx":1234,"txe":8,"rxe":0,"state":"RUNNING","missed":0,"buserr":6,"arb":0,"txfail":0,"ovr":0,"noack":0,"sdemo":0}
```

| Поле | Тип | Джерело в TWAI | Опис |
|---|---|---|---|
| `t` | string | — | завжди `"s"` (stats) |
| `rx` | int | `totalRx` (лічильник) | загальна кількість отриманих фреймів |
| `txe` | int | `tx_error_counter` | TEC — лічильник помилок TX |
| `rxe` | int | `rx_error_counter` | REC — лічильник помилок RX |
| `state` | string | `twai_state_t` | `RUNNING` / `BUS_OFF` / `RECOVERING` / `STOPPED` |
| `missed` | int | `rx_missed_count` | фрейми відкинуті програмною чергою (переповнення) |
| `buserr` | int | `bus_error_count` | кумулятивна сума всіх помилок шини |
| `arb` | int | `arb_lost_count` | програші арбітражу |
| `txfail` | int | `tx_failed_count` | TX-повідомлення скасовані через ліміт помилок |
| `ovr` | int | `rx_overrun_count` | апаратне переповнення RX-буфера |
| `noack` | int | `NO_ACK_MODE` define | `1` якщо прошивка в режимі no-ack |
| `sdemo` | int | `SPEED_MISMATCH_DEMO` define | `1` якщо демонстрація розбіжності швидкостей |

### Автовідновлення після BUS-OFF

```cpp
if (status.state == TWAI_STATE_BUS_OFF) {
    twai_initiate_recovery();  // запускає 128 пауз між фреймами, потім RUNNING
}
```

---

## 4. Прошивка SENDER (`arduino/sender_can/sender_can.ino`)

### Сигнали (всі режими, крім 2)

8 автомобільних сигналів з різною частотою:

| CAN ID | Сигнал | Частота |
|---|---|---|
| 0x0C0 | EngineRPM | 10 Hz |
| 0x0C8 | VehicleSpeed | 10 Hz |
| 0x0D0 | ThrottlePosition | 5 Hz |
| 0x0D8 | CoolantTemp | 5 Hz |
| 0x1A0 | BrakePressure | 2 Hz |
| 0x1A8 | SteeringAngle | 2 Hz |
| 0x2B0 | BatteryVoltage | 1 Hz |
| 0x2B8 | OilPressure | 1 Hz |

### Режими (`#define SEND_MODE`)

**MODE 1 — Normal (500 kbps)**
Надсилає 8 сигналів на відповідних інтервалах. `data[0]` = лічильник, `data[1]` = лічильник×3. Базова демонстрація нормального трафіку.

**MODE 2 — Overload (500 kbps, без затримок)**
Надсилає фрейми без жодної затримки між ними (~3000–5000 фреймів/сек). TX-черга ESP32 збільшена до 32 слотів. Переповнює програмну чергу RECEIVER (`rx_missed_count`) і апаратний буфер (`rx_overrun_count`).

**MODE 3 — Speed Mismatch (250 kbps)**
Той самий патерн що і MODE 1, але TWAI ініціалізується на 250 kbps (`TWAI_TIMING_CONFIG_250KBITS()`). RECEIVER залишається на 500 kbps. Результат: RECEIVER бачить некоректні bit-stuffing патерни і неправильні форматні поля.

**MODE 4 — RTR Demo (500 kbps)**
Нормальні 8 сигналів + кожні 2 секунди надсилає RTR-фрейм на ID `0x0C0` (запит EngineRPM). RTR = Remote Transmission Request, DLC=8 вказує очікуваний розмір відповіді, data порожній.

```cpp
twai_message_t rtr = {};
rtr.identifier       = 0x0C0;
rtr.data_length_code = 8;
rtr.rtr  = 1;  // ← ключовий прапор
rtr.extd = 0;
```

**MODE 5 — Extended ID Demo (500 kbps)**
Нормальні 8 сигналів + кожну секунду 3 фрейми з 29-bit ID у стилі SAE J1939:

```cpp
const uint32_t extIds[] = { 0x18FF0001, 0x18FEE300, 0x0CF00400 };
ext.extd = 1;  // ← 29-bit extended frame
```

`0x18FF0001` = PGN 0xFF00 (Proprietary A) від адреси 0x01  
`0x18FEE300` = PGN 0xFEE3 (Engine Temperature)  
`0x0CF00400` = PGN 0xF004 (Electronic Engine Controller 1)

---

## 5. Flutter-застосунок — архітектура

### Стек

- Flutter 3.x, Dart
- `flutter_blue_plus` — BLE
- BLoC + Provider — стан
- CustomPainter — графік помилок

### Ключові файли

```
lib/
├── domain/
│   ├── models/
│   │   ├── can_frame.dart      — модель одного CAN-фрейму
│   │   └── can_stats.dart      — модель TWAI-статистики
│   ├── source/
│   │   ├── can_frame_source.dart    — абстрактний інтерфейс джерела
│   │   ├── ble_can_source.dart      — BLE реалізація (ESP32)
│   │   └── (can_frame_simulator)    — симулятор для тестування без заліза
│   └── detection/
│       └── can_error_checker.dart   — enum CanErrorType, клас CanErrorInfo
├── presentation/
│   └── screens/
│       └── monitor_screen.dart      — головний екран моніторингу
```

---

## 6. Модель CanFrame (`can_frame.dart`)

```dart
class CanFrame {
  final int id;           // CAN ID (11-bit або 29-bit)
  final int dlc;          // Data Length Code, 0–8
  final List<int> data;   // байти даних
  final int crc;          // XOR-CRC (для відображення, не реальний CAN CRC)
  final DateTime timestamp;
  final bool isCorrupted; // true → симулятор навмисно зіпсував CRC
  final bool isRtr;       // true → Remote Transmission Request
  final bool isExtended;  // true → 29-bit extended ID
  final List<dynamic> errors; // список CanErrorInfo (порожній для нормальних фреймів)
}
```

**Геттери:**
```dart
String get status    // 'ERROR' | 'RTR' | 'EXT' | 'OK'
String get idHex     // '0x0C0' (11-bit) або '0x18FF0001' (29-bit)
String get dataHex   // 'AA BB CC DD ...'
String get timeFormatted // 'HH:MM:SS.mmm'
```

**Рахується як помилка** якщо `isCorrupted == true` АБО `errors.isNotEmpty`.  
RTR і Extended фрейми **не рахуються** як помилки.

---

## 7. Модель CanStats (`can_stats.dart`)

```dart
class CanStats {
  final int rxTotal;         // загальна кількість прийнятих фреймів
  final int txErrorCounter;  // TEC
  final int rxErrorCounter;  // REC
  final String busState;     // 'RUNNING' | 'BUS_OFF' | 'RECOVERING' | 'STOPPED'
  final int rxMissed;        // rx_missed_count
  final int busErrorCount;   // bus_error_count (кумулятивний)
  final int arbLostCount;    // arb_lost_count
  final int txFailedCount;   // tx_failed_count
  final int rxOverrunCount;  // rx_overrun_count
  final bool isNoAckMode;    // прошивка з NO_ACK_MODE=1
  final bool isSpeedMismatchDemo; // прошивка з SPEED_MISMATCH_DEMO=1
  final DateTime timestamp;
}
```

**Геттери стану:**
```dart
bool get isBusOff        => busState == 'BUS_OFF';
bool get isRecovering    => busState == 'RECOVERING';
bool get isRunning       => busState == 'RUNNING';
bool get isErrorPassive  => txErrorCounter > 127 || rxErrorCounter > 127;
bool get isErrorWarning  => !isErrorPassive && (txErrorCounter > 96 || rxErrorCounter > 96);
```

---

## 8. Enum CanErrorType (`can_error_checker.dart`)

```dart
enum CanErrorType {
  none,           // нормальний фрейм
  crcError,       // помилка CRC або прийому (REC↑, TEC=0)
  formatError,    // некоректний формат фрейму (speed mismatch)
  stuffingError,  // порушення bit stuffing (speed mismatch)
  ackError,       // немає підтвердження ACK
  overloadError,  // переповнення черги / апаратний overrun
  formError,      // фіксований формат поля (використовується для arb_lost)
  activeError,    // active error flag (TEC↑ + REC↑)
  passiveError,   // error-passive state (TEC/REC > 127)
  busOffError,    // bus-off (TEC > 255)
}
```

---

## 9. Логіка виявлення помилок в `monitor_screen.dart`

### Джерела даних

1. **Потік фреймів** (`frameStream`) — кожен реальний CAN-фрейм від ESP32
2. **Потік статистики** (`statsStream`) — stats-пакет кожну ~1 секунду

### Буферизація фреймів

Фрейми не йдуть напряму в `setState()`. Вони накопичуються в `_pendingFrames`, а таймер кожні 50 мс (`_flushPending()`) перекладає їх у UI одним оновленням. Це забезпечує плавність при 200+ фреймів/сек.

### Обробка stats-пакету (раз на ~1 сек)

При отриманні нового `CanStats` обчислюються **дельти** відносно попереднього пакету:

```dart
final errorDelta  = stats.busErrorCount - prev.busErrorCount;
final rxDelta     = stats.rxTotal       - prev.rxTotal;
final tecDelta    = stats.txErrorCounter - prev.txErrorCounter;
final recDelta    = stats.rxErrorCounter - prev.rxErrorCounter;
final arbDelta    = stats.arbLostCount   - prev.arbLostCount;
final txFailDelta = stats.txFailedCount  - prev.txFailedCount;
final ovrDelta    = stats.rxOverrunCount - prev.rxOverrunCount;
final missedDelta = stats.rxMissed       - prev.rxMissed;
```

**Оновлення графіку помилок (тільки hardware mode):**
```dart
final total = errorDelta + rxDelta;
final hwRate = total > 0 ? (errorDelta / total) * 100.0 : 0.0;
_errorRateHistory.add(hwRate.clamp(0.0, 100.0));
```

### Синтетичні фрейми-маркери помилок

Коли TWAI фіксує помилку, в `_pendingFrames` вставляється синтетичний фрейм з `id=0x000`, `dlc=0`, `data=[]`, `isCorrupted=false`, але з заповненим `errors` списком. Це робить помилку видимою у списку фреймів і збільшує лічильник `_errorFrames`.

Порядок пріоритетів при формуванні синтетичних фреймів:

```
1. stats.isErrorWarning && !prev.isErrorWarning  → _makeErrorWarningFrame()
2. txFailDelta > 0                               → _makeTxFailFrame()        (ACK Error)
3. ovrDelta > 0                                  → _makeOverrunFrame()       (HW Overrun)
4. missedDelta > 0                               → _makeMissedFrame()        (SW Queue Overflow)
5. residual > 0 && stats.isNoAckMode            → _makeNoAckErrorFrame()    (ACK Error / no-ack mode)
6. residual > 0 && stats.isSpeedMismatchDemo    → _makeStuffingErrorFrame()
                                                   + _makeFormatErrorFrame()  (Speed Mismatch)
7. residual > 0 (звичайний режим)               → _makeTwaiErrorFrame()     (heuristic)
8. arbDelta > 0                                  → _makeArbLostFrame()       (Arb Lost)
```

де `residual = errorDelta - txFailDelta` (помилки, не пояснені точними лічильниками).

### Heuristic класифікація (звичайний режим, `_makeTwaiErrorFrame`)

| TEC delta | REC delta | Тип помилки | Фізична причина |
|---|---|---|---|
| 0 | > 0 | `crcError` | Пошкоджений фрейм (CANH від'єднаний) |
| > 0 | 0 | `ackError` | RECEIVER надіслав error flag, проблема TX |
| > 0 | > 0 | `activeError` | Обидва вузли обмінюються error flags |
| isBusOff | — | `busOffError` | TEC > 255 |
| isErrorPassive | — | `passiveError` | TEC/REC > 127 |
| інше | інше | `activeError` | загальна помилка шини |

---

## 10. Всі 11 типів помилок — повна таблиця

| # | Тип | CanErrorType | Колір у списку | Рахується? | Що відображається |
|---|---|---|---|---|---|
| 1 | CRC/Receive Error | `crcError` | червоний | ✅ | "REC↑N — CRC/form/stuff error in received frame" |
| 2 | Active Error Flag | `activeError` | червоний | ✅ | "TEC↑N REC↑N — active error flag exchange" |
| 3 | Error Passive | `passiveError` | червоний | ✅ | "error-passive (TEC/REC > 127)" + бурштиновий банер |
| 4 | Bus-Off | `busOffError` | червоний | ✅ | "TEC > 255 → BUS-OFF" + червоний банер |
| 5 | ACK Error (no-ack) | `ackError` | червоний | ✅ | "No-ACK mode: RECEIVER not sending ACK bits — SENDER TEC↑N" |
| 6a | Overload SW | `overloadError` | червоний | ✅ | "RX queue overflow — N frame(s) dropped" |
| 6b | Overload HW | `overloadError` | червоний | ✅ | "HW RX overrun ×N — frame(s) dropped at hardware level" |
| 7 | Stuffing Error | `stuffingError` | червоний | ✅ | "bit stuffing violation — SENDER 250k ≠ RECEIVER 500k" |
| 8 | Format Error | `formatError` | червоний | ✅ | "frame format error — EOF/delimiter bits at wrong positions" |
| 9 | RTR Frame | — (не помилка) | **жовтий** | ❌ | нормальний рядок зі статусом "RTR", data порожній |
| 10 | Extended Frame | — (не помилка) | **зелений** | ❌ | нормальний рядок зі статусом "EXT", ID 8 цифр |
| 11 | Error Warning | `activeError` (severity 2) | червоний | ✅ | "Error Warning: TEC X / REC Y exceeded 96" (одноразово) |

### Банери (верх екрану, тільки hardware mode)

| Стан | Колір банеру | Умова |
|---|---|---|
| NO-ACK чіп | червоний чіп | `stats.isNoAckMode` |
| 250k≠500k чіп | жовтий чіп | `stats.isSpeedMismatchDemo` |
| Error Warning | жовтий банер | `stats.isErrorWarning` (TEC/REC 96–127) |
| Error Passive | бурштиновий банер | `stats.isErrorPassive` (TEC/REC > 127) |
| Bus Silent | помаранчевий банер | 3 секунди без фреймів при активному з'єднанні |
| Recovering | бурштиновий банер | `busState == 'RECOVERING'` |
| BUS-OFF | червоний банер | `busState == 'BUS_OFF'` |

Пріоритет (вищий перекриває нижчий): BUS-OFF > RECOVERING > Bus Silent > Error Passive > Error Warning.

---

## 11. BLE-з'єднання (`ble_can_source.dart`)

### Процес підключення

1. Scan для пристроїв → `BleConnectScreen` показує список з RSSI
2. Підключення до обраного пристрою → `BleCanSource.start()`
3. MTU negotiation: запит 247 байт
4. `discoverServices()` → знаходить service `FF10`
5. Subscribe на characteristics `FF11` (frames) і `FF12` (stats)
6. Emit `SourceState.streaming`

### Стани з'єднання (`SourceState`)

```dart
enum SourceState { idle, connecting, connected, streaming, disconnected, error }
```

### Reconnect логіка

Exponential backoff: 4 → 8 → 16 → 32 → 32 секунди між спробами.

### Парсинг фрейму

```dart
final frame = CanFrame.create(
  id:         json['id']  as int,
  dlc:        json['dlc'] as int,
  data:       List<int>.from(json['data'] as List),
  timestamp:  DateTime.now(),
  isRtr:      (json['rtr']  as int?) == 1,
  isExtended: (json['extd'] as int?) == 1,
);
```

### Парсинг stats

```dart
CanStats.fromJson(json)
// json['arb'], json['txfail'], json['ovr'] мають fallback ?? 0
// json['noack'] == 1  → isNoAckMode = true
// json['sdemo'] == 1  → isSpeedMismatchDemo = true
```

---

## 12. Конфігурація прошивок для кожного сценарію

```
Сценарій               SENDER define      RECEIVER define
─────────────────────────────────────────────────────────────
Нормальна робота       SEND_MODE 1        NO_ACK_MODE 0
Overload               SEND_MODE 2        NO_ACK_MODE 0
Speed Mismatch         SEND_MODE 3        SPEED_MISMATCH_DEMO 1
RTR Demo               SEND_MODE 4        NO_ACK_MODE 0
Extended ID Demo       SEND_MODE 5        NO_ACK_MODE 0
ACK Error (No-ACK)     SEND_MODE 1        NO_ACK_MODE 1
```

**Примітка:** `NO_ACK_MODE` і `SPEED_MISMATCH_DEMO` не можна використовувати одночасно. `SPEED_MISMATCH_DEMO` змінює тільки класифікацію в Flutter — сама TWAI-конфігурація RECEIVER залишається 500 kbps.

---

## 13. Фізичні дії для демонстрації

| Дія | Очікуваний результат |
|---|---|
| Від'єднати CANH або CANL | REC росте → `crcError` фрейми + Bus Silent банер через 3 сек |
| Замкнути CANH і CANL на резистор | `bus_error_count` стрибає → `activeError` фрейми |
| Залишити SENDER увімкненим, RECEIVER на NO_ACK_MODE | SENDER TEC 0→128→255, `ackError` фрейми, BUS-OFF, автовідновлення |
| SENDER MODE 2 + RECEIVER нормальний | `rx_missed_count` росте → `overloadError` фрейми |
| SENDER MODE 3 (250k) + RECEIVER SPEED_MISMATCH_DEMO 1 | `stuffingError` + `formatError` фрейми, банер 250k≠500k |
| SENDER MODE 4 | Кожні 2 сек жовтий RTR рядок у списку |
| SENDER MODE 5 | Кожну сек три зелені EXT рядки з J1939 ID |
| Будь-які помилки на рівні 96 < TEC/REC ≤ 127 | Жовтий банер Error Warning + один запис у списку |
