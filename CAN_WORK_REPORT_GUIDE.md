# CAN Debug Pro — Hardware and Software Work Report Guide

## 1. Purpose

This document describes the completed CAN monitoring system as a compact technical context for writing a project report or passing the project to another AI assistant.

The system consists of:

- a physical CAN bus with two ESP32 boards;
- SN65HVD230/VP230 CAN transceivers;
- an ESP32 SENDER that generates CAN traffic;
- an ESP32 RECEIVER that reads CAN traffic and publishes telemetry over BLE;
- a Flutter Android application that monitors, classifies, stores, replays, compares, and exports CAN sessions.

Primary data path:

```text
SENDER ESP32
    -> SN65HVD230
    -> CANH/CANL bus
    -> SN65HVD230
    -> RECEIVER ESP32 / TWAI
    -> BLE GATT notifications
    -> Flutter Android application
    -> session persistence / analytics / replay / export
```

---

## 2. Hardware

### 2.1 Components

| Component | Quantity | Purpose |
|---|---:|---|
| ESP32 DevKit | 2 | SENDER and RECEIVER controllers |
| SN65HVD230/VP230 CAN transceiver | 2 | Converts ESP32 TWAI logic to differential CAN bus signals |
| CANH/CANL wiring | 1 bus | Differential CAN physical medium |
| USB cables | 2 | Programming and Serial Monitor |
| Android phone | 1 | BLE client and Flutter application |
| 120 Ohm termination | 2 total | One terminator at each physical bus end |

The firmware uses the ESP32 built-in TWAI controller, which is the ESP32 implementation of a CAN-compatible two-wire automotive interface.

### 2.2 ESP32 to VP230 wiring

The working wiring for both boards is:

```text
ESP32 GPIO5 / D5  -> VP230 TXD / TX
ESP32 GPIO4 / D4  <- VP230 RXD / RX
ESP32 3.3V        -> VP230 VCC
ESP32 GND         -> VP230 GND
```

The direction matters:

- ESP32 GPIO5 is configured as `CAN_TX_PIN`;
- ESP32 GPIO4 is configured as `CAN_RX_PIN`.

Do not connect D5 of one ESP32 directly to D4 of the other. The two transceivers communicate through the CAN bus pins.

### 2.3 Transceiver-to-transceiver wiring

```text
SENDER VP230 CANH    -> RECEIVER VP230 CANH
SENDER VP230 CANL    -> RECEIVER VP230 CANL
SENDER GND           -> RECEIVER GND
```

CANH must connect to CANH and CANL to CANL. Reversing CANH/CANL prevents valid communication.

The bus should have 120 Ohm termination at both ends. With power disconnected, a correctly terminated bus normally measures approximately 60 Ohm between CANH and CANL because two 120 Ohm terminators are in parallel.

The VP230 module's fixed `121` resistor is the 120 Ohm terminator. The yellow jumper on the relevant module is the `Rs` slope-control connection, not a termination selector.

### 2.4 Nominal CAN configuration

Normal operation uses:

```text
Bitrate: 500 kbit/s
CAN mode: TWAI_MODE_NORMAL
Standard and extended CAN frames accepted
Receiver filter: accept all
```

---

## 3. ESP32 firmware

### 3.1 SENDER firmware

File:

```text
arduino/sender_can/sender_can.ino
```

The SENDER configures:

```cpp
#define CAN_TX_PIN GPIO_NUM_5
#define CAN_RX_PIN GPIO_NUM_4
#define SEND_MODE 1
```

It installs and starts the TWAI driver, then periodically calls `twai_transmit()`.

Normal mode generates eight automotive-style signals:

| CAN ID | Example signal | Period |
|---|---|---:|
| `0x0C0` | Engine RPM | 100 ms |
| `0x0C8` | Vehicle speed | 100 ms |
| `0x0D0` | Throttle position | 200 ms |
| `0x0D8` | Coolant temperature | 200 ms |
| `0x1A0` | Brake pressure | 500 ms |
| `0x1A8` | Steering angle | 500 ms |
| `0x2B0` | Battery voltage | 1000 ms |
| `0x2B8` | Oil pressure | 1000 ms |

Each payload is up to 8 bytes. The first bytes contain changing counters in the normal modes, allowing traffic activity to be observed.

The sender prints transmission and status information at 115200 baud. Telemetry v2 identifies the sender firmware, mode, and bitrate in Serial output.

