/*
PLTS RAMLI 343 - v88.02 ESP32-S3 + OTA UPDATE
============================================
FITUR UTAMA:
1. ESP32-S3 Optimized: Pin aman (GPIO 4, 5, 10, 11), anti brownout.
2. OTA Update: Bisa update firmware jarak jauh via WiFi (HTTPS) ke GitHub.
3. Glitch Immune: Sensor ADS1115 dengan filter Median + EMA, anti noise.
4. Heap Safe: Global WiFiClientSecure & Mutex (tanpa new/delete).
5. Logic: PV Interlock >= 70V, Relay LF/HF, Drop Mode, Anti-hunting 60s.
*/

// Wajib untuk ESP32-S3 agar Serial Monitor jalan di port USB Native
#ifndef ARDUINO_USB_MODE
#define ARDUINO_USB_MODE 1
#endif
#ifndef ARDUINO_USB_CDC_ON_BOOT
#define ARDUINO_USB_CDC_ON_BOOT 1
#endif

#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <HTTPUpdate.h>       // Library wajib untuk OTA
#include <ArduinoJson.h>
#include <Wire.h>
#include <Adafruit_ADS1X15.h>
#include <Preferences.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <LiquidCrystal_PCF8574.h>
#include <time.h>
#include <nvs_flash.h>
#include <esp_task_wdt.h>
#include <esp_coexist.h>
#include <esp_wifi.h>
#include <math.h>

// ========================================================
// OTA CONFIGURATION (Sudah disesuaikan dengan GitHub Anda)
// ========================================================
#define CURRENT_FIRMWARE_VERSION "v88.02" 

// PENTING: Pastikan nama file di GitHub SAMA PERSIS dengan yang di sini (misal: firmware.bin)
#define OTA_BIN_URL "https://raw.githubusercontent.com/Denasrudin/plts_ramli343/main/firmware.bin"

// ========================================================
// SUPABASE
// ========================================================
#define SUPABASE_URL "https://msmvwgtqvgeofhcnuyin.supabase.co"
#define SUPABASE_KEY "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1zbXZ3Z3Rxdmdlb2ZoY251eWluIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI4Njc5MDAsImV4cCI6MjA5ODQ0MzkwMH0.Dw8tOuQPzV1Bh1Wz767LXG4vDSD3HGRwAhxZwHzF4Xc"
#define SUPABASE_TABLE "battery_data"
#define CONFIG_TABLE "relay_config"
#define SUPABASE_HOST "msmvwgtqvgeofhcnuyin.supabase.co"

// ========================================================
// PIN (AMAN UNTUK ESP32-S3)
// ========================================================
#define RELAY1_PIN 10
#define RELAY2_PIN 11
#define I2C_SDA 4
#define I2C_SCL 5

// ========================================================
// ADS1115
// ========================================================
#define ADS1115_ADDR 0x48
#define ADS_CH_BATT_VOLT 0
#define ADS_CH_PV_VOLT   1

// ========================================================
// DIVIDER & SHUNT
// ========================================================
#define R1_BATT_DIVIDER 330000.0f
#define R2_BATT_DIVIDER 10000.0f
#define BATT_DIVIDER_RATIO 34.0f
float calibrationFactorBatt = 0.969f;

#define R1_PV_DIVIDER 1320000.0f
#define R2_PV_DIVIDER 10000.0f
#define PV_DIVIDER_RATIO 133.0f
float calibrationFactorPV = 1.0f;

#define SHUNT_MV_PER_A 0.75f
#define ARUS_IDLE_THRESHOLD 0.5f
float arusOffset = 0.0f;
float calibrationFactorArus = 1.0f;

// ========================================================
// FILTER & HTTP
// ========================================================
#define FILTER_SAMPLES 7
#define EMA_ALPHA_TEGANGAN 0.25f
#define EMA_ALPHA_ARUS     0.30f
#define EMA_ALPHA_SHUNT    0.30f

#define HTTP_CONNECT_TIMEOUT_MS 8000
#define HTTP_TIMEOUT_MS 8000
#define HTTP_MAX_RETRY 2
#define WIFI_CONNECT_TIMEOUT_MS 12000
#define WIFI_RECONNECT_INTERVAL 15000
#define SERVER_POLL_INTERVAL_MS 5000

// ========================================================
// BLE
// ========================================================
#define SERVICE_UUID "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHAR_WRITE_UUID "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
#define CHAR_STATUS_UUID "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

// ========================================================
// GLOBAL OBJECT
// ========================================================
Adafruit_ADS1115 ads;
LiquidCrystal_PCF8574 lcd(0x27);
Preferences preferences;

BLEServer *pServer = nullptr;
BLECharacteristic *pCharWrite = nullptr;
BLECharacteristic *pCharStatus = nullptr;

SemaphoreHandle_t i2cMutex = NULL;
SemaphoreHandle_t httpMutex = NULL;
WiFiClientSecure globalSecureClient;

// ========================================================
// SYSTEM STATE
// ========================================================
bool bleConnected = false;
bool adsOK = false;
bool batteryConnected = false;
bool timeSynced = false;
bool serverOnline = false;
volatile bool httpBusy = false;
volatile bool otaRequested = false;
volatile bool otaTriggeredThisBoot = false;
bool wifiReconnectPending = false;
unsigned long wifiConnectStart = 0;
bool ntpConfigured = false;

String pendingSsid = "";
String pendingPass = "";

float teganganSamples[FILTER_SAMPLES] = {0};
int teganganIndex = 0;
float teganganFiltered = 0.0f;

float arusSamples[FILTER_SAMPLES] = {0};
int arusIndex = 0;
float arusFiltered = 0.0f;

float shuntSamples[FILTER_SAMPLES] = {0};
int shuntIndex = 0;
float shunt_mVFiltered = 0.0f;

float teganganPV = 0.0f;

bool teganganFilterInitialized = false;
bool arusFilterInitialized = false;
bool shuntFilterInitialized = false;

bool relay1Auto = true;
bool relay2Auto = true;
bool pln1Aktif = false;
bool pln2Aktif = false;

unsigned long lastRelay1Switch = 0;
unsigned long lastRelay2Switch = 0;

bool hfDropMode = false;
bool hfWaitingForStable = false;
unsigned long hfStableStartTime = 0;
unsigned long hfLastOffTime = 0;

