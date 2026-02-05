import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'dart:ui';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/pdf.dart';
import 'package:share_plus/share_plus.dart';
import 'package:pdfx/pdfx.dart' as pdfx;    // for viewing PDFs


enum AppPage {log,liveCan, scan, diagnostics, deviceInfo }


void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE Raw Data Table',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        primaryColor: Colors.blue,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: Colors.white),
          bodyMedium: TextStyle(color: Colors.white),
        ),
      ),
      home: const BlePage(),
    );
  }
}

class BlePage extends StatefulWidget {
  const BlePage({super.key});

  @override
  State<BlePage> createState() => _BlePageState();
}

// ----------------- HELPERS -----------------

// Extension to allow copying a DiscoveredDevice with modified fields
extension DiscoveredDeviceCopy on DiscoveredDevice {
  DiscoveredDevice copyWith({int? rssi}) {
    return DiscoveredDevice(
      id: id,
      name: name,
      serviceData: serviceData,
      manufacturerData: manufacturerData,
      rssi: rssi ?? this.rssi,
      serviceUuids: serviceUuids,
    );
  }
}


class _BlePageState extends State<BlePage> with WidgetsBindingObserver {

  
  AppPage currentPage = AppPage.log;
  // OCR camera fields
CameraController? _controller;
late final TextRecognizer _textRecognizer;


double _frontweight = 0.00;
double _rearweight = 0.00;
double _totalweight = 0.00;
String _containerNumberText = "";
String _sealNumberText = "";
String _tareText = "";
String? _ocrDebugImagePath;
  final GlobalKey _cameraPreviewKey = GlobalKey();
  Timer? _bleUiThrottle;
bool _bleUiPendingUpdate = false;
String? _lastConnectedMac;
bool _isReconnecting = false;

Timer? _rssiTimer;
bool _isCapturing = false;
bool _hasWeightData = false;

static const _ocrTtlMinutes = 10;
final pageWidth = 80 * PdfPageFormat.mm;
 

static const _keyContainer = 'ocr_container';
static const _keySeal = 'ocr_seal';
static const _keyTare = 'ocr_tare';

static const _keyLastUsedTs = 'ocr_last_used_ts';

static const _keyLockedWeight = 'locked_weight';
 static const _keyIsLocked = 'is_weight_locked';
 bool _isDisconnected = false;

bool _isWeightLocked = false;
 double _lockedWeight = 0.0;


// Clock for live time
  DateTime _currentTime = DateTime.now(); // <- ADD THIS
  Timer? _clockTimer; // <- ADD THIS


  final flutterReactiveBle = FlutterReactiveBle();
  final List<DiscoveredDevice> devices = [];
  DiscoveredDevice? connectedDevice;
  

  final Map<String, StreamSubscription<List<int>>> subscriptions = {};
  final Set<String> subscribedCharacteristics = {};
  StreamSubscription<DiscoveredDevice>? scanSubscription;
  StreamSubscription<ConnectionStateUpdate>? connectionSubscription;

  final Map<String, Map<String, String>> latestData = {};
  DateTime _lastPacketTime = DateTime.now();
  Timer? _watchdogTimer;


@override
void initState() {
  super.initState();

  WidgetsBinding.instance.addObserver(this);

  _requestPermissionsAndScan();
  _loadOcrCache();

  _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

  _startWatchdog();
_loadLockedWeight();

  _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
    setState(() {
      _currentTime = DateTime.now();
    });
  });

  _loadLastConnectedDevice().then((mac) {
    if (mac != null) {
      setState(() => _lastConnectedMac = mac);
    }
  });
}






@override
void dispose() {
  WidgetsBinding.instance.removeObserver(this);

  scanSubscription?.cancel();
  connectionSubscription?.cancel();
  for (final sub in subscriptions.values) {
    sub.cancel();
  }
  _watchdogTimer?.cancel();
  _controller?.dispose();
  _textRecognizer.close();
  super.dispose();
}



Future<void> _requestPermissionsAndScan() async {
  final status = await [
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
    Permission.location,
    Permission.camera
  ].request();

  if (status.values.every((s) => s.isGranted)) {
    _startScan();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initCamera();   // ✅ SAFE INITIALIZATION
    });
  }
}

void _startScan() {
  scanSubscription?.cancel();
  devices.clear();

  scanSubscription = flutterReactiveBle
      .scanForDevices(withServices: [], scanMode: ScanMode.lowLatency)
      .listen((device) {
    if (!devices.any((d) => d.id == device.id)) {
      setState(() => devices.add(device));
    }

    // Auto-connect if this device matches last connected MAC
    if (_lastConnectedMac != null && device.id == _lastConnectedMac) {
      print("Auto-connecting to last device: ${device.id}");
      _connectToDevice(device);
    }
  });
}

void _connectToDevice(DiscoveredDevice device) {
  connectionSubscription?.cancel();

  _lastConnectedMac = device.id;
  _saveLastConnectedDevice(device.id);

  try {
    connectionSubscription = flutterReactiveBle
        .connectToDevice(
          id: device.id,
          connectionTimeout: const Duration(seconds: 10),
        )
        .listen(
      (update) async {
        print("BLE State: ${update.connectionState}");
        if (update.connectionState == DeviceConnectionState.connected) {
          _isReconnecting = false;
          scanSubscription?.cancel();
          setState(() => connectedDevice = device);
          _isDisconnected = false;
          try {
            await flutterReactiveBle.requestMtu(deviceId: device.id, mtu: 247);
          } catch (_) {}

          await Future.delayed(const Duration(milliseconds: 300));
          await _discoverAndSubscribe(device);
          _startRssiUpdates(device.id);
        } else if (update.connectionState == DeviceConnectionState.disconnected) {
  print("Device disconnected, attempting reconnect...");

  setState(() {
    _isDisconnected = true;
    _hasWeightData = false;
  });

  _clearConnection();
  _reconnectDevice();
}

      },
      onError: (err) {
        print("Connection error (catch): $err");
        _clearConnection();
        _reconnectDevice();
      },
    );
  } catch (e) {
    print("BLE connect failed: $e");
    Future.delayed(const Duration(seconds: 2), () => _reconnectDevice());
  }
}


void _reconnectDevice() {
  if (_lastConnectedMac == null || _isReconnecting) return;

  _isReconnecting = true;

  try {
    final device = devices.firstWhere((d) => d.id == _lastConnectedMac);
    print("Auto-reconnecting to ${device.id}...");

    _clearConnection();

    Future.delayed(const Duration(seconds: 2), () {
      _connectToDevice(device);
    });
  } catch (e) {
    print("Device $_lastConnectedMac not found, retrying in 2s...");
    Future.delayed(const Duration(seconds: 2), () {
      _isReconnecting = false;
      _reconnectDevice();
    });
  }
}




void _clearConnection() {
  setState(() => connectedDevice = null);

  // Cancel all characteristic subscriptions
  for (final sub in subscriptions.values) {
    sub.cancel();
  }
  subscriptions.clear();
  subscribedCharacteristics.clear();

  // Cancel main connection subscription if it exists
  connectionSubscription?.cancel();
  connectionSubscription = null;
  
    // ✅ Stop RSSI updates
  _stopRssiUpdates();

  // Reset reconnect flag
  _isReconnecting = false;
}