### 3.2 SENDER demonstration modes

```cpp
#define SEND_MODE 1
```

Normal traffic at 500 kbit/s.

```cpp
#define SEND_MODE 2
```

Overload mode. Frames are transmitted as quickly as possible. This can fill the receiver software queue or hardware RX buffer.

```cpp
#define SEND_MODE 3
```

Speed mismatch mode. The sender uses 250 kbit/s while the receiver remains at 500 kbit/s.

```cpp
#define SEND_MODE 4
```

RTR mode. Normal traffic is combined with Remote Transmission Request frames.

```cpp
#define SEND_MODE 5
```

Extended-ID mode. Normal 11-bit frames are combined with 29-bit IDs such as:

```text
0x18FF0001
0x18FEE300
0x0CF00400
```

### 3.3 RECEIVER firmware

File:

```text
arduino/receiver_ble/receiver_ble.ino
```

The receiver configures the same CAN pins:

```cpp
#define CAN_TX_PIN GPIO_NUM_5
#define CAN_RX_PIN GPIO_NUM_4
```

It initializes:

1. Serial output at 115200 baud;
2. BLE device name `CAN-Monitor`;
3. BLE GATT service `FF10`;
4. frame notification characteristic `FF11`;
5. stats notification characteristic `FF12`;
6. TWAI at 500 kbit/s;
7. an accept-all CAN filter;
8. automatic advertising and reconnect support.

The receiver calls `twai_receive()` in the main loop. For every valid frame it:

1. increments `totalRx`;
2. prints an `RX,...` Serial line;
3. serializes the frame to JSON;
4. sends the JSON through BLE characteristic `FF11` when a client is subscribed.

Every second it calls `twai_get_status_info()` and sends telemetry through `FF12`.

### 3.4 Receiver modes

```cpp
#define NO_ACK_MODE 0
```

Normal mode. The receiver participates in ACK handling.

```cpp
#define NO_ACK_MODE 1
```

No-ACK/listen-only mode. The receiver does not send ACK bits. The sender eventually accumulates transmission errors and can enter BUS-OFF.

```cpp
#define SPEED_MISMATCH_DEMO 0
```

Normal classification mode.

```cpp
#define SPEED_MISMATCH_DEMO 1
```

Tells the Flutter application that the current receiver scenario is the intentional 250k/500k speed mismatch.

---

## 4. CAN and BLE protocol

### 4.1 CAN frame lifecycle

```text
1. SENDER creates a twai_message_t.
2. SENDER fills identifier, DLC, payload, RTR and extended-ID flags.
3. SENDER calls twai_transmit().
4. ESP32 TWAI serializes the frame onto CANH/CANL.
5. Transceivers convert logic-level TX/RX to differential CAN signals.
6. RECEIVER transceiver converts CANH/CANL back to ESP32 logic.
7. RECEIVER TWAI validates the frame and handles ACK/error counters.
8. RECEIVER twai_receive() returns the valid message.
9. RECEIVER increments totalRx and creates JSON.
10. RECEIVER sends JSON through BLE FF11.
11. Flutter receives BLE notification and parses CanFrame.
12. Monitor buffers frames and renders them in batches.
13. Session service stores frames, events and stats snapshots.
14. Summary, health analysis, replay and export use the stored contract.
```

### 4.2 Frame JSON on FF11

Example:

```json
{
  "t": "f",
  "id": 192,
  "dlc": 8,
  "data": [1, 2, 3, 4, 5, 6, 7, 8],
  "ts": 12345
}
```

Optional fields:

```json
{
  "rtr": 1,
  "extd": 1
}
```

- `rtr=1` marks an RTR frame;
- `extd=1` marks a 29-bit extended frame.

### 4.3 Stats JSON on FF12

Telemetry v2 keeps the original counters and adds metadata:

```json
{
  "t": "s",
  "v": 2,
  "node": "receiver",
  "fw": "can-monitor-telemetry-v2",
  "uptime": 123456,
  "bitrate": 500000,
  "reason": "ok",
  "rx": 1234,
  "txe": 0,
  "rxe": 0,
  "state": "RUNNING",
  "missed": 0,
  "buserr": 0,
  "arb": 0,
  "txfail": 0,
  "ovr": 0,
  "noack": 0,
  "sdemo": 0
}
```

Important counters:

