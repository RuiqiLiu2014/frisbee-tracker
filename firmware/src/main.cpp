// Frisbee Tracker — firmware (Seeed XIAO nRF52840 Sense + LSM6DS3)
//
// STORE-AND-FORWARD: a thrown disc leaves BLE range mid-flight, so we never
// stream live. Instead the board detects a throw, records it to an on-device
// RAM ring buffer, and forwards queued throws over BLE once the disc is back in
// range. This lets throws survive going out of range AND lets several throws
// queue up while the phone is far away.
//
// The BLE throughput recipe (2 Mbps PHY, DLE, MTU 247, 7.5 ms interval,
// BANDWIDTH_MAX, notify() flow-control, no per-packet delays) is copied from the
// PingPongTracker firmware, which sustains 1660 Hz. That is what keeps uploads
// fast; the old Arduino build was slow because of the default ~30-50 ms
// connection interval + String building + delay() per packet.
//
// Protocol (matches app/lib/services/frisbee_ble.dart), one packet per notify:
//   0x01 BEGIN   [u8][u32 throwId][u16 rateHz][u16 totalSamples]
//   0x02 SAMPLES [u8][u16 firstIndex][u8 n] + n*(int16 ax,ay,az,gx,gy,gz)
//   0x03 END     [u8][u32 throwId][u16 count][f32 peakA_g][f32 peakG_dps]
//                [u32 flightMs][u8 labelLen][label...]
//   0x10 STATUS  [u8][u8 batt%][u16 mV][u8 queuedThrows]     (idle heartbeat)
// App -> device (ASCII, newline): "ACK:<id>", "LABEL:<s>", "CLEAR",
//   "RATE:<hz>", "MAXMS:<ms>".

#include <Arduino.h>
#include <bluefruit.h>
#include "LSM6DS3.h"
#include "Wire.h"
#include <math.h>

// ---------------------------------------------------------------------------
// IMU (LSM6DS3TR-C on the XIAO Sense internal I2C -> Wire1 via the Seeed lib)
// ---------------------------------------------------------------------------
LSM6DS3 myIMU(I2C_MODE, 0x6A);
#define LSM6DS3_STATUS_REG 0x1E // bit0 XLDA (accel new)
#define LSM6DS3_OUTX_L_G 0x22   // gx,gy,gz,ax,ay,az contiguous 0x22..0x2D

// Raw int16 count -> engineering units (must match the app's constants).
static const float ACCEL_SCALE_G = 0.488f / 1000.0f;  // +/-16 g
static const float GYRO_SCALE_DPS = 70.0f / 1000.0f;   // +/-2000 dps

// ---------------------------------------------------------------------------
// BLE Nordic UART UUIDs (little-endian 128-bit)
// ---------------------------------------------------------------------------
const uint8_t UART_SERVICE_UUID[16] = {0x9E, 0xCA, 0xDC, 0x24, 0x0E, 0xE5, 0xA9,
                                       0xE0, 0x93, 0xF3, 0xA3, 0xB5, 0x01, 0x00,
                                       0x40, 0x6E};
const uint8_t UART_TX_UUID[16] = {0x9E, 0xCA, 0xDC, 0x24, 0x0E, 0xE5, 0xA9, 0xE0,
                                  0x93, 0xF3, 0xA3, 0xB5, 0x03, 0x00, 0x40, 0x6E};
const uint8_t UART_RX_UUID[16] = {0x9E, 0xCA, 0xDC, 0x24, 0x0E, 0xE5, 0xA9, 0xE0,
                                  0x93, 0xF3, 0xA3, 0xB5, 0x02, 0x00, 0x40, 0x6E};
const uint8_t UART_VER_UUID[16] = {0x9E, 0xCA, 0xDC, 0x24, 0x0E, 0xE5, 0xA9,
                                   0xE0, 0x93, 0xF3, 0xA3, 0xB5, 0x04, 0x00,
                                   0x40, 0x6E};
#define FW_VERSION "0.1"

BLEService uartService(UART_SERVICE_UUID);
BLECharacteristic txChar(UART_TX_UUID);
BLECharacteristic rxChar(UART_RX_UUID);
BLECharacteristic verChar(UART_VER_UUID);