Future<void> _discoverAndSubscribe(DiscoveredDevice device) async {
  final services = await flutterReactiveBle.discoverServices(device.id);

  for (final s in services) {
    for (final c in s.characteristics) {
      if (c.characteristicId ==
          Uuid.parse("2b68c570-8e48-11e7-bb31-be2e44b06b34")) {
        _subscribeToCharacteristic(device.id, s.serviceId, c.characteristicId);
      }
    }
  }
}

void _subscribeToCharacteristic(String deviceId, Uuid serviceId, Uuid charId) {
  final key = '$deviceId-$serviceId-$charId';
  if (subscribedCharacteristics.contains(key)) return;

  final qc = QualifiedCharacteristic(
    deviceId: deviceId,
    serviceId: serviceId,
    characteristicId: charId,
  );

  try {
    final sub = flutterReactiveBle.subscribeToCharacteristic(qc).listen(
      (data) {
        if (_isDisconnected) return; // stop updates instantly
        // Update last packet time
        _lastPacketTime = DateTime.now();

        final packets = _parseBlePacket(data);
        if (packets.isEmpty) return;

        for (final p in packets) {
          latestData[p['id']!] = {
            'timestamp': p['timestamp']!,
            'data': p['data']!
          };
          _logPacket(p);
        }

if (!_isWeightLocked && !_isDisconnected) {
  final fw = getCanValue('0x403', byteIndex: 4, length: 2, scale: 0.01);
  final rw = getCanValue('0x404', byteIndex: 4, length: 2, scale: 0.01);

  // Detect if packets are valid
  if (fw != 0 || rw != 0) {
    _hasWeightData = true;
    _frontweight = fw;
    _rearweight = rw;
    _totalweight = fw + rw;
  }
}



        // Throttle UI updates to max 5Hz
        if (_bleUiThrottle == null || !_bleUiThrottle!.isActive) {
          _bleUiThrottle = Timer(const Duration(milliseconds: 200), () {
            setState(() {});
            if (_bleUiPendingUpdate) {
              _bleUiPendingUpdate = false;
              _bleUiThrottle = Timer(const Duration(milliseconds: 200), () {
                setState(() {});
              });
            }
          });
        } else {
          _bleUiPendingUpdate = true;
        }
      },
      onError: (err) async {
        print("Subscription error for $key: $err");
        await _cleanupSubscription(key);
        // Delay reconnect to avoid race condition
        Future.delayed(const Duration(seconds: 2), _reconnectDevice);
      },
      onDone: () async {
        print("Subscription done for $key");
        await _cleanupSubscription(key);
        Future.delayed(const Duration(seconds: 2), _reconnectDevice);
      },
    );

    subscriptions[key] = sub;
    subscribedCharacteristics.add(key);

  } catch (e) {
    // Catch synchronous exceptions from RxBLE (like GATT status 8)
    print("Failed to subscribe to $key: $e");
    Future.delayed(const Duration(seconds: 2), _reconnectDevice);
  }
}


Future<void> _cleanupSubscription(String key) async {
  final sub = subscriptions[key];
  if (sub != null) {
    await sub.cancel();
    subscriptions.remove(key);
  }
  subscribedCharacteristics.remove(key);
}


  List<Map<String, String>> _parseBlePacket(List<int> raw) {
    final packets = <Map<String, String>>[];
    int i = 0;

    while (i + 10 < raw.length) {
      if (raw[i] != 0x21) {
        i++;
        continue;
      }

      final idLow = raw[i + 1];
      final idHigh = raw[i + 2];
      String hexId = "${idHigh.toRadixString(16).padLeft(2,'0')}${idLow.toRadixString(16).padLeft(2,'0')}";
      hexId = hexId.toUpperCase().replaceFirst(RegExp(r'^0+'), '');
      final id = "0x$hexId";

      final payloadBytes = raw.sublist(i + 4, i + 12);
      final data = payloadBytes.map((b) => b.toRadixString(16).padLeft(2,'0').toUpperCase()).join(' ');

      final now = DateTime.now();
      final ts = "${now.hour.toString().padLeft(2,'0')}:${now.minute.toString().padLeft(2,'0')}:${now.second.toString().padLeft(2,'0')}";

      packets.add({'timestamp': ts, 'id': id, 'data': data});
      i += 11;
    }
    return packets;
  }

  Future<File> _getLogFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/ble_raw_log.csv');
    if (!await file.exists()) {
      await file.writeAsString('timestamp,id,data\n');
    }
    return file;
  }

  void _logPacket(Map<String, String> p) async {
    final file = await _getLogFile();
    await file.writeAsString("${p['timestamp']},${p['id']},${p['data']}\n", mode: FileMode.append);
  }

void _startWatchdog() {
  _watchdogTimer?.cancel();
  _watchdogTimer = Timer.periodic(const Duration(seconds: 5), (_) {
    if (connectedDevice != null && !_isReconnecting) {
      final diff = DateTime.now().difference(_lastPacketTime).inSeconds;
      if (diff > 10) {
        print("No packets in $diff seconds, reconnecting...");
        _isReconnecting = true;
        _reconnectDevice();
      }
    }
  });
}


/// ---------------- UI ----------------
@override
Widget build(BuildContext context) {
  return Scaffold(
    appBar: currentPage == AppPage.log
        ? null
        : AppBar(
            title: Text(
              _getPageTitle(),
              style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
            ),
            backgroundColor: Colors.black,
            iconTheme: const IconThemeData(color: Colors.green),
          ),
    body: _getPageWidget(),
 bottomNavigationBar: BottomNavigationBar(
  backgroundColor: Colors.black,
  selectedItemColor: Colors.green,
  unselectedItemColor: Colors.white70,
  currentIndex: currentPage.index,
  onTap: (index) => setState(() => currentPage = AppPage.values[index]),
  items: const [
    BottomNavigationBarItem(icon: Icon(Icons.home), label: 'SOLAS Ticket'),
    BottomNavigationBarItem(icon: Icon(Icons.monitor_heart), label: 'Live CAN'),
    BottomNavigationBarItem(icon: Icon(Icons.search), label: 'Scan BT'),
    BottomNavigationBarItem(icon: Icon(Icons.build), label: 'Diagnostics'), // NEW
    
    BottomNavigationBarItem(icon: Icon(Icons.info), label: 'Device Info'),
  ],
),

  );
}



  String _getPageTitle() {
    switch (currentPage) {
      case AppPage.scan:
        return 'Discovered Devices';
      case AppPage.liveCan:
        return 'CanBus Live Data';
case AppPage.diagnostics:
  return 'CanBus Diagnostics';
      

      case AppPage.log:
        return 'SOLAS Ticket';
      case AppPage.deviceInfo:
        return 'Device Info';
    }
  }

  Widget _getPageWidget() {
    switch (currentPage) {
      case AppPage.scan:
        return _buildScanPage();
      case AppPage.liveCan:
        return _buildFullScreenTable();
      case AppPage.log:
        return _buildLogPage();
      case AppPage.deviceInfo:
        return _buildDeviceInfoPage();
        case AppPage.diagnostics:
  return _buildDiagnosticsPage();
    }
  }

 Widget _buildScanPage() {
  return ListView.separated(
    itemCount: devices.length,
    itemBuilder: (_, i) {
      final d = devices[i];
      final isSelected = connectedDevice?.id == d.id;
      final isSaved = d.id == _lastConnectedMac;

      return ListTile(
        tileColor: isSelected
            ? Colors.blueGrey[400]
            : isSaved
                ? Colors.blueGrey[400]
                : null,
        title: Text(
          d.name.isEmpty ? 'Unknown' : d.name,
          style: const TextStyle(color: Colors.white),
        ),
        subtitle: Text(d.id, style: const TextStyle(color: Colors.white70)),
        trailing: isSelected
            ? const Icon(Icons.bluetooth_connected, color: Color.fromARGB(255, 0, 255, 100),size: 40,)
            : isSaved
                ? const Icon(Icons.bluetooth_connected, color: Color.fromARGB(255, 255, 0, 0),size: 40,)
                : null,
        onTap: () => _connectToDevice(d),
      );
    },
    separatorBuilder: (_, __) => const Divider(
      color: Colors.grey,  // thin grey line
      height: 1,           // space taken by the divider
      thickness: 0.5,      // actual line thickness
    ),
  );
}



  Widget _buildLiveCanPage() => _buildFullScreenTable();