| Field | Meaning |
|---|---|
| `rx` | Total received frames |
| `txe` | TEC, transmit error counter |
| `rxe` | REC, receive error counter |
| `missed` | Software RX queue drops |
| `ovr` | Hardware RX overrun |
| `buserr` | Cumulative bus errors |
| `arb` | Arbitration lost count |
| `txfail` | Failed transmissions |
| `state` | `RUNNING`, `BUS_OFF`, `RECOVERING`, or `STOPPED` |
| `reason` | Main current condition such as `ok`, `bus_error`, `rx_missed`, `rx_overrun`, `error_warning`, `error_passive`, `recovering`, or `bus_off` |

### 4.4 BLE GATT layout

```text
Device name: CAN-Monitor
Service:     0000FF10-0000-1000-8000-00805F9B34FB
FF11:        CAN frame notifications
FF12:        telemetry/statistics notifications
```

Flutter scans for the device, connects, discovers services, enables notifications on FF11 and FF12, and reconnects after unexpected disconnects using backoff.

---

## 5. Flutter software architecture

Project directory:

```text
can_debug/
```

### 5.1 Source abstraction

`CanFrameSource` is the common contract for:

- BLE hardware source;
- simulator source;
- replay source.

The contract exposes:

```dart
Stream<CanFrame> get frameStream;
Stream<SourceState> get stateStream;
Stream<CanStats>? get statsStream;
Future<void> start();
Future<void> stop();
void dispose();
```

This allows all sources to use the same monitor/session pipeline.

### 5.2 Important application layers

```text
lib/domain/models/
  can_frame.dart
  can_stats.dart
  can_session.dart
  can_session_event.dart
  can_session_summary.dart

lib/domain/source/
  can_frame_source.dart
  ble_can_source.dart
  replay_can_source.dart

lib/domain/detection/
  can_error_checker.dart
  can_health_analyzer.dart

lib/domain/services/
  can_session_service.dart
  session_summary_builder.dart
  session_analytics.dart
  session_comparison.dart

lib/presentation/screens/
  ble_connect_screen.dart
  monitor_screen.dart
  session_analytics_detail_screen.dart
  replay_screen.dart
```

### 5.3 Live processing

The monitor does not call `setState` for every incoming frame. It first places frames in a pending buffer and flushes them periodically. This limits UI rendering pressure during high-rate traffic.

During a flush the application:

1. updates total and error frame counters;
2. updates error statistics;
3. records frame batch events;
4. records error events;
5. stores the current session snapshot;
6. updates charts and live metrics;
7. checks silent-bus timeout;
8. updates health score.

### 5.4 Session persistence

`CanSessionService` stores sessions in `SharedPreferences` as JSON. A session contains:

- metadata;
- frames;
- stats snapshots;
- normalized events;
- error aggregates;
- schema version;
- active/completed state.

Old sessions are loaded with backward-compatible defaults and migrated to the current schema.

### 5.5 Session events

`CanSessionEvent` supports:

- source start/stop;
- source state changes;
- stats snapshots;
- frame batches;
- detected errors;
- diagnostic events;
- notes.

Diagnostic events include:

- severity;
- cause;
- explanation;
- recommendation.

---

## 6. Error processing algorithm

### 6.1 Three evidence origins

Every application-level `CanErrorInfo` is classified as:

```text
hardware   - direct or exact TWAI hardware signal
inferred   - application conclusion derived from counters/context
simulated  - generated by simulator/error checker
```

This distinction is important for a technical report: the application does not claim that an aggregated `bus_error_count` is always an exact CRC or Form error.

### 6.2 Hardware-origin errors

Hardware-origin examples:

- `tx_failed_count` increment;
- `rx_overrun_count` increment;
- `rx_missed_count` increment;
- explicit NO-ACK scenario;
- BUS_OFF state;
- recovery state.

### 6.3 Inferred errors

The application derives some categories from telemetry deltas:

```text
TEC delta > 0, REC delta = 0
    -> ACK/bit error is inferred

REC delta > 0, TEC delta = 0
    -> CRC/form/stuffing family is inferred

TEC delta > 0, REC delta > 0
    -> active error exchange is inferred

SPEED_MISMATCH_DEMO + bus errors
    -> stuffingError and formatError are inferred
```

### 6.4 Simulated errors

`CanErrorChecker` deterministically generates protocol error examples from frame properties and timestamp seed. These are useful for simulator mode and UI testing, but they are not proof of a physical bus error.