// ---------------------------------------------------------------------------
// Protocol packet types
// ---------------------------------------------------------------------------
#define PKT_BEGIN 0x01
#define PKT_SAMPLES 0x02
#define PKT_END 0x03
#define PKT_STATUS 0x10
#define SAMPLE_BYTES 12
#define MAX_PKT_SAMPLES 20 // 4 + 20*12 = 244 <= 247 MTU payload

// ---------------------------------------------------------------------------
// Runtime settings (adjustable from the app; defaults here)
// ---------------------------------------------------------------------------
static uint16_t odrHz = 416;        // ~400 Hz target; nearest LSM6DS3 hardware ODR
static uint32_t maxThrowMs = 5000;  // hard cap on a single capture

// Throw start/stop detection thresholds. These are the values tuned + validated
// on real throws in the old Nano/BMI270 firmware; they're in physical units
// (g, dps) so they carry over to the LSM6DS3.
static const float THROW_ACCEL_G = 2.5f;
static const float THROW_GYRO_DPS = 150.0f;
static const float STOP_GYRO_DPS = 100.0f;
static const uint32_t STOP_DEBOUNCE_MS = 200;
static const uint32_t MIN_THROW_MS = 250;
static const uint16_t MIN_SAMPLES = 24;
// Pre-trigger is a SAMPLE count, so its time span = PRE_TRIGGER/odrHz. The old
// firmware's 30 samples @ ~45 Hz was ~0.67 s of windup lead-in; at 416 Hz we
// need many more samples to keep a comparable window (~0.5 s here). Preliminary
// value — refine once D1 measures real windup->release duration.
#define PRE_TRIGGER 208
#define MAX_LABEL 16

// ---------------------------------------------------------------------------
// Storage: one big byte ring (arena) holds throws packed back-to-back; a ring
// of descriptors holds each throw's metadata. Throws are always uploaded and
// freed oldest-first, so the byte ring never fragments.
// ---------------------------------------------------------------------------
#define ARENA_BYTES (112 * 1024)
#define MAX_QUEUED 64
static uint8_t arena[ARENA_BYTES];
static uint32_t arenaHead = 0;  // oldest byte
static uint32_t arenaCount = 0; // bytes in use (queued + in-progress recording)

struct ThrowRec {
  uint32_t id;
  uint32_t offset;   // arena offset of the first sample
  uint32_t byteLen;  // sampleCount * 12
  uint16_t sampleCount;
  uint16_t rateHz;
  float peakAccelG;
  float peakGyroDps;
  uint32_t flightMs;
  char label[MAX_LABEL + 1];
};
static ThrowRec queue[MAX_QUEUED];
static int qHead = 0, qCount = 0;
static uint32_t droppedThrows = 0; // throws lost because storage was full

static inline uint32_t arenaFree() { return ARENA_BYTES - arenaCount; }

static void arenaWrite(const uint8_t *src, uint32_t len) {
  uint32_t tail = (arenaHead + arenaCount) % ARENA_BYTES;
  uint32_t first = len < (ARENA_BYTES - tail) ? len : (ARENA_BYTES - tail);
  memcpy(&arena[tail], src, first);
  if (len > first) memcpy(&arena[0], src + first, len - first);
  arenaCount += len;
}

static void arenaReadAt(uint32_t offset, uint8_t *dst, uint32_t len) {
  offset %= ARENA_BYTES;
  uint32_t first = len < (ARENA_BYTES - offset) ? len : (ARENA_BYTES - offset);
  memcpy(dst, &arena[offset], first);
  if (len > first) memcpy(dst + first, &arena[0], len - first);
}

// ---------------------------------------------------------------------------
// Pre-trigger ring (raw samples captured just before the throw is detected)
// ---------------------------------------------------------------------------
static uint8_t preBuf[PRE_TRIGGER][SAMPLE_BYTES];
static float preMagA[PRE_TRIGGER], preMagG[PRE_TRIGGER];
static uint16_t preWrite = 0, preCount = 0;