Widget _buildLogPage() {
  return Stack(
    children: [
      // 1️⃣ Main scrollable content
      SingleChildScrollView(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 25),
            SizedBox(
              height: 125,
              child: Image.asset('assets/boxloader.png', fit: BoxFit.contain),
            ),
            const SizedBox(height: 6),
          SizedBox(
  height: 60,
  width: double.infinity,
  child: _controller != null && _controller!.value.isInitialized
      ? RepaintBoundary(
          key: _cameraPreviewKey,
          child: ClipRect(
            child: OverflowBox(
              maxHeight: double.infinity,
              maxWidth: double.infinity,
              alignment: Alignment.center,
              child: FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: _controller!.value.previewSize!.height,
                  height: _controller!.value.previewSize!.width,
                  child: CameraPreview(_controller!),
                ),
              ),
            ),
          ),
        )
      : const Center(child: CircularProgressIndicator()),
),



            const SizedBox(height: 6),
            _ocrDebugImage(),
            const SizedBox(height: 6),
            _dateTimeBlock(),
            const SizedBox(height: 6),
          
            const SizedBox(height: 1),
 Row(
  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
  children: [
    _actionButton("Create Docket", Colors.deepPurple, onPressed: () {  viewAndShareSolasPdf(
    context,
    dateTime: DateTime.now(),
    containerNo: _containerNumberText,
    sealNo: _sealNumberText,
    tare: _tareText,
    netWeight: _totalweight*1000-(double.tryParse(_tareText) ?? 0),
    verifiedGrossMass: _totalweight*1000,
  );},),
    _actionButton(
      _isWeightLocked ? "Unlock Weight" : " Lock Weight ",
      Colors.deepPurple,
      onPressed: _toggleLockWeight,
    ),
  ],
),


            const SizedBox(height: 6),
            SizedBox(
              height: 40,
              child: Image.asset('assets/logo_customer.png', fit: BoxFit.contain),
            ),
          ],
        ),
      ),

      // 2️⃣ Floating BLE icon + RSSI (top-right)
Positioned(
  top: 30,
  left: 30,  // far left for Bluetooth
  right: 30,  // far right for RSSI
  child: Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      // Bluetooth icon on the far left
      connectedDevice != null
          ? const Icon(
              Icons.bluetooth_connected,
              color: Color.fromARGB(255, 0, 255, 100),
              size: 30,
            )
          : const Icon(
              Icons.bluetooth_disabled,
              color: Colors.red,
              size: 30,
            ),

      // RSSI bars on the far right
      _rssiIcon(connectedDevice?.rssi ?? -100),
    ],
  ),
),

    ],
  );
}










  Widget _buildFullScreenTable() {
    final sortedIds = latestData.keys.toList()..sort();
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: SingleChildScrollView(
              scrollDirection: Axis.vertical,
              child: DataTable(
                headingRowHeight: 32,
                dataRowHeight: 28,
                columnSpacing: 12,
                headingRowColor: WidgetStateProperty.all(Colors.grey[900]),
                dataRowColor: WidgetStateProperty.all(Colors.black),
                columns: const [
                  DataColumn(label: Text('Time', style: TextStyle(color: Colors.white))),
                  DataColumn(label: Text('ID', style: TextStyle(color: Colors.white))),
                  DataColumn(label: Text('Data', style: TextStyle(color: Colors.white))),
                ],
                rows: sortedIds.map((id) {
                  final p = latestData[id]!;
                  return DataRow(cells: [
                    DataCell(Text(p['timestamp']!, style: const TextStyle(color: Colors.white))),
                    DataCell(Text(id, style: const TextStyle(color: Colors.white))),
                    DataCell(Text(p['data']!, style: const TextStyle(fontFamily: 'monospace', color: Color.fromARGB(255, 171, 166, 166)))),
                                    ]);
                }).toList(),
              ),
            ),
          ),
        );
      },
      
    );
  }

/// Helper function to get a value from a CAN packet
/// [canId] = packet ID like '0x403'
/// [byteIndex] = starting byte index to read
/// [length] = number of bytes to combine (1 or 2 for example)
/// [scale] = optional scaling factor
double getCanValue(
  String canId, {
  int byteIndex = 0,
  int length = 2,
  double scale = 1.0,
}) {
  final packet = latestData[canId];
  if (packet == null) return 0.0;

  final bytes = packet['data']!
      .split(' ')
      .map((b) => int.tryParse(b, radix: 16) ?? 0)
      .toList();

  if (bytes.length < byteIndex + length) return 0.0;

  int value = 0;

  // Little endian reconstruction (same as your original)
  for (int i = 0; i < length; i++) {
    value |= bytes[byteIndex + i] << (8 * i);
  }

  // ---- SIGN EXTENSION ----
  int bitLength = length * 8;
  int signBit = 1 << (bitLength - 1);

  if ((value & signBit) != 0) {
    value = value - (1 << bitLength);
  }

  return value.toDouble() * scale;
}


bool getCanBit(String canId, {int byteIndex = 0, int bitIndex = 0}) {
  final packet = latestData[canId];
  if (packet == null) return false;

  final bytes = packet['data']!
      .split(' ')
      .map((b) => int.tryParse(b, radix: 16) ?? 0)
      .toList();

  if (bytes.length <= byteIndex) return false;
  if (bitIndex < 0 || bitIndex > 7) return false;

  return (bytes[byteIndex] & (1 << bitIndex)) != 0;
}

  bool canIdExists(String id) {
    return latestData.containsKey(id);
  }