### 6.5 Health rules

`CanHealthAnalyzer` evaluates:

- silent bus;
- bus-off;
- recovery;
- error warning;
- error passive;
- RX overflow;
- high frame error rate;
- reconnect storm.

It returns:

- health score from 0 to 100;
- severity;
- findings;
- explanation;
- recommendation.

---

## 7. Demonstration scenarios

### Normal

```text
Sender:   SEND_MODE 1
Receiver: NO_ACK_MODE 0
          SPEED_MISMATCH_DEMO 0
```

Expected: `TX` on sender, `RX` and growing `rx` on receiver, normal frames on Android.

### ACK error / No ACK

```text
Sender:   SEND_MODE 1
Receiver: NO_ACK_MODE 1
```

Expected: sender TEC rises, transmission failures appear, possible BUS_OFF and recovery. The application marks exact TX failures as hardware-origin and ACK interpretation as hardware/inferred depending on the signal.

### Overload

```text
Sender:   SEND_MODE 2
Receiver: NO_ACK_MODE 0
```

Expected: receiver `missed` or `ovr` counters increase and the application shows hardware-origin RX overflow.

### Speed mismatch

```text
Sender:   SEND_MODE 3
Receiver: SPEED_MISMATCH_DEMO 1
```

Expected: receiver stays at 500 kbit/s, sender uses 250 kbit/s, bus error counters rise, and the app classifies stuffing/format errors as inferred.

### RTR

```text
Sender: SEND_MODE 4
```

Expected: RTR frames appear. RTR is a valid CAN frame type, not an error.

### Extended IDs

```text
Sender: SEND_MODE 5
```

Expected: 29-bit extended frames appear. Extended ID is a valid frame format, not an error.

---

## 8. Verification and acceptance checklist

### Hardware

- [ ] D5/GPIO5 is connected to VP230 TXD/TX on both boards.
- [ ] D4/GPIO4 is connected to VP230 RXD/RX on both boards.
- [ ] CANH is connected to CANH.
- [ ] CANL is connected to CANL.
- [ ] Sender and receiver share GND.
- [ ] Both physical bus ends have 120 Ohm termination.
- [ ] Sender and receiver use the expected bitrate.

### Firmware

- [ ] Sender prints `CAN ready` and a selected mode.
- [ ] Receiver prints `CAN-Monitor` and `CAN ready @ 500 kbit/s`.
- [ ] Receiver prints `BLE: client connected` after Android connection.
- [ ] Receiver prints `RX,...` when CAN traffic arrives.
- [ ] Receiver `STATS` shows growing `rx` in normal mode.
- [ ] Receiver FF12 packet contains telemetry v2 fields after reflashing.

### Android

- [ ] Preflight passes Bluetooth, connection, FF10, FF11 and FF12.
- [ ] Live monitor shows frames and telemetry.
- [ ] Health score updates.
- [ ] Sessions save after stopping monitor.
- [ ] Analytics shows diagnostics and origins.
- [ ] Replay plays frames and supports seek.
- [ ] Comparison shows metric and CAN-ID differences.
- [ ] CSV, JSON and PDF exports contain summary data.

---

## 9. Known limitations

- The receiver exposes aggregate TWAI counters, not a hardware reason code for every individual CAN error.
- Exact distinction between CRC, Form, Stuffing and Bit errors requires richer firmware/controller diagnostics than the current aggregate telemetry.
- Sender telemetry is currently printed to Serial; the BLE telemetry stream is provided by the receiver.
- Physical fault experiments must be performed carefully and only with current-limited, correctly terminated hardware.
- The application distinguishes hardware, inferred and simulated evidence, but inferred categories remain interpretations of telemetry rather than direct controller reason codes.

---

## 10. Exact Report Editing Plan for a 15-Page Limit

This section is an editing map for the final practice report. It is intended to replace verbose or inaccurate material, not to add new pages.

### Replace the hardware wiring text

Replace any wording that describes the ESP32-to-transceiver connection as intentionally crossed with:

```text
ESP32 GPIO5/TWAI TX -> VP230 TXD/TX
ESP32 GPIO4/TWAI RX <- VP230 RXD/RX
VP230 CANH -> CANH bus
VP230 CANL -> CANL bus
Common GND between both nodes
```

Keep the distinction between logic-side TX/RX and differential-side CANH/CANL explicit.

### Replace the error-detection claim