// ---------------------------------------------------------------------------
// Recording + upload state
// ---------------------------------------------------------------------------
static bool recording = false;
static uint32_t recStartOffset = 0, recBytes = 0;
static uint16_t recSamples = 0;
static float recPeakA = 0, recPeakG = 0;
static uint32_t throwStartMs = 0;
static uint32_t curThrowId = 0;
static bool inLowSpin = false;
static uint32_t lowSpinStartMs = 0;

enum UpPhase { UP_BEGIN, UP_SAMPLES, UP_END };
static UpPhase upPhase = UP_BEGIN;
static uint16_t upSampleIdx = 0;
static bool waitingAck = false;
static uint32_t ackDeadline = 0;
static const uint32_t ACK_TIMEOUT_MS = 3000;
static uint8_t txbuf[4 + MAX_PKT_SAMPLES * SAMPLE_BYTES];

// ---------------------------------------------------------------------------
// Connection + battery + LED
// ---------------------------------------------------------------------------
volatile bool connected = false;
volatile uint16_t connHdl = BLE_CONN_HANDLE_INVALID;
int batteryPct = 100;
uint16_t batteryMv = 0;
uint32_t lastBattUs = 0;
uint32_t lastStatusMs = 0;
bool pluggedIn = false, chargeActive = false, lowBatt = false;
char curLabel[MAX_LABEL + 1] = "unlabeled";

#define PIN_CHARGE_STATE 23
#define LED_BLINK_MS 300
#define LED_DUTY_BLUE 128
#define LED_DUTY_GREEN 0
#define LED_DUTY_RED 128
#define BATT_LOW_MV 3730
#define BATT_LOW_CLR 3770
enum LedColor { LED_C_OFF, LED_C_BLUE, LED_C_GREEN, LED_C_RED };

// ---------------------------------------------------------------------------
// Commands from the app (RX write callback sets flags; loop() acts on them)
// ---------------------------------------------------------------------------
volatile bool g_hasAck = false, g_hasLabel = false, g_hasClear = false;
volatile bool g_hasRate = false, g_hasMaxMs = false;
volatile uint32_t g_pendingAckId = 0;
volatile uint16_t g_pendingRate = 0;
volatile uint32_t g_pendingMaxMs = 0;
char g_pendingLabel[MAX_LABEL + 1] = "";

// ===========================================================================
// IMU
// ===========================================================================
static void setOdr(uint16_t hz) {
  const uint16_t allowed[] = {104, 208, 416, 833, 1660};
  uint16_t best = 1660;
  uint32_t bestErr = 0xFFFFFFFF;
  for (uint16_t a : allowed) {
    uint32_t e = a > hz ? a - hz : hz - a;
    if (e < bestErr) { bestErr = e; best = a; }
  }
  odrHz = best;
  myIMU.settings.gyroSampleRate = best;
  myIMU.settings.accelSampleRate = best;
  myIMU.begin();
  Wire1.setClock(400000);
}

// Read one fresh sample. Fills out12 (accel-first raw bytes) + magnitudes.
static bool readSample(uint8_t out12[12], float *accG, float *gyrDps) {
  uint8_t status = 0;
  myIMU.readRegister(&status, LSM6DS3_STATUS_REG);
  if (!(status & 0x01)) return false;
  uint8_t raw[12];
  if (myIMU.readRegisterRegion(raw, LSM6DS3_OUTX_L_G, 12) != 0) return false;
  memcpy(out12 + 0, raw + 6, 6); // ax, ay, az
  memcpy(out12 + 6, raw + 0, 6); // gx, gy, gz
  int16_t ax = (int16_t)(raw[6] | (raw[7] << 8));
  int16_t ay = (int16_t)(raw[8] | (raw[9] << 8));
  int16_t az = (int16_t)(raw[10] | (raw[11] << 8));
  int16_t gx = (int16_t)(raw[0] | (raw[1] << 8));
  int16_t gy = (int16_t)(raw[2] | (raw[3] << 8));
  int16_t gz = (int16_t)(raw[4] | (raw[5] << 8));
  float axg = ax * ACCEL_SCALE_G, ayg = ay * ACCEL_SCALE_G, azg = az * ACCEL_SCALE_G;
  float gxd = gx * GYRO_SCALE_DPS, gyd = gy * GYRO_SCALE_DPS, gzd = gz * GYRO_SCALE_DPS;
  *accG = sqrtf(axg * axg + ayg * ayg + azg * azg);
  *gyrDps = sqrtf(gxd * gxd + gyd * gyd + gzd * gzd);
  return true;
}