String getWeightHex() {
  final packet = latestData['0x401'];
  if (packet == null) return "0x00";

  final bytes = packet['data']!
      .split(' ')
      .map((b) => int.tryParse(b, radix: 16) ?? 0)
      .toList();

  if (bytes.length < 4) return "0x00";

  final value = (bytes[5] << 8) | bytes[4];
  return "0x${value.toRadixString(16).toUpperCase().padLeft(4, '0')}";
}

Future<void> _initCamera() async {
  try {
    final cameras = await availableCameras();
    final camera = cameras.first;

    final controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
    );

    await controller.initialize();   // initialize FIRST

    if (!mounted) return;

    setState(() {
      _controller = controller;      // assign AFTER init
    });
  } catch (e) {
    print("Camera init error: $e");
  }
}



Future<void> _scanTextAndSet(String type) async {
    if (_controller == null || !_controller!.value.isInitialized) return;
  if (_isCapturing) return; // already capturing, skip
  _isCapturing = true;

  try {
    // 1️⃣ Take picture
    final picture = await _controller!.takePicture();
    final bytes = await picture.readAsBytes();

    // 2️⃣ Decode image
    img.Image? image = img.decodeImage(bytes);
    if (image == null) return;

    // 3️⃣ Rotate to upright orientation
    final orientation = _controller!.description.sensorOrientation;
     {
      image = img.copyRotate(image, angle: 0);
    }

 // 4️⃣ Crop a centered horizontal strip (match preview strip exactly)
final previewWidth = _controller!.value.previewSize!.width;
final previewHeight = _controller!.value.previewSize!.height;

// desired strip height in pixels relative to camera image
const stripHeightPx = 60; // same as UI strip
final scale = image.width / previewHeight; // because preview is rotated
final stripHeight = (stripHeightPx * scale).round();

final y = ((image.height - stripHeight) / 2).round();

image = img.copyCrop(
  image,
  x: 0,
  y: y,
  width: image.width,
  height: stripHeight,
);


    // 5️⃣ Save debug image
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/ocr_$type.png');
    await file.writeAsBytes(img.encodePng(image));

  // setState(() {
   //   _ocrDebugImagePath = file.path; // show in debug UI
   // });

    // 6️⃣ Run OCR
    final inputImage = InputImage.fromFilePath(file.path);
    final recognized = await _textRecognizer.processImage(inputImage);

    // 7️⃣ Update OCR text in UI
    setState(() {
      final text = recognized.text.trim().split('\n').first;
      if (type == "Container Number") 
      {
        _containerNumberText = text;
          _saveOcrValue(_keyContainer, text);
      } 
      else if (type == "Seal Number")
       {_sealNumberText = text;
          _saveOcrValue(_keySeal, text);
          }
      else if (type == "Tare")
       {final cleaned = text.replaceAll(RegExp(r'[^0-9]'), '');

int tare = int.tryParse(cleaned) ?? 0;

// Round to nearest 10
tare = (tare / 10).round() * 10;

_tareText = tare.toString();

       _saveOcrValue(_keyTare, text);
       }
    });
  } catch (e) {
    print("OCR error for $type: $e");
  }
  finally {
    _isCapturing = false; // allow next capture
  }
}









Future<void> _scanContainerNumber() async => _scanTextAndSet("Container Number");
Future<void> _scanSealNumber() async => _scanTextAndSet("Seal Number");
Future<void> _scanTare() async => _scanTextAndSet("Tare");

Widget _scanButton(String promptText, VoidCallback onTap, {String? ocrText}) {
  final hasScanned = ocrText != null && ocrText.isNotEmpty;

  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: SizedBox(
      width: double.infinity,
      height: 40,
      child: ElevatedButton(
        onPressed: onTap,
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith<Color>((states) {
            if (states.contains(WidgetState.pressed)) {
              return Colors.deepPurple; // pressed color
            }
            return hasScanned ? Colors.grey : Colors.blueAccent;
          }),
          foregroundColor: WidgetStateProperty.all(hasScanned ? Colors.amber : Colors.yellow),
          padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 12)),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(
              borderRadius: hasScanned ?  BorderRadius.circular(5):BorderRadius.circular(15),
              side: hasScanned ? BorderSide.none : const BorderSide(color: Colors.yellow, width: 2),
            ),
          ),
          textStyle: WidgetStateProperty.all(
            const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          elevation: WidgetStateProperty.resolveWith<double>((states) {
            if (states.contains(WidgetState.pressed)) return 0;
            return hasScanned ? 0 : 2;
          }),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            hasScanned ? "$promptText $ocrText" : promptText,
            maxLines: 1,
          ),
        ),
      ),
    ),
  );
}



Widget _actionButton(String text, Color color, {VoidCallback? onPressed}) {
  return ElevatedButton(
    onPressed: onPressed,
    style: ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith<Color>((states) {
        if (states.contains(WidgetState.pressed)) {
        return const Color(0xFF2E2E2E);

        }
        if (states.contains(WidgetState.disabled)) {
          return const Color(0xFF512DA8);
        }
        return color;                      // normal state
      }),
      foregroundColor: WidgetStateProperty.all(Colors.yellow),
      padding: WidgetStateProperty.all(
        const EdgeInsets.symmetric(horizontal: 24, vertical: 3),
      ),
      shape: WidgetStateProperty.all(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: Colors.yellow, width: 2),
        ),
      ),
    ),
    child: Text(text, style: const TextStyle(fontSize: 18)),
  );
}




Widget _dateTimeBlock() {
  final now = DateTime.now();

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // --- Date & Time ---
      Padding(
        padding: const EdgeInsets.only(left: 10), // shift 10 pixels right
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Date: ${now.day.toString().padLeft(2,'0')}/${now.month.toString().padLeft(2,'0')}/${now.year}",
              style: const TextStyle(
                color: Colors.amber,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              "Time: ${now.hour.toString().padLeft(2,'0')}:${now.minute.toString().padLeft(2,'0')}:${now.second.toString().padLeft(2,'0')}",
              style: const TextStyle(
                color: Colors.amber,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),

      const SizedBox(height: 0),

      // --- Container Number Button ---
      _scanButton(
        _containerNumberText.isEmpty ? "Press to Scan Container No:" : "Container No:",
        _scanContainerNumber,
        ocrText: _containerNumberText,
      ),

      // --- Seal Number Button ---
      _scanButton(
        _sealNumberText.isEmpty ? "Press to Scan Seal No:" : "Seal No:",
        _scanSealNumber,
        ocrText: _sealNumberText,
      ),

      // --- Container Tare Button ---
      _scanButton(
        _tareText.isEmpty ? "Press to Scan Container Tare:" : "Container Tare:",
        _scanTare,
        ocrText: _tareText,
      ),

      const SizedBox(height: 0),

      // --- Net Weight ---
      Padding(
        padding: const EdgeInsets.only(left: 10), // shift 10 pixels right
        child: Text(
          _tareText.isEmpty
              ? "Net Weight:"
              : "Net Weight: ${((_totalweight * 1000) - (double.tryParse(_tareText) ?? 0)).toStringAsFixed(0)} kg",

          style: const TextStyle(
            color: Colors.amber,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),

      // --- Gross Weight ---
Padding(
  padding: const EdgeInsets.only(left: 10),
  child: Row(
    children: [
      Text(
        "WEIGHT: ${_totalweight == 0 && !_isWeightLocked && !_isDisconnected
    ? "0 kg"
    : "${((_isWeightLocked ? _lockedWeight : _totalweight) * 1000).toStringAsFixed(0)} kg"}"
,
        style: TextStyle(
color: _isWeightLocked
    ? Colors.red
    : (_isDisconnected || !_hasWeightData)
        ? const Color(0xFFE65100)
        : const Color.fromARGB(255, 2, 179, 25),


          fontSize: 28,
          fontWeight: FontWeight.bold,
        ),
      ),

      const SizedBox(width: 10),

      if (connectedDevice != null)
        Icon(
          _isWeightLocked ? Icons.lock : Icons.lock_open,
          color: _isWeightLocked ? Colors.red : const Color.fromARGB(255, 0, 0, 0),
          size: 30,
        ),
    ],
  ),
),


    ],
  );
}



Size _getCameraPreviewSize() {
  if (_controller != null && _controller!.value.isInitialized) {
    final size = _controller!.value.previewSize!;
    // Swap width and height for portrait mode
    return Size(size.height, size.width);
  }
  return const Size(1, 1);
}

Widget _ocrDebugImage() {
  if (_ocrDebugImagePath == null) return const SizedBox();

  final previewSize = _getCameraPreviewSize();

  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "OCR DEBUG IMAGE",
          style: TextStyle(
            color: Colors.redAccent,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          height: 60, // match your camera strip
          width: double.infinity,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.redAccent, width: 2),
          ),
          child: ClipRect(
            child: Image.file(
              File(_ocrDebugImagePath!),
              fit: BoxFit.fitHeight, // scale to container height, preserve aspect ratio
              alignment: Alignment.center,
            ),
          ),
        ),
      ],
    ),
  );
}