Replace statements such as “the application detects the exact CRC/Form/Stuffing error from the receiver counter” with:

```text
The receiver exposes aggregate TWAI counters. The Flutter application combines these counters with TEC/REC deltas and the active demonstration mode. Therefore, some error labels are direct hardware evidence, while others are application-level inferences.
```

Use the three evidence labels:

```text
hardware  - direct TWAI signal
inferred  - interpretation of counters and context
simulated - generated by the simulator/error checker
```

### Replace the CAN threshold table

Use this compact version:

| Condition | Threshold |
|---|---|
| Error Warning | TEC or REC >= 96 |
| Error Passive | TEC or REC > 127 |
| Bus-Off | TEC >= 256 |
| Recovery | Controller recovery after Bus-Off |

Avoid wording that states `TEC = 255` is already Bus-Off.

### Replace separate feature descriptions with one table

Use one table instead of separate long sections for every mode:

| Scenario | Firmware configuration | Observable result |
|---|---|---|
| Normal | `SEND_MODE 1`, `NO_ACK_MODE 0` | Valid CAN frames |
| No ACK | `NO_ACK_MODE 1` | ACK-related errors, TEC growth, possible Bus-Off |
| Overload | `SEND_MODE 2` | RX missed/overrun counters |
| Speed mismatch | `SEND_MODE 3`, `SPEED_MISMATCH_DEMO 1` | Inferred stuffing/format errors |
| RTR | `SEND_MODE 4` | Valid RTR frames |
| Extended ID | `SEND_MODE 5` | Valid 29-bit frames |

### Replace the software feature list

Replace long UI feature lists with this pipeline:

```text
BLE source -> normalized CanFrame/CanStats -> frame buffer -> error and health analysis -> CanSession -> summary -> analytics/replay/export
```

Then describe only one representative lifecycle in prose.

### Keep only one short limitations paragraph

Use this wording:

```text
The current receiver sends aggregate TWAI telemetry rather than a dedicated reason code for every physical CAN error. Consequently, the application reports direct hardware events separately from inferred classifications. Exact separation of bit, CRC, Form and Stuffing errors would require additional firmware-level diagnostics.
```

### Recommended page allocation

| Section | Target length |
|---|---:|
| Goal and system architecture | 1 page |
| Hardware and wiring | 1.5 pages |
| CAN/TWAI and BLE protocol | 2 pages |
| ESP32 firmware | 2 pages |
| Flutter processing and session lifecycle | 2.5 pages |
| Error classification and scenarios | 2 pages |
| Results and screenshots | 2 pages |
| Limitations and conclusions | 1 page |

The remaining space should be reserved for the title page, contents, diagrams, and references. Do not add full source-code listings; include only short fragments such as pin definitions, `SEND_MODE`, GATT UUIDs, and the telemetry JSON structure.
```old sender```
#include <Arduino.h>
#include "driver/twai.h"

#define CAN_TX_PIN GPIO_NUM_5
#define CAN_RX_PIN GPIO_NUM_4

uint32_t txCount = 0;
uint8_t counter = 0;
unsigned long lastTx = 0;
unsigned long lastStats = 0;

const char* busStateName(twai_state_t s) {
  switch (s) {
    case TWAI_STATE_STOPPED:    return "STOPPED";
    case TWAI_STATE_RUNNING:    return "RUNNING";
    case TWAI_STATE_BUS_OFF:    return "BUS_OFF";
    case TWAI_STATE_RECOVERING: return "RECOVERING";
    default:                    return "UNKNOWN";
  }
}

void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.println("SENDER MIN ready");

  twai_general_config_t g = TWAI_GENERAL_CONFIG_DEFAULT(CAN_TX_PIN, CAN_RX_PIN, TWAI_MODE_NORMAL);
  twai_timing_config_t  t = TWAI_TIMING_CONFIG_500KBITS();
  twai_filter_config_t  f = TWAI_FILTER_CONFIG_ACCEPT_ALL();

  if (twai_driver_install(&g, &t, &f) != ESP_OK) {
    Serial.println("SENDER: CAN init FAILED");
    return;
  }
  if (twai_start() != ESP_OK) {
    Serial.println("SENDER: CAN start FAILED");
    return;
  }

  Serial.println("SENDER: CAN @ 500kbps");
  Serial.println("FMT: TX,id,dlc,err,seq | SENDER_STATS,tx,tec,state");
}

