/*
  Coban ESP32-C3 Super Mini firmware.

  BLE protocol follows the friend-project pattern:
    Device name: Coban
    Service UUID:        4fafc201-1fb5-459e-8fcc-c5c9c331914b
    Characteristic UUID: beb5483e-36e1-4688-b7f5-ea07361b26a8

  The Flutter app writes JSON to the characteristic:
    {"t":"note","n":"A5","m":31,"d":500,"b":0.68}

  Fields:
    t = packet type, "note"
    n = display note name
    m = fingering bitmask, bit 0..5 map to holes from mouthpiece to foot
    d = duration in milliseconds
    b = breath intensity for the app UI, ignored by firmware

  Correct solenoid order:
    hole 1 GPIO 1, hole 2 GPIO 6, hole 3 GPIO 5,
    hole 4 GPIO 2, hole 5 GPIO 3, hole 6 GPIO 4.

  Hardware note:
    Do not drive solenoids directly from ESP32 GPIO pins. Use MOSFET/transistor
    drivers, flyback diodes, and a solenoid power supply with a shared ground.
*/

#include <Arduino.h>
#include <ArduinoJson.h>
#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

static const char *DEVICE_NAME = "Coban";

static const char *SERVICE_UUID = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
static const char *CHARACTERISTIC_UUID = "beb5483e-36e1-4688-b7f5-ea07361b26a8";

static const uint8_t SOLENOID_COUNT = 6;
static const uint8_t MAX_ACTIVE_SOLENOIDS = 6;
static const uint8_t SOLENOID_PINS[SOLENOID_COUNT] = {1, 6, 5, 2, 3, 4};

// Change these if your driver board is active-low.
static const uint8_t SOLENOID_ACTIVE_LEVEL = HIGH;
static const uint8_t SOLENOID_INACTIVE_LEVEL = LOW;

BLEServer *bleServer = nullptr;
BLECharacteristic *commandCharacteristic = nullptr;

bool deviceConnected = false;
bool noteActive = false;
uint32_t noteOffAtMs = 0;

uint8_t countActiveBits(uint8_t mask) {
  uint8_t count = 0;
  for (uint8_t i = 0; i < SOLENOID_COUNT; i++) {
    if ((mask & (1 << i)) != 0) {
      count++;
    }
  }
  return count;
}

void notifyStatus(const char *message) {
  Serial.println(message);

  if (deviceConnected && commandCharacteristic != nullptr) {
    StaticJsonDocument<96> doc;
    doc["t"] = "status";
    doc["v"] = message;

    char buffer[96];
    serializeJson(doc, buffer);
    commandCharacteristic->setValue(buffer);
    commandCharacteristic->notify();
  }
}

void allSolenoidsOff() {
  for (uint8_t i = 0; i < SOLENOID_COUNT; i++) {
    digitalWrite(SOLENOID_PINS[i], SOLENOID_INACTIVE_LEVEL);
  }
  noteActive = false;
}

bool applyFingering(uint8_t mask, uint16_t durationMs) {
  mask &= 0x3F;

  const uint8_t activeCount = countActiveBits(mask);
  if (activeCount > MAX_ACTIVE_SOLENOIDS) {
    allSolenoidsOff();
    notifyStatus("ERR_LIMIT");
    return false;
  }

  for (uint8_t i = 0; i < SOLENOID_COUNT; i++) {
    const bool isActive = (mask & (1 << i)) != 0;
    digitalWrite(
      SOLENOID_PINS[i],
      isActive ? SOLENOID_ACTIVE_LEVEL : SOLENOID_INACTIVE_LEVEL
    );
  }

  if (durationMs == 0 || activeCount == 0) {
    noteActive = false;
    if (activeCount == 0) {
      allSolenoidsOff();
    }
    return true;
  }

  noteActive = true;
  noteOffAtMs = millis() + durationMs;
  return true;
}

bool handleJsonCommand(const String &value) {
  StaticJsonDocument<192> doc;
  const DeserializationError error = deserializeJson(doc, value);
  if (error) {
    notifyStatus("ERR_JSON");
    return false;
  }

  const char *type = doc["t"] | "";
  if (strcmp(type, "note") != 0) {
    notifyStatus("ERR_TYPE");
    return false;
  }

  const uint8_t mask = doc["m"] | 0;
  const uint16_t durationMs = doc["d"] | 0;
  return applyFingering(mask, durationMs);
}

// Backward compatibility with the earlier 4-byte prototype packet.
bool handleBinaryCommand(const String &value) {
  if (value.length() < 4) {
    notifyStatus("ERR_SHORT_PACKET");
    return false;
  }

  const uint8_t magic = static_cast<uint8_t>(value[0]);
  if (magic != 0x52) {
    notifyStatus("ERR_BAD_MAGIC");
    return false;
  }

  const uint8_t mask = static_cast<uint8_t>(value[1]);
  const uint16_t durationMs =
      static_cast<uint8_t>(value[2]) |
      (static_cast<uint16_t>(static_cast<uint8_t>(value[3])) << 8);
  return applyFingering(mask, durationMs);
}

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *server) override {
    deviceConnected = true;
    notifyStatus("CONNECTED");
  }

  void onDisconnect(BLEServer *server) override {
    deviceConnected = false;
    allSolenoidsOff();
    Serial.println("DISCONNECTED");
    BLEDevice::startAdvertising();
  }
};

class CommandCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) override {
    const String value = characteristic->getValue();
    if (value.length() == 0) {
      notifyStatus("ERR_EMPTY");
      return;
    }

    const bool ok = value[0] == '{'
        ? handleJsonCommand(value)
        : handleBinaryCommand(value);

    if (ok) {
      notifyStatus("OK");
    }
  }
};

void setupPins() {
  for (uint8_t i = 0; i < SOLENOID_COUNT; i++) {
    digitalWrite(SOLENOID_PINS[i], SOLENOID_INACTIVE_LEVEL);
    pinMode(SOLENOID_PINS[i], OUTPUT);
    digitalWrite(SOLENOID_PINS[i], SOLENOID_INACTIVE_LEVEL);
  }
}

void setupBle() {
  BLEDevice::init(DEVICE_NAME);
  BLEDevice::setPower(ESP_PWR_LVL_P9);

  bleServer = BLEDevice::createServer();
  bleServer->setCallbacks(new ServerCallbacks());

  BLEService *service = bleServer->createService(SERVICE_UUID);

  commandCharacteristic = service->createCharacteristic(
    CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_READ |
      BLECharacteristic::PROPERTY_WRITE |
      BLECharacteristic::PROPERTY_WRITE_NR |
      BLECharacteristic::PROPERTY_NOTIFY
  );
  commandCharacteristic->addDescriptor(new BLE2902());
  commandCharacteristic->setCallbacks(new CommandCallbacks());
  commandCharacteristic->setValue("{\"t\":\"status\",\"v\":\"READY\"}");

  service->start();

  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(false);
  advertising->setMinPreferred(0x0);

  BLEDevice::startAdvertising();
  Serial.println("BLE advertising as Coban");
}

void setup() {
  Serial.begin(115200);
  delay(250);

  setupPins();
  setupBle();

  Serial.println("Coban recorder firmware ready");
}

void loop() {
  if (noteActive && static_cast<int32_t>(millis() - noteOffAtMs) >= 0) {
    allSolenoidsOff();
  }

  delay(2);
}