Future<void> _saveLastConnectedDevice(String macAddress) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('last_connected_device', macAddress);
}

Future<String?> _loadLastConnectedDevice() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString('last_connected_device');
}
Widget _rssiIcon(int rssi) {
  // Clamp RSSI to realistic BLE range
 
  // Map RSSI to 0–5 bars
 int bars;
if (rssi >= -55) bars = 5;
else if (rssi >= -65) bars = 4;
else if (rssi >= -75) bars = 3;
else if (rssi >= -85) bars = 2;
else if (rssi >= -95) bars = 1;
else bars = 0;


  // Define bar heights (shortest to tallest)
  final barHeights = [4.0, 8.0, 12.0, 16.0, 20.0];

  return Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.end,
    children: List.generate(5, (i) {
      Color color;
      if (i < bars) {
        if (i < 2) {
          color = Colors.blue;
        } else if (i < 4) color = Colors.blue;
        else color = Colors.blue;
      } else {
        color = Colors.grey[700]!;
      }

      return Container(
        width: 4,
        height: barHeights[i],
        margin: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(1),
        ),
      );
    }),
  );
}


Future<void> viewAndShareSolasPdf(
  BuildContext context, {
  required DateTime dateTime,
  String containerNo = "",
  String sealNo = "",
  String tare = "",
  double netWeight = 0.0,
  double verifiedGrossMass = 0.0,
}) async {   
  final pdf = pw.Document();

  // Load logo
  final logoData = await rootBundle.load('assets/logo_customer.png');
  final logoBytes = logoData.buffer.asUint8List();
  final tareKg = int.tryParse(_tareText) ?? 0;

  final totalKg = verifiedGrossMass; // already passed in correctly
 final netWeightKg = tareKg > 0 ? (totalKg - tareKg) : 0;

  // QR code data
final qrData = '''
Date: ${dateTime.day.toString().padLeft(2,'0')}/${dateTime.month.toString().padLeft(2,'0')}/${dateTime.year}
Time: ${dateTime.hour.toString().padLeft(2,'0')}:${dateTime.minute.toString().padLeft(2,'0')}:${dateTime.second.toString().padLeft(2,'0')}
Container No: $containerNo
Seal No: $sealNo
Container Tare: ${tareKg.toStringAsFixed(0)} kg
Net Weight: ${netWeightKg.toStringAsFixed(0)} kg
Verified Gross Mass: ${totalKg.toStringAsFixed(0)} kg
''';




  pdf.addPage(
    pw.Page(
      pageFormat: PdfPageFormat(pageWidth, double.infinity),
      build: (pw.Context context) {
        return pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // FULL WIDTH LOGO
              pw.Image(
                  pw.MemoryImage(logoBytes),
  width: pageWidth,
  height: 40, // fixed height, no extra vertical space
  fit: pw.BoxFit.contain,
              ),
              pw.SizedBox(height: 12),

                        pw.Text(
                  "      Date: ${dateTime.day.toString().padLeft(2,'0')}/${dateTime.month.toString().padLeft(2,'0')}/${dateTime.year}",
                  style: const pw.TextStyle(fontSize: 12)),
              pw.SizedBox(height: 8),
              pw.Text(
                  "      Time: ${dateTime.hour.toString().padLeft(2,'0')}:${dateTime.minute.toString().padLeft(2,'0')}:${dateTime.second.toString().padLeft(2,'0')}",
                  style: const pw.TextStyle(fontSize: 12)),
              pw.SizedBox(height: 8),
              pw.Text("      Container No: $containerNo", style: const pw.TextStyle(fontSize: 12)),
              pw.SizedBox(height: 8),
              pw.Text("      Seal No: $sealNo", style: const pw.TextStyle(fontSize: 12)),
              pw.SizedBox(height: 8),
pw.Text(
  tareKg > 0
      ? "      Container Tare: ${tareKg.toStringAsFixed(0)} kg"
      : "      Container Tare:",
  style: const pw.TextStyle(fontSize: 12),
),

pw.SizedBox(height: 8),

pw.Text(
  tareKg > 0
      ? "      Net Weight: ${netWeightKg.toStringAsFixed(0)} kg"
      : "      Net Weight:",
  style: const pw.TextStyle(fontSize: 12),
),

pw.SizedBox(height: 8),

pw.Text(
  "      Verified Gross Mass: ${totalKg.toStringAsFixed(0)} kg",
  style: const pw.TextStyle(fontSize: 12),
),


pw.SizedBox(height: 12),

              // QR code
           pw.Padding(
  padding: const pw.EdgeInsets.only(left: 20), // adjust left padding as needed
  child: pw.Container(
    alignment: pw.Alignment.centerLeft, // align to the left
    child: pw.BarcodeWidget(
      data: qrData,
      barcode: pw.Barcode.qrCode(),
      width: 100,
      height: 100,
    ),
  ),
),
              pw.SizedBox(height: 12),
              pw.Text(
                "    * Weighed by BoxLift\n      SOLAS Compliant weighing system",
                style: const pw.TextStyle(fontSize: 12),
              ),
               pw.SizedBox(height: 12),
            ],
          ),
        );
      },
    ),
  );

  // Save PDF
  final tempDir = await getTemporaryDirectory();
  final file = File('${tempDir.path}/solas_ticket.pdf');
  await file.writeAsBytes(await pdf.save());

  // Preview & share
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(
          title: const Text('SOLAS Ticket Preview'),
          actions: [
            IconButton(
              icon: const Icon(Icons.share),
              onPressed: () {
                Share.shareXFiles([XFile(file.path)], text: 'SOLAS Ticket PDF');
              },
            ),
          ],
        ),
        body: pdfx.PdfView(
          controller: pdfx.PdfController(
            document: pdfx.PdfDocument.openFile(file.path),
          ),
        ),
      ),
    ),
  );
}


