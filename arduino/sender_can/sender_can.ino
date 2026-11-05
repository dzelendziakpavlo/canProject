/**
 * CAN-Monitor — ESP32 SENDER
 *
 * Wiring (inverted TX/RX — same as receiver):
 *   ESP32 GPIO5 (TX) → SN65HVD230 RX
 *   ESP32 GPIO4 (RX) → SN65HVD230 TX
 *
 * SEND_MODE 1 — Normal: sends 8 signals at ~10 Hz each (EngineRPM, Speed, etc.)
 * SEND_MODE 2 — Overload: sends at maximum rate to overflow RECEIVER's RX queue
 *               → triggers rx_missed_count / rx_overrun_count on RECEIVER
 *               → demonstrates overloadError in the Flutter app
 * SEND_MODE 3 — Speed Mismatch: sends at 250 kbps while RECEIVER expects 500 kbps
 *               → RECEIVER sees bit stuffing violations and frame format errors
 *               → demonstrates stuffingError + formatError in the Flutter app
 *               → Flash RECEIVER with SPEED_MISMATCH_DEMO 1 so app classifies correctly
 * SEND_MODE 4 — RTR Demo: sends normal frames mixed with RTR frames every 2 s
 *               → RTR = Remote Transmission Request (no data payload, requests data)
 *               → demonstrates RTR frame type in the Flutter app
 * SEND_MODE 5 — Extended ID Demo: sends 29-bit identifier frames (SAE J1939 style)
 *               → mixed with standard 11-bit frames
 *               → demonstrates Extended frame type in the Flutter app
 *               → RECEIVER sees bit stuffing violations and frame format errors
 *               → demonstrates stuffingError + formatError in the Flutter app
 *               → Flash RECEIVER with SPEED_MISMATCH_DEMO 1 so app classifies correctly
 */

#include <Arduino.h>
#include "driver/twai.h"

// ── Config ────────────────────────────────────────────────────────────────────
#define CAN_TX_PIN  GPIO_NUM_5
#define CAN_RX_PIN  GPIO_NUM_4

// 1 = normal demo (10 Hz per signal)
// 2 = overload (max rate, no delay between frames)
// 3 = speed mismatch: sends at 250 kbps (RECEIVER must stay at 500 kbps)
// 4 = RTR demo: normal frames + RTR request every 2 s
// 5 = Extended ID demo: 11-bit standard + 29-bit extended (J1939-style) frames
#define SEND_MODE 1

// ── Signal table (MODE 1) ─────────────────────────────────────────────────────
struct Signal {
  uint32_t id;
  uint8_t  dlc;
  uint8_t  data[8];
  uint32_t intervalMs;
};

Signal signals[] = {
  { 0x0C0, 8, {0,0,0,0,0,0,0,0}, 100 },  // EngineRPM   10 Hz
  { 0x0C8, 8, {0,0,0,0,0,0,0,0}, 100 },  // VehicleSpeed 10 Hz
  { 0x0D0, 8, {0,0,0,0,0,0,0,0}, 200 },  // ThrottlePos  5 Hz
  { 0x0D8, 8, {0,0,0,0,0,0,0,0}, 200 },  // CoolantTemp  5 Hz
  { 0x1A0, 8, {0,0,0,0,0,0,0,0}, 500 },  // BrakePress   2 Hz
  { 0x1A8, 8, {0,0,0,0,0,0,0,0}, 500 },  // SteeringAngle 2 Hz
  { 0x2B0, 8, {0,0,0,0,0,0,0,0}, 1000 }, // BattVoltage  1 Hz
  { 0x2B8, 8, {0,0,0,0,0,0,0,0}, 1000 }, // OilPressure  1 Hz
};
const int NUM_SIGNALS = sizeof(signals) / sizeof(signals[0]);
unsigned long lastSent[8] = {0};
uint8_t counters[8] = {0};

uint32_t totalTx = 0;
unsigned long lastStats = 0;

// ── Setup ─────────────────────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.printf("=== CAN SENDER | MODE %d ===\n", SEND_MODE);
  Serial.printf("TELEMETRY,v=2,node=sender,fw=can-sender-v2,bitrate=%s,mode=%d\n",
    SEND_MODE == 3 ? "250000" : "500000", SEND_MODE);

  twai_general_config_t g = TWAI_GENERAL_CONFIG_DEFAULT(CAN_TX_PIN, CAN_RX_PIN, TWAI_MODE_NORMAL);
  twai_filter_config_t  f = TWAI_FILTER_CONFIG_ACCEPT_ALL();

#if SEND_MODE == 3
  // 250 kbps — intentional mismatch with RECEIVER at 500 kbps
  twai_timing_config_t t = TWAI_TIMING_CONFIG_250KBITS();
#else
  twai_timing_config_t t = TWAI_TIMING_CONFIG_500KBITS();
#endif

  // MODE 2: large TX queue to sustain burst sending
  if (SEND_MODE == 2) {
    g.tx_queue_len = 32;
    g.rx_queue_len = 1;
  }

  ESP_ERROR_CHECK(twai_driver_install(&g, &t, &f));
  ESP_ERROR_CHECK(twai_start());

  Serial.printf("CAN ready @ %s | mode %d\n",
    SEND_MODE == 3 ? "250 kbit/s (MISMATCH)" : "500 kbit/s", SEND_MODE);
}