void loop() {
  unsigned long now = millis();

  // 10 кадрів/сек
  if (now - lastTx >= 100) {
    lastTx = now;

    twai_message_t msg = {};
    msg.identifier = 0x7FF;
    msg.data_length_code = 8;
    msg.extd = 0;
    msg.rtr = 0;

    for (int i = 0; i < 8; i++) {
      msg.data[i] = counter + i;
    }

    esp_err_t e = twai_transmit(&msg, pdMS_TO_TICKS(10));
    if (e == ESP_OK) {
      txCount++;
      Serial.printf("TX,0x%03X,%d,0,%lu\n", msg.identifier, msg.data_length_code, (unsigned long)txCount);
    } else {
      Serial.printf("TX,0x%03X,%d,%d,%lu\n", msg.identifier, msg.data_length_code, (int)e, (unsigned long)txCount);
    }

    counter++;
  }

  if (now - lastStats >= 1000) {
    lastStats = now;
    twai_status_info_t st;
    twai_get_status_info(&st);
    Serial.printf("SENDER_STATS,%lu,%lu,%s\n",
      (unsigned long)txCount,
      (unsigned long)st.tx_error_counter,
      busStateName(st.state));

    if (st.state == TWAI_STATE_BUS_OFF) {
      Serial.println("SENDER: BUS_OFF -> RECOVERY");
      twai_initiate_recovery();
    }
  }
}

```olde receiver```
#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include "driver/twai.h"

// CAN pins (для ваших VP230 модулів)
#define CAN_TX_PIN GPIO_NUM_5
#define CAN_RX_PIN GPIO_NUM_4

// Режими експерименту
#define NO_ACK_MODE 0
#define SPEED_MISMATCH_DEMO 0

// BLE UUIDs (мають збігатися з Flutter)
#define SERVICE_UUID      "0000FF10-0000-1000-8000-00805F9B34FB"
#define CHAR_FRAMES_UUID  "0000FF11-0000-1000-8000-00805F9B34FB"
#define CHAR_STATS_UUID   "0000FF12-0000-1000-8000-00805F9B34FB"

BLEServer* g_server = nullptr;
BLECharacteristic* g_framesChar = nullptr;
BLECharacteristic* g_statsChar = nullptr;

bool g_deviceConnected = false;
bool g_oldConnected = false;

uint32_t g_totalRx = 0;
unsigned long g_lastStatsMs = 0;

const char* busStateName(twai_state_t s) {
  switch (s) {
    case TWAI_STATE_STOPPED:    return "STOPPED";
    case TWAI_STATE_RUNNING:    return "RUNNING";
    case TWAI_STATE_BUS_OFF:    return "BUS_OFF";
    case TWAI_STATE_RECOVERING: return "RECOVERING";
    default:                    return "UNKNOWN";
  }
}

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* s) override {
    (void)s;
    g_deviceConnected = true;
    Serial.println("BLE: client connected");
  }

  void onDisconnect(BLEServer* s) override {
    (void)s;
    g_deviceConnected = false;
    Serial.println("BLE: client disconnected");
  }
};

String buildFrameJson(const twai_message_t& msg) {
  String s;
  s.reserve(120);

  s  = "{\"t\":\"f\",\"id\":";
  s += msg.identifier;
  s += ",\"dlc\":";
  s += msg.data_length_code;
  s += ",\"data\":[";

  if (!msg.rtr) {
    for (uint8_t i = 0; i < msg.data_length_code; i++) {
      if (i) s += ",";
      s += msg.data[i];
    }
  }

  s += "],\"ts\":";
  s += millis();
  if (msg.rtr)  s += ",\"rtr\":1";
  if (msg.extd) s += ",\"extd\":1";
  s += "}";

  return s;
}

String buildStatsJson(const twai_status_info_t& st) {
  String s;
  s.reserve(160);

  s  = "{\"t\":\"s\",\"rx\":";
  s += g_totalRx;
  s += ",\"txe\":";
  s += st.tx_error_counter;
  s += ",\"rxe\":";
  s += st.rx_error_counter;
  s += ",\"state\":\"";
  s += busStateName(st.state);
  s += "\",\"missed\":";
  s += st.rx_missed_count;
  s += ",\"buserr\":";
  s += st.bus_error_count;
  s += ",\"arb\":";
  s += st.arb_lost_count;
  s += ",\"txfail\":";
  s += st.tx_failed_count;
  s += ",\"ovr\":";
  s += st.rx_overrun_count;
  s += ",\"noack\":";
  s += NO_ACK_MODE ? 1 : 0;
  s += ",\"sdemo\":";
  s += SPEED_MISMATCH_DEMO ? 1 : 0;
  s += "}";

  return s;
}