const unsigned long LCD_INTERVAL_UPDATE = 1000;
const unsigned long SCROLL_INTERVAL_MS = 250;
const unsigned long PAGE_DURATION_OTHER = 10000;
const int TOTAL_PAGES = 4;

int currentLcdPage = 0;
int lastLcdPage = -1;
unsigned long lcdPageStartTime = 0;
unsigned long lastLcdUpdate = 0;
unsigned long lastScrollTime = 0;
int scrollOffset = 0;
int scrollPassCount = 0;
char dateTimeStr[80] = "  ";

const unsigned long INTERVAL_KIRIM_MS = 15000;
const unsigned long RELAY_COOLDOWN_MS = 5000;
const unsigned long HF_STABLE_TIME_MS = 3000;
const unsigned long HF_RESTART_LOCK_MS = 60000;

const char* hariIndonesia[] = {"Minggu", "Senin", "Selasa", "Rabu", "Kamis", "Jumat", "Sabtu"};

// ========================================================
// PROTOTYPE
// ========================================================
float hitungMedian(float *arr, int n);
float bacaTeganganBaterai();
float bacaArusBaterai();
float bacaTeganganPV();
void sendDataToSupabase();
void supabaseTaskFn(void *pvParameters);
void pollRelayConfigFromServer();
void syncTimeNTP();
void updateLcdDisplay();
void kontrolRelay();
bool isWeatherTime();
bool connectWiFi(String ssid, String pass);
void startWiFiReconnect();
void serviceWiFiReconnect();
void serviceTimeSync();
void formatTanggalIndonesia(char* buffer, size_t bufferSize, time_t t);
bool pvInterlockAktif();
void forceAllRelayOff(const char* alasan);
void executeOTAUpdate();
void requestOTA(const char* source);
bool clearServerOtaTrigger();

// ========================================================
// HELPER FUNCTIONS
// ========================================================
void formatTanggalIndonesia(char* buffer, size_t bufferSize, time_t t) {
  struct tm* tmInfo = localtime(&t);
  snprintf(buffer, bufferSize, "%s, %02d-%02d-%04d %02d:%02d:%02d ",
    hariIndonesia[tmInfo->tm_wday], tmInfo->tm_mday, tmInfo->tm_mon + 1,
    tmInfo->tm_year + 1900, tmInfo->tm_hour, tmInfo->tm_min, tmInfo->tm_sec);
}

bool isWeatherTime() {
  if (!timeSynced) return false;
  time_t now = time(nullptr);
  struct tm* tmInfo = localtime(&now);
  return (tmInfo->tm_hour >= 6 && tmInfo->tm_hour < 17);
}

float hitungMedian(float *arr, int n) {
  float temp[FILTER_SAMPLES];
  for (int i = 0; i < n; i++) temp[i] = arr[i];
  for (int i = 0; i < n - 1; i++) {
    for (int j = 0; j < n - i - 1; j++) {
      if (temp[j] > temp[j + 1]) { float t = temp[j]; temp[j] = temp[j + 1]; temp[j + 1] = t; }
    }
  }
  return temp[n / 2];
}

// ========================================================
// WIFI & NTP
// ========================================================
void WiFiEvent(WiFiEvent_t event) {
  if (event == ARDUINO_EVENT_WIFI_STA_GOT_IP) {
    Serial.printf("[WiFi] GOT IP: %s | RSSI: %d dBm\n", WiFi.localIP().toString().c_str(), WiFi.RSSI());
  } else if (event == ARDUINO_EVENT_WIFI_STA_DISCONNECTED) {
    Serial.printf("[WiFi] Disconnected | status=%d\n", (int)WiFi.status());
  }
}

bool connectWiFi(String ssid, String pass) {
  if (ssid.length() == 0) return false;
  if (WiFi.status() == WL_CONNECTED) return true;

  Serial.printf("[WiFi] Connecting to \"%s\"...\n", ssid.c_str());
  WiFi.mode(WIFI_STA);
  WiFi.setHostname("PLTS_RAMLI343");
  WiFi.persistent(false);
  WiFi.setAutoReconnect(false);
  WiFi.setSleep(false);
  esp_coex_preference_set(ESP_COEX_PREFER_WIFI);
  esp_wifi_set_max_tx_power(52);

  WiFi.disconnect(false);
  delay(100);
  WiFi.begin(ssid.c_str(), pass.c_str());

  unsigned long t0 = millis();
  unsigned long lastPrint = 0;
  while (millis() - t0 < WIFI_CONNECT_TIMEOUT_MS) {
    esp_task_wdt_reset();
    if (WiFi.status() == WL_CONNECTED) {
      Serial.printf("[WiFi] CONNECTED | IP=%s | RSSI=%d dBm\n", WiFi.localIP().toString().c_str(), WiFi.RSSI());
      return true;
    }
    if (millis() - lastPrint >= 2000) {
      Serial.printf("[WiFi] Waiting... status=%d\n", (int)WiFi.status());
      lastPrint = millis();
    }
    delay(100);
  }

  Serial.println("[WiFi] Connect timeout 12s");
  WiFi.disconnect(false);
  return false;
}

void syncTimeNTP() {
  if (WiFi.status() != WL_CONNECTED) {
    timeSynced = false;
    return;
  }
  if (!ntpConfigured) {
    Serial.println("[NTP] Configuring NTP...");
    configTime(7 * 3600, 0, "id.pool.ntp.org", "time.google.com");
    ntpConfigured = true;
  }
  time_t now = time(nullptr);
  if (now > 24 * 3600) {
    if (!timeSynced) Serial.println("[NTP] Synced");
    timeSynced = true;
  } else {
    timeSynced = false;
  }
}

void startWiFiReconnect() {
  if (WiFi.status() == WL_CONNECTED || wifiReconnectPending) return;

  preferences.begin("plts", false);
  String ssid = preferences.getString("ssid", "");
  String pass = preferences.getString("pass", "");
  preferences.end();
  if (ssid.length() == 0) return;

  WiFi.mode(WIFI_STA);
  WiFi.setHostname("PLTS_RAMLI343");
  WiFi.persistent(false);
  WiFi.setAutoReconnect(false);
  WiFi.setSleep(false);
  esp_coex_preference_set(ESP_COEX_PREFER_WIFI);
  esp_wifi_set_max_tx_power(52);
  WiFi.disconnect(false);
  delay(50);
  WiFi.begin(ssid.c_str(), pass.c_str());
  wifiConnectStart = millis();
  wifiReconnectPending = true;
  Serial.printf("[WiFi] Async reconnect dimulai: %s\n", ssid.c_str());
}

