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

    final isSensorError =
        latest.isSensorError;

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
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
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
                          offline:
                              _isSensorWifiOffline,
                        ),

                        Container(
                          padding:
                              const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration:
                              BoxDecoration(
                            color: Colors.blueGrey
                                .withOpacity(0.1),
                            borderRadius:
                                BorderRadius.circular(
                              12,
                            ),
                            border: Border.all(
                              color: Colors.blueGrey
                                  .withOpacity(0.3),
                            ),
                          ),
                          child: Text(
                            'FW: $firmwareDisplay',
                            style:
                                const TextStyle(
                              fontSize: 10,
                              color:
                                  Colors.blueGrey,
                              fontWeight:
                                  FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 8),

              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment:
                      Alignment.centerRight,
                  child: Row(
                    mainAxisSize:
                        MainAxisSize.min,
                    children: [
                      StatusBadge(
                        plnAktif:
                            latest.plnAktif,
                        pln2Aktif:
                            latest.pln2Aktif,
                        isRly1Manual:
                            _isRly1Manual,
                        isRly2Manual:
                            _isRly2Manual,
                      ),

                      const SizedBox(width: 4),

                      // ==================================================
                      // MENU DASHBOARD
                      // OTA SUDAH DIHAPUS
                      // ==================================================

                      PopupMenuButton<String>(
                        tooltip: 'Menu',
                        icon: const Icon(
                          Icons.more_vert,
                        ),
                        onSelected: (value) {
                          if (value == 'ble') {
                            _confirmResetToBleSetup(
                              context,
                            );
                          } else if (value ==
                              'settings') {
                            Navigator.of(context)
                                .push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    const SettingsScreen(),
                              ),
                            );
                          }
                        },
                        itemBuilder:
                            (context) => [
                          const PopupMenuItem<
                              String>(
                            value: 'ble',
                            child: Row(
                              children: [
                                Icon(
                                  Icons
                                      .settings_bluetooth,
                                  size: 20,
                                ),
                                SizedBox(width: 8),
                                Text(
                                  'Setup BLE',
                                ),
                              ],
                            ),
                          ),

                          const PopupMenuItem<
                              String>(
                            value: 'settings',
                            child: Row(
                              children: [
                                Icon(
                                  Icons.tune,
                                  size: 20,
                                ),
                                SizedBox(width: 8),
                                Text(
                                  'Kalibrasi / Settings',
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          // ======================================================
          // POWER FLOW
          // ======================================================

          PowerFlowCard(
            data: latest,
            lfOnOverride:
                _rly1OptimisticOn,
            hfOnOverride:
                _rly2OptimisticOn,
            stickyArusIn:
                _stickyArusIn,
            stickyArusOut:
                _stickyArusOut,
          ),

          const SizedBox(height: 20),

          // ======================================================
          // RELAY CONTROL
          // ======================================================

          Card(
            elevation: 2,
            shape:
                RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.circular(16),
            ),
            child: Padding(
              padding:
                  const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.tune,
                        size: 20,
                        color: Colors.orange,
                      ),

                      const SizedBox(width: 8),

                      const Expanded(
                        child: Text(
                          'Kontrol Manual Relay',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight:
                                FontWeight.bold,
                          ),
                          overflow:
                              TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // ==================================================
                  // LF
                  // ==================================================

                  _RelaySwitchTile(
                    title:
                        'LF — Low Frequency',
                    subtitle:
                        'AUTO: ON ≤48.2V, OFF ≥52V, PV ≥70V→OFF\n'
                        'Sekarang: '
                        '${(_rly1OptimisticOn ?? latest.plnAktif) ? "PLN AKTIF" : "PLTS AKTIF"}'
                        '${_isRly1Manual ? " (dikontrol MANUAL)" : " (dikontrol AUTO firmware)"}',
                    isOn:
                        _rly1OptimisticOn ??
                            latest.plnAktif,
                    isManual:
                        _isRly1Manual,
                    onToggle: (val) =>
                        _toggleRelay(
                      1,
                      val,
                      pvVoltage:
                          latest.pvVoltage,
                    ),
                    onAuto: () =>
                        _setRelayAuto(1),
                  ),

                  const Divider(
                    height: 24,
                  ),

                  // ==================================================
                  // HF
                  // ==================================================

                  _RelaySwitchTile(
                    title:
                        'HF — High Frequency',
                    subtitle:
                        'AUTO: ON jika batt ≤48.7V atau arus drop\n'
                        'Sekarang: '
                        '${(_rly2OptimisticOn ?? latest.pln2Aktif) ? "PLN AKTIF" : "PLTS AKTIF"}'
                        '${_isRly2Manual ? " (dikontrol MANUAL)" : " (dikontrol AUTO firmware)"}',
                    isOn:
                        _rly2OptimisticOn ??
                            latest.pln2Aktif,
                    isManual:
                        _isRly2Manual,
                    onToggle: (val) =>
                        _toggleRelay(
                      2,
                      val,
                      pvVoltage:
                          latest.pvVoltage,
                    ),
                    onAuto: () =>
                        _setRelayAuto(2),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 20),

          // ======================================================
          // STAT CARDS
          // ======================================================

          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics:
                const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.05,
            children: [
              StatCard(
                label:
                    'TEGANGAN BATT',
                value:
                    isSensorError
                        ? 'Err'
                        : latest.tegangan
                            .toStringAsFixed(2),
                unit: 'V',
                icon:
                    Icons.battery_full,
                color:
                    isSensorError
                        ? Colors.red
                        : const Color(
                            0xFF0F9D58,
                          ),
              ),

              StatCard(
                label: 'CHARGING IN',
                value:
                    isSensorError
                        ? 'Err'
                        : _stickyArusIn
                            .toStringAsFixed(2),
                unit: 'A',
                icon: Icons
                    .battery_charging_full,
                color:
                    isSensorError
                        ? Colors.red
                        : const Color(
                            0xFF0F9D58,
                          ),
              ),

              StatCard(
                label: 'BEBAN OUT',
                value:
                    isSensorError
                        ? 'Err'
                        : _stickyArusOut
                            .toStringAsFixed(2),
                unit: 'A',
                icon:
                    Icons.home_rounded,
                color:
                    isSensorError
                        ? Colors.red
                        : const Color(
                            0xFFF57C00,
                          ),
              ),

              StatCard(
                label: 'DAYA BATT',
                value:
                    isSensorError
                        ? 'Err'
                        : latest.daya
                            .toStringAsFixed(1),
                unit: 'W',
                icon: Icons.bolt,
                color:
                    isSensorError
                        ? Colors.red
                        : const Color(
                            0xFFF57C00,
                          ),
              ),

              StatCard(
                label: 'STATUS',
                value:
                    isSensorError
                        ? 'ERR'
                        : latest.statusDisplay,
                unit: '',
                icon:
                    _statusIcon(
                  latest.statusDisplay,
                ),
                color:
                    _statusColor(
                  latest.statusDisplay,
                ),
              ),

              StatCard(
                label:
                    'TEGANGAN PV',
                value:
                    isSensorError
                        ? 'Err'
                        : latest.pvVoltage
                            .toStringAsFixed(1),
                unit: 'V',
                icon:
                    Icons.wb_sunny,
                color:
                    isSensorError
                        ? Colors.red
                        : (
                            latest.pvVoltage >
                                    70
                                ? Colors.orange
                                : Colors.grey
                          ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ======================================================
          // GRAPH
          // ======================================================

          _ArusChart(
            data: chartData,
          ),
        ],
      ),
    );
  }

  // ============================================================
  // STATUS ICON
  // ============================================================

  IconData _statusIcon(String status) {
    switch (status) {
      case 'CHARGING':
        return Icons
            .battery_charging_full;

      case 'DISCHARGING':
        return Icons.battery_alert;

      case 'CEK SENSOR':
      case 'SENSOR_ERR':
        return Icons.warning;

      default:
        return Icons.battery_full;
    }
  }

  // ============================================================
  // STATUS COLOR
  // ============================================================

  Color _statusColor(String status) {
    switch (status) {
      case 'CHARGING':
        return const Color(
          0xFF0F9D58,
        );

      case 'DISCHARGING':
        return const Color(
          0xFFF57C00,
        );

      case 'CEK SENSOR':
      case 'SENSOR_ERR':
        return Colors.red;

      default:
        return const Color(
          0xFF7B1FA2,
        );
    }
  }
}

// ============================================================
// RELAY SWITCH TILE
// ============================================================

class _RelaySwitchTile
    extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool isOn;
  final bool isManual;
  final ValueChanged<bool> onToggle;
  final VoidCallback onAuto;

  const _RelaySwitchTile({
    required this.title,
    required this.subtitle,
    required this.isOn,
    required this.isManual,
    required this.onToggle,
    required this.onAuto,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style:
                    const TextStyle(
                  fontWeight:
                      FontWeight.w600,
                ),
              ),

              const SizedBox(height: 2),

              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 11,
                  color:
                      Colors.grey[600],
                ),
              ),

              const SizedBox(height: 4),

              Container(
                padding:
                    const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 2,
                ),
                decoration:
                    BoxDecoration(
                  color: isManual
                      ? Colors.orange
                          .withOpacity(
                          0.15,
                        )
                      : Colors.green
                          .withOpacity(
                          0.15,
                        ),
                  borderRadius:
                      BorderRadius.circular(
                    8,
                  ),
                ),
                child: Text(
                  isManual
                      ? 'MANUAL'
                      : 'OTOMATIS',
                  style: TextStyle(
                    fontSize: 10,
                    color: isManual
                        ? Colors.orange[800]
                        : Colors.green[800],
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),

        if (isManual)
          TextButton(
            onPressed: onAuto,
            child: const Text(
              'AUTO',
              style: TextStyle(
                fontSize: 12,
              ),
            ),
          ),

        const SizedBox(width: 8),

        GestureDetector(
          onTap: () =>
              onToggle(!isOn),
          child: Container(
            width: 56,
            height: 56,
            decoration:
                BoxDecoration(
              shape:
                  BoxShape.circle,
              color: isOn
                  ? const Color(
                      0xFF00E676,
                    )
                  : Colors.grey[300]!,
              boxShadow: [
                BoxShadow(
                  color: isOn
                      ? const Color(
                          0xFF00E676,
                        ).withOpacity(
                          0.4,
                        )
                      : Colors.grey
                          .withOpacity(
                          0.2,
                        ),
                  blurRadius: 8,
                  spreadRadius:
                      isOn ? 2 : 0,
                ),
              ],
            ),
            child: Icon(
              Icons
                  .power_settings_new,
              color: isOn
                  ? Colors.white
                  : Colors.grey[500],
              size: 28,
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================
// GRAFIK ARUS PLTS
// ============================================================

class _ArusChart
    extends StatefulWidget {
  final List<BatteryData> data;

  const _ArusChart({
    required this.data,
  });

  @override
  State<_ArusChart> createState() =>
      _ArusChartState();
}

class _ArusChartState
    extends State<_ArusChart> {
  int _tab = 0;

  static const _tabs = [
    (
      'Charging',
      Color(0xFF00C853),
      'A',
    ),
    (
      'Load',
      Color(0xFFF57C00),
      'A',
    ),
    (
      'Tegangan',
      Color(0xFF29B6F6),
      'V',
    ),
  ];

  List<FlSpot> _spots() {
    final d = widget.data;

    return [
      for (int i = 0;
          i < d.length;
          i++)
        FlSpot(
          i.toDouble(),
          _tab == 0
              ? d[i].arusInput
              : _tab == 1
                  ? d[i].arusLoad
                  : d[i].tegangan,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final color =
        _tabs[_tab].$2;

    final unit =
        _tabs[_tab].$3;

    final spots = _spots();

    final d = widget.data;

    double maxY = spots.isEmpty
        ? 10
        : spots
            .map((s) => s.y)
            .reduce(
              (a, b) =>
                  a > b ? a : b,
            );

    double minY = spots.isEmpty
        ? 0
        : spots
            .map((s) => s.y)
            .reduce(
              (a, b) =>
                  a < b ? a : b,
            );

    final pad =
        ((maxY - minY) * 0.15)
            .clamp(0.5, 5.0);

    maxY += pad;

    minY = (minY - pad)
        .clamp(
          0,
          double.infinity,
        );

    final interval =
        ((maxY - minY) / 4)
            .clamp(0.5, 20);

    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        // ======================================================
        // GRAPH HEADER
        // ======================================================

        Row(
          children: [
            const Text(
              'Grafik PLTS',
              style: TextStyle(
                fontSize: 15,
                fontWeight:
                    FontWeight.w600,
              ),
            ),

            const Spacer(),

            ...List.generate(
              _tabs.length,
              (i) {
                final selected =
                    i == _tab;

                return GestureDetector(
                  onTap: () {
                    setState(() {
                      _tab = i;
                    });
                  },
                  child:
                      AnimatedContainer(
                    duration:
                        const Duration(
                      milliseconds: 180,
                    ),
                    margin:
                        const EdgeInsets.only(
                      left: 6,
                    ),
                    padding:
                        const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration:
                        BoxDecoration(
                      color: selected
                          ? _tabs[i].$2
                          : _tabs[i]
                              .$2
                              .withOpacity(
                              0.1,
                            ),
                      borderRadius:
                          BorderRadius.circular(
                        20,
                      ),
                      border:
                          Border.all(
                        color: _tabs[i]
                            .$2
                            .withOpacity(
                              selected
                                  ? 1
                                  : 0.4,
                            ),
                      ),
                    ),
                    child: Text(
                      _tabs[i].$1,
                      style:
                          TextStyle(
                        fontSize: 11,
                        fontWeight:
                            FontWeight
                                .bold,
                        color: selected
                            ? Colors.white
                            : _tabs[i]
                                .$2,
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),

        const SizedBox(height: 10),

        // ======================================================
        // CURRENT VALUE
        // ======================================================

        if (d.isNotEmpty)
          Padding(
            padding:
                const EdgeInsets.only(
              bottom: 6,
            ),
            child: Row(
              crossAxisAlignment:
                  CrossAxisAlignment.end,
              children: [
                Text(
                  _tab == 0
                      ? d.last.arusInput
                          .toStringAsFixed(2)
                      : _tab == 1
                          ? d.last.arusLoad
                              .toStringAsFixed(
                              2,
                            )
                          : d.last.tegangan
                              .toStringAsFixed(
                              2,
                            ),
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight:
                        FontWeight.bold,
                    color: color,
                  ),
                ),

                Padding(
                  padding:
                      const EdgeInsets.only(
                    bottom: 5,
                    left: 4,
                  ),
                  child: Text(
                    unit,
                    style:
                        TextStyle(
                      fontSize: 14,
                      color: color
                          .withOpacity(
                        0.7,
                      ),
                    ),
                  ),
                ),

                const SizedBox(width: 12),

                Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(
                      'max '
                      '${spots.map((s) => s.y).reduce((a, b) => a > b ? a : b).toStringAsFixed(1)}'
                      '$unit',
                      style: TextStyle(
                        fontSize: 10,
                        color:
                            Colors.grey[500],
                      ),
                    ),

                    Text(
                      'min '
                      '${spots.map((s) => s.y).reduce((a, b) => a < b ? a : b).toStringAsFixed(1)}'
                      '$unit',
                      style: TextStyle(
                        fontSize: 10,
                        color:
                            Colors.grey[500],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

        // ======================================================
        // GRAPH
        // ======================================================

        Container(
          height: 200,
          padding:
              const EdgeInsets.fromLTRB(
            4,
            8,
            12,
            4,
          ),
          decoration:
              BoxDecoration(
            color: Colors.white,
            borderRadius:
                BorderRadius.circular(
              16,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black
                    .withOpacity(
                  0.04,
                ),
                blurRadius: 12,
                offset:
                    const Offset(
                  0,
                  4,
                ),
              ),
            ],
          ),
          child: spots.isEmpty
              ? const Center(
                  child: Text(
                    'Belum ada data',
                    style: TextStyle(
                      color:
                          Colors.grey,
                    ),
                  ),
                )
              : LineChart(
                  LineChartData(
                    minY: minY,
                    maxY: maxY,

                    gridData:
                        FlGridData(
                      show: true,
                      drawVerticalLine:
                          false,
                      horizontalInterval:
                          interval,
                      getDrawingHorizontalLine:
                          (_) => FlLine(
                        color: Colors.grey
                            .withOpacity(
                          0.15,
                        ),
                        strokeWidth: 1,
                      ),
                    ),

                    titlesData:
                        FlTitlesData(
                      topTitles:
                          const AxisTitles(
                        sideTitles:
                            SideTitles(
                          showTitles:
                              false,
                        ),
                      ),

                      rightTitles:
                          const AxisTitles(
                        sideTitles:
                            SideTitles(
                          showTitles:
                              false,
                        ),
                      ),

                      leftTitles:
                          AxisTitles(
                        sideTitles:
                            SideTitles(
                          showTitles:
                              true,
                          reservedSize:
                              38,
                          interval:
                              interval,
                          getTitlesWidget:
                              (v, _) =>
                                  Text(
                            v.toStringAsFixed(
                              _tab == 2
                                  ? 0
                                  : 1,
                            ),
                            style:
                                const TextStyle(
                              fontSize:
                                  9,
                              color:
                                  Colors.grey,
                            ),
                          ),
                        ),
                      ),

                      bottomTitles:
                          AxisTitles(
                        sideTitles:
                            SideTitles(
                          showTitles:
                              true,
                          reservedSize:
                              24,
                          getTitlesWidget:
                              (value,
                                  meta) {
                            if (d.isEmpty) {
                              return const SizedBox
                                  .shrink();
                            }

                            final total =
                                d.length;

                            final idx =
                                value.toInt();

                            if (idx == 0 ||
                                idx ==
                                    total -
                                        1 ||
                                idx ==
                                    total ~/
                                        2) {
                              final safeIdx =
                                  idx.clamp(
                                0,
                                total - 1,
                              );

                              return Padding(
                                padding:
                                    const EdgeInsets
                                        .only(
                                  top: 4,
                                ),
                                child:
                                    Text(
                                  DateFormat(
                                    'HH:mm',
                                  ).format(
                                    d[safeIdx]
                                        .createdAt,
                                  ),
                                  style:
                                      const TextStyle(
                                    fontSize:
                                        9,
                                    color:
                                        Colors.grey,
                                  ),
                                ),
                              );
                            }

                            return const SizedBox
                                .shrink();
                          },
                        ),
                      ),
                    ),

                    borderData:
                        FlBorderData(
                      show: false,
                    ),

                    lineBarsData: [
                      LineChartBarData(
                        spots: spots,
                        isCurved: true,
                        color: color,
                        barWidth: 2.5,

                        dotData:
                            FlDotData(
                          show: true,
                          getDotPainter:
                              (
                            spot,
                            _,
                            __,
                            idx,
                          ) {
                            final isLast =
                                idx ==
                                    spots.length -
                                        1;

                            return FlDotCirclePainter(
                              radius:
                                  isLast
                                      ? 4.5
                                      : 0,
                              color:
                                  color,
                              strokeWidth:
                                  0,
                              strokeColor:
                                  Colors
                                      .transparent,
                            );
                          },
                        ),

                        belowBarData:
                            BarAreaData(
                          show: true,
                          gradient:
                              LinearGradient(
                            begin:
                                Alignment
                                    .topCenter,
                            end:
                                Alignment
                                    .bottomCenter,
                            colors: [
                              color.withOpacity(
                                0.22,
                              ),
                              color.withOpacity(
                                0.01,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],

                    lineTouchData:
                        LineTouchData(
                      touchTooltipData:
                          LineTouchTooltipData(
                        getTooltipItems:
                            (spots) =>
                                spots
                                    .map(
                                      (s) =>
                                          LineTooltipItem(
                                        '${s.y.toStringAsFixed(2)} $unit',
                                        TextStyle(
                                          color:
                                              color,
                                          fontWeight:
                                              FontWeight.bold,
                                          fontSize:
                                              12,
                                        ),
                                      ),
                                    )
                                    .toList(),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

// ============================================================
// EMPTY STATE
// ============================================================

class _EmptyState
    extends StatelessWidget {
  final bool sensorWifiOffline;

  const _EmptyState({
    this.sensorWifiOffline = false,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding:
            const EdgeInsets.all(24),
        child: Column(
          mainAxisSize:
              MainAxisSize.min,
          children: [
            Icon(
              sensorWifiOffline
                  ? Icons
                      .wifi_off_rounded
                  : Icons
                      .hourglass_empty,
              size: 48,
              color: sensorWifiOffline
                  ? Colors.redAccent
                  : Colors.grey[400],
            ),

            const SizedBox(height: 12),

            Text(
              sensorWifiOffline
                  ? 'WIFI SENSOR OFF\n'
                    'Menunggu data pertama masuk...'
                  : 'Belum ada data.\n'
                    'Menunggu data dari device...',
              textAlign:
                  TextAlign.center,
            ),

            const SizedBox(height: 16),

            OutlinedButton.icon(
              onPressed: () {
                Navigator.of(context)
                    .push(
                  MaterialPageRoute(
                    builder: (_) =>
                        const BLESetupScreen(),
                  ),
                );
              },
              icon: const Icon(
                Icons.settings_bluetooth,
                size: 18,
              ),
              label: const Text(
                'Setup Device Baru',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// SENSOR WIFI STATUS BADGE
// ============================================================

class _SensorStatusBadge
    extends StatelessWidget {
  final bool offline;

  const _SensorStatusBadge({
    required this.offline,
  });

  @override
  Widget build(BuildContext context) {
    final color = offline
        ? Colors.redAccent
        : const Color(
            0xFF00C853,
          );

    final label = offline
        ? 'WIFI SENSOR OFF'
        : 'WIFI SENSOR ON';

    return AnimatedContainer(
      duration:
          const Duration(
        milliseconds: 400,
      ),
      padding:
          const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 5,
      ),
      decoration:
          BoxDecoration(
        color: color.withOpacity(
          0.12,
        ),
        borderRadius:
            BorderRadius.circular(
          20,
        ),
        border: Border.all(
          color: color.withOpacity(
            0.5,
          ),
        ),
      ),
      child: Row(
        mainAxisSize:
            MainAxisSize.min,
        children: [
          _WifiIcon(
            color: color,
            offline: offline,
          ),

          const SizedBox(width: 6),

          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight:
                  FontWeight.bold,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// WIFI ICON
// ============================================================

class _WifiIcon
    extends StatelessWidget {
  final Color color;
  final bool offline;

  const _WifiIcon({
    required this.color,
    required this.offline,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20,
      height: 18,
      child: CustomPaint(
        painter: _WifiPainter(
          color: color,
          offline: offline,
        ),
      ),
    );
  }
}

// ============================================================
// WIFI PAINTER
// ============================================================

class _WifiPainter
    extends CustomPainter {
  final Color color;
  final bool offline;

  const _WifiPainter({
    required this.color,
    required this.offline,
  });

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    final paint = Paint()
      ..color = color
      ..style =
          PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap =
          StrokeCap.round;

    final cx =
        size.width / 2;

    final cy =
        size.height * 0.72;

    final r3 =
        size.width * 0.48;

    canvas.drawArc(
      Rect.fromCircle(
        center:
            Offset(cx, cy),
        radius: r3,
      ),
      _deg(-155),
      _deg(130),
      false,
      paint,
    );

    final r2 =
        size.width * 0.32;

    canvas.drawArc(
      Rect.fromCircle(
        center:
            Offset(cx, cy),
        radius: r2,
      ),
      _deg(-155),
      _deg(130),
      false,
      paint,
    );

    final r1 =
        size.width * 0.16;

    canvas.drawArc(
      Rect.fromCircle(
        center:
            Offset(cx, cy),
        radius: r1,
      ),
      _deg(-155),
      _deg(130),
      false,
      paint,
    );

    canvas.drawCircle(
      Offset(cx, cy),
      1.8,
      Paint()..color = color,
    );

    if (offline) {
      final xPaint = Paint()
        ..color =
            Colors.redAccent
        ..strokeWidth = 2.2
        ..strokeCap =
            StrokeCap.round;

      canvas.drawLine(
        Offset(
          size.width * 0.15,
          size.height * 0.15,
        ),
        Offset(
          size.width * 0.85,
          size.height * 0.88,
        ),
        xPaint,
      );
    }
  }

  double _deg(double deg) =>
      deg * 3.14159265 / 180;

  @override
  bool shouldRepaint(
    covariant _WifiPainter old,
  ) {
    return old.color != color ||
        old.offline != offline;
  }
}

// ============================================================
// ERROR STATE
// ============================================================

class _ErrorState
    extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const _ErrorState({
    required this.message,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding:
            const EdgeInsets.all(24),
        child: Column(
          mainAxisSize:
              MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: Colors.red[300],
            ),

            const SizedBox(height: 12),

            Text(
              'Gagal memuat data:\n$message',
              textAlign:
                  TextAlign.center,
              style:
                  const TextStyle(
                fontSize: 13,
              ),
            ),

            if (onRetry != null) ...[
              const SizedBox(
                height: 16,
              ),

              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(
                  Icons.refresh,
                  size: 18,
                ),
                label: const Text(
                  'Coba Lagi',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}