// ===========================================================================
// Recording
// ===========================================================================
static bool appendSample(const uint8_t *s12, float accG, float gyrDps) {
  if (arenaFree() < SAMPLE_BYTES || recSamples >= 65000 ||
      recBytes >= (maxThrowMs * (uint32_t)odrHz / 1000 + PRE_TRIGGER) * SAMPLE_BYTES) {
    return false; // storage full or throw too long
  }
  arenaWrite(s12, SAMPLE_BYTES);
  recBytes += SAMPLE_BYTES;
  recSamples++;
  if (accG > recPeakA) recPeakA = accG;
  if (gyrDps > recPeakG) recPeakG = gyrDps;
  return true;
}

static void startRecording() {
  recStartOffset = (arenaHead + arenaCount) % ARENA_BYTES;
  recBytes = 0;
  recSamples = 0;
  recPeakA = 0;
  recPeakG = 0;
  inLowSpin = false;
  throwStartMs = millis();
  curThrowId++;
  recording = true;
  // Fold in the pre-trigger history, oldest first.
  uint16_t oldest = (preWrite + PRE_TRIGGER - preCount) % PRE_TRIGGER;
  for (uint16_t i = 0; i < preCount; i++) {
    uint16_t idx = (oldest + i) % PRE_TRIGGER;
    appendSample(preBuf[idx], preMagA[idx], preMagG[idx]);
  }
}

static void finishRecording() {
  recording = false;
  uint32_t duration = millis() - throwStartMs;
  bool tooShort = recSamples < MIN_SAMPLES || duration < MIN_THROW_MS;
  if (tooShort || qCount >= MAX_QUEUED) {
    arenaCount -= recBytes; // roll back the bytes we appended
    if (!tooShort) droppedThrows++; // queue was full
    return;
  }
  int slot = (qHead + qCount) % MAX_QUEUED;
  ThrowRec &r = queue[slot];
  r.id = curThrowId;
  r.offset = recStartOffset;
  r.byteLen = recBytes;
  r.sampleCount = recSamples;
  r.rateHz = odrHz;
  r.peakAccelG = recPeakA;
  r.peakGyroDps = recPeakG;
  r.flightMs = duration;
  strncpy(r.label, curLabel, MAX_LABEL);
  r.label[MAX_LABEL] = 0;
  qCount++;
}

// ===========================================================================
// Upload
// ===========================================================================
static void popOldest() {
  if (qCount == 0) return;
  ThrowRec &r = queue[qHead];
  arenaHead = (arenaHead + r.byteLen) % ARENA_BYTES;
  arenaCount -= r.byteLen;
  qHead = (qHead + 1) % MAX_QUEUED;
  qCount--;
}