void serviceWiFiReconnect() {
  if (!wifiReconnectPending) return;
  if (WiFi.status() == WL_CONNECTED) {
    wifiReconnectPending = false;
    ntpConfigured = false;
    timeSynced = false;
    serverOnline = false;
    Serial.printf("[WiFi] RECONNECTED | IP=%s | RSSI=%d dBm\n", WiFi.localIP().toString().c_str(), WiFi.RSSI());
    syncTimeNTP();
    return;
  }
  if (millis() - wifiConnectStart >= WIFI_CONNECT_TIMEOUT_MS) {
    Serial.println("[WiFi] Async reconnect timeout 12s");
    WiFi.disconnect(false);
    wifiReconnectPending = false;
    timeSynced = false;
    serverOnline = false;
  }
}

void serviceTimeSync() {
  if (WiFi.status() != WL_CONNECTED) {
    timeSynced = false;
    return;
  }
  if (!ntpConfigured) syncTimeNTP();
  else {
    time_t now = time(nullptr);
    timeSynced = (now > 24 * 3600);
  }
}

// ========================================================
// INTERLOCK & RELAY
// ========================================================
bool pvInterlockAktif() {
  return (teganganPV >= 70.0f);
}

void forceAllRelayOff(const char* alasan) {
  unsigned long now = millis();
  bool changed = false;
  if (pln1Aktif) {
    digitalWrite(RELAY1_PIN, HIGH);
    pln1Aktif = false;
    lastRelay1Switch = now;
    changed = true;
  }
  if (pln2Aktif) {
    digitalWrite(RELAY2_PIN, HIGH);
    pln2Aktif = false;
    lastRelay2Switch = now;
    changed = true;
  }
  hfDropMode = false;
  hfWaitingForStable = false;
  hfStableStartTime = 0;
  hfLastOffTime = now;
  
  if (changed) {
    Serial.printf("[INTERLOCK] SEMUA RELAY OFF | PV=%.2fV | %s\n", teganganPV, alasan);
  }
}

// ========================================================
// BLE CALLBACKS
// ========================================================
class MyServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) override { bleConnected = true; Serial.println("BLE: Connected"); }
  void onDisconnect(BLEServer* pServer) override { bleConnected = false; BLEDevice::startAdvertising(); }
};

class RelayCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *pCharacteristic) override {
    String cmd = pCharacteristic->getValue();
    cmd.trim();
    if (cmd.length() == 0) return;

    if (cmd.startsWith("SSID=")) pendingSsid = cmd.substring(5);
    else if (cmd.startsWith("PASS=")) pendingPass = cmd.substring(5);
    else if (cmd == "SAVE") {
      if (pendingSsid.length() > 0 && pendingPass.length() > 0) {
        preferences.begin("plts", false);
        preferences.putString("ssid", pendingSsid);
        preferences.putString("pass", pendingPass);
        preferences.end();
        delay(800);
        ESP.restart();
      }
    }
    else if (cmd == "RESET") {
      preferences.begin("plts", false);
      preferences.remove("ssid");
      preferences.remove("pass");
      preferences.end();
      delay(1000);
      ESP.restart();
    }
    else if (cmd == "RLY1_ON") {
      if (pvInterlockAktif()) { Serial.printf("[BLE] RLY1_ON DITOLAK | PV=%.1fV >=70V\n", teganganPV); forceAllRelayOff("BLE LF blocked by PV"); }
      else { relay1Auto = false; pln1Aktif = true; digitalWrite(RELAY1_PIN, LOW); lastRelay1Switch = millis(); Serial.println("[BLE] LF MANUAL ON"); }
    }
    else if (cmd == "RLY1_OFF") { relay1Auto = false; pln1Aktif = false; digitalWrite(RELAY1_PIN, HIGH); lastRelay1Switch = millis(); Serial.println("[BLE] LF MANUAL OFF"); }
    else if (cmd == "RLY1_AUTO") { relay1Auto = true; Serial.println("[BLE] LF AUTO"); }
    else if (cmd == "RLY2_ON") {
      if (pvInterlockAktif()) { Serial.printf("[BLE] RLY2_ON DITOLAK | PV=%.1fV >=70V\n", teganganPV); forceAllRelayOff("BLE HF blocked by PV"); }
      else { relay2Auto = false; pln2Aktif = true; digitalWrite(RELAY2_PIN, LOW); lastRelay2Switch = millis(); Serial.println("[BLE] HF MANUAL ON"); }
    }
    else if (cmd == "RLY2_OFF") { relay2Auto = false; pln2Aktif = false; digitalWrite(RELAY2_PIN, HIGH); lastRelay2Switch = millis(); hfDropMode = false; hfWaitingForStable = false; hfStableStartTime = 0; hfLastOffTime = millis(); Serial.println("[BLE] HF MANUAL OFF"); }
    else if (cmd == "RLY2_AUTO") { relay2Auto = true; Serial.println("[BLE] HF AUTO"); }
    else if (cmd == "CMD_OTA") {
      Serial.println("[BLE] Perintah OTA diterima.");
      requestOTA("BLE"); 
    }
  }
};

