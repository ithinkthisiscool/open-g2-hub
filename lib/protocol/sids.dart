/// Service IDs (frame byte 6): which on-glasses feature a message is for. Port of g2/sids.py.
library;

const int sidDashboard = 0x01;
const int sidMenu = 0x03;
const int sidNotification = 0x04;
const int sidTranslate = 0x05;
const int sidTeleprompter = 0x06;
const int sidEvenAi = 0x07;
const int sidNavigation = 0x08;
const int sidSettings = 0x09;
const int sidTranscribe = 0x0A;
const int sidConversate = 0x0B;
const int sidQuicklist = 0x0C;
const int sidAppSync = 0x0D;
const int sidHealth = 0x0E;
const int sidLogger = 0x0F;
const int sidOnboarding = 0x10;
const int sidTracepoint = 0x11;
const int sidDashboardExt = 0x1F;
const int sidModuleConfig = 0x20;
const int sidTerminal = 0x30;
const int sidDeviceConfig = 0x80;
const int sidCase = 0x81;
const int sidRing = 0x90;
const int sidRing2 = 0x91;
const int sidOtaFirst = 0xC0;
const int sidOtaLast = 0xC3;
const int sidFileCmd = 0xC4;
const int sidFileData = 0xC5;
const int sidFileExportCmd = 0xC6;
const int sidFileExportData = 0xC7;
const int sidEvenHub = 0xE0;

const Map<int, String> sidNames = {
  sidDashboard: 'Dashboard',
  sidMenu: 'Menu',
  sidNotification: 'Notification',
  sidTranslate: 'Translate',
  sidTeleprompter: 'Teleprompter',
  sidEvenAi: 'Even AI',
  sidNavigation: 'Navigation',
  sidSettings: 'Settings',
  sidTranscribe: 'Transcribe',
  sidConversate: 'Conversate',
  sidQuicklist: 'Quicklist',
  sidAppSync: 'App sync',
  sidHealth: 'Health',
  sidLogger: 'Logger',
  sidOnboarding: 'Onboarding',
  sidTracepoint: 'Tracepoint',
  sidDashboardExt: 'Watchface layout',
  sidModuleConfig: 'Module config',
  sidTerminal: 'Terminal',
  sidDeviceConfig: 'Device config',
  sidCase: 'Case',
  sidRing: 'Ring',
  sidRing2: 'Ring',
  sidFileCmd: 'File (cmd)',
  sidFileData: 'File (data)',
  sidFileExportCmd: 'File export (cmd)',
  sidFileExportData: 'File export (data)',
  sidEvenHub: 'EvenHub',
  0xC0: 'OTA',
  0xC1: 'OTA',
  0xC2: 'OTA',
  0xC3: 'OTA',
};

/// Human name for a SID; unknown ids → '0x2a'.
String sidName(int sid) => sidNames[sid] ?? '0x${sid.toRadixString(16).padLeft(2, '0')}';