static void uploadStep() {
  if (!connected || connHdl == BLE_CONN_HANDLE_INVALID) return;
  if (!txChar.notifyEnabled(connHdl)) return;
  if (qCount == 0) return;
  if (waitingAck) {
    if (millis() > ackDeadline) { // no ACK -> resend from the top
      waitingAck = false;
      upPhase = UP_BEGIN;
    } else {
      return;
    }
  }

  ThrowRec &t = queue[qHead];
  BLEConnection *conn = Bluefruit.Connection(connHdl);
  uint16_t mtu = conn ? conn->getMtu() : 23;
  uint16_t nmax = (mtu > 7) ? ((mtu - 3 - 4) / SAMPLE_BYTES) : 1;
  if (nmax > MAX_PKT_SAMPLES) nmax = MAX_PKT_SAMPLES;
  if (nmax < 1) nmax = 1;

  // Pump as many packets as the BLE stack will queue this loop (flow-controlled
  // by notify()'s return, never by delay()).
  for (int k = 0; k < 16; k++) {
    if (upPhase == UP_BEGIN) {
      uint8_t p[9];
      p[0] = PKT_BEGIN;
      memcpy(p + 1, &t.id, 4);
      memcpy(p + 5, &t.rateHz, 2);
      memcpy(p + 7, &t.sampleCount, 2);
      if (!txChar.notify(p, 9)) break;
      upSampleIdx = 0;
      upPhase = UP_SAMPLES;
    } else if (upPhase == UP_SAMPLES) {
      if (upSampleIdx >= t.sampleCount) {
        upPhase = UP_END;
        continue;
      }
      uint16_t n = t.sampleCount - upSampleIdx;
      if (n > nmax) n = nmax;
      txbuf[0] = PKT_SAMPLES;
      memcpy(txbuf + 1, &upSampleIdx, 2);
      txbuf[3] = (uint8_t)n;
      uint32_t off = (t.offset + (uint32_t)upSampleIdx * SAMPLE_BYTES) % ARENA_BYTES;
      arenaReadAt(off, &txbuf[4], (uint32_t)n * SAMPLE_BYTES);
      if (!txChar.notify(txbuf, 4 + n * SAMPLE_BYTES)) break;
      upSampleIdx += n;
    } else { // UP_END
      uint8_t p[32];
      int o = 0;
      p[o++] = PKT_END;
      memcpy(p + o, &t.id, 4); o += 4;
      memcpy(p + o, &t.sampleCount, 2); o += 2;
      memcpy(p + o, &t.peakAccelG, 4); o += 4;
      memcpy(p + o, &t.peakGyroDps, 4); o += 4;
      memcpy(p + o, &t.flightMs, 4); o += 4;
      uint8_t ll = strlen(t.label);
      if (ll > MAX_LABEL) ll = MAX_LABEL;
      p[o++] = ll;
      memcpy(p + o, t.label, ll); o += ll;
      if (!txChar.notify(p, o)) break;
      waitingAck = true;
      ackDeadline = millis() + ACK_TIMEOUT_MS;
      upPhase = UP_BEGIN; // ready for the next throw once this one is ACKed
      break;
    }
  }
}

// ===========================================================================
// Commands
// ===========================================================================
static void processCommands() {
  if (g_hasClear) {
    g_hasClear = false;
    recording = false;
    qHead = qCount = 0;
    arenaHead = arenaCount = 0;
    waitingAck = false;
    upPhase = UP_BEGIN;
  }
  if (g_hasAck) {
    g_hasAck = false;
    if (waitingAck && qCount > 0 && queue[qHead].id == g_pendingAckId) {
      popOldest();
      waitingAck = false;
      upPhase = UP_BEGIN;
    }
  }
  if (g_hasLabel) {
    g_hasLabel = false;
    strncpy(curLabel, g_pendingLabel, MAX_LABEL);
    curLabel[MAX_LABEL] = 0;
  }
  if (g_hasMaxMs) {
    g_hasMaxMs = false;
    if (g_pendingMaxMs >= 500 && g_pendingMaxMs <= 30000) maxThrowMs = g_pendingMaxMs;
  }
  if (g_hasRate && !recording) {
    g_hasRate = false;
    setOdr(g_pendingRate);
  }
}

// ===========================================================================
// Battery + LED (from the ping-pong firmware)
// ===========================================================================
void sampleBattery() {
  digitalWrite(VBAT_ENABLE, LOW);
  delay(2);
  uint32_t acc = 0;
  for (int i = 0; i < 64; i++) acc += analogRead(PIN_VBAT);
  digitalWrite(VBAT_ENABLE, HIGH);
  float rawADC = acc / 64.0f;
  float vbat = (rawADC / 4096.0f) * 3.6f * (1510.0f / 510.0f);
  batteryMv = (uint16_t)(vbat * 1000.0f);
  int pct = (int)(((vbat - 3.2f) / (4.2f - 3.2f)) * 100.0f);
  batteryPct = constrain(pct, 0, 100);
}