void _startRssiUpdates(String deviceId) {
  // Cancel any existing timer
  _rssiTimer?.cancel();

  _rssiTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
    // Only proceed if the device is connected and not reconnecting
    if (connectedDevice == null || connectedDevice!.id != deviceId || _isReconnecting) {
      return; // Skip reading RSSI
    }

    try {
      // Read RSSI safely
      final rssi = await flutterReactiveBle.readRssi(deviceId);

      // Update UI
      if (mounted) {
        setState(() {
          connectedDevice = connectedDevice!.copyWith(rssi: rssi);
        });
      }
    } on PlatformException catch (e) {
      // Status 8 = GATT_INSUF_AUTHORIZATION or GATT_CONN_TIMEOUT
      print("RSSI read failed: ${e.code} / ${e.message}");

      // Stop RSSI updates to avoid repeated failures
      _stopRssiUpdates();

      // Optional: trigger reconnect after short delay
      Future.delayed(const Duration(seconds: 2), () {
        if (!_isReconnecting) _reconnectDevice();
      });
    } catch (e) {
      print("Unexpected RSSI error: $e");
      _stopRssiUpdates();
    }
  });
}


void _stopRssiUpdates() {
  _rssiTimer?.cancel();
  _rssiTimer = null;
}

@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.paused) {
    // App is going to background -> close
    _controller?.dispose();
    _controller = null;
    _stopRssiUpdates();
    connectionSubscription?.cancel();
    _clearConnection();
_loadOcrCache();
    // Close the app
    SystemNavigator.pop();
  }
}


Future<void> _saveOcrValue(String key, String value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(key, value);

  // 🔁 reset global timer whenever ANY OCR is used
  await prefs.setInt(
    _keyLastUsedTs,
    DateTime.now().millisecondsSinceEpoch,
  );
}


Future<void> _loadOcrCache() async {
  final prefs = await SharedPreferences.getInstance();

  final ts = prefs.getInt(_keyLastUsedTs);
  if (ts == null) {
    _clearOcrState();
    return;
  }

  final lastUsed = DateTime.fromMillisecondsSinceEpoch(ts);
  final age = DateTime.now().difference(lastUsed);

  if (age.inMinutes > _ocrTtlMinutes) {
    // ⏱ expired → clear everything
    await _clearOcrPrefs();
    _clearOcrState();
    return;
  }

  if (!mounted) return;

  setState(() {
    _containerNumberText = prefs.getString(_keyContainer) ?? "";
    _sealNumberText = prefs.getString(_keySeal) ?? "";
    _tareText = prefs.getString(_keyTare) ?? "";
  });
}
Future<void> _clearOcrPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_keyContainer);
  await prefs.remove(_keySeal);
  await prefs.remove(_keyTare);
  await prefs.remove(_keyLastUsedTs);
}

void _clearOcrState() {
  if (!mounted) return;
  setState(() {
    _containerNumberText = "";
    _sealNumberText = "";
    _tareText = "";
  });
}

void _toggleLockWeight() async {
  final prefs = await SharedPreferences.getInstance();

  setState(() {
    if (!_isWeightLocked) {
      // Locking
      _lockedWeight = _totalweight;
      _isWeightLocked = true;

      prefs.setBool(_keyIsLocked, true);
      prefs.setDouble(_keyLockedWeight, _lockedWeight);
    } else {
      // Unlocking
      _isWeightLocked = false;

      prefs.remove(_keyIsLocked);
      prefs.remove(_keyLockedWeight);
    }
  });
}

Future<void> _loadLockedWeight() async {
  final prefs = await SharedPreferences.getInstance();

  final savedLocked = prefs.getBool(_keyIsLocked) ?? false;
  final savedWeight = prefs.getDouble(_keyLockedWeight);

  if (savedLocked && savedWeight != null) {
    setState(() {
      _isWeightLocked = true;
      _lockedWeight = savedWeight;
    });
  }
}
Widget _diagRow(String title, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title,
            style: const TextStyle(
                color: Colors.grey,
                fontSize: 16)),

        Text(value,
            style: const TextStyle(
                color: Colors.green,
                fontSize: 16,
                fontWeight: FontWeight.bold)),
      ],
    ),
  );
}

Widget diagRowRight(String title, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(
          "$title ",
          style: const TextStyle(
            color: Colors.grey,
            fontSize: 16,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            color: Colors.green,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    ),
  );
}


