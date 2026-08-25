import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';

import '../models/battery_data.dart';
import '../services/supabase_service.dart';
import '../services/local_prefs_service.dart';
import '../services/ble_provisioning_service.dart';
import '../services/ble_constants.dart';
import '../widgets/stat_card.dart';
import '../widgets/status_badge.dart';
import '../widgets/power_flow_card.dart';
import 'ble_setup_screen.dart';
import 'settings_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  // ============================================================
  // TELEMETRY
  // ============================================================

  static const Duration _telemetryInterval = Duration(seconds: 15);

  // 12 x 15 detik = 180 detik = 3 menit
  static const int _maxMissedTelemetry = 12;

  StreamSubscription<List<BatteryData>>? _batterySub;
  StreamSubscription<String>? _bleStatusSub;
  StreamSubscription<bool>? _bleConnSub;
  StreamSubscription<Map<String, dynamic>?>? _relayConfigSub;

  Timer? _pollTimer;
  Timer? _streamRetryTimer;
  Timer? _telemetryWatchdog;

  List<BatteryData> _rows = [];

  bool _loadingFirst = true;
  Object? _streamError;

  int _streamRetryAttempt = 0;

  // ============================================================
  // SENSOR WIFI STATUS
  // ============================================================

  bool _isSensorWifiOffline = true;

  DateTime? _lastTelemetryAt;
  int _missedTelemetryCount = 0;

  // ============================================================
  // FIRMWARE
  // ============================================================

  String _firmwareVersion = '';

  // ============================================================
  // RELAY STATUS
  // ============================================================

  bool _isRly1Manual = false;
  bool _isRly2Manual = false;

  bool _isBleConnecting = false;

  // Optimistic UI
  bool? _rly1OptimisticOn;
  bool? _rly2OptimisticOn;

  Timer? _rly1OptTimer;
  Timer? _rly2OptTimer;

  // ============================================================
  // STICKY CURRENT
  // ============================================================

  double _stickyArusIn = 0.0;
  double _stickyArusOut = 0.0;

  int _zeroCountIn = 0;
  int _zeroCountOut = 0;

  static const int _zeroThreshold = 3;

  // ============================================================
  // INIT
  // ============================================================

  @override
  void initState() {
    super.initState();

    _subscribeStream();
    _listenRelayConfig();
    _autoReconnectBle();

    // Backup polling setiap 5 detik
    _pollTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _pollLatest(),
    );

    // Watchdog telemetry
    _telemetryWatchdog = Timer.periodic(
      _telemetryInterval,
      (_) => _checkTelemetryWatchdog(),
    );

    // BLE status
    _bleStatusSub =
        BLEProvisioningService.instance.statusStream.listen((resp) {
      if (!mounted) return;

      if (resp == BLEConstants.respRly1On ||
          resp == BLEConstants.respRly1Off) {
        setState(() {
          _isRly1Manual = true;
        });
      } else if (resp == BLEConstants.respRly1Auto) {
        setState(() {
          _isRly1Manual = false;
        });
      } else if (resp == BLEConstants.respRly2On ||
          resp == BLEConstants.respRly2Off) {
        setState(() {
          _isRly2Manual = true;
        });
      } else if (resp == BLEConstants.respRly2Auto) {
        setState(() {
          _isRly2Manual = false;
        });
      }
    });

    // BLE connection
    _bleConnSub =
        BLEProvisioningService.instance.connectionStream.listen((_) {
      if (!mounted) return;

      setState(() {});
    });
  }

  // ============================================================
  // STICKY ARUS
  // ============================================================

  void _updateStickyArus(BatteryData d) {
    // ----------------------------
    // ARUS INPUT
    // ----------------------------

    if (d.arusInput > 0) {
      _stickyArusIn = d.arusInput;
      _zeroCountIn = 0;
    } else {
      _zeroCountIn++;

      if (_zeroCountIn >= _zeroThreshold) {
        _stickyArusIn = 0.0;
      }
    }

    // ----------------------------
    // ARUS LOAD
    // ----------------------------

    if (d.arusLoad > 0) {
      _stickyArusOut = d.arusLoad;
      _zeroCountOut = 0;
    } else {
      _zeroCountOut++;

      if (_zeroCountOut >= _zeroThreshold) {
        _stickyArusOut = 0.0;
      }
    }
  }

  // ============================================================
  // REALTIME STREAM
  // ============================================================

  void _subscribeStream() {
    _batterySub?.cancel();

    _batterySub = SupabaseService.instance
        .streamBatteryData(limit: 30)
        .listen(
      (data) {
        if (!mounted) return;

        if (data.isNotEmpty) {
          final latest = data.first;

          _recordIncomingTelemetry(latest);
          _updateStickyArus(latest);
        }

        setState(() {
          if (data.isNotEmpty) {
            _rows = data;
          }

          _loadingFirst = false;
          _streamError = null;
        });

        _streamRetryAttempt = 0;
      },
      onError: (e) {
        if (!mounted) return;

        setState(() {
          _streamError = e;
        });

        _scheduleStreamRetry();
      },
      cancelOnError: false,
    );
  }

  // ============================================================
  // STREAM RETRY
  // ============================================================

  void _scheduleStreamRetry() {
    _streamRetryAttempt++;

    final delaySec =
        _streamRetryAttempt <= 5
            ? _streamRetryAttempt * 2
            : 10;

    _streamRetryTimer?.cancel();

    _streamRetryTimer = Timer(
      Duration(seconds: delaySec),
      _subscribeStream,
    );
  }

  // ============================================================
  // BACKUP POLLING
  // ============================================================

  Future<void> _pollLatest() async {
    if (!mounted) return;

    try {
      final row =
          await SupabaseService.instance.fetchLatestBatteryData();

      if (row == null || !mounted) return;

      final fresh = BatteryData.fromMap(row);

      final currentLatest =
          _rows.isNotEmpty ? _rows.first : null;

      // Hanya proses kalau benar-benar data lebih baru
      if (currentLatest == null ||
          fresh.createdAt.isAfter(currentLatest.createdAt)) {
        final updated = [
          fresh,
          ..._rows.where((e) => e.id != fresh.id),
        ];

        if (!mounted) return;

        setState(() {
          _rows =
              updated.length > 30
                  ? updated.sublist(0, 30)
                  : updated;

          _loadingFirst = false;
          _streamError = null;
        });

        _recordIncomingTelemetry(fresh);
        _updateStickyArus(fresh);

        _streamRetryAttempt = 0;

        debugPrint(
          '[POLL] DATA BARU '
          'id=${fresh.id} '
          'time=${fresh.createdAt}',
        );
      }
    } catch (e) {
      debugPrint('[POLL] gagal: $e');
    }
  }

  // ============================================================
  // RELAY CONFIG STREAM
  // ============================================================

  void _listenRelayConfig() {
    _relayConfigSub =
        SupabaseService.instance.streamRelayConfig().listen(
      (relayConfig) {
        if (!mounted || relayConfig == null) return;

        setState(() {
          if (_rly1OptimisticOn == null) {
            _isRly1Manual =
                relayConfig['relay1_auto'] == false;
          }

          if (_rly2OptimisticOn == null) {
            _isRly2Manual =
                relayConfig['relay2_auto'] == false;
          }
        });
      },
      onError: (e) {
        debugPrint(
          '[Dashboard] streamRelayConfig error: $e',
        );
      },
    );
  }

  // ============================================================
  // TELEMETRY WATCHDOG
  // ============================================================

  void _checkTelemetryWatchdog() {
    if (!mounted) return;

    // Belum pernah mendapat telemetry
    if (_lastTelemetryAt == null) return;

    _missedTelemetryCount++;

    if (_missedTelemetryCount >= _maxMissedTelemetry) {
      if (_isSensorWifiOffline) return;

      setState(() {
        _isSensorWifiOffline = true;
      });
    }
  }

  // ============================================================
  // RECORD TELEMETRY
  // ============================================================

  void _recordIncomingTelemetry(BatteryData latest) {
    final isNewData =
        _lastTelemetryAt == null ||
        latest.createdAt.isAfter(_lastTelemetryAt!);

    if (!isNewData) return;

    _lastTelemetryAt = latest.createdAt;

    // Firmware
    if (latest.firmware.isNotEmpty) {
      _firmwareVersion = latest.firmware;
    }

    final now = DateTime.now();

    final ageInSeconds =
        now.difference(latest.createdAt).inSeconds;

    if (ageInSeconds <= 180) {
      _missedTelemetryCount = 0;
      _isSensorWifiOffline = false;
    } else {
      _missedTelemetryCount = _maxMissedTelemetry;
      _isSensorWifiOffline = true;
    }
  }

  // ============================================================
  // AUTO RECONNECT BLE
  // ============================================================

  Future<void> _autoReconnectBle() async {
    if (!mounted) return;

    setState(() {
      _isBleConnecting = true;
    });

    try {
      await BLEProvisioningService.instance
          .reconnectToSavedDevice();
    } catch (e) {
      debugPrint(
        '[Dashboard] BLE reconnect gagal: $e',
      );
    }

    if (!mounted) return;

    setState(() {
      _isBleConnecting = false;
    });
  }

  // ============================================================
  // DISPOSE
  // ============================================================

  @override
  void dispose() {
    _batterySub?.cancel();
    _bleStatusSub?.cancel();
    _bleConnSub?.cancel();
    _relayConfigSub?.cancel();

    _rly1OptTimer?.cancel();
    _rly2OptTimer?.cancel();

    _streamRetryTimer?.cancel();
    _pollTimer?.cancel();
    _telemetryWatchdog?.cancel();

    super.dispose();
  }

  // ============================================================
  // RESET KE BLE SETUP
  // ============================================================

  Future<void> _confirmResetToBleSetup(
    BuildContext context,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Reset ke Setup BLE?'),
          content: const Text(
            'Ini akan membuka ulang layar setup WiFi. '
            'Kamu perlu menyambungkan device via Bluetooth '
            'dan memasukkan WiFi lagi.',
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(false),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(true),
              child: const Text('Ya, Reset'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;
    if (!context.mounted) return;

    await LocalPrefsService.setSetupDone(false);

    if (!context.mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const BLESetupScreen(),
      ),
    );
  }

  // ============================================================
  // BLE RELAY COMMAND
  // ============================================================

  Future<bool> _trySendRelayViaBle(
    int relayNum, {
    bool? turnOn,
    bool auto = false,
  }) async {
    final cmd = auto
        ? (
            relayNum == 1
                ? BLEConstants.cmdRly1Auto
                : BLEConstants.cmdRly2Auto
          )
        : (
            relayNum == 1
                ? (
                    turnOn!
                        ? BLEConstants.cmdRly1On
                        : BLEConstants.cmdRly1Off
                  )
                : (
                    turnOn!
                        ? BLEConstants.cmdRly2On
                        : BLEConstants.cmdRly2Off
                  )
          );

    try {
      await BLEProvisioningService.instance
          .sendRelayCommand(cmd);

      return true;
    } catch (e) {
      debugPrint(
        '[Dashboard] BLE relay gagal: $e',
      );

      return false;
    }
  }

  // ============================================================
  // SERVER RELAY BACKGROUND
  // ============================================================

  void _syncRelayToServerBackground({
    required int relayNum,
    required bool manual,
    bool state = false,
  }) {
    SupabaseService.instance
        .updateRelayControl(
          relayNum: relayNum,
          manual: manual,
          state: state,
        )
        .catchError(
          (e) => debugPrint(
            '[Dashboard] Sync relay ke server gagal: $e',
          ),
        );
  }

  // ============================================================
  // REVERT OPTIMISTIC RELAY
  // ============================================================

  void _revertRelayOptimistic(
    int relayNum,
    bool prevManual,
  ) {
    if (!mounted) return;

    setState(() {
      if (relayNum == 1) {
        _isRly1Manual = prevManual;
        _rly1OptimisticOn = null;
        _rly1OptTimer?.cancel();
      } else {
        _isRly2Manual = prevManual;
        _rly2OptimisticOn = null;
        _rly2OptTimer?.cancel();
      }
    });
  }

  // ============================================================
  // TOGGLE RELAY
  // ============================================================

  Future<void> _toggleRelay(
    int relayNum,
    bool turnOn, {
    required double pvVoltage,
  }) async {
    // Safety PV
    if (turnOn && pvVoltage >= 70.0) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Relay ON ditolak: PV ≥ 70V, sistem memakai PLTS.',
          ),
          backgroundColor: Colors.orange,
        ),
      );

      return;
    }

    final prevManual =
        relayNum == 1
            ? _isRly1Manual
            : _isRly2Manual;

    // ========================================================
    // OPTIMISTIC UI
    // ========================================================

    setState(() {
      if (relayNum == 1) {
        _isRly1Manual = true;
        _rly1OptimisticOn = turnOn;

        _rly1OptTimer?.cancel();

        _rly1OptTimer = Timer(
          const Duration(seconds: 20),
          () {
            if (!mounted) return;

            setState(() {
              _rly1OptimisticOn = null;
            });
          },
        );

        // Tandai relay 2 sebentar supaya tampilan power flow
        // tidak langsung berkedip
        if (_rly2OptimisticOn == null) {
          final latest =
              _rows.isNotEmpty
                  ? _rows.first
                  : null;

          _rly2OptimisticOn =
              latest?.pln2Aktif;

          _rly2OptTimer?.cancel();

          _rly2OptTimer = Timer(
            const Duration(seconds: 6),
            () {
              if (!mounted) return;

              setState(() {
                _rly2OptimisticOn = null;
              });
            },
          );
        }
      } else {
        _isRly2Manual = true;
        _rly2OptimisticOn = turnOn;

        _rly2OptTimer?.cancel();

        _rly2OptTimer = Timer(
          const Duration(seconds: 20),
          () {
            if (!mounted) return;

            setState(() {
              _rly2OptimisticOn = null;
            });
          },
        );

        if (_rly1OptimisticOn == null) {
          final latest =
              _rows.isNotEmpty
                  ? _rows.first
                  : null;

          _rly1OptimisticOn =
              latest?.plnAktif;

          _rly1OptTimer?.cancel();

          _rly1OptTimer = Timer(
            const Duration(seconds: 6),
            () {
              if (!mounted) return;

              setState(() {
                _rly1OptimisticOn = null;
              });
            },
          );
        }
      }
    });

    // ========================================================
    // COBA BLE TERLEBIH DAHULU
    // ========================================================

    final viaBle = await _trySendRelayViaBle(
      relayNum,
      turnOn: turnOn,
    );

    if (viaBle) {
      _syncRelayToServerBackground(
        relayNum: relayNum,
        manual: true,
        state: turnOn,
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Relay $relayNum → '
            '${turnOn ? "ON" : "OFF"} '
            '(MANUAL, instan via BLE)',
          ),
          duration: const Duration(seconds: 2),
        ),
      );

      return;
    }

    // ========================================================
    // FALLBACK SERVER
    // ========================================================

    try {
      await SupabaseService.instance.updateRelayControl(
        relayNum: relayNum,
        manual: true,
        state: turnOn,
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Relay $relayNum → '
            '${turnOn ? "ON" : "OFF"} '
            '(MANUAL, via server, '
            'diterapkan device dalam ≤5 detik)',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      _revertRelayOptimistic(
        relayNum,
        prevManual,
      );

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Gagal kirim perintah '
            '(BLE & server tidak tersedia): $e',
          ),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // ============================================================
  // SET RELAY AUTO
  // ============================================================

  Future<void> _setRelayAuto(
    int relayNum,
  ) async {
    final prevManual =
        relayNum == 1
            ? _isRly1Manual
            : _isRly2Manual;

    setState(() {
      if (relayNum == 1) {
        _isRly1Manual = false;
        _rly1OptimisticOn = null;
        _rly1OptTimer?.cancel();
      } else {
        _isRly2Manual = false;
        _rly2OptimisticOn = null;
        _rly2OptTimer?.cancel();
      }
    });

    // ========================================================
    // BLE
    // ========================================================

    final viaBle = await _trySendRelayViaBle(
      relayNum,
      auto: true,
    );

    if (viaBle) {
      _syncRelayToServerBackground(
        relayNum: relayNum,
        manual: false,
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Relay $relayNum → OTOMATIS '
            '(instan via BLE)',
          ),
          duration: const Duration(seconds: 2),
        ),
      );

      return;
    }

    // ========================================================
    // SERVER
    // ========================================================

    try {
      await SupabaseService.instance.updateRelayControl(
        relayNum: relayNum,
        manual: false,
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Relay $relayNum → OTOMATIS '
            '(via server, diterapkan device dalam ≤5 detik)',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      setState(() {
        if (relayNum == 1) {
          _isRly1Manual = prevManual;
        } else {
          _isRly2Manual = prevManual;
        }
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Gagal kirim perintah '
            '(BLE & server tidak tersedia): $e',
          ),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    Widget body;

    if (_loadingFirst) {
      body = const Center(
        child: CircularProgressIndicator(),
      );
    } else if (_rows.isEmpty &&
        _streamError != null) {
      body = _ErrorState(
        message: '$_streamError',
        onRetry: _subscribeStream,
      );
    } else if (_rows.isEmpty) {
      body = _EmptyState(
        sensorWifiOffline: _isSensorWifiOffline,
      );
    } else {
      body = _buildDashboardContent(
        context,
        _rows,
        reconnecting: _streamError != null,
      );
    }

    return Scaffold(
      body: body,
    );
  }

  // ============================================================
  // DASHBOARD CONTENT
  // ============================================================

  Widget _buildDashboardContent(
    BuildContext context,
    List<BatteryData> rows, {
    required bool reconnecting,
  }) {
    final latest = rows.first;

    // ============================================================
    // IMPORTANT:
    // Tidak ada lagi _recordIncomingTelemetry() di build().
    // Telemetry hanya diproses ketika data masuk dari stream/poll.
    // ============================================================

    // ============================================================
    // CLEAR OPTIMISTIC RELAY
    // ============================================================

    if (_rly1OptimisticOn != null &&
        latest.plnAktif == _rly1OptimisticOn) {
      _rly1OptimisticOn = null;
      _rly1OptTimer?.cancel();
    }

    if (_rly2OptimisticOn != null &&
        latest.pln2Aktif == _rly2OptimisticOn) {
      _rly2OptimisticOn = null;
      _rly2OptTimer?.cancel();
    }

    final chartData = rows.reversed.toList();

    final isSensorError = latest.isSensorError;

    final firmwareDisplay =
        _firmwareVersion.isNotEmpty
            ? _firmwareVersion
            : 'v--';

    return RefreshIndicator(
      onRefresh: () async {
        await _pollLatest();
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          16,
          16,
          16,
          32,
        ),
        children: [
          // ======================================================
          // HEADER
          // ======================================================

          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'PLTS RAMLI 343',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'Update: '
                      '${DateFormat('dd MMM, HH:mm:ss').format(latest.createdAt)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[600],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        _SensorStatusBadge(
                          offline: _isSensorWifiOffline,
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: isSensorError
                                ? Colors.red
                                : Colors.green,
                            borderRadius:
                                BorderRadius.circular(4),
                          ),
                          child: Text(
                            isSensorError
                                ? 'Sensor Error'
                                : 'Sensor OK',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.blue[700],
                            borderRadius:
                                BorderRadius.circular(4),
                          ),
                          child: Text(
                            'FW: $firmwareDisplay',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const SettingsScreen(),
                  ),
                ),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  child: const Icon(
                    Icons.settings,
                    size: 24,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // ======================================================
          // POWER FLOW CARD
          // ======================================================

          PowerFlowCard(
            pvVoltage: latest.tegPv,
            pvCurrent: _stickyArusIn,
            batVoltage: latest.tegBat,
            batCurrent: _stickyArusOut,
            pln1Aktif: _rly1OptimisticOn ?? latest.plnAktif,
            pln2Aktif: _rly2OptimisticOn ?? latest.pln2Aktif,
            onTogglePln1: () => _toggleRelay(
              1,
              !(_rly1OptimisticOn ?? latest.plnAktif),
              pvVoltage: latest.tegPv,
            ),
            onTogglePln2: () => _toggleRelay(
              2,
              !(_rly2OptimisticOn ?? latest.pln2Aktif),
              pvVoltage: latest.tegPv,
            ),
          ),

          const SizedBox(height: 16),

          // ======================================================
          // RELAY CONTROL SECTION
          // ======================================================

          if (!_isBleConnecting)
            Column(
              children: [
                // Relay 1
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Colors.grey[300]!,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Relay 1 (PLN 1)',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (_isRly1Manual) ...[
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton(
                                onPressed: () => _toggleRelay(
                                  1,
                                  true,
                                  pvVoltage: latest.tegPv,
                                ),
                                child: const Text('ON'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton(
                                onPressed: () => _toggleRelay(
                                  1,
                                  false,
                                  pvVoltage: latest.tegPv,
                                ),
                                child: const Text('OFF'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                      ],
                      FilledButton.tonal(
                        onPressed: () =>
                            _setRelayAuto(1),
                        child: const Text('Set Auto'),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // Relay 2
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Colors.grey[300]!,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Relay 2 (PLN 2)',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (_isRly2Manual) ...[
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton(
                                onPressed: () => _toggleRelay(
                                  2,
                                  true,
                                  pvVoltage: latest.tegPv,
                                ),
                                child: const Text('ON'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton(
                                onPressed: () => _toggleRelay(
                                  2,
                                  false,
                                  pvVoltage: latest.tegPv,
                                ),
                                child: const Text('OFF'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                      ],
                      FilledButton.tonal(
                        onPressed: () =>
                            _setRelayAuto(2),
                        child: const Text('Set Auto'),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),
              ],
            ),

          // ======================================================
          // STAT CARDS
          // ======================================================

          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            children: [
              StatCard(
                title: 'Tegangan PV',
                value:
                    '${latest.tegPv.toStringAsFixed(1)} V',
                color: Colors.blue,
              ),
              StatCard(
                title: 'Tegangan Batt',
                value:
                    '${latest.tegBat.toStringAsFixed(1)} V',
                color: Colors.green,
              ),
              StatCard(
                title: 'Arus Input',
                value: '${_stickyArusIn.toStringAsFixed(1)} A',
                color: Colors.orange,
              ),
              StatCard(
                title: 'Arus Load',
                value:
                    '${_stickyArusOut.toStringAsFixed(1)} A',
                color: Colors.red,
              ),
            ],
          ),

          const SizedBox(height: 16),

          // ======================================================
          // CHART
          // ======================================================

          if (chartData.length > 1)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(
                  color: Colors.grey[300]!,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Tegangan Batt 30 menit terakhir',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 200,
                    child: LineChart(
                      LineChartData(
                        gridData: FlGridData(show: true),
                        titlesData: FlTitlesData(
                          show: true,
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              getTitlesWidget: (value, meta) {
                                final idx =
                                    value.toInt();
                                if (idx < 0 ||
                                    idx >=
                                        chartData
                                            .length) {
                                  return const Text('');
                                }
                                return Text('');
                              },
                            ),
                          ),
                        ),
                        borderData:
                            FlBorderData(show: true),
                        lineBarsData: [
                          LineChartBarData(
                            spots: chartData
                                .asMap()
                                .entries
                                .map((e) {
                              return FlSpot(
                                e.key.toDouble(),
                                e.value.tegBat,
                              );
                            }).toList(),
                            isCurved: true,
                            color: Colors.blue,
                            barWidth: 2,
                            isStrokeCapRound: true,
                            dotData: FlDotData(
                              show: false,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

          const SizedBox(height: 16),

          // ======================================================
          // RESET BUTTON
          // ======================================================

          FilledButton.tonal(
            onPressed: () =>
                _confirmResetToBleSetup(context),
            child: const Text('Reset ke Setup BLE'),
          ),
        ],
      ),
    );
  }
}

// ================================================================
// ERROR STATE
// ================================================================

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline,
            size: 48,
            color: Colors.red[400],
          ),
          const SizedBox(height: 16),
          const Text(
            'Error loading data',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

// ================================================================
// EMPTY STATE
// ================================================================

class _EmptyState extends StatelessWidget {
  final bool sensorWifiOffline;

  const _EmptyState({
    required this.sensorWifiOffline,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.inbox_outlined,
            size: 48,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            sensorWifiOffline
                ? 'Sensor WiFi Offline'
                : 'Belum ada data',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            sensorWifiOffline
                ? 'Tunggu koneksi WiFi sensor aktif kembali'
                : 'Tunggu data dari sensor masuk...',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }
}

// ================================================================
// SENSOR STATUS BADGE
// ================================================================

class _SensorStatusBadge extends StatelessWidget {
  final bool offline;

  const _SensorStatusBadge({
    required this.offline,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 7,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: offline ? Colors.orange : Colors.green,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        offline
            ? 'Sensor WiFi: Offline'
            : 'Sensor WiFi: Online',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