static inline uint8_t ledLit(LedColor c) {
  switch (c) {
    case LED_C_GREEN: return LED_DUTY_GREEN;
    case LED_C_RED: return LED_DUTY_RED;
    default: return LED_DUTY_BLUE;
  }
}
void setStatusLed(LedColor c, bool on) {
  uint8_t v = on ? ledLit(c) : 255;
  analogWrite(LED_RED, c == LED_C_RED ? v : 255);
  analogWrite(LED_GREEN, c == LED_C_GREEN ? v : 255);
  analogWrite(LED_BLUE, c == LED_C_BLUE ? v : 255);
}
void updateStatusLed() {
  if (batteryMv <= BATT_LOW_MV) lowBatt = true;
  else if (batteryMv >= BATT_LOW_CLR) lowBatt = false;
  const bool blink = ((millis() / LED_BLINK_MS) & 1) == 0;
  LedColor color;
  bool on;
  if (pluggedIn) {
    color = LED_C_GREEN;
    on = chargeActive ? blink : true;
  } else {
    color = lowBatt ? LED_C_RED : LED_C_BLUE;
    on = connected ? true : blink;
  }
  static LedColor lastColor = LED_C_OFF;
  static bool lastOn = false, inited = false;
  if (inited && color == lastColor && on == lastOn) return;
  lastColor = color;
  lastOn = on;
  inited = true;
  setStatusLed(color, on);
}

// ===========================================================================
// BLE callbacks
// ===========================================================================
void connectCallback(uint16_t ch) {
  BLEConnection *conn = Bluefruit.Connection(ch);
  conn->requestPHY();
  conn->requestDataLengthUpdate();
  conn->requestMtuExchange(247);
  conn->requestConnectionParameter(6); // 7.5 ms
  connHdl = ch;
  connected = true;
  upPhase = UP_BEGIN;
  waitingAck = false;
}
void disconnectCallback(uint16_t ch, uint8_t reason) {
  (void)ch;
  (void)reason;
  connected = false;
  connHdl = BLE_CONN_HANDLE_INVALID;
  waitingAck = false;
  upPhase = UP_BEGIN; // re-upload the oldest from the top on reconnect
}
void rxWriteCallback(uint16_t ch, BLECharacteristic *c, uint8_t *data,
                     uint16_t len) {
  (void)ch;
  (void)c;
  char buf[64];
  uint16_t n = len < 63 ? len : 63;
  memcpy(buf, data, n);
  buf[n] = 0;
  while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) buf[--n] = 0;
  if (!strncmp(buf, "ACK:", 4)) {
    g_pendingAckId = (uint32_t)atol(buf + 4);
    g_hasAck = true;
  } else if (!strncmp(buf, "LABEL:", 6)) {
    strncpy(g_pendingLabel, buf + 6, MAX_LABEL);
    g_pendingLabel[MAX_LABEL] = 0;
    g_hasLabel = true;
  } else if (!strcmp(buf, "CLEAR")) {
    g_hasClear = true;
  } else if (!strncmp(buf, "RATE:", 5)) {
    g_pendingRate = (uint16_t)atoi(buf + 5);
    g_hasRate = true;
  } else if (!strncmp(buf, "MAXMS:", 6)) {
    g_pendingMaxMs = (uint32_t)atol(buf + 6);
    g_hasMaxMs = true;
  }
}

// ===========================================================================
// Setup / loop
// ===========================================================================
void setup() {
  Serial.begin(115200);
  uint32_t t0 = millis();
  while (!Serial && millis() - t0 < 2000) {}

  myIMU.settings.gyroEnabled = 1;
  myIMU.settings.gyroRange = 2000;
  myIMU.settings.gyroSampleRate = odrHz;
  myIMU.settings.gyroFifoEnabled = 0;
  myIMU.settings.accelEnabled = 1;
  myIMU.settings.accelRange = 16;
  myIMU.settings.accelSampleRate = odrHz;
  myIMU.settings.accelFifoEnabled = 0;
  myIMU.settings.tempEnabled = 0;
  if (myIMU.begin() != 0) {
    Serial.println("IMU init failed");
    while (1) {}
  }
  Wire1.setClock(400000);

  pinMode(PIN_VBAT, INPUT);
  pinMode(VBAT_ENABLE, OUTPUT);
  analogReadResolution(12);
  digitalWrite(VBAT_ENABLE, HIGH);
  pinMode(PIN_CHARGE_STATE, INPUT_PULLUP);
  sampleBattery();

  Bluefruit.configPrphBandwidth(BANDWIDTH_MAX);
  Bluefruit.begin();
  Bluefruit.autoConnLed(false);
  setStatusLed(LED_C_OFF, false);
  Bluefruit.setTxPower(4);
  Bluefruit.setName("FrisbeeTrack");
  Bluefruit.Periph.setConnectCallback(connectCallback);
  Bluefruit.Periph.setDisconnectCallback(disconnectCallback);
  Bluefruit.Periph.setConnInterval(6, 12);

  uartService.begin();
  txChar.setProperties(CHR_PROPS_NOTIFY);
  txChar.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  txChar.setMaxLen(sizeof(txbuf));
  txChar.begin();
  rxChar.setProperties(CHR_PROPS_WRITE | CHR_PROPS_WRITE_WO_RESP);
  rxChar.setPermission(SECMODE_OPEN, SECMODE_OPEN);
  rxChar.setMaxLen(64);
  rxChar.setWriteCallback(rxWriteCallback);
  rxChar.begin();
  verChar.setProperties(CHR_PROPS_READ);
  verChar.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  verChar.setMaxLen(8);
  verChar.begin();
  verChar.write(FW_VERSION, sizeof(FW_VERSION) - 1);

  Bluefruit.Advertising.addFlags(BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE);
  Bluefruit.Advertising.addTxPower();
  Bluefruit.Advertising.addService(uartService);
  Bluefruit.ScanResponse.addName();
  Bluefruit.Advertising.restartOnDisconnect(true);
  Bluefruit.Advertising.setInterval(32, 244);
  Bluefruit.Advertising.setFastTimeout(30);
  Bluefruit.Advertising.start(0);

  lastBattUs = micros();
  Serial.println("FrisbeeTrack advertising (store-and-forward)");
}

void loop() {
  uint32_t nowUs = micros();
  if (nowUs - lastBattUs > 2000000UL) {
    sampleBattery();
    lastBattUs = nowUs;
  }
  pluggedIn = (NRF_POWER->USBREGSTATUS & POWER_USBREGSTATUS_VBUSDETECT_Msk) != 0;
  chargeActive = (digitalRead(PIN_CHARGE_STATE) == LOW);
  updateStatusLed();

  processCommands();

  // ---- Capture: read every fresh sample; detect throw start/stop ----
  uint8_t s12[12];
  float accG, gyrDps;
  if (readSample(s12, &accG, &gyrDps)) {
    if (!recording) {
      memcpy(preBuf[preWrite], s12, SAMPLE_BYTES);
      preMagA[preWrite] = accG;
      preMagG[preWrite] = gyrDps;
      preWrite = (preWrite + 1) % PRE_TRIGGER;
      if (preCount < PRE_TRIGGER) preCount++;
      if (accG > THROW_ACCEL_G && gyrDps > THROW_GYRO_DPS) startRecording();
    } else {
      if (!appendSample(s12, accG, gyrDps)) {
        finishRecording(); // storage full or throw too long
      } else {
        uint32_t dur = millis() - throwStartMs;
        if (dur > MIN_THROW_MS) {
          if (gyrDps < STOP_GYRO_DPS) {
            if (!inLowSpin) {
              inLowSpin = true;
              lowSpinStartMs = millis();
            } else if (millis() - lowSpinStartMs > STOP_DEBOUNCE_MS) {
              finishRecording(); // spin decayed -> throw over
            }
          } else {
            inLowSpin = false;
          }
        }
        if (recording && dur > maxThrowMs) finishRecording();
      }
    }
  }

  // ---- Upload queued throws only while not recording ----
  if (!recording) uploadStep();

  // ---- Idle status heartbeat (~1.5 s) so the app shows battery + queue ----
  if (connected && !recording && !(qCount > 0 && !waitingAck)) {
    uint32_t nowMs = millis();
    if (nowMs - lastStatusMs >= 1500 && connHdl != BLE_CONN_HANDLE_INVALID &&
        txChar.notifyEnabled(connHdl)) {
      uint8_t p[5];
      p[0] = PKT_STATUS;
      p[1] = (uint8_t)batteryPct;
      memcpy(p + 2, &batteryMv, 2);
      p[4] = (uint8_t)qCount;
      txChar.notify(p, 5);
      lastStatusMs = nowMs;
    }
  }
}