Widget diagRowLeft(String title, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        Text(
          "$title ",
          style: const TextStyle(
            color: Colors.grey,
            fontSize: 16,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            color: Colors.green,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    ),
  );
}
Widget diagRowInline({
  required String leftTitle,
  required String leftValue,
  required String rightTitle,
  required String rightValue,
  double titleWidth = 90 // <-- fixed width for titles
}) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Row(
      children: [
        // LEFT
        Expanded(
          child: Row(
            children: [
              SizedBox(
                width: titleWidth,
                child: Text(
                  leftTitle,
                  style: const TextStyle(color: Colors.grey, fontSize: 16),
                ),
              ),
              Flexible(
                child: Text(
                  leftValue,
                  style: const TextStyle(
                      color: Colors.green,
                      fontSize: 16,
                      fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12), // small gap
        // RIGHT
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              SizedBox(
                width: titleWidth,
                child: Text(
                  rightTitle,
                  style: const TextStyle(color: Colors.grey, fontSize: 16),
                ),
              ),
              Flexible(
                child: Text(
                  rightValue,
                  style: const TextStyle(
                      color: Colors.green,
                      fontSize: 16,
                      fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

Widget diagHeaderInline({
  String? leftTitle,
  String? rightTitle,
  String? centerTitle,
}) {
  const redHeaderStyle = TextStyle(
    color: Colors.red,
    fontWeight: FontWeight.bold,
    fontSize: 18,
  );

  const blueHeaderStyle = TextStyle(
    color: Colors.blue,
    fontWeight: FontWeight.bold,
    fontSize: 18,
  );

  return Padding(
    padding: const EdgeInsets.only(bottom: 6, top: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // LEFT & RIGHT inline
        Row(
          children: [
            Expanded(
              child: leftTitle != null
                  ? Text(leftTitle, style: redHeaderStyle)
                  : const SizedBox.shrink(),
            ),
            Expanded(
              child: rightTitle != null
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: Text(rightTitle, style: redHeaderStyle),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),

        // CENTER full width
        if (centerTitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              centerTitle,
              style: blueHeaderStyle,
              textAlign: TextAlign.center,
            ),
          ),
      ],
    ),
  );
}







Widget _buildDiagnosticsPage() {
  final now = DateTime.now();
  final lastPacketAge = now.difference(_lastPacketTime).inSeconds;
String AppRear_VersionA =  getCanValue('0x340', byteIndex: 0, length: 1, scale: 1).toStringAsFixed(0);
String AppRear_VersionB =  getCanValue('0x340', byteIndex: 1, length: 1, scale: 1).toStringAsFixed(0);
String AppRear_VersionC =  getCanValue('0x340', byteIndex: 2, length: 1, scale: 1).toStringAsFixed(0);
String AppRear_VersionDay =
    getCanValue('0x340', byteIndex: 3, length: 1, scale: 1)
        .toStringAsFixed(0)
        .padLeft(2, '0');

String AppRear_VersionMonth =
    getCanValue('0x340', byteIndex: 4, length: 1, scale: 1)
        .toStringAsFixed(0)
        .padLeft(2, '0');
String AppRear_VersionYear=  getCanValue('0x340', byteIndex: 5, length: 2, scale: 1).toStringAsFixed(0);
String AppRear_PrjVersion=  getCanValue('0x340', byteIndex: 7, length: 1, scale: 1).toStringAsFixed(0);


String AppFront_VersionA =  getCanValue('0x310', byteIndex: 0, length: 1, scale: 1).toStringAsFixed(0);
String AppFront_VersionB =  getCanValue('0x310', byteIndex: 1, length: 1, scale: 1).toStringAsFixed(0);
String AppFront_VersionC =  getCanValue('0x310', byteIndex: 2, length: 1, scale: 1).toStringAsFixed(0);
String AppFront_VersionDay =
    getCanValue('0x310', byteIndex: 3, length: 1, scale: 1)
        .toStringAsFixed(0)
        .padLeft(2, '0');

String AppFront_VersionMonth =
    getCanValue('0x310', byteIndex: 4, length: 1, scale: 1)
        .toStringAsFixed(0)
        .padLeft(2, '0');
String AppFront_VersionYear=  getCanValue('0x310', byteIndex: 5, length: 2, scale: 1).toStringAsFixed(0);
String AppFront_PrjVersion=  getCanValue('0x310', byteIndex: 7, length: 1, scale: 1).toStringAsFixed(0);


String FrontPwrSupply = getCanValue('0x313', byteIndex: 0, length: 2, scale: .1).toStringAsFixed(1) + " V";
String FrontVPwrA = getCanValue('0x313', byteIndex: 2, length: 2, scale: .1).toStringAsFixed(1) + " V";
String FrontVPwrB = getCanValue('0x313', byteIndex: 4, length: 2, scale: .1).toStringAsFixed(1) + " V";
String FrontVPwrCD = getCanValue('0x313', byteIndex: 6, length: 2, scale: .1).toStringAsFixed(1) + " V";

String RearPwrSupply = getCanValue('0x343', byteIndex: 0, length: 2, scale: .1).toStringAsFixed(1) + " V";
String RearVPwrA = getCanValue('0x343', byteIndex: 2, length: 2, scale: .1).toStringAsFixed(1) + " V";
String RearVPwrB = getCanValue('0x343', byteIndex: 4, length: 2, scale: .1).toStringAsFixed(1) + " V";
String RearVPwrCD = getCanValue('0x343', byteIndex: 6, length: 2, scale: .1).toStringAsFixed(1) + " V";


String AmuStabFront_AngleAct = getCanValue('0x320', byteIndex: 2, length: 2, scale: .1).toStringAsFixed(1)+ "°";
String AmuUnderArmFront_AngleAct = getCanValue('0x320', byteIndex: 6, length: 2, scale: .1).toStringAsFixed(1)+ "°";
String AmuUpperArmFront_AngleAct = getCanValue('0x321', byteIndex: 2, length: 2, scale: .1).toStringAsFixed(1)+ "°";
String AmuCraneFrameFront_AngleAct = getCanValue('0x321', byteIndex: 6, length: 2, scale: .1).toStringAsFixed(1)+ "°";
String AmuStabRear_AngleAct = getCanValue('0x350', byteIndex: 2, length: 2, scale: .1).toStringAsFixed(1)+ "°";
String AmuUnderArmRear_AngleAct = getCanValue('0x350', byteIndex: 6, length: 2, scale:.1).toStringAsFixed(1)+ "°";
String AmuUpperArmRear_AngleAct = getCanValue('0x351', byteIndex: 2, length: 2, scale: .1).toStringAsFixed(1)+ "°";
String AmuCraneFrameRear_AngleAct = getCanValue('0x351', byteIndex: 6, length: 2, scale: .1).toStringAsFixed(1)+ "°";

String pressRear_PistonSide_Adc = getCanValue('0x341', byteIndex: 0, length: 2, scale: 0.01).toStringAsFixed(1)+ " V";
String pressRear_PistonSide_Act = getCanValue('0x341', byteIndex: 2, length: 2, scale: 0.1).toStringAsFixed(1)+ " Bar";
String pressRear_RodSide_Adc = getCanValue('0x341', byteIndex: 4, length: 2, scale: 0.01).toStringAsFixed(1)+ " V";
String pressRear_RodSide_Act = getCanValue('0x341', byteIndex: 6, length: 2, scale: 0.1).toStringAsFixed(1)+ " Bar";

String pressFront_PistonSide_Adc = getCanValue('0x311', byteIndex: 0, length: 2, scale: 0.01).toStringAsFixed(1)+ " V";
String pressFront_PistonSide_Act = getCanValue('0x311', byteIndex: 2, length: 2, scale: 0.1).toStringAsFixed(1)+ " Bar";
String pressFront_RodSide_Adc = getCanValue('0x311', byteIndex: 4, length: 2, scale: 0.01).toStringAsFixed(1)+ " V";
String pressFront_RodSide_Act = getCanValue('0x311', byteIndex: 6, length: 2, scale: 0.1).toStringAsFixed(1)+ " Bar";
  
String sqFront_ExtraLegC2 = getCanBit('0x312', byteIndex: 0, bitIndex: 3) ? "ON" : "OFF";
String sqFront_ExtraLegC1 = getCanBit('0x312', byteIndex: 0, bitIndex: 4) ? "ON" : "OFF";
String sqFront_StabGround = getCanBit('0x312', byteIndex: 0, bitIndex: 5) ? "ON" : "OFF";

String sqRear_ExtraLegC2 = getCanBit('0x342', byteIndex: 0, bitIndex: 3) ? "ON" : "OFF";
String sqRear_ExtraLegC1 = getCanBit('0x342', byteIndex: 0, bitIndex: 4) ? "ON" : "OFF";
String sqRear_StabGround = getCanBit('0x342', byteIndex: 0, bitIndex: 5) ? "ON" : "OFF";


String Display_FRONTactualLoadCorr = getCanValue('0x403', byteIndex: 4, length: 2, scale: 10).toStringAsFixed(0)+ " kg";
String Display_REARactualLoadCorr= getCanValue('0x404', byteIndex: 4, length: 2, scale: 10).toStringAsFixed(0)+ " kg";

String Display_REARstabOutreach = getCanValue('0x404', byteIndex: 0, length: 2, scale: 1).toStringAsFixed(0)+ " mm";
String Display_REARpgh1 = getCanValue('0x404', byteIndex: 2, length: 2, scale: 1).toStringAsFixed(0)+ " mm";

String Display_FRONTstabOutreach = getCanValue('0x403', byteIndex: 0, length: 2, scale: 1).toStringAsFixed(0)+ " mm";
String Display_FRONTpgh1 = getCanValue('0x403', byteIndex: 2, length: 2, scale: 1).toStringAsFixed(0)+ " mm";

String Display_FRONTactualForce = getCanValue('0x40C', byteIndex: 0, length: 2, scale: 0.00981).toStringAsFixed(1)+ " T";
String Display_REARactualForce = getCanValue('0x40C', byteIndex: 2, length: 2, scale: 0.00981).toStringAsFixed(1)+ " T";
  
  return Padding(
    padding: const EdgeInsets.all(12),
    child: ListView(
      children: [

  diagHeaderInline(
    leftTitle: "Front Crane",
    rightTitle: "Rear Crane",
  ),

   

if (canIdExists('0x340') || canIdExists('0x310')) ...[
  diagRowInline(
    leftTitle: "Program",
    leftValue: "$AppFront_VersionA.$AppFront_VersionB.$AppFront_VersionC",
    rightTitle: "Program",
    rightValue: "$AppRear_VersionA.$AppRear_VersionB.$AppRear_VersionC",
  ),
  diagRowInline(
    leftTitle: "Date",
    leftValue: "${AppFront_VersionDay}/${AppFront_VersionMonth}/${AppFront_VersionYear}",
    rightTitle: "Date   ",
    rightValue: "${AppRear_VersionDay}/${AppRear_VersionMonth}/${AppRear_VersionYear}",
  ),
],

 diagHeaderInline(
    centerTitle: "MC2M Voltages",
     ),
if (canIdExists('0x313') || canIdExists('0x343')) ...[
  diagRowInline(
    leftTitle: "Supply",leftValue: FrontPwrSupply,rightTitle: "Supply",rightValue: FrontPwrSupply,),
  diagRowInline(leftTitle: "Output A  ",leftValue: FrontVPwrA,rightTitle: "Output A   ",rightValue: RearVPwrA,),
  diagRowInline(leftTitle: "Output B  ",leftValue: FrontVPwrA,rightTitle: "Output B   ",rightValue: RearVPwrA,),
  diagRowInline(leftTitle: "Output C&D  ",leftValue: FrontVPwrCD,rightTitle: "Output C&D  ",rightValue: RearVPwrCD,),
  ],

 diagHeaderInline(
    centerTitle: "Inclinometer Angles",
     ),

if (canIdExists('0x313') || canIdExists('0x343')) ...[
  diagRowInline(leftTitle: "Over Arm",leftValue: AmuUpperArmFront_AngleAct,rightTitle: "Over Arm",rightValue: AmuUpperArmRear_AngleAct,),
  diagRowInline(leftTitle: "Under Arm",leftValue: AmuUnderArmFront_AngleAct,rightTitle: "Under Arm",rightValue: AmuUnderArmRear_AngleAct,),
  diagRowInline(leftTitle: "Stabiliser",leftValue: AmuStabFront_AngleAct,rightTitle: "Stabiliser",rightValue:AmuStabRear_AngleAct,),
  diagRowInline(leftTitle: "Crane Base",leftValue: AmuCraneFrameFront_AngleAct,rightTitle: "Crane Base",rightValue: AmuCraneFrameRear_AngleAct,),
  ],

  diagHeaderInline(
    centerTitle: "Pressure Tranducers",
     ), 

if (canIdExists('0x313') || canIdExists('0x343')) ...[
  diagRowInline(leftTitle: "Piston Side",leftValue: pressFront_PistonSide_Adc,rightTitle: "Piston Side",rightValue: pressRear_PistonSide_Adc,),
  diagRowInline(leftTitle: "Rod Side",leftValue: pressFront_RodSide_Adc,rightTitle: "Rod Side",rightValue: pressRear_RodSide_Adc,),
  diagRowInline(leftTitle: "Piston Side",leftValue: pressFront_PistonSide_Act,rightTitle: "Piston Side",rightValue:pressRear_PistonSide_Act,),
  diagRowInline(leftTitle: "Rod Side",leftValue: pressFront_RodSide_Act,rightTitle: "Rod Side",rightValue: pressRear_RodSide_Act,),
  ],

  diagHeaderInline(
    centerTitle: "Inductive Sensors",
     ), 

  if (canIdExists('0x313') || canIdExists('0x343')) ...[
  diagRowInline(leftTitle: "Stabiliser",leftValue: sqFront_StabGround,rightTitle: "Stabiliser",rightValue: sqRear_StabGround,),
  diagRowInline(leftTitle: "X Leg In",leftValue: sqFront_ExtraLegC1,rightTitle: "X Leg In",rightValue: sqRear_ExtraLegC1,),
  diagRowInline(leftTitle: "X Leg Up",leftValue:sqFront_ExtraLegC2,rightTitle: "X Leg Up",rightValue: sqRear_ExtraLegC2,),
  ],

    diagHeaderInline(
    centerTitle: "Actual Values",
     ), 

  if (canIdExists('0x313') || canIdExists('0x343')) ...[
  diagRowInline(leftTitle: "Weight",leftValue: Display_FRONTactualLoadCorr,rightTitle: "Weight",rightValue: Display_REARactualLoadCorr,),
  diagRowInline(leftTitle: "Arm Dist",leftValue: Display_FRONTpgh1,rightTitle: "Arm Dist",rightValue: Display_REARpgh1,),
  diagRowInline(leftTitle: "Stab Dist",leftValue:Display_FRONTstabOutreach,rightTitle: "Stab Dist",rightValue: Display_REARstabOutreach,),
  diagRowInline(leftTitle: "Cyl Load",leftValue: Display_FRONTactualForce,rightTitle: "Cyl Load",rightValue:  Display_REARactualForce,),
  ],

  
 

      ],
    ),
  );
}



  Widget _buildDeviceInfoPage() {
    if (connectedDevice == null) return const Center(child: Text('No device connected', style: TextStyle(color: Colors.white)));
    return Padding(
    padding: const EdgeInsets.all(12),
    child: ListView(
      children: [

_diagRow("Connected Device",
            connectedDevice?.name ?? "None"),

        _diagRow("Device ID",
            connectedDevice?.id ?? "N/A"),

        _diagRow("Connection State",
            connectedDevice != null ? "Connected" : "Disconnected"),

        _diagRow("RSSI",
            connectedDevice != null
                ? "${connectedDevice!.rssi} dBm"
                : "N/A"),

        _diagRow("Subscribed Characteristics",
            subscribedCharacteristics.length.toString()),

        _diagRow("Active Subscriptions",
            subscriptions.length.toString()),

      
        _diagRow("Packets Stored",
            latestData.length.toString()),

        _diagRow("Reconnecting",
            _isReconnecting ? "YES" : "NO"),

        _diagRow("Disconnected Flag",
            _isDisconnected ? "YES" : "NO"),

        _diagRow("Weight Locked",
            _isWeightLocked ? "YES" : "NO"),

      ],
    ),
  );
  }

} 