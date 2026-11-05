/**
 * CAN-Monitor — ESP32 RECEIVER + BLE
 * Phase 2: GATT server, two notify characteristics (Frames + Stats)
 *
 * Wiring (inverted TX/RX — verified on these specific modules):
 *   ESP32 GPIO5 (TX) → SN65HVD230 RX
 *   ESP32 GPIO4 (RX) → SN65HVD230 TX
 *
 * BLE GATT layout:
 *   Service  0000FF10-0000-1000-8000-00805F9B34FB
 *   Char     0000FF11-0000-1000-8000-00805F9B34FB  NOTIFY  — CAN frames
 *   Char     0000FF12-0000-1000-8000-00805F9B34FB  NOTIFY  — TWAI stats (1/sec)
 *
 * Frame JSON:  {"t":"f","id":192,"dlc":8,"data":[144,145,146,147,148,149,150,151],"ts":12345}
 * Stats JSON:  {"t":"s","rx":1234,"txe":0,"rxe":0,"state":"RUNNING","missed":0,"buserr":0,"arb":0,"txfail":0,"ovr":0}
 *
 * Verification: nRF Connect → find "CAN-Monitor" → subscribe to both chars → see JSON stream.
 */

#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include "driver/twai.h"

// ── CAN pins ────────────────────────────────────────────────────────────────
#define CAN_TX_PIN GPIO_NUM_5
#define CAN_RX_PIN GPIO_NUM_4

// ── Experiment mode ──────────────────────────────────────────────────────────
// Set to 1 to enter No-ACK (listen-only) mode: RECEIVER stops sending ACK bits.
// SENDER will not get acknowledgement → its TEC rises → SENDER goes BUS-OFF.
// Demonstrates ACK Error scenario. Reflash with NO_ACK_MODE 0 to restore.
#define NO_ACK_MODE 0

// Set to 1 when SENDER is flashed at 250 kbps (SEND_MODE 3) but RECEIVER stays at 500 kbps.
// RECEIVER will see bit stuffing violations and frame format errors.
// Flutter reads this flag and classifies bus errors as stuffingError / formatError.
#define SPEED_MISMATCH_DEMO 0

// ── BLE UUIDs ────────────────────────────────────────────────────────────────
#define SERVICE_UUID   "0000FF10-0000-1000-8000-00805F9B34FB"
#define CHAR_FRAMES_UUID "0000FF11-0000-1000-8000-00805F9B34FB"
#define CHAR_STATS_UUID  "0000FF12-0000-1000-8000-00805F9B34FB"

// ── BLE globals ──────────────────────────────────────────────────────────────
BLEServer*         pServer        = nullptr;
BLECharacteristic* pCharFrames    = nullptr;
BLECharacteristic* pCharStats     = nullptr;
bool               deviceConnected = false;
bool               oldConnected    = false;

// ── CAN counters ─────────────────────────────────────────────────────────────
uint32_t totalRx   = 0;
unsigned long lastStats = 0;

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pSvr) override {
    deviceConnected = true;
    Serial.println("BLE: client connected");
  }
  void onDisconnect(BLEServer* pSvr) override {
    deviceConnected = false;
    Serial.println("BLE: client disconnected");
  }
};

// ── Helpers ──────────────────────────────────────────────────────────────────
const char* busStateName(twai_state_t s) {
  switch (s) {
    case TWAI_STATE_STOPPED:    return "STOPPED";
    case TWAI_STATE_RUNNING:    return "RUNNING";
    case TWAI_STATE_BUS_OFF:    return "BUS_OFF";
    case TWAI_STATE_RECOVERING: return "RECOVERING";
    default:                    return "UNKNOWN";
  }
}

// Build frame JSON: {"t":"f","id":NNN,"dlc":N,"data":[...],"ts":NNN}
// Max length with dlc=8 and full values: ~80 chars — fits in MTU 256.
String buildFrameJson(const twai_message_t& msg) {
  String s;
  s.reserve(100);
  s  = "{\"t\":\"f\",\"id\":";
  s += msg.identifier;
  s += ",\"dlc\":";
  s += msg.data_length_code;
  s += ",\"data\":[";
  // RTR frames carry no data payload even if dlc > 0
  if (!msg.rtr) {
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

const char* busReasonCode(const twai_status_info_t& st) {
  if (st.state == TWAI_STATE_BUS_OFF) return "bus_off";
  if (st.state == TWAI_STATE_RECOVERING) return "recovering";
  if (st.tx_error_counter > 127 || st.rx_error_counter > 127) return "error_passive";
  if (st.tx_error_counter > 96 || st.rx_error_counter > 96) return "error_warning";
  if (st.rx_overrun_count > 0) return "rx_overrun";
  if (st.rx_missed_count > 0) return "rx_missed";
  if (st.bus_error_count > 0) return "bus_error";
  return "ok";
}

// Stats JSON keeps the original fields and adds v/node/fw/uptime/bitrate/reason.
String buildStatsJson(const twai_status_info_t& st) {
  String s;
  s.reserve(220);
  s  = "{\"t\":\"s\",\"v\":2,\"node\":\"receiver\",\"fw\":\"can-monitor-telemetry-v2\",\"uptime\":";
  s += millis();
  s += ",\"bitrate\":500000,\"reason\":\"";
  s += busReasonCode(st);
  s += "\",\"rx\":";
  s += totalRx;
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
  s += '}';
  return s;
}

void notifyString(BLECharacteristic* pChar, const String& json) {
  pChar->setValue((uint8_t*)json.c_str(), json.length());
  pChar->notify();
}

// ── Setup ─────────────────────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.println("=== CAN-Monitor RECEIVER+BLE ===");
  Serial.printf("Free heap before BLE: %lu\n", (unsigned long)ESP.getFreeHeap());
  Serial.flush();

  // ── Init BLE first (needs heap grabbed early) ─────────────────────────────
  BLEDevice::init("CAN-Monitor");
  Serial.println("BLE device init OK"); Serial.flush();
  BLEDevice::setMTU(256);
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());
  Serial.println("BLE server OK"); Serial.flush();
  BLEService* pService = pServer->createService(SERVICE_UUID);
  // Frames characteristic (NOTIFY)
  pCharFrames = pService->createCharacteristic(
    CHAR_FRAMES_UUID,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pCharFrames->addDescriptor(new BLE2902());
  // Stats characteristic (NOTIFY)
  pCharStats = pService->createCharacteristic(
    CHAR_STATS_UUID,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pCharStats->addDescriptor(new BLE2902());
  pService->start();

  BLEAdvertising* pAdv = BLEDevice::getAdvertising();
  pAdv->addServiceUUID(SERVICE_UUID);
  pAdv->setScanResponse(true);
  pAdv->setMinPreferred(0x06); // helps iPhone connections
  BLEDevice::startAdvertising();
  Serial.println("BLE advertising as \"CAN-Monitor\""); Serial.flush();

  // ── Init TWAI (CAN) after BLE ─────────────────────────────────────────────
  Serial.printf("Free heap before CAN: %lu\n", (unsigned long)ESP.getFreeHeap()); Serial.flush();

  twai_general_config_t g = TWAI_GENERAL_CONFIG_DEFAULT(
    CAN_TX_PIN, CAN_RX_PIN,
    NO_ACK_MODE ? TWAI_MODE_NO_ACK : TWAI_MODE_NORMAL
  );
  Serial.printf("CAN mode: %s\n", NO_ACK_MODE ? "NO_ACK (listen-only)" : "NORMAL");
  twai_timing_config_t  t = TWAI_TIMING_CONFIG_500KBITS();
  twai_filter_config_t  f = TWAI_FILTER_CONFIG_ACCEPT_ALL();

  if (twai_driver_install(&g, &t, &f) != ESP_OK) {
    Serial.println("CAN init FAILED"); Serial.flush(); return;
  }
  if (twai_start() != ESP_OK) {
    Serial.println("CAN start FAILED"); Serial.flush(); return;
  }
  Serial.println("CAN ready @ 500 kbit/s");
  Serial.println("FMT: RX,id,dlc,data... | STATS,... | ALERT,...");
}

// ── Loop ──────────────────────────────────────────────────────────────────────
void loop() {
  twai_message_t msg;
  esp_err_t res = twai_receive(&msg, pdMS_TO_TICKS(10));

  if (res == ESP_OK) {
    totalRx++;

    // Serial debug
    Serial.printf("RX,0x%03X,%d", msg.identifier, msg.data_length_code);
    for (int i = 0; i < msg.data_length_code; i++) Serial.printf(",%02X", msg.data[i]);
    Serial.println();

    if (msg.rtr)  Serial.println("ALERT,RTR_FRAME");
    if (msg.extd) Serial.println("ALERT,EXTENDED_ID");

    // BLE notify — only when client is subscribed
    if (deviceConnected) {
      String json = buildFrameJson(msg);
      notifyString(pCharFrames, json);
    }
  }

  // ── Bus state monitoring ──────────────────────────────────────────────────
  twai_status_info_t status;
  twai_get_status_info(&status);

  static twai_state_t lastState = TWAI_STATE_STOPPED;
  if (status.state != lastState) {
    Serial.printf("ALERT,BUS_STATE_CHANGE,%s\n", busStateName(status.state));
    lastState = status.state;
  }

  if (status.state == TWAI_STATE_BUS_OFF) {
    Serial.println("ALERT,INITIATING_RECOVERY");
    twai_initiate_recovery();
  }

  // ── Stats once per second ─────────────────────────────────────────────────
  unsigned long now = millis();
  if (now - lastStats >= 1000) {
    lastStats = now;

    twai_status_info_t st;
    twai_get_status_info(&st);

    // Serial stats
    Serial.printf("STATS,%lu,%lu,%lu,%lu,%s,%lu,%lu,%lu\n",
      now, totalRx,
      st.tx_error_counter, st.rx_error_counter,
      busStateName(st.state),
      st.rx_missed_count, st.arb_lost_count, st.bus_error_count);

    // BLE stats notify
    if (deviceConnected) {
      String json = buildStatsJson(st);
      notifyString(pCharStats, json);
    }
  }

  // ── Re-advertise after disconnect ─────────────────────────────────────────
  if (!deviceConnected && oldConnected) {
    delay(200);
    pServer->startAdvertising();
    Serial.println("BLE: re-advertising");
    oldConnected = false;
  }
  if (deviceConnected && !oldConnected) {
    oldConnected = true;
  }
}