// ── Send one frame ─────────────────────────────────────────────────────────────
void sendFrame(uint32_t id, uint8_t dlc, uint8_t* data) {
  twai_message_t msg = {};
  msg.identifier       = id;
  msg.data_length_code = dlc;
  msg.extd = 0;
  msg.rtr  = 0;
  for (int i = 0; i < dlc; i++) msg.data[i] = data[i];

  if (twai_transmit(&msg, pdMS_TO_TICKS(2)) == ESP_OK) {
    totalTx++;
  }
}

// ── Loop ──────────────────────────────────────────────────────────────────────
void loop() {
#if SEND_MODE == 2
  // ── Overload: blast frames with no delay — fills RECEIVER RX queue ────────
  static uint8_t idx = 0;
  static uint8_t val = 0;
  uint8_t data[8];
  for (int i = 0; i < 8; i++) data[i] = val + i;
  sendFrame(signals[idx].id, 8, data);
  idx = (idx + 1) % NUM_SIGNALS;
  val++;
  // No delay — ~3000–5000 frames/sec at 500 kbps

#elif SEND_MODE == 4
  // ── RTR Demo: normal frames + RTR request every 2 s ──────────────────────
  // RTR = Remote Transmission Request: frame with no data, requests a response
  // from a node that "owns" the given ID. Useful for on-demand data polling.
  static unsigned long lastRtr = 0;
  unsigned long now = millis();

  // Send normal signals at regular intervals
  for (int i = 0; i < NUM_SIGNALS; i++) {
    if (now - lastSent[i] >= signals[i].intervalMs) {
      lastSent[i] = now;
      counters[i]++;
      signals[i].data[0] = counters[i];
      signals[i].data[1] = (counters[i] * 3) & 0xFF;
      sendFrame(signals[i].id, signals[i].dlc, signals[i].data);
    }
  }

  // Send RTR frame every 2 seconds — request EngineRPM (0x0C0) from bus
  if (now - lastRtr >= 2000) {
    lastRtr = now;
    twai_message_t rtr = {};
    rtr.identifier       = 0x0C0;  // requesting EngineRPM signal
    rtr.data_length_code = 8;      // expected response length
    rtr.rtr  = 1;                  // Remote Transmission Request flag
    rtr.extd = 0;
    if (twai_transmit(&rtr, pdMS_TO_TICKS(5)) == ESP_OK) {
      totalTx++;
      Serial.println("TX RTR 0x0C0 (requesting EngineRPM)");
    }
  }

#elif SEND_MODE == 5
  // ── Extended ID Demo: standard 11-bit + 29-bit J1939-style frames ─────────
  // J1939 PGN examples: 0x18FF0001 (proprietary A), 0x18FEE300 (engine temp)
  static unsigned long lastExt = 0;
  static uint8_t extVal = 0;
  unsigned long now = millis();

  // Standard 11-bit frames at normal rate
  for (int i = 0; i < NUM_SIGNALS; i++) {
    if (now - lastSent[i] >= signals[i].intervalMs) {
      lastSent[i] = now;
      counters[i]++;
      signals[i].data[0] = counters[i];
      signals[i].data[1] = (counters[i] * 3) & 0xFF;
      sendFrame(signals[i].id, signals[i].dlc, signals[i].data);
    }
  }

  // 29-bit extended frames every 1 s — J1939-style IDs
  if (now - lastExt >= 1000) {
    lastExt = now;
    extVal++;

    // J1939 PGN 0xFF00 (proprietary) from source address 0x01
    const uint32_t extIds[] = { 0x18FF0001, 0x18FEE300, 0x0CF00400 };
    for (int i = 0; i < 3; i++) {
      twai_message_t ext = {};
      ext.identifier       = extIds[i];
      ext.data_length_code = 8;
      ext.extd = 1;   // 29-bit extended frame
      ext.rtr  = 0;
      for (int b = 0; b < 8; b++) ext.data[b] = extVal + b;
      if (twai_transmit(&ext, pdMS_TO_TICKS(5)) == ESP_OK) {
        totalTx++;
        Serial.printf("TX EXT 0x%08X\n", extIds[i]);
      }
    }
  }

#else
  // ── MODE 1 (500 kbps normal) and MODE 3 (250 kbps mismatch) ─────────────
  unsigned long now = millis();
  for (int i = 0; i < NUM_SIGNALS; i++) {
    if (now - lastSent[i] >= signals[i].intervalMs) {
      lastSent[i] = now;
      counters[i]++;
      signals[i].data[0] = counters[i];
      signals[i].data[1] = (counters[i] * 3) & 0xFF;
      sendFrame(signals[i].id, signals[i].dlc, signals[i].data);
    }
  }
#endif

  // ── Stats every second ────────────────────────────────────────────────────
  unsigned long now2 = millis();
  if (now2 - lastStats >= 1000) {
    lastStats = now2;
    twai_status_info_t st;
    twai_get_status_info(&st);
    Serial.printf("SENDER STATS: tx=%lu tec=%lu state=%s\n",
      totalTx, st.tx_error_counter,
      st.state == TWAI_STATE_BUS_OFF ? "BUS_OFF" :
      st.state == TWAI_STATE_RUNNING ? "RUNNING" : "OTHER");

    // Auto-recovery if bus-off
    if (st.state == TWAI_STATE_BUS_OFF) {
      Serial.println("SENDER: BUS_OFF — initiating recovery");
      twai_initiate_recovery();
    }
  }
}