// ========================================================
// OTA UPDATE FUNCTION
// ========================================================
void executeOTAUpdate() {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[OTA] DIBATALKAN: WiFi belum connected");
    return;
  }

  if (httpBusy) {
    Serial.println("[OTA] Ditunda: HTTP sedang sibuk");
    return;
  }

  Serial.println("========================================");
  Serial.println("[OTA] Memulai proses update firmware...");
  Serial.println("[OTA] JANGAN MATIKAN DAYA SELAMA PROSES INI!");
  Serial.println("========================================");

  otaRequested = false;
  if (httpMutex == NULL || xSemaphoreTake(httpMutex, pdMS_TO_TICKS(100)) != pdTRUE) {
    Serial.println("[OTA] Gagal memperoleh HTTP mutex.");
    return;
  }
  httpBusy = true;
  esp_task_wdt_delete(NULL);

  // Pastikan relay aman sebelum firmware diganti.
  digitalWrite(RELAY1_PIN, HIGH);
  digitalWrite(RELAY2_PIN, HIGH);
  pln1Aktif = false;
  pln2Aktif = false;

  WiFiClientSecure client;
  client.setInsecure();
  client.setTimeout(120);
  httpUpdate.rebootOnUpdate(true);

  Serial.printf("[OTA] Versi Saat Ini: %s\n", CURRENT_FIRMWARE_VERSION);
  Serial.printf("[OTA] Mengunduh dari: %s\n", OTA_BIN_URL);

  t_httpUpdate_return ret = httpUpdate.update(client, OTA_BIN_URL, CURRENT_FIRMWARE_VERSION);

  switch (ret) {
    case HTTP_UPDATE_FAILED:
      Serial.printf("[OTA] GAGAL! Error (%d): %s\n", httpUpdate.getLastError(), httpUpdate.getLastErrorString().c_str());
      break;
    case HTTP_UPDATE_NO_UPDATES:
      Serial.println("[OTA] Tidak ada update baru.");
      break;
    case HTTP_UPDATE_OK:
      Serial.println("[OTA] BERHASIL. Restart otomatis...");
      break;
  }

  esp_task_wdt_add(NULL);
  httpBusy = false;
  xSemaphoreGive(httpMutex);
}

void requestOTA(const char* source) {
  if (otaTriggeredThisBoot) {
    Serial.printf("[OTA] Permintaan dari %s diabaikan: sudah pernah dipicu pada boot ini.\n", source);
    return;
  }
  otaTriggeredThisBoot = true;
  otaRequested = true;
  Serial.printf("[OTA] Request diterima dari %s\n", source);
}

bool clearServerOtaTrigger() {
  if (WiFi.status() != WL_CONNECTED) return false;
  if (httpMutex == NULL || xSemaphoreTake(httpMutex, pdMS_TO_TICKS(100)) != pdTRUE) return false;
  if (httpBusy) { xSemaphoreGive(httpMutex); return false; }

  httpBusy = true;
  bool ok = false;
  String url = String(SUPABASE_URL) + "/rest/v1/" + CONFIG_TABLE + "?id=eq.1";

  globalSecureClient.setInsecure();
  globalSecureClient.setTimeout(8);
  HTTPClient http;
  http.setConnectTimeout(HTTP_CONNECT_TIMEOUT_MS);
  http.setTimeout(HTTP_TIMEOUT_MS);
  http.setReuse(false);

  if (http.begin(globalSecureClient, url)) {
    http.addHeader("Content-Type", "application/json");
    http.addHeader("apikey", SUPABASE_KEY);
    http.addHeader("Authorization", "Bearer " + String(SUPABASE_KEY));
    http.addHeader("Prefer", "return=minimal");
    int code = http.sendRequest("PATCH", "{\"trigger_ota\":false}");
    ok = (code >= 200 && code < 300);
    Serial.printf("[OTA] Clear trigger_ota: HTTP %d\n", code);
    http.end();
  }
  httpBusy = false;
  xSemaphoreGive(httpMutex);
  return ok;
}