void bleNotify(BLECharacteristic* ch, const String& json) {
  ch->setValue((uint8_t*)json.c_str(), json.length());
  ch->notify();
}

void setupBle() {
  BLEDevice::init("CAN-Monitor");
  BLEDevice::setMTU(256);

  g_server = BLEDevice::createServer();
  g_server->setCallbacks(new ServerCallbacks());

  BLEService* service = g_server->createService(SERVICE_UUID);

  g_framesChar = service->createCharacteristic(
    CHAR_FRAMES_UUID,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  g_framesChar->addDescriptor(new BLE2902());

  g_statsChar = service->createCharacteristic(
    CHAR_STATS_UUID,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  g_statsChar->addDescriptor(new BLE2902());

  service->start();

  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(true);
  adv->setMinPreferred(0x06);
  BLEDevice::startAdvertising();

  Serial.println("BLE: advertising CAN-Monitor");
}

bool setupCan() {
  twai_general_config_t g = TWAI_GENERAL_CONFIG_DEFAULT(
    CAN_TX_PIN,
    CAN_RX_PIN,
    NO_ACK_MODE ? TWAI_MODE_NO_ACK : TWAI_MODE_NORMAL
  );
  twai_timing_config_t t = TWAI_TIMING_CONFIG_500KBITS();
  twai_filter_config_t f = TWAI_FILTER_CONFIG_ACCEPT_ALL();

  if (twai_driver_install(&g, &t, &f) != ESP_OK) return false;
  if (twai_start() != ESP_OK) return false;
  return true;
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  Serial.println("=== RECEIVER BLE+CAN clean ===");
  setupBle();

  if (!setupCan()) {
    Serial.println("CAN init FAILED");
    return;
  }

  Serial.println("CAN ready @ 500kbps");
  Serial.println("FMT: RX,... | STATS,...");
}

void loop() {
  // 1) Прийом CAN кадру
  twai_message_t msg;
  esp_err_t r = twai_receive(&msg, pdMS_TO_TICKS(10));
  if (r == ESP_OK) {
    g_totalRx++;

    Serial.printf("RX,0x%03X,%d", msg.identifier, msg.data_length_code);
    for (int i = 0; i < msg.data_length_code; i++) {
      Serial.printf(",%02X", msg.data[i]);
    }
    Serial.println();

    if (msg.rtr)  Serial.println("ALERT,RTR_FRAME");
    if (msg.extd) Serial.println("ALERT,EXTENDED_ID");

    if (g_deviceConnected) {
      String json = buildFrameJson(msg);
      bleNotify(g_framesChar, json);
    }
  }

  // 2) Моніторинг стану шини
  twai_status_info_t st;
  twai_get_status_info(&st);

  static twai_state_t lastState = TWAI_STATE_STOPPED;
  if (st.state != lastState) {
    Serial.printf("ALERT,BUS_STATE_CHANGE,%s\n", busStateName(st.state));
    lastState = st.state;
  }

  if (st.state == TWAI_STATE_BUS_OFF) {
    Serial.println("ALERT,INITIATING_RECOVERY");
    twai_initiate_recovery();
  }

  // 3) Статистика раз на секунду
  unsigned long now = millis();
  if (now - g_lastStatsMs >= 1000) {
    g_lastStatsMs = now;

    Serial.printf("STATS,%lu,%lu,%lu,%lu,%s,%lu,%lu,%lu\n",
      now,
      g_totalRx,
      st.tx_error_counter,
      st.rx_error_counter,
      busStateName(st.state),
      st.rx_missed_count,
      st.arb_lost_count,
      st.bus_error_count
    );

    if (g_deviceConnected) {
      String statsJson = buildStatsJson(st);
      bleNotify(g_statsChar, statsJson);
    }
  }

  // 4) Re-advertise після disconnect
  if (!g_deviceConnected && g_oldConnected) {
    delay(200);
    g_server->startAdvertising();
    Serial.println("BLE: re-advertising");
    g_oldConnected = false;
  }
  if (g_deviceConnected && !g_oldConnected) {
    g_oldConnected = true;
  }
}