// ========================================================
// SETUP
// ========================================================
void setup() {
  Serial.begin(115200);
  delay(1000);

  Serial.println();
  Serial.println("========================================");
  Serial.printf(" PLTS RAMLI 343 %s ESP32-S3\n", CURRENT_FIRMWARE_VERSION);
  Serial.println(" ANTI-BROWNOUT + STABLE WIFI + OTA");
  Serial.println("========================================");

  nvs_flash_init();
  WiFi.onEvent(WiFiEvent);

  pinMode(RELAY1_PIN, OUTPUT);
  pinMode(RELAY2_PIN, OUTPUT);
  digitalWrite(RELAY1_PIN, HIGH);
  digitalWrite(RELAY2_PIN, HIGH);
  delay(300);

  esp_task_wdt_config_t wdt_config = { .timeout_ms = 30000, .idle_core_mask = 0, .trigger_panic = true };
  esp_task_wdt_reconfigure(&wdt_config);
  esp_task_wdt_add(NULL);

  i2cMutex = xSemaphoreCreateMutex();
  httpMutex = xSemaphoreCreateMutex();
  Wire.begin(I2C_SDA, I2C_SCL);
  Wire.setClock(100000);
  delay(300);

  if (xSemaphoreTake(i2cMutex, (TickType_t)100) == pdTRUE) {
    lcd.begin(16, 2);
    lcd.setBacklight(0);
    lcd.clear();
    lcd.print("INITIALIZING...");
    xSemaphoreGive(i2cMutex);
  }
  delay(300);

  adsOK = ads.begin(ADS1115_ADDR);
  Serial.printf("[STARTUP] ADS1115: %s\n", adsOK ? "OK" : "FAIL");
  delay(300);

  preferences.begin("plts", false);
  String ssid = preferences.getString("ssid", "");
  String pass = preferences.getString("pass", "");
  preferences.end();

  if (ssid.length() > 0) {
    if (connectWiFi(ssid, pass)) {
      delay(1000);
      syncTimeNTP();
    }
  } else {
    Serial.println("[WiFi] No saved SSID");
  }

  delay(500);
  BLEDevice::init("PLTS_RAMLI343");
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());
  BLEService *pService = pServer->createService(SERVICE_UUID);
  pCharWrite = pService->createCharacteristic(CHAR_WRITE_UUID, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  pCharWrite->setCallbacks(new RelayCallbacks());
  pCharStatus = pService->createCharacteristic(CHAR_STATUS_UUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  pCharStatus->addDescriptor(new BLE2902());
  pService->start();
  BLEDevice::getAdvertising()->addServiceUUID(SERVICE_UUID);
  BLEDevice::startAdvertising();
  esp_coex_preference_set(ESP_COEX_PREFER_BALANCE);
  delay(500);

  if (adsOK) {
    Serial.println("[CAL] Calibrating Current Offset...");
    ads.setGain(GAIN_SIXTEEN);
    delay(300);
    float offsetSum = 0.0f;
    for (int i = 0; i < 20; i++) {
      esp_task_wdt_reset();
      int16_t adcRaw = ads.readADC_Differential_2_3();
      float shunt_mV = adcRaw * 0.0078125f;
      float current = (shunt_mV / SHUNT_MV_PER_A) * calibrationFactorArus;
      offsetSum += current;
      delay(30);
    }
    arusOffset = offsetSum / 20.0f;
    if (fabs(arusOffset) > 2.0f) {
      Serial.printf("[CAL] WARNING: Offset %.4f A terlalu besar. Dipaksa 0A.\n", arusOffset);
      arusOffset = 0.0f;
    }
    Serial.printf("[CAL] Current Offset: %.4f A\n", arusOffset);
  }

  if (xSemaphoreTake(i2cMutex, (TickType_t)100) == pdTRUE) {
    lcd.setBacklight(200);
    xSemaphoreGive(i2cMutex);
  }

  xTaskCreate(supabaseTaskFn, "SupabaseTask", 16384, NULL, 1, NULL);
  Serial.printf("[HEAP] Free: %u bytes\n", ESP.getFreeHeap());
  Serial.println("=== INIT COMPLETE ===");

  currentLcdPage = 0;
  lastLcdPage = -1;
  lcdPageStartTime = millis();
  scrollOffset = 0;
  scrollPassCount = 0;
  lastScrollTime = millis();
  updateLcdDisplay();
}

// ========================================================
// MAIN LOOP
// ========================================================
void loop() {
  esp_task_wdt_reset();
  unsigned long now = millis();

  static unsigned long lastHeartbeat = 0;
  if (now - lastHeartbeat > 10000) {
    int rssi = (WiFi.status() == WL_CONNECTED) ? WiFi.RSSI() : 0;
    Serial.printf("[HEARTBEAT] Heap:%u | BATT:%.2fV | PV:%.1fV | ARUS:%.1fA | SHUNT:%.2fmV | HF:%s | LF:%s | Server:%s | RSSI:%d\n",
      ESP.getFreeHeap(), teganganFiltered, teganganPV, arusFiltered, shunt_mVFiltered,
      pln2Aktif ? "PLN" : "PLTS", pln1Aktif ? "PLN" : "PLTS", serverOnline ? "ONLINE" : "OFFLINE", rssi);
    lastHeartbeat = now;
  }

  static unsigned long lastReconnect = 0;
  serviceWiFiReconnect();
  serviceTimeSync();

  if (WiFi.status() != WL_CONNECTED && !wifiReconnectPending && now - lastReconnect >= WIFI_RECONNECT_INTERVAL) {
    lastReconnect = now;
    Serial.println("[WiFi] Scheduling reconnect...");
    startWiFiReconnect();
  }

  if (otaRequested && WiFi.status() == WL_CONNECTED) {
    if (clearServerOtaTrigger()) {
      Serial.println("[OTA] Trigger server berhasil di-clear.");
    }
    executeOTAUpdate();
  }

  teganganPV = bacaTeganganPV();
  bacaTeganganBaterai();
  bacaArusBaterai();

  if (pvInterlockAktif()) {
    forceAllRelayOff("LOOP PV >=70V");
  }
  kontrolRelay();

  static unsigned long lastPollRelay = 0;
  if (WiFi.status() == WL_CONNECTED && timeSynced && now - lastPollRelay >= SERVER_POLL_INTERVAL_MS) {
    lastPollRelay = now;
    pollRelayConfigFromServer();
  }

  if (timeSynced) {
    char tanggal[40];
    formatTanggalIndonesia(tanggal, sizeof(tanggal), time(nullptr));
    String weatherText;
    if (isWeatherTime()) {
      if (teganganPV < 70.0f) weatherText = " CUACA:BLM MENDUKUNG";
      else if (teganganPV < 110.0f) weatherText = " CUACA:PANAS";
      else weatherText = " CUACA:PANAS BANGET";
    } else {
      weatherText = " CUACA:CHG PV BELUM SIAP";
    }
    snprintf(dateTimeStr, sizeof(dateTimeStr), "%s%s     ", tanggal, weatherText.c_str());
  } else {
    strcpy(dateTimeStr, "--:--:-- --/--/----  CHG PV BELUM SIAP     ");
  }

  bool bothAuto = relay1Auto && relay2Auto;
  bool wifiOnline = (WiFi.status() == WL_CONNECTED);
  bool anyOffline = !wifiOnline || !timeSynced;

  if (!bothAuto && currentLcdPage != 2) {
    currentLcdPage = 2; lcdPageStartTime = now; scrollOffset = 0; scrollPassCount = 0;
  } else if (anyOffline && currentLcdPage != 3) {
    currentLcdPage = 3; lcdPageStartTime = now; scrollOffset = 0; scrollPassCount = 0;
  } else if (bothAuto && !anyOffline) {
    if (currentLcdPage == 0) {
      if (now - lastScrollTime >= SCROLL_INTERVAL_MS) {
        lastScrollTime = now;
        int len = strlen(dateTimeStr);
        if (len > 0) {
          scrollOffset++;
          if (scrollOffset >= len) {
            scrollPassCount++;
            if (scrollPassCount >= 1) {
              currentLcdPage = 1; lcdPageStartTime = now; scrollOffset = 0; scrollPassCount = 0;
            }
          }
        }
      }
    } else {
      unsigned long elapsed = now - lcdPageStartTime;
      if (elapsed >= PAGE_DURATION_OTHER) {
        currentLcdPage = (currentLcdPage + 1) % TOTAL_PAGES;
        lcdPageStartTime = now; scrollOffset = 0; scrollPassCount = 0;
      }
    }
  }

  if (now - lastLcdUpdate >= LCD_INTERVAL_UPDATE) {
    lastLcdUpdate = now;
    updateLcdDisplay();
  }
  delay(10);
}

// ========================================================
// KONTROL RELAY
// ========================================================
void kontrolRelay() {
  unsigned long now = millis();
  const float LF_BATT_ON_V = 48.2f;
  const float HF_BATT_ON_V = 48.7f;
  const float HF_SHUNT_ON_MV = 55.4f;
  const float HF_ARUS_DROP_ON_A = 5.0f;
  const float HF_ARUS_STABLE_A = 15.0f;
  const float PV_OFF_V = 70.0f;

  float arusAbs = fabs(arusFiltered);

  if (teganganPV >= PV_OFF_V) {
    forceAllRelayOff("PV >= 70V");
    return;
  }

  if (!batteryConnected) {
    if (pln1Aktif && relay1Auto) { digitalWrite(RELAY1_PIN, HIGH); pln1Aktif = false; lastRelay1Switch = now; }
    if (pln2Aktif && relay2Auto) { digitalWrite(RELAY2_PIN, HIGH); pln2Aktif = false; hfDropMode = false; hfWaitingForStable = false; hfStableStartTime = 0; lastRelay2Switch = now; }
    return;
  }

  if (relay1Auto && now - lastRelay1Switch >= RELAY_COOLDOWN_MS) {
    if (!pln1Aktif && teganganFiltered <= LF_BATT_ON_V) {
      digitalWrite(RELAY1_PIN, LOW); pln1Aktif = true; lastRelay1Switch = now;
      Serial.printf("[LF] PLN ON | BATT=%.2fV | PV=%.1fV\n", teganganFiltered, teganganPV);
    }
  }

  if (!relay2Auto) return;
  if (now - lastRelay2Switch < RELAY_COOLDOWN_MS) return;

  if (pln2Aktif) {
    if (hfDropMode) {
      if (arusAbs >= HF_ARUS_STABLE_A) {
        if (!hfWaitingForStable) {
          hfWaitingForStable = true;
          hfStableStartTime = now;
          Serial.printf("[HF] ARUS >= %.1fA | MULAI STABIL 3 DETIK | ARUS=%.1fA\n", HF_ARUS_STABLE_A, arusAbs);
        }
        if (hfWaitingForStable && now - hfStableStartTime >= HF_STABLE_TIME_MS) {
          digitalWrite(RELAY2_PIN, HIGH); pln2Aktif = false;
          hfDropMode = false; hfWaitingForStable = false; hfStableStartTime = 0;
          hfLastOffTime = now; lastRelay2Switch = now;
          Serial.printf("[HF] OFF | ARUS %.1fA STABIL >= %.1fA SELAMA 3 DETIK\n", arusAbs, HF_ARUS_STABLE_A);
        }
      } else {
        if (hfWaitingForStable) {
          Serial.printf("[HF] STABIL RESET | ARUS TURUN %.1fA < %.1fA\n", arusAbs, HF_ARUS_STABLE_A);
        }
        hfWaitingForStable = false; hfStableStartTime = 0;
      }
      return;
    }
    return;
  }

  if (!pln2Aktif) {
    if (now - hfLastOffTime < HF_RESTART_LOCK_MS) return;

    bool triggerDrop = (arusAbs <= HF_ARUS_DROP_ON_A);
    bool triggerBattery = (teganganFiltered <= HF_BATT_ON_V);
    bool triggerShunt = (shunt_mVFiltered >= HF_SHUNT_ON_MV);

    if (!triggerDrop && !triggerBattery && !triggerShunt) return;

    digitalWrite(RELAY2_PIN, LOW); pln2Aktif = true; lastRelay2Switch = now;
    hfDropMode = triggerDrop; hfWaitingForStable = false; hfStableStartTime = 0;

    Serial.printf("[HF] PLN ON | BATT=%.2fV | ARUS=%.1fA | SHUNT=%.2fmV | PV=%.1fV | TRIGGER=", teganganFiltered, arusAbs, shunt_mVFiltered, teganganPV);
    if (triggerDrop) Serial.print("DROP_<=5A");
    if (triggerBattery) { if (triggerDrop) Serial.print("+"); Serial.print("BATT_<=48.7V"); }
    if (triggerShunt) { if (triggerDrop || triggerBattery) Serial.print("+"); Serial.print("SHUNT_>=55.4mV"); }
    Serial.println();

    if (hfDropMode) Serial.println("[HF] MODE DROP AKTIF -> TUNGGU ARUS >=15A STABIL 3 DETIK");
    else Serial.println("[HF] MODE NORMAL -> OFF MENUNGGU PV >=70V");
  }
}

// ========================================================
// LCD & SENSOR FUNCTIONS (GLITCH IMMUNE)
// ========================================================
void updateLcdDisplay() {
  if (currentLcdPage != lastLcdPage) {
    if (xSemaphoreTake(i2cMutex, (TickType_t)100) == pdTRUE) {
      lcd.clear();
      xSemaphoreGive(i2cMutex);
    }
    lastLcdPage = currentLcdPage;
  }

  float tegangan = batteryConnected ? teganganFiltered : 0.0f;
  float arus = arusFiltered;
  bool wifiOK = (WiFi.status() == WL_CONNECTED);

  if (xSemaphoreTake(i2cMutex, (TickType_t)100) == pdTRUE) {
    switch (currentLcdPage) {
      case 0: {
        lcd.setCursor(1, 0); lcd.print("PLTS RAMLI343");
        int len = strlen(dateTimeStr);
        if (len > 0) {
          char display[17];
          for (int i = 0; i < 16; i++) {
            int idx = (scrollOffset + i) % len;
            display[i] = dateTimeStr[idx];
          }
          display[16] = '\0';
          lcd.setCursor(0, 1); lcd.print(display);
        }
        break;
      }
      case 1: {
        char battStr[10]; dtostrf(tegangan, 4, 1, battStr);
        lcd.setCursor(0, 0); lcd.print("BATT:"); lcd.print(battStr); lcd.print("V       ");
        float arusIn = (arus > ARUS_IDLE_THRESHOLD) ? arus : 0.0f;
        float arusLoad = (arus < -ARUS_IDLE_THRESHOLD) ? -arus : 0.0f;
        lcd.setCursor(0, 1); lcd.print("IN:"); lcd.print((int)round(arusIn)); lcd.print("A");
        lcd.setCursor(9, 1); lcd.print("OUT:"); lcd.print((int)round(arusLoad)); lcd.print("A");
        break;
      }
      case 2: {
        char line1[17]; snprintf(line1, sizeof(line1), "LF:%s %-7s", pln1Aktif ? "PLN" : "PLTS", relay1Auto ? "AUTO" : "MANUAL");
        lcd.setCursor(0, 0); lcd.print(line1);
        char line2[17]; snprintf(line2, sizeof(line2), "HF:%s %-7s", pln2Aktif ? "PLN" : "PLTS", relay2Auto ? "AUTO" : "MANUAL");
        lcd.setCursor(0, 1); lcd.print(line2);
        break;
      }
      case 3: {
        char line1[17]; snprintf(line1, sizeof(line1), "WIFI:%-9s", wifiOK ? "ONLINE" : "OFFLINE");
        lcd.setCursor(0, 0); lcd.print(line1);
        char line2[17]; snprintf(line2, sizeof(line2), "SERVER:%-8s", serverOnline ? "ONLINE" : "OFFLINE");
        lcd.setCursor(0, 1); lcd.print(line2);
        break;
      }
    }
    xSemaphoreGive(i2cMutex);
  }
}

float bacaTeganganPV() {
  if (!adsOK) return 0.0f;
  float sum = 0.0f;
  bool gotI2C = false;
  if (xSemaphoreTake(i2cMutex, (TickType_t)50) == pdTRUE) {
    gotI2C = true;
    ads.setGain(GAIN_TWOTHIRDS);
    for (int i = 0; i < 5; i++) {
      int16_t adcRaw = ads.readADC_SingleEnded(ADS_CH_PV_VOLT);
      float adcVolt = adcRaw * 0.1875f / 1000.0f;
      sum += (adcVolt * PV_DIVIDER_RATIO * calibrationFactorPV);
      delayMicroseconds(800);
    }
    xSemaphoreGive(i2cMutex);
  }
  if (!gotI2C) return teganganPV;
  float raw = sum / 5.0f;
  if (raw < 0.0f) raw = 0.0f;
  if (raw > 160.0f) return teganganPV; 
  if (raw < 15.0f) return 0.0f; 
  return raw;
}

float bacaTeganganBaterai() {
  if (!adsOK) { batteryConnected = false; return 0.0f; }
  float sum = 0.0f;
  bool gotI2C = false;
  if (xSemaphoreTake(i2cMutex, (TickType_t)50) == pdTRUE) {
    gotI2C = true;
    ads.setGain(GAIN_TWOTHIRDS);
    for (int i = 0; i < 5; i++) {
      int16_t adcRaw = ads.readADC_SingleEnded(ADS_CH_BATT_VOLT);
      float adcVolt = adcRaw * 0.1875f / 1000.0f;
      sum += (adcVolt * BATT_DIVIDER_RATIO * calibrationFactorBatt);
      delayMicroseconds(800);
    }
    xSemaphoreGive(i2cMutex);
  }
  if (!gotI2C) return teganganFiltered;
  float raw = sum / 5.0f;
  if (raw < 0.0f) raw = 0.0f;

  if (raw < 10.0f || raw > 65.0f) return teganganFiltered; 

  if (!teganganFilterInitialized) {
    for (int i = 0; i < FILTER_SAMPLES; i++) teganganSamples[i] = raw;
    teganganFiltered = raw;
    teganganFilterInitialized = true;
    teganganIndex = 0;
  } else {
    teganganSamples[teganganIndex] = raw;
    teganganIndex = (teganganIndex + 1) % FILTER_SAMPLES;
    float median = hitungMedian(teganganSamples, FILTER_SAMPLES);
    teganganFiltered = EMA_ALPHA_TEGANGAN * median + (1.0f - EMA_ALPHA_TEGANGAN) * teganganFiltered;
  }

  if (teganganFiltered < 0.0f) teganganFiltered = 0.0f;
  batteryConnected = (teganganFiltered >= 20.0f); 
  return teganganFiltered;
}

float bacaArusBaterai() {
  if (!adsOK || !batteryConnected) { arusFiltered = 0.0f; shunt_mVFiltered = 0.0f; return 0.0f; }

  float sumCurrent = 0.0f;
  float sumShunt = 0.0f;
  bool gotI2C = false;
  if (xSemaphoreTake(i2cMutex, (TickType_t)50) == pdTRUE) {
    gotI2C = true;
    ads.setGain(GAIN_SIXTEEN);
    for (int i = 0; i < 5; i++) {
      int16_t adcRaw = ads.readADC_Differential_2_3();
      float shunt_mV = adcRaw * 0.0078125f;
      float current = (shunt_mV / SHUNT_MV_PER_A) * calibrationFactorArus;
      sumShunt += shunt_mV;
      sumCurrent += current;
      delayMicroseconds(800);
    }
    xSemaphoreGive(i2cMutex);
  }
  if (!gotI2C) return arusFiltered;
  float shuntRaw = sumShunt / 5.0f;
  float rawCurrent = (sumCurrent / 5.0f) - arusOffset;

  if (rawCurrent > 100.0f) rawCurrent = 100.0f;
  if (rawCurrent < -100.0f) rawCurrent = -100.0f;
  if (fabs(rawCurrent) < ARUS_IDLE_THRESHOLD) rawCurrent = 0.0f;

  if (!shuntFilterInitialized) {
    for (int i = 0; i < FILTER_SAMPLES; i++) shuntSamples[i] = shuntRaw;
    shunt_mVFiltered = shuntRaw;
    shuntFilterInitialized = true;
    shuntIndex = 0;
  } else {
    shuntSamples[shuntIndex] = shuntRaw;
    shuntIndex = (shuntIndex + 1) % FILTER_SAMPLES;
    float shuntMedian = hitungMedian(shuntSamples, FILTER_SAMPLES);
    shunt_mVFiltered = EMA_ALPHA_SHUNT * shuntMedian + (1.0f - EMA_ALPHA_SHUNT) * shunt_mVFiltered;
  }

  if (!arusFilterInitialized) {
    for (int i = 0; i < FILTER_SAMPLES; i++) arusSamples[i] = rawCurrent;
    arusFiltered = rawCurrent;
    arusFilterInitialized = true;
    arusIndex = 0;
  } else {
    arusSamples[arusIndex] = rawCurrent;
    arusIndex = (arusIndex + 1) % FILTER_SAMPLES;
    float currentMedian = hitungMedian(arusSamples, FILTER_SAMPLES);
    arusFiltered = EMA_ALPHA_ARUS * currentMedian + (1.0f - EMA_ALPHA_ARUS) * arusFiltered;
  }

  if (fabs(arusFiltered) < ARUS_IDLE_THRESHOLD) arusFiltered = 0.0f;
  return arusFiltered;
}

// ========================================================
// SERVER & SUPABASE
// ========================================================
void pollRelayConfigFromServer() {
  if (WiFi.status() != WL_CONNECTED) return;
  if (pvInterlockAktif()) { forceAllRelayOff("SERVER POLL BLOCKED BY PV"); return; }
  if (httpMutex == NULL || xSemaphoreTake(httpMutex, 0) != pdTRUE) return;
  if (httpBusy) { xSemaphoreGive(httpMutex); return; }
  
  httpBusy = true;
  String url = String(SUPABASE_URL) + "/rest/v1/" + CONFIG_TABLE + "?id=eq.1";

  globalSecureClient.setInsecure();
  globalSecureClient.setTimeout(8);
  HTTPClient http;
  http.setConnectTimeout(HTTP_CONNECT_TIMEOUT_MS);
  http.setTimeout(HTTP_TIMEOUT_MS);
  http.setReuse(false);
  
  if (http.begin(globalSecureClient, url)) {
    http.addHeader("apikey", SUPABASE_KEY);
    http.addHeader("Authorization", "Bearer " + String(SUPABASE_KEY));
    int httpCode = http.GET();
    if (httpCode == 200) {
      serverOnline = true;
      String payload = http.getString();
      if (payload.length() > 2) {
        StaticJsonDocument<512> doc;
        DeserializationError error = deserializeJson(doc, payload);
        if (!error && doc.is<JsonArray>() && doc.size() > 0) {
          JsonObject row = doc[0];
          bool newR1Auto = row["relay1_auto"] | true;
          bool newR1State = row["relay1_state"] | false;
          bool newR2Auto = row["relay2_auto"] | true;
          bool newR2State = row["relay2_state"] | false;
          
          bool triggerOTA = row["trigger_ota"] | false;
          if (triggerOTA && !otaTriggeredThisBoot) {
             Serial.println("[SERVER] Perintah OTA diterima dari Supabase!");
             requestOTA("SUPABASE");
          }

          unsigned long now = millis();

          if (relay1Auto != newR1Auto || (relay1Auto == false && pln1Aktif != newR1State)) {
            if (now - lastRelay1Switch >= RELAY_COOLDOWN_MS) {
              relay1Auto = newR1Auto;
              if (!relay1Auto && teganganPV < 70.0f) {
                pln1Aktif = newR1State;
                digitalWrite(RELAY1_PIN, pln1Aktif ? LOW : HIGH);
                lastRelay1Switch = now;
              }
            }
          }
          if (relay2Auto != newR2Auto || (relay2Auto == false && pln2Aktif != newR2State)) {
            if (now - lastRelay2Switch >= RELAY_COOLDOWN_MS) {
              relay2Auto = newR2Auto;
              if (!relay2Auto && teganganPV < 70.0f) {
                pln2Aktif = newR2State;
                digitalWrite(RELAY2_PIN, pln2Aktif ? LOW : HIGH);
                lastRelay2Switch = now;
              }
            }
          }
        }
      }
    } else {
      serverOnline = false;
    }
    http.end();
  }
  httpBusy = false;
  xSemaphoreGive(httpMutex);
}

void supabaseTaskFn(void *pvParameters) {
  esp_task_wdt_add(NULL);
  for (;;) {
    esp_task_wdt_reset();
    if (WiFi.status() == WL_CONNECTED && timeSynced) sendDataToSupabase();
    vTaskDelay(pdMS_TO_TICKS(INTERVAL_KIRIM_MS));
  }
}

void sendDataToSupabase() {
  if (WiFi.status() != WL_CONNECTED || ESP.getFreeHeap() < 15000) return;
  if (httpMutex == NULL || xSemaphoreTake(httpMutex, pdMS_TO_TICKS(100)) != pdTRUE) return;
  if (httpBusy) { xSemaphoreGive(httpMutex); return; }
  httpBusy = true;
  esp_coex_preference_set(ESP_COEX_PREFER_WIFI);

  bool success = false;
  for (int attempt = 1; attempt <= HTTP_MAX_RETRY; attempt++) {
    if (attempt > 1) {
      int delayMs = 1000 * (1 << (attempt - 1));
      Serial.printf("[HTTP] Retry %d after %dms\n", attempt, delayMs);
      vTaskDelay(pdMS_TO_TICKS(delayMs));
    }
    esp_task_wdt_reset();

    StaticJsonDocument<256> doc;
    float teganganKirim = batteryConnected ? teganganFiltered : 0.0f;
    doc["tegangan"] = teganganKirim;
    doc["arus"] = batteryConnected ? arusFiltered : 0.0f;
    doc["daya"] = batteryConnected ? (teganganFiltered * fabs(arusFiltered)) : 0.0f;
    doc["arus_input"] = (batteryConnected && arusFiltered > 0) ? arusFiltered : 0.0f;
    doc["arus_load"] = (batteryConnected && arusFiltered < 0) ? fabs(arusFiltered) : 0.0f;
    doc["pv_voltage"] = teganganPV;
    
    String statusStr = !adsOK ? "SENSOR_ERR" : !batteryConnected ? "NO_BATTERY" : arusFiltered > 0.5f ? "CHARGING" : arusFiltered < -0.5f ? "DISCHARGING" : "IDLE";
    doc["status"] = statusStr;
    doc["pln_aktif"] = pln1Aktif;
    doc["pln2_aktif"] = pln2Aktif;
    doc["sensor_ok"] = adsOK;
    doc["battery_connected"] = batteryConnected;
    doc["wifi_ssid"] = WiFi.SSID();

    String jsonData;
    serializeJson(doc, jsonData);
    String url = String(SUPABASE_URL) + "/rest/v1/" + SUPABASE_TABLE;

    globalSecureClient.setInsecure();
    globalSecureClient.setTimeout(8);
    HTTPClient http;
    http.setConnectTimeout(HTTP_CONNECT_TIMEOUT_MS);
    http.setTimeout(HTTP_TIMEOUT_MS);
    http.setReuse(false);
    
    if (http.begin(globalSecureClient, url)) {
      http.addHeader("Content-Type", "application/json");
      http.addHeader("Host", SUPABASE_HOST);
      http.addHeader("apikey", SUPABASE_KEY);
      http.addHeader("Authorization", "Bearer " + String(SUPABASE_KEY));
      http.addHeader("Prefer", "return=minimal");

      unsigned long t0 = millis();
      int httpCode = http.POST(jsonData);
      unsigned long dur = millis() - t0;
      http.end();

      if (httpCode >= 200 && httpCode < 300) {
        success = true;
        serverOnline = true;
        Serial.printf("[HTTP] OK %d (%lums) attempt %d\n", httpCode, dur, attempt);
        break;
      } else {
        Serial.printf("[HTTP] FAIL %d (%lums) attempt %d\n", httpCode, dur, attempt);
        if (attempt == HTTP_MAX_RETRY) serverOnline = false;
      }
    }
    esp_task_wdt_reset();
  }
  esp_coex_preference_set(ESP_COEX_PREFER_BALANCE);
  httpBusy = false;
  xSemaphoreGive(httpMutex);
}