import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import '../mysql_helper.dart';
import '../midtrans_service.dart';
import '../doku_service.dart';
import '../payment_config.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../photo_filters.dart';
import 'welcome_screen.dart';

class SessionScreen extends StatefulWidget {
  final Map<String, dynamic> user;
  final CameraDescription camera;
  final String printer;

  const SessionScreen({
    super.key,
    required this.user,
    required this.camera,
    required this.printer,
  });

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  static const Color kPrimaryRed = Color(0xFFD3242B);
  static const Color kDarkRed = Color(0xFF94151A);
  static const Color kSoftRedBg = Color(0xFFFFF5F5);
  static const Color kBorderRed = Color(0xFFF3C6C8);
  static const Color kTextDark = Color(0xFF1F1F1F);
  static const Color kTextMuted = Color(0xFF7A6869);

  // Stages: WELCOME, PAYMENT, SHOOTING, SELECTION, PRINTING, DONE
  String _currentStage = 'WELCOME';

  // QRIS Payment variables (Midtrans & DOKU)
  String? _qrisUrl;
  String? _qrisString;
  String? _currentOrderId;
  Timer? _qrisPollingTimer;
  bool _isGeneratingQR = false;
  bool _isCheckingPayment = false;
  String _paymentStatus = 'pending';

  int _selectedPriceIndex = 0;
  int _selectedPrintCount = 1;
  double _price = 25000.0;
  bool _isLoadingPrice = true;
  List<Map<String, dynamic>> _priceList = [];

  // Camera Controller
  CameraController? _cameraController;
  bool _isCameraInitialized = false;

  // Kalibrasi Posisi Cetak
  double _printOffsetX = 0.0;
  double _printOffsetY = 0.0;

  // Templates
  List<Map<String, dynamic>> _templatesList = [];
  Map<String, dynamic>? _selectedTemplate;
  bool _isLoadingTemplates = true;

  // State Pengambilan Foto
  bool _hasStartedShooting = false;
  int _overallTimeRemaining = 120; // 2 menit
  int _shotCountdown = 5; // 5 detik per foto
  int _takenPhotosCount = 0; // Target 5 foto
  bool _isFlashActive = false;
  bool _isCameraMirrored = true; // true = mirror/cermin, false = no mirror/asli

  // Pelacak Retake Foto (Maksimal 2 kali per sesi)
  int _retakeCount = 0;
  static const int _maxRetakeLimit = 2;
  int get _remainingRetakes => (_maxRetakeLimit - _retakeCount).clamp(0, _maxRetakeLimit);

  // Target retake spesifik (jika pengguna hanya memilih foto tertentu untuk difoto ulang)
  List<int> _retakeTargetIndices = [];
  int _currentRetakeIndex = 0;
  bool get _isRetakeMode => _retakeTargetIndices.isNotEmpty;

  // Sub-langkah pada Tahap Pemilihan (1 = Foto & Template, 2 = Filter & Efek, 3 = Preview Full & Cetak)
  int _selectionSubStep = 1;

  void _toggleCameraMirror() {
    setState(() {
      _isCameraMirrored = !_isCameraMirrored;
    });
  }

  Timer? _overallTimer;
  Timer? _shotTimer;
  Timer? _doneTimer;
  Timer? _paymentCountdownTimer;
  int _paymentCountdown = 179; // 02:59
  int _doneCountdown = 60;
  String? _softfileDownloadUrl;
  bool _isUploadingSoftfile = false;
  bool _isSoftfileUploaded = false;
  Map<String, dynamic>? _lastSoftfilePayload;

  // List menyimpan file foto asli
  final List<XFile> _capturedPhotos = [];

  // Pilihan 3 foto (menyimpan indeks foto dari _capturedPhotos)
  final List<int> _selectedPhotosIndices = [];

  // Filter foto terpilih, intensitas (0.0 s/d 1.0) & kecerahan (-0.5 s/d +0.5)
  String _selectedFilterId = 'normal';
  double _filterIntensity = 1.0;
  double _photoBrightness = 0.0;

  List<double> _getEffectiveColorMatrix({String? filterIdOverride, double? intensityOverride}) {
    return getInterpolatedColorMatrix(
      filterIdOverride ?? _selectedFilterId,
      intensityOverride ?? _filterIntensity,
      brightness: _photoBrightness,
    );
  }

  Widget _applyLiveFilter(Widget child, {String? filterIdOverride, double? intensityOverride}) {
    final String fId = filterIdOverride ?? _selectedFilterId;
    final double inten = intensityOverride ?? _filterIntensity;
    if (fId == 'normal' && _photoBrightness == 0.0) {
      return child;
    }
    if (fId != 'normal' && inten <= 0.0 && _photoBrightness == 0.0) {
      return child;
    }
    return ColorFiltered(
      colorFilter: ColorFilter.matrix(
        _getEffectiveColorMatrix(
          filterIdOverride: fId,
          intensityOverride: inten,
        ),
      ),
      child: child,
    );
  }

  @override
  void initState() {
    super.initState();
    windowManager.setFullScreen(true);
    _loadCalibrationSettings();
    _fetchPricing();
    DokuService.prewarmToken();
    _initCamera();
    _fetchTemplates();
  }

  Future<void> _loadCalibrationSettings() async {
    try {
      final file = File('print_calibration.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final data = jsonDecode(content);
        setState(() {
          _printOffsetX = (data['offsetX'] ?? 0.0).toDouble();
          _printOffsetY = (data['offsetY'] ?? 0.0).toDouble();
        });
        debugPrint('Loaded calibration: X=$_printOffsetX mm, Y=$_printOffsetY mm');
      }
    } catch (e) {
      debugPrint('Error loading calibration settings: $e');
    }
  }

  Future<void> _initCamera() async {
    await Future.delayed(const Duration(milliseconds: 1500));

    final List<ResolutionPreset> presets = [
      ResolutionPreset.max,
      ResolutionPreset.veryHigh,
      ResolutionPreset.high,
    ];

    CameraController? activeController;
    bool success = false;

    for (final preset in presets) {
      if (!mounted) break;
      final candidate = CameraController(
        widget.camera,
        preset,
        enableAudio: false,
      );
      _cameraController = candidate;
      try {
        await candidate.initialize();
        activeController = candidate;
        success = true;
        debugPrint('Session camera initialized in HD mode: $preset');
        break;
      } catch (e) {
        debugPrint('Camera preset $preset failed, trying fallback: $e');
        try {
          await candidate.dispose();
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }

    if (mounted && activeController != null && _cameraController == activeController) {
      setState(() {
        _isCameraInitialized = success;
      });
    }
  }

  Future<void> _fetchPricing() async {
    setState(() {
      _isLoadingPrice = true;
    });

    final userId = widget.user['id_user'] as int;
    final prices = await MySqlHelper.getPricesForUser(userId);

    if (!mounted) return;
    setState(() {
      _priceList = prices;
      if (_selectedPriceIndex >= _priceList.length) {
        _selectedPriceIndex = 0;
      }
      _updatePrice();
      _isLoadingPrice = false;
    });
  }

  void _goToPaymentStage() {
    setState(() {
      _currentStage = 'PAYMENT';
      _paymentCountdown = 179; // 02:59
      _selectedPriceIndex = 0;
    });
    _startPaymentCountdown();
    _generateQrisPayment(refreshFromDb: true);
  }

  void _startPaymentCountdown() {
    _paymentCountdownTimer?.cancel();
    _paymentCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _currentStage != 'PAYMENT') {
        timer.cancel();
        return;
      }
      if (_paymentCountdown > 0) {
        setState(() {
          _paymentCountdown--;
        });
      } else {
        timer.cancel();
        _backToWelcomeStage();
      }
    });
  }

  void _backToWelcomeStage() {
    _qrisPollingTimer?.cancel();
    _paymentCountdownTimer?.cancel();
    _isCheckingPayment = false;
    setState(() {
      _currentStage = 'WELCOME';
      _qrisUrl = null;
      _qrisString = null;
      _currentOrderId = null;
      _isGeneratingQR = false;
      _paymentStatus = 'pending';
    });
    // Segarkan harga dan template terbaru dari database online di background saat di layar Welcome
    _fetchPricing();
    _fetchTemplates();
    DokuService.prewarmToken();
  }

  Future<void> _generateQrisPayment({bool refreshFromDb = true}) async {
    _qrisPollingTimer?.cancel();

    setState(() {
      _isGeneratingQR = true;
      _qrisUrl = null;
      _qrisString = null;
      _paymentStatus = 'pending';
      _paymentCountdown = 179;
    });
    _startPaymentCountdown();

    // Selalu ambil daftar harga real-time dari database online saat masuk ke Step 2
    if (refreshFromDb || _priceList.isEmpty || _price <= 0) {
      final userId = widget.user['id_user'] as int;
      final prices = await MySqlHelper.getPricesForUser(userId);
      if (!mounted) return;
      if (prices.isNotEmpty) {
        setState(() {
          _priceList = prices;
          if (_selectedPriceIndex >= _priceList.length) {
            _selectedPriceIndex = 0;
          }
          _updatePrice();
          _isLoadingPrice = false;
        });
      }
    } else {
      _updatePrice();
    }

    final int paymentAmount = (_price > 0 ? _price : 25000.0).toInt();

    final orderId = 'PB-${widget.user['id_user']}-${DateTime.now().millisecondsSinceEpoch}';
    _currentOrderId = orderId;

    final isDoku = PaymentConfig.activeGateway == PaymentGateway.doku;
    Map<String, dynamic>? result;

    if (isDoku) {
      result = await DokuService.generateQRIS(
        orderId: orderId,
        amount: paymentAmount,
        itemName: "PixyBox ${_selectedPrintCount}x cetak",
      );
    } else {
      result = await MidtransService.generateQRIS(
        orderId: orderId,
        amount: paymentAmount,
        itemName: "PixyBox ${_selectedPrintCount}x cetak",
      );
    }

    if (result != null && mounted && _currentOrderId == orderId) {
      MySqlHelper.createSessionHistory(
        orderId: orderId,
        idUser: widget.user['id_user'] as int,
        idTemplate: _selectedTemplate?['id_template'] as int?,
        templateName: _selectedTemplate?['name'] as String?,
        printCount: _selectedPrintCount,
        totalPrice: _price,
        paymentType: isDoku ? 'doku_qris' : 'midtrans_qris',
      );

      setState(() {
        _qrisUrl = result!['qr_url'];
        _qrisString = result['qr_string'];
        _isGeneratingQR = false;
      });
      _startQrisPolling(orderId);
    } else if (mounted) {
      setState(() {
        _isGeneratingQR = false;
      });
    }
  }

  void _startQrisPolling(String orderId) {
    _qrisPollingTimer?.cancel();
    _isCheckingPayment = false;

    _qrisPollingTimer = Timer.periodic(const Duration(seconds: 4), (timer) async {
      if (_currentStage != 'PAYMENT' || _currentOrderId != orderId || !mounted) {
        timer.cancel();
        return;
      }

      if (_isCheckingPayment) {
        return;
      }

      _isCheckingPayment = true;
      try {
        final isDoku = PaymentConfig.activeGateway == PaymentGateway.doku;
        final status = isDoku
            ? await DokuService.checkPaymentStatus(orderId)
            : await MidtransService.checkPaymentStatus(orderId);

        if (!mounted || _currentStage != 'PAYMENT' || _currentOrderId != orderId) {
          timer.cancel();
          return;
        }

        setState(() {
          _paymentStatus = status;
        });

        if (status == 'settlement' || status == 'capture') {
          timer.cancel();
          MySqlHelper.updateSessionStatus(
            orderId: orderId,
            paymentStatus: status,
            sessionStatus: 'paid',
          );
          _goToShootingStage();
        } else if (status == 'expire' || status == 'cancel' || status == 'deny') {
          timer.cancel();
          MySqlHelper.updateSessionStatus(
            orderId: orderId,
            paymentStatus: status,
            sessionStatus: 'cancelled',
          );
        }
      } catch (e) {
        debugPrint('Error polling status: $e');
      } finally {
        _isCheckingPayment = false;
      }
    });
  }

  void _updatePrice() {
    if (_priceList.isEmpty) return;
    final int idx = _selectedPriceIndex.clamp(0, _priceList.length - 1);
    final match = _priceList[idx];
    final int parsedCount = (match['print_count'] is int)
        ? match['print_count'] as int
        : (int.tryParse(match['print_count']?.toString() ?? '') ?? 1);
    final double parsedPrice = (match['price'] is num)
        ? (match['price'] as num).toDouble()
        : (double.tryParse(match['price']?.toString() ?? '') ?? 25000.0);

    _selectedPriceIndex = idx;
    _selectedPrintCount = parsedCount;
    _price = parsedPrice > 0 ? parsedPrice : 25000.0;
  }

  Future<void> _fetchTemplates() async {
    if (!mounted) return;
    setState(() {
      _isLoadingTemplates = true;
    });
    try {
      final int userId = widget.user['id_user'] is int
          ? widget.user['id_user'] as int
          : (int.tryParse(widget.user['id_user']?.toString() ?? '') ?? 1);
      final String role = (widget.user['role'] ?? 'booth').toString();
      final temps = await MySqlHelper.getTemplatesForUser(userId, role);
      if (!mounted) return;
      setState(() {
        _templatesList = temps;
        if (temps.isNotEmpty) {
          final currentId = _selectedTemplate?['id_template'];
          final match = currentId != null
              ? temps.where((t) => t['id_template'] == currentId).toList()
              : <Map<String, dynamic>>[];
          _selectedTemplate = match.isNotEmpty ? match.first : temps.first;
        } else {
          _selectedTemplate = null;
        }
        _isLoadingTemplates = false;
      });
    } catch (e) {
      debugPrint('Error fetching templates: $e');
      if (!mounted) return;
      setState(() {
        _isLoadingTemplates = false;
      });
    }
  }

  double _getTemplateSheetAspectRatio([Map<String, dynamic>? templateOverride]) {
    final targetTemplate = templateOverride ?? _selectedTemplate;
    if (targetTemplate == null) return 102.0 / 152.0;
    final bool isStrip = targetTemplate['template_mode'] == 'strip';
    if (!isStrip) return 102.0 / 152.0;

    final imgData = targetTemplate['image_data'] as Uint8List?;
    if (imgData != null && imgData.length >= 24 && imgData[0] == 0x89 && imgData[1] == 0x50) {
      final bd = ByteData.sublistView(imgData);
      final w = bd.getInt32(16);
      final h = bd.getInt32(20);
      if (h > 0 && (w / h) > 0.55) {
        return 152.0 / 102.0;
      }
    }
    return 102.0 / 152.0;
  }

  Widget _buildSingleStripContent(
    Map<String, dynamic> t,
    double stripW,
    double stripH, {
    String? filterIdOverride,
    double? intensityOverride,
  }) {
    final double slot1X = (t['slot1_x'] as num).toDouble();
    final double slot1Y = (t['slot1_y'] as num).toDouble();
    final double slot1W = (t['slot1_w'] as num).toDouble();
    final double slot1H = (t['slot1_h'] as num).toDouble();

    final double slot2X = (t['slot2_x'] as num).toDouble();
    final double slot2Y = (t['slot2_y'] as num).toDouble();
    final double slot2W = (t['slot2_w'] as num).toDouble();
    final double slot2H = (t['slot2_h'] as num).toDouble();

    final double slot3X = (t['slot3_x'] as num).toDouble();
    final double slot3Y = (t['slot3_y'] as num).toDouble();
    final double slot3W = (t['slot3_w'] as num).toDouble();
    final double slot3H = (t['slot3_h'] as num).toDouble();

    return Stack(
      children: [
        _buildPreviewSlot(0, slot1X, slot1Y, slot1W, slot1H, stripW, stripH, 'Foto 1',
            filterIdOverride: filterIdOverride, intensityOverride: intensityOverride),
        _buildPreviewSlot(1, slot2X, slot2Y, slot2W, slot2H, stripW, stripH, 'Foto 2',
            filterIdOverride: filterIdOverride, intensityOverride: intensityOverride),
        _buildPreviewSlot(2, slot3X, slot3Y, slot3W, slot3H, stripW, stripH, 'Foto 3',
            filterIdOverride: filterIdOverride, intensityOverride: intensityOverride),
        Positioned.fill(
          child: IgnorePointer(
            child: Image.memory(
              t['image_data'] as Uint8List,
              fit: BoxFit.fill,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStripSemi4RContent(
    Map<String, dynamic> t,
    double width,
    double height, {
    String? filterIdOverride,
    double? intensityOverride,
  }) {
    final double slot1X = (t['slot1_x'] as num).toDouble();
    final double slot1Y = (t['slot1_y'] as num).toDouble();
    final double slot1W = (t['slot1_w'] as num).toDouble();
    final double slot1H = (t['slot1_h'] as num).toDouble();

    final double slot2X = (t['slot2_x'] as num).toDouble();
    final double slot2Y = (t['slot2_y'] as num).toDouble();
    final double slot2W = (t['slot2_w'] as num).toDouble();
    final double slot2H = (t['slot2_h'] as num).toDouble();

    final double slot3X = (t['slot3_x'] as num).toDouble();
    final double slot3Y = (t['slot3_y'] as num).toDouble();
    final double slot3W = (t['slot3_w'] as num).toDouble();
    final double slot3H = (t['slot3_h'] as num).toDouble();

    final double slot4X = ((t['slot4_x'] ?? (slot1X + 0.5)) as num).toDouble();
    final double slot4Y = ((t['slot4_y'] ?? slot1Y) as num).toDouble();
    final double slot4W = ((t['slot4_w'] ?? slot1W) as num).toDouble();
    final double slot4H = ((t['slot4_h'] ?? slot1H) as num).toDouble();

    final double slot5X = ((t['slot5_x'] ?? (slot2X + 0.5)) as num).toDouble();
    final double slot5Y = ((t['slot5_y'] ?? slot2Y) as num).toDouble();
    final double slot5W = ((t['slot5_w'] ?? slot2W) as num).toDouble();
    final double slot5H = ((t['slot5_h'] ?? slot2H) as num).toDouble();

    final double slot6X = ((t['slot6_x'] ?? (slot3X + 0.5)) as num).toDouble();
    final double slot6Y = ((t['slot6_y'] ?? slot3Y) as num).toDouble();
    final double slot6W = ((t['slot6_w'] ?? slot3W) as num).toDouble();
    final double slot6H = ((t['slot6_h'] ?? slot3H) as num).toDouble();

    return Stack(
      children: [
        _buildPreviewSlot(0, slot1X, slot1Y, slot1W, slot1H, width, height, 'Foto 1',
            filterIdOverride: filterIdOverride, intensityOverride: intensityOverride),
        _buildPreviewSlot(1, slot2X, slot2Y, slot2W, slot2H, width, height, 'Foto 2',
            filterIdOverride: filterIdOverride, intensityOverride: intensityOverride),
        _buildPreviewSlot(2, slot3X, slot3Y, slot3W, slot3H, width, height, 'Foto 3',
            filterIdOverride: filterIdOverride, intensityOverride: intensityOverride),

        _buildPreviewSlot(0, slot4X, slot4Y, slot4W, slot4H, width, height, 'Foto 1',
            filterIdOverride: filterIdOverride, intensityOverride: intensityOverride),
        _buildPreviewSlot(1, slot5X, slot5Y, slot5W, slot5H, width, height, 'Foto 2',
            filterIdOverride: filterIdOverride, intensityOverride: intensityOverride),
        _buildPreviewSlot(2, slot6X, slot6Y, slot6W, slot6H, width, height, 'Foto 3',
            filterIdOverride: filterIdOverride, intensityOverride: intensityOverride),

        Positioned(
          left: width * 0.5 - 0.5,
          top: 0,
          bottom: 0,
          width: 1,
          child: Container(color: kBorderRed.withAlpha(120)),
        ),

        Positioned.fill(
          child: IgnorePointer(
            child: Image.memory(
              t['image_data'] as Uint8List,
              fit: BoxFit.fill,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCompositePreview(
    double width,
    double height, {
    Map<String, dynamic>? templateOverride,
    String? filterIdOverride,
    double? intensityOverride,
  }) {
    final t = templateOverride ?? _selectedTemplate;
    if (t == null) return const SizedBox();
    final bool isStrip = t['template_mode'] == 'strip';
    final bool isStripSemi4R = t['template_mode'] == 'strip_semi_4r';

    if (isStrip) {
      final double stripW = width / 2.0;
      return Row(
        children: [
          SizedBox(
            width: stripW,
            height: height,
            child: _buildSingleStripContent(
              t,
              stripW,
              height,
              filterIdOverride: filterIdOverride,
              intensityOverride: intensityOverride,
            ),
          ),
          Container(
            width: 1,
            height: height,
            color: kBorderRed,
          ),
          SizedBox(
            width: stripW - 1,
            height: height,
            child: _buildSingleStripContent(
              t,
              stripW - 1,
              height,
              filterIdOverride: filterIdOverride,
              intensityOverride: intensityOverride,
            ),
          ),
        ],
      );
    } else if (isStripSemi4R) {
      return _buildStripSemi4RContent(
        t,
        width,
        height,
        filterIdOverride: filterIdOverride,
        intensityOverride: intensityOverride,
      );
    }

    return _buildSingleStripContent(
      t,
      width,
      height,
      filterIdOverride: filterIdOverride,
      intensityOverride: intensityOverride,
    );
  }

  Widget _buildPreviewSlot(
    int index,
    double x,
    double y,
    double w,
    double h,
    double canvasW,
    double canvasH,
    String placeholder, {
    String? filterIdOverride,
    double? intensityOverride,
  }) {
    final double left = x * canvasW;
    final double top = y * canvasH;
    final double width = w * canvasW;
    final double height = h * canvasH;

    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: Container(
        decoration: BoxDecoration(
          color: kSoftRedBg,
          border: Border.all(color: kBorderRed),
        ),
        child: _selectedPhotosIndices.length > index
            ? ClipRRect(
                child: _applyLiveFilter(
                  Transform.scale(
                    scaleX: _isCameraMirrored ? -1 : 1,
                    child: _capturedPhotos[_selectedPhotosIndices[index]].path.isNotEmpty
                        ? Image.file(
                            File(_capturedPhotos[_selectedPhotosIndices[index]].path),
                            fit: BoxFit.cover,
                            width: double.infinity,
                            height: double.infinity,
                          )
                        : const Center(
                            child: Icon(Icons.broken_image, color: kBorderRed),
                          ),
                  ),
                  filterIdOverride: filterIdOverride,
                  intensityOverride: intensityOverride,
                ),
              )
            : Center(
                child: Text(
                  placeholder,
                  style: TextStyle(color: kPrimaryRed.withAlpha(110), fontSize: 10, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center,
                ),
              ),
      ),
    );
  }

  void _skipPaymentForDebug() {
    _qrisPollingTimer?.cancel();
    _paymentCountdownTimer?.cancel();
    _isCheckingPayment = false;
    setState(() {
      _paymentStatus = 'settlement';
      _currentOrderId ??= 'DEBUG-${DateTime.now().millisecondsSinceEpoch}';
    });
    _goToShootingStage();
  }

  void _goToShootingStage() {
    _qrisPollingTimer?.cancel();
    _paymentCountdownTimer?.cancel();
    _isCheckingPayment = false;
    setState(() {
      _currentStage = 'SHOOTING';
      _hasStartedShooting = false;
      _overallTimeRemaining = 120;
      _shotCountdown = 5;
      _takenPhotosCount = 0;
      _capturedPhotos.clear();
      _selectedPhotosIndices.clear();
      _isFlashActive = false;
    });
    // Segarkan daftar template dari database online saat masuk tahap foto agar siap di Step 3
    _fetchTemplates();
  }

  Future<void> _handleRetake() async {
    if (_remainingRetakes <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Kesempatan foto ulang sudah habis (maksimal 2x per sesi).'),
          backgroundColor: kPrimaryRed,
        ),
      );
      return;
    }

    final List<int>? selectedIndices = await showDialog<List<int>>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _RetakeSelectionDialog(
        capturedPhotos: _capturedPhotos,
        selectedPhotosIndices: _selectedPhotosIndices,
        isCameraMirrored: _isCameraMirrored,
        remainingRetakes: _remainingRetakes,
        maxRetakeLimit: _maxRetakeLimit,
        applyLiveFilter: _applyLiveFilter,
      ),
    );

    if (selectedIndices != null && selectedIndices.isNotEmpty && mounted) {
      setState(() {
        _retakeCount++;
        _retakeTargetIndices = List<int>.from(selectedIndices);
        _currentRetakeIndex = 0;
        _takenPhotosCount = 0;
        _hasStartedShooting = false;
        _overallTimeRemaining = 60;
        _shotCountdown = 5;
        _isFlashActive = false;
        _currentStage = 'SHOOTING';
      });
    }
  }

  void _startShootingFlow() {
    setState(() {
      _hasStartedShooting = true;
    });

    _overallTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_overallTimeRemaining > 1) {
        setState(() {
          _overallTimeRemaining--;
        });
      } else {
        _stopTimers();
        _retakeTargetIndices.clear();
        _currentRetakeIndex = 0;
        _goToSelectionStage();
      }
    });

    _startNextShotTimer();
  }

  void _startNextShotTimer() {
    setState(() {
      _shotCountdown = 5;
    });

    _shotTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_shotCountdown > 1) {
        setState(() {
          _shotCountdown--;
        });
      } else {
        timer.cancel();
        _snapPhoto();
      }
    });
  }

  Future<void> _snapPhoto() async {
    setState(() {
      _isFlashActive = true;
    });

    XFile? file;
    try {
      if (_cameraController != null && _cameraController!.value.isInitialized) {
        file = await _cameraController!.takePicture();
      }
    } catch (e) {
      debugPrint("Gagal menjepret gambar: $e");
    }

    file ??= XFile('');

    if (_isRetakeMode) {
      final int targetIdx = _retakeTargetIndices[_currentRetakeIndex];
      if (targetIdx < _capturedPhotos.length) {
        try {
          final oldFile = File(_capturedPhotos[targetIdx].path);
          if (oldFile.existsSync()) oldFile.deleteSync();
        } catch (_) {}
        _capturedPhotos[targetIdx] = file;
      }
      _currentRetakeIndex++;
      _takenPhotosCount++;
    } else {
      _capturedPhotos.add(file);
      _takenPhotosCount++;
    }

    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        setState(() {
          _isFlashActive = false;
        });

        final bool hasMoreShots = _isRetakeMode
            ? _currentRetakeIndex < _retakeTargetIndices.length
            : _takenPhotosCount < 5;

        if (hasMoreShots) {
          _startNextShotTimer();
        } else {
          _stopTimers();
          _retakeTargetIndices.clear();
          _currentRetakeIndex = 0;
          _goToSelectionStage();
        }
      }
    });
  }

  void _goToSelectionStage() {
    setState(() {
      _currentStage = 'SELECTION';
      _selectionSubStep = 1;
    });
    // Selalu ambil daftar template terbaru langsung dari database online saat masuk ke Step 3
    _fetchTemplates();
  }

  Future<void> _renderAndUploadSoftfile(
    List<img.Image> processedSelectedPhotos,
    Map<int, Uint8List> preProcessedByCaptureIndex,
  ) async {
    final String rawOrderId = _currentOrderId ?? 'PB-${widget.user['id_user']}-${DateTime.now().millisecondsSinceEpoch}';
    final String safeCode = rawOrderId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '');
    _currentOrderId = safeCode;

    if (mounted) {
      setState(() {
        _isUploadingSoftfile = true;
        _isSoftfileUploaded = false;
        _softfileDownloadUrl = null;
      });
    }

    try {
      // Siapkan kelima foto hasil jepretan (_capturedPhotos 1..5) sesuai pilihan Mirror/No Mirror & Filter
      final List<Uint8List> allCapturedJpgBytes = [];
      final effectiveMatrix = _getEffectiveColorMatrix();
      final bool needsFilter =
          (_selectedFilterId != 'normal' && _filterIntensity > 0.0) || _photoBrightness != 0.0;

      for (int i = 0; i < _capturedPhotos.length; i++) {
        if (preProcessedByCaptureIndex.containsKey(i)) {
          allCapturedJpgBytes.add(preProcessedByCaptureIndex[i]!);
          continue;
        }
        final f = File(_capturedPhotos[i].path);
        if (await f.exists()) {
          final bytes = await f.readAsBytes();
          try {
            final decoded = img.decodeImage(bytes);
            if (decoded != null) {
              if (_isCameraMirrored) {
                img.flipHorizontal(decoded);
              }
              if (needsFilter) {
                applyColorMatrixToImage(decoded, effectiveMatrix);
              }
              allCapturedJpgBytes.add(Uint8List.fromList(img.encodeJpg(decoded, quality: 98)));
            } else {
              allCapturedJpgBytes.add(bytes);
            }
          } catch (_) {
            allCapturedJpgBytes.add(bytes);
          }
        }
      }

      img.Image? templateOverlay;
      int canvasW = 1600;
      int canvasH = 2400;

      if (_selectedTemplate != null && _selectedTemplate!['image_data'] != null) {
        final Uint8List tplBytes = _selectedTemplate!['image_data'] as Uint8List;
        templateOverlay = img.decodeImage(tplBytes);
        if (templateOverlay != null && templateOverlay.width > 0 && templateOverlay.height > 0) {
          if (templateOverlay.height < 2400) {
            final double aspect = templateOverlay.width / templateOverlay.height;
            canvasH = 2400;
            canvasW = (canvasH * aspect).round().clamp(1, 4800);
            templateOverlay = img.copyResize(
              templateOverlay,
              width: canvasW,
              height: canvasH,
              interpolation: img.Interpolation.cubic,
            );
          } else {
            canvasW = templateOverlay.width;
            canvasH = templateOverlay.height;
          }
        }
      }

      final img.Image canvas = img.Image(width: canvasW, height: canvasH, numChannels: 4);
      img.fill(canvas, color: img.ColorRgba8(255, 255, 255, 255));

      void drawPhotoSlot(img.Image src, double sx, double sy, double sw, double sh) {
        final int dx = (sx * canvasW).round();
        final int dy = (sy * canvasH).round();
        final int dw = (sw * canvasW).round().clamp(1, canvasW);
        final int dh = (sh * canvasH).round().clamp(1, canvasH);

        final double targetAspect = dw / dh;
        final double srcAspect = src.width / src.height;
        int cropW = src.width;
        int cropH = src.height;
        int cropX = 0;
        int cropY = 0;

        if (srcAspect > targetAspect) {
          cropW = (src.height * targetAspect).round().clamp(1, src.width);
          cropX = ((src.width - cropW) / 2).round();
        } else {
          cropH = (src.width / targetAspect).round().clamp(1, src.height);
          cropY = ((src.height - cropH) / 2).round();
        }

        final img.Image cropped = img.copyCrop(src, x: cropX, y: cropY, width: cropW, height: cropH);
        final img.Image resized = img.copyResize(
          cropped,
          width: dw,
          height: dh,
          interpolation: img.Interpolation.cubic,
        );
        img.compositeImage(canvas, resized, dstX: dx, dstY: dy);
      }

      if (_selectedTemplate != null) {
        final t = _selectedTemplate!;
        final double s1x = (t['slot1_x'] as num).toDouble();
        final double s1y = (t['slot1_y'] as num).toDouble();
        final double s1w = (t['slot1_w'] as num).toDouble();
        final double s1h = (t['slot1_h'] as num).toDouble();

        final double s2x = (t['slot2_x'] as num).toDouble();
        final double s2y = (t['slot2_y'] as num).toDouble();
        final double s2w = (t['slot2_w'] as num).toDouble();
        final double s2h = (t['slot2_h'] as num).toDouble();

        final double s3x = (t['slot3_x'] as num).toDouble();
        final double s3y = (t['slot3_y'] as num).toDouble();
        final double s3w = (t['slot3_w'] as num).toDouble();
        final double s3H = (t['slot3_h'] as num).toDouble();

        if (processedSelectedPhotos.isNotEmpty) drawPhotoSlot(processedSelectedPhotos[0], s1x, s1y, s1w, s1h);
        if (processedSelectedPhotos.length > 1) drawPhotoSlot(processedSelectedPhotos[1], s2x, s2y, s2w, s2h);
        if (processedSelectedPhotos.length > 2) drawPhotoSlot(processedSelectedPhotos[2], s3x, s3y, s3w, s3H);

        if (t['template_mode'] == 'strip_semi_4r') {
          final double s4x = ((t['slot4_x'] ?? (s1x + 0.5)) as num).toDouble();
          final double s4y = ((t['slot4_y'] ?? s1y) as num).toDouble();
          final double s4w = ((t['slot4_w'] ?? s1w) as num).toDouble();
          final double s4h = ((t['slot4_h'] ?? s1h) as num).toDouble();

          final double s5x = ((t['slot5_x'] ?? (s2x + 0.5)) as num).toDouble();
          final double s5y = ((t['slot5_y'] ?? s2y) as num).toDouble();
          final double s5w = ((t['slot5_w'] ?? s2w) as num).toDouble();
          final double s5h = ((t['slot5_h'] ?? s2h) as num).toDouble();

          final double s6x = ((t['slot6_x'] ?? (s3x + 0.5)) as num).toDouble();
          final double s6y = ((t['slot6_y'] ?? s3y) as num).toDouble();
          final double s6w = ((t['slot6_w'] ?? s3w) as num).toDouble();
          final double s6h = ((t['slot6_h'] ?? s3H) as num).toDouble();

          if (processedSelectedPhotos.isNotEmpty) drawPhotoSlot(processedSelectedPhotos[0], s4x, s4y, s4w, s4h);
          if (processedSelectedPhotos.length > 1) drawPhotoSlot(processedSelectedPhotos[1], s5x, s5y, s5w, s5h);
          if (processedSelectedPhotos.length > 2) drawPhotoSlot(processedSelectedPhotos[2], s6x, s6y, s6w, s6h);
        }

        if (templateOverlay != null) {
          img.compositeImage(canvas, templateOverlay, dstX: 0, dstY: 0);
        }
      } else {
        if (processedSelectedPhotos.isNotEmpty) drawPhotoSlot(processedSelectedPhotos[0], 0.06, 0.04, 0.88, 0.28);
        if (processedSelectedPhotos.length > 1) drawPhotoSlot(processedSelectedPhotos[1], 0.06, 0.36, 0.88, 0.28);
        if (processedSelectedPhotos.length > 2) drawPhotoSlot(processedSelectedPhotos[2], 0.06, 0.68, 0.88, 0.28);
      }

      final Uint8List compositeBytes = Uint8List.fromList(img.encodeJpg(canvas, quality: 98));
      final activePreset = kPhotoFilterPresets.firstWhere(
        (p) => p.id == _selectedFilterId,
        orElse: () => kPhotoFilterPresets.first,
      );

      final Map<String, dynamic> payload = {
        'order_id': safeCode,
        'id_user': widget.user['id_user'] ?? 1,
        'template_name': _selectedTemplate?['name'] ?? 'Polos',
        'filter_name': activePreset.name,
        'print_count': _selectedPrintCount,
        'total_price': _price,
        'payment_status': _paymentStatus,
        'composite_base64': base64Encode(compositeBytes),
        if (allCapturedJpgBytes.isNotEmpty) 'photo1_base64': base64Encode(allCapturedJpgBytes[0]),
        if (allCapturedJpgBytes.length > 1) 'photo2_base64': base64Encode(allCapturedJpgBytes[1]),
        if (allCapturedJpgBytes.length > 2) 'photo3_base64': base64Encode(allCapturedJpgBytes[2]),
        if (allCapturedJpgBytes.length > 3) 'photo4_base64': base64Encode(allCapturedJpgBytes[3]),
        if (allCapturedJpgBytes.length > 4) 'photo5_base64': base64Encode(allCapturedJpgBytes[4]),
      };

      _lastSoftfilePayload = payload;
      await _sendSoftfilePayload(payload, safeCode);
    } catch (e) {
      debugPrint('Gagal merender/upload softfile ke pixyboxstudio.biz.id: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingSoftfile = false;
        });
      }
    }
  }

  Future<void> _sendSoftfilePayload(Map<String, dynamic> payload, String safeCode) async {
    for (int attempt = 1; attempt <= 2; attempt++) {
      try {
        final response = await http
            .post(
              Uri.parse('http://pixyboxstudio.biz.id/?path=/api/upload-softfile'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(payload),
            )
            .timeout(const Duration(seconds: 40));

        if (response.statusCode == 200) {
          final decoded = jsonDecode(response.body);
          if (decoded is Map && decoded['success'] == true) {
            if (mounted) {
              setState(() {
                _isSoftfileUploaded = true;
                _softfileDownloadUrl = (decoded['download_url'] ?? 'http://pixyboxstudio.biz.id/?path=/s/$safeCode').toString();
                _doneCountdown = 60;
              });
            }
            return;
          }
        }
      } catch (e) {
        debugPrint('Attempt $attempt gagal upload softfile: $e');
        if (attempt < 2) {
          await Future.delayed(const Duration(seconds: 2));
        }
      }
    }
  }

  Future<void> _retryUploadSoftfile() async {
    if (_lastSoftfilePayload == null || _isUploadingSoftfile) return;
    final String safeCode = (_lastSoftfilePayload!['order_id'] ?? _currentOrderId ?? '').toString();
    setState(() {
      _isUploadingSoftfile = true;
      _isSoftfileUploaded = false;
    });
    try {
      await _sendSoftfilePayload(_lastSoftfilePayload!, safeCode);
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingSoftfile = false;
        });
      }
    }
  }

  Future<void> _triggerRealPrint() async {
    setState(() {
      _currentStage = 'PRINTING';
    });

    try {
      List<pw.MemoryImage> pdfImages = [];
      List<img.Image> processedImgList = [];
      Map<int, Uint8List> preProcessedByCaptureIndex = {};
      final effectiveMatrix = _getEffectiveColorMatrix();
      final bool needsFilter =
          (_selectedFilterId != 'normal' && _filterIntensity > 0.0) || _photoBrightness != 0.0;

      for (final int captureIdx in _selectedPhotosIndices) {
        final f = File(_capturedPhotos[captureIdx].path);
        if (await f.exists()) {
          final bytes = await f.readAsBytes();
          try {
            final decoded = img.decodeImage(bytes);
            if (decoded != null) {
              if (_isCameraMirrored) {
                img.flipHorizontal(decoded);
              }
              if (needsFilter) {
                applyColorMatrixToImage(decoded, effectiveMatrix);
              }
              final flippedBytes = Uint8List.fromList(img.encodeJpg(decoded, quality: 100));
              processedImgList.add(decoded);
              preProcessedByCaptureIndex[captureIdx] = flippedBytes;
              pdfImages.add(pw.MemoryImage(flippedBytes));
            } else {
              pdfImages.add(pw.MemoryImage(bytes));
            }
          } catch (e) {
            debugPrint('Error processing/mirroring print image: $e');
            pdfImages.add(pw.MemoryImage(bytes));
          }
        }
      }

      // Render composite template image & upload all 5 raw photos + composite softfile asynchronously
      unawaited(_renderAndUploadSoftfile(processedImgList, preProcessedByCaptureIndex));

      final printers = await Printing.listPrinters();
      Printer? targetPrinter;
      for (var p in printers) {
        if (p.name.toLowerCase() == widget.printer.toLowerCase()) {
          targetPrinter = p;
          break;
        }
      }
      targetPrinter ??= printers.firstWhere(
        (p) => p.name.toLowerCase().contains(widget.printer.toLowerCase()),
        orElse: () => printers.isNotEmpty ? printers.first : const Printer(url: 'default', name: 'Default'),
      );

      final bool isStripMode = _selectedTemplate?['template_mode'] == 'strip';
      final bool isStripSemi4R = _selectedTemplate?['template_mode'] == 'strip_semi_4r';
      bool isLandscapeStrip = false;
      if (isStripMode && _selectedTemplate?['image_data'] != null) {
        final imgData = _selectedTemplate!['image_data'] as Uint8List;
        if (imgData.length >= 24 && imgData[0] == 0x89 && imgData[1] == 0x50) {
          final bd = ByteData.sublistView(imgData);
          final w = bd.getInt32(16);
          final h = bd.getInt32(20);
          if (h > 0 && (w / h) > 0.55) {
            isLandscapeStrip = true;
          }
        }
      }

      final pageFormat4R = isLandscapeStrip
          ? const PdfPageFormat(152 * PdfPageFormat.mm, 102 * PdfPageFormat.mm, marginAll: 0)
          : const PdfPageFormat(102 * PdfPageFormat.mm, 152 * PdfPageFormat.mm, marginAll: 0);

      await Printing.directPrintPdf(
        printer: targetPrinter,
        format: pageFormat4R,
        usePrinterSettings: true,
        onLayout: (PdfPageFormat format) async {
          debugPrint('Printer layout format: $format');

          final doc = pw.Document(compress: false);
          final bool isLargePaper = format.width > (isLandscapeStrip ? 160.0 : 130.0) * PdfPageFormat.mm;
          final pageFormat = isLargePaper ? format : pageFormat4R;

          final double photo4RWidth = isLandscapeStrip ? (152.0 * PdfPageFormat.mm) : (102.0 * PdfPageFormat.mm);
          final double photo4RHeight = isLandscapeStrip ? (102.0 * PdfPageFormat.mm) : (152.0 * PdfPageFormat.mm);

          double baseX = 0.0;
          double baseY = 0.0;
          if (isLargePaper) {
            final isEpson = targetPrinter?.name.toLowerCase().contains('epson') ?? false;
            if (isEpson) {
              baseX = pageFormat.width - photo4RWidth;
            } else {
              baseX = (pageFormat.width - photo4RWidth) / 2.0;
            }
          }

          final double leftOffset = baseX + (_printOffsetX * PdfPageFormat.mm);
          final double topOffset = baseY + (_printOffsetY * PdfPageFormat.mm);

          pw.Widget buildPdfStripContent(double sW, double sH) {
            final t = _selectedTemplate!;
            final double s1x = (t['slot1_x'] as num).toDouble();
            final double s1y = (t['slot1_y'] as num).toDouble();
            final double s1w = (t['slot1_w'] as num).toDouble();
            final double s1h = (t['slot1_h'] as num).toDouble();

            final double s2x = (t['slot2_x'] as num).toDouble();
            final double s2y = (t['slot2_y'] as num).toDouble();
            final double s2w = (t['slot2_w'] as num).toDouble();
            final double s2h = (t['slot2_h'] as num).toDouble();

            final double s3x = (t['slot3_x'] as num).toDouble();
            final double s3y = (t['slot3_y'] as num).toDouble();
            final double s3w = (t['slot3_w'] as num).toDouble();
            final double s3h = (t['slot3_h'] as num).toDouble();

            return pw.Stack(
              children: [
                if (pdfImages.isNotEmpty)
                  pw.Positioned(
                    left: s1x * sW,
                    top: s1y * sH,
                    child: pw.SizedBox(
                      width: s1w * sW,
                      height: s1h * sH,
                      child: pw.Image(pdfImages[0], fit: pw.BoxFit.cover, dpi: 300),
                    ),
                  ),
                if (pdfImages.length > 1)
                  pw.Positioned(
                    left: s2x * sW,
                    top: s2y * sH,
                    child: pw.SizedBox(
                      width: s2w * sW,
                      height: s2h * sH,
                      child: pw.Image(pdfImages[1], fit: pw.BoxFit.cover, dpi: 300),
                    ),
                  ),
                if (pdfImages.length > 2)
                  pw.Positioned(
                    left: s3x * sW,
                    top: s3y * sH,
                    child: pw.SizedBox(
                      width: s3w * sW,
                      height: s3h * sH,
                      child: pw.Image(pdfImages[2], fit: pw.BoxFit.cover, dpi: 300),
                    ),
                  ),
                pw.Positioned.fill(
                  child: pw.Image(
                    pw.MemoryImage(t['image_data'] as Uint8List),
                    fit: pw.BoxFit.fill,
                    dpi: 300,
                  ),
                ),
              ],
            );
          }

          pw.Widget buildPdfStripSemi4RContent(double w4R, double h4R) {
            final t = _selectedTemplate!;
            final double s1x = (t['slot1_x'] as num).toDouble();
            final double s1y = (t['slot1_y'] as num).toDouble();
            final double s1w = (t['slot1_w'] as num).toDouble();
            final double s1h = (t['slot1_h'] as num).toDouble();

            final double s2x = (t['slot2_x'] as num).toDouble();
            final double s2y = (t['slot2_y'] as num).toDouble();
            final double s2w = (t['slot2_w'] as num).toDouble();
            final double s2h = (t['slot2_h'] as num).toDouble();

            final double s3x = (t['slot3_x'] as num).toDouble();
            final double s3y = (t['slot3_y'] as num).toDouble();
            final double s3w = (t['slot3_w'] as num).toDouble();
            final double s3h = (t['slot3_h'] as num).toDouble();

            final double s4x = ((t['slot4_x'] ?? (s1x + 0.5)) as num).toDouble();
            final double s4y = ((t['slot4_y'] ?? s1y) as num).toDouble();
            final double s4w = ((t['slot4_w'] ?? s1w) as num).toDouble();
            final double s4h = ((t['slot4_h'] ?? s1h) as num).toDouble();

            final double s5x = ((t['slot5_x'] ?? (s2x + 0.5)) as num).toDouble();
            final double s5y = ((t['slot5_y'] ?? s2y) as num).toDouble();
            final double s5w = ((t['slot5_w'] ?? s2w) as num).toDouble();
            final double s5h = ((t['slot5_h'] ?? s2h) as num).toDouble();

            final double s6x = ((t['slot6_x'] ?? (s3X(t) + 0.5)) as num).toDouble();
            final double s6y = ((t['slot6_y'] ?? s3y) as num).toDouble();
            final double s6w = ((t['slot6_w'] ?? s3w) as num).toDouble();
            final double s6h = ((t['slot6_h'] ?? s3h) as num).toDouble();

            return pw.Stack(
              children: [
                if (pdfImages.isNotEmpty)
                  pw.Positioned(
                    left: s1x * w4R,
                    top: s1y * h4R,
                    child: pw.SizedBox(
                      width: s1w * w4R,
                      height: s1h * h4R,
                      child: pw.Image(pdfImages[0], fit: pw.BoxFit.cover, dpi: 300),
                    ),
                  ),
                if (pdfImages.length > 1)
                  pw.Positioned(
                    left: s2x * w4R,
                    top: s2y * h4R,
                    child: pw.SizedBox(
                      width: s2w * w4R,
                      height: s2h * h4R,
                      child: pw.Image(pdfImages[1], fit: pw.BoxFit.cover, dpi: 300),
                    ),
                  ),
                if (pdfImages.length > 2)
                  pw.Positioned(
                    left: s3x * w4R,
                    top: s3y * h4R,
                    child: pw.SizedBox(
                      width: s3w * w4R,
                      height: s3h * h4R,
                      child: pw.Image(pdfImages[2], fit: pw.BoxFit.cover, dpi: 300),
                    ),
                  ),
                if (pdfImages.isNotEmpty)
                  pw.Positioned(
                    left: s4x * w4R,
                    top: s4y * h4R,
                    child: pw.SizedBox(
                      width: s4w * w4R,
                      height: s4h * h4R,
                      child: pw.Image(pdfImages[0], fit: pw.BoxFit.cover, dpi: 300),
                    ),
                  ),
                if (pdfImages.length > 1)
                  pw.Positioned(
                    left: s5x * w4R,
                    top: s5y * h4R,
                    child: pw.SizedBox(
                      width: s5w * w4R,
                      height: s5h * h4R,
                      child: pw.Image(pdfImages[1], fit: pw.BoxFit.cover, dpi: 300),
                    ),
                  ),
                if (pdfImages.length > 2)
                  pw.Positioned(
                    left: s6x * w4R,
                    top: s6y * h4R,
                    child: pw.SizedBox(
                      width: s6w * w4R,
                      height: s6h * h4R,
                      child: pw.Image(pdfImages[2], fit: pw.BoxFit.cover, dpi: 300),
                    ),
                  ),
                pw.Positioned.fill(
                  child: pw.Image(
                    pw.MemoryImage(t['image_data'] as Uint8List),
                    fit: pw.BoxFit.fill,
                    dpi: 300,
                  ),
                ),
              ],
            );
          }

          for (int copy = 0; copy < _selectedPrintCount; copy++) {
            doc.addPage(
              pw.Page(
                pageFormat: pageFormat,
                margin: pw.EdgeInsets.zero,
                build: (pw.Context context) {
                  return pw.Stack(
                    children: [
                      pw.Positioned(
                        left: leftOffset,
                        top: topOffset,
                        child: pw.SizedBox(
                          width: photo4RWidth,
                          height: photo4RHeight,
                          child: _selectedTemplate != null
                              ? (isStripMode
                                  ? pw.Row(
                                      children: [
                                        pw.SizedBox(
                                          width: photo4RWidth / 2.0,
                                          height: photo4RHeight,
                                          child: buildPdfStripContent(photo4RWidth / 2.0, photo4RHeight),
                                        ),
                                        pw.SizedBox(
                                          width: photo4RWidth / 2.0,
                                          height: photo4RHeight,
                                          child: buildPdfStripContent(photo4RWidth / 2.0, photo4RHeight),
                                        ),
                                      ],
                                    )
                                  : (isStripSemi4R
                                      ? buildPdfStripSemi4RContent(photo4RWidth, photo4RHeight)
                                      : buildPdfStripContent(photo4RWidth, photo4RHeight)))
                              : pw.Center(
                                  child: pw.Column(
                                    mainAxisAlignment: pw.MainAxisAlignment.center,
                                    crossAxisAlignment: pw.CrossAxisAlignment.center,
                                    children: [
                                      for (int i = 0; i < pdfImages.length; i++)
                                        pw.Container(
                                          width: 120,
                                          height: 120,
                                          margin: pw.EdgeInsets.only(bottom: i < pdfImages.length - 1 ? 8 : 0),
                                          decoration: pw.BoxDecoration(
                                            border: pw.Border.all(color: PdfColors.black, width: 2),
                                          ),
                                          child: pw.Image(pdfImages[i], fit: pw.BoxFit.cover),
                                        ),
                                    ],
                                  ),
                                ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            );
          }
          return doc.save();
        },
      );
    } catch (e) {
      debugPrint("Gagal melakukan pencetakan: $e");
    }

    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) {
        if (_currentOrderId != null) {
          MySqlHelper.updateSessionStatus(
            orderId: _currentOrderId!,
            paymentStatus: _paymentStatus,
            sessionStatus: 'completed',
            idTemplate: _selectedTemplate?['id_template'] as int?,
            templateName: _selectedTemplate?['name'] as String?,
          );
        }
        setState(() {
          _currentStage = 'DONE';
          _doneCountdown = 60;
        });
        _startDoneTimer();
      }
    });
  }

  double s3X(Map<String, dynamic> t) => (t['slot3_x'] as num).toDouble();

  void _startDoneTimer() {
    _doneTimer?.cancel();
    _doneTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _currentStage != 'DONE') {
        timer.cancel();
        return;
      }
      // Jangan kurangi waktu hitung mundur selama softfile masih sedang diunggah ke server
      if (_isUploadingSoftfile) {
        return;
      }
      if (_doneCountdown > 1) {
        setState(() {
          _doneCountdown--;
        });
      } else {
        timer.cancel();
        _resetToStart();
      }
    });
  }

  void _stopTimers() {
    _overallTimer?.cancel();
    _shotTimer?.cancel();
    _qrisPollingTimer?.cancel();
    _paymentCountdownTimer?.cancel();
    _doneTimer?.cancel();
    _isCheckingPayment = false;
  }

  void _resetToStart() {
    _stopTimers();

    for (var photo in _capturedPhotos) {
      try {
        final f = File(photo.path);
        if (f.existsSync()) {
          f.deleteSync();
        }
      } catch (_) {}
    }

    setState(() {
      _currentStage = 'WELCOME';
      _selectedPrintCount = 1;
      _paymentStatus = 'pending';
      _qrisUrl = null;
      _qrisString = null;
      _currentOrderId = null;
      _isGeneratingQR = false;
      _capturedPhotos.clear();
      _selectedPhotosIndices.clear();
      _takenPhotosCount = 0;
      _hasStartedShooting = false;
      _overallTimeRemaining = 120;
      _shotCountdown = 5;
      _isFlashActive = false;
      _selectedFilterId = 'normal';
      _filterIntensity = 1.0;
      _photoBrightness = 0.0;
      _isCameraMirrored = true;
      _retakeCount = 0;
      _retakeTargetIndices.clear();
      _currentRetakeIndex = 0;
      _selectionSubStep = 1;
      _softfileDownloadUrl = null;
      _isUploadingSoftfile = false;
      _isSoftfileUploaded = false;
      _lastSoftfilePayload = null;
    });

    _updatePrice();
    _fetchPricing();
    _fetchTemplates();
  }

  bool _canPop = false;
  bool _isDialogShowing = false;

  Future<void> _goBack() async {
    _stopTimers();
    if (_cameraController != null) {
      await _cameraController!.dispose();
      _cameraController = null;
    }
    if (mounted) {
      setState(() {
        _canPop = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.of(context).pop();
        }
      });
    }
  }

  Future<void> _confirmExitWithPassword() async {
    if (_isDialogShowing || !mounted) return;
    _isDialogShowing = true;

    try {
      final bool? verified = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext dialogContext) {
          return _StaffAuthDialog(user: widget.user);
        },
      );

      if (verified == true && mounted) {
        await _goBack();
      }
    } finally {
      _isDialogShowing = false;
    }
  }

  @override
  void dispose() {
    _stopTimers();
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String formattedPrice = 'Rp ${_price.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]}.')}';
    final bool isFullBleedStage = _currentStage == 'SHOOTING' || _currentStage == 'WELCOME' || _currentStage == 'PAYMENT';

    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_currentStage == 'WELCOME') {
          _confirmExitWithPassword();
        } else if (_currentStage == 'PAYMENT') {
          _backToWelcomeStage();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: isFullBleedStage
            ? null
            : AppBar(
                title: Text(
                  _currentStage == 'PAYMENT'
                      ? 'TAHAP 1: PEMBAYARAN & CETAK'
                      : _currentStage == 'SELECTION'
                          ? 'TAHAP 3: PILIH 3 FOTO ANDALAN'
                          : _currentStage == 'PRINTING'
                              ? 'TAHAP 4: MENCETAK'
                              : 'SESI SELESAI',
                  style: const TextStyle(fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 1.2),
                ),
                backgroundColor: kPrimaryRed,
                elevation: 0,
                leading: _currentStage == 'PAYMENT'
                    ? IconButton(
                        icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                        tooltip: 'Kembali ke Welcome Screen',
                        onPressed: _backToWelcomeStage,
                      )
                    : null,
                actions: [
                  if (_currentStage == 'PAYMENT')
                    IconButton(
                      icon: const Icon(Icons.lock_outline_rounded, color: Colors.white70, size: 20),
                      tooltip: 'Keluar ke Dashboard (Petugas)',
                      onPressed: _confirmExitWithPassword,
                    ),
                ],
              ),
        body: Container(
          color: const Color(0xFFFFFDFC),
          child: Padding(
            padding: isFullBleedStage ? EdgeInsets.zero : const EdgeInsets.all(24),
            child: _buildStageContent(formattedPrice),
          ),
        ),
      ),
    );
  }

  Widget _buildStageContent(String formattedPrice) {
    switch (_currentStage) {
      case 'WELCOME':
        return _buildWelcomeStage();
      case 'PAYMENT':
        return _buildPaymentStage(formattedPrice);
      case 'SHOOTING':
        return _buildShootingStage();
      case 'SELECTION':
        return _buildSelectionStage();
      case 'PRINTING':
        return _buildPrintingStage();
      case 'DONE':
        return _buildDoneStage();
      default:
        return Container();
    }
  }

  // =========================================================================
  // TAHAP 0 (BARU): WELCOME SCREEN SEBELUM QRIS (SESUAI REFERENSI GAMBAR)
  // =========================================================================
  Widget _buildWelcomeStage() {
    return Container(
      margin: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFDFC),
        border: Border.all(color: kPrimaryRed, width: 6),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;

          return Stack(
            fit: StackFit.expand,
            children: [
              // Soft pinkish-red radial glow behind the PIXYBOX oval logo
              Center(
                child: Container(
                  width: w * 0.65,
                  height: h * 0.78,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        kPrimaryRed.withAlpha(24),
                        kPrimaryRed.withAlpha(10),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.55, 1.0],
                    ),
                  ),
                ),
              ),

              // 5 Sparkle 4-point stars matching the exact reference image positions
              Positioned(
                left: w * 0.068,
                top: h * 0.20,
                child: const FourPointStar(size: 46, color: kPrimaryRed),
              ),
              Positioned(
                left: w * 0.278,
                top: h * 0.145,
                child: const FourPointStar(size: 24, color: kPrimaryRed),
              ),
              Positioned(
                right: w * 0.222,
                top: h * 0.215,
                child: const FourPointStar(size: 30, color: kPrimaryRed),
              ),
              Positioned(
                left: w * 0.192,
                bottom: h * 0.17,
                child: const FourPointStar(size: 32, color: kPrimaryRed),
              ),
              Positioned(
                right: w * 0.112,
                bottom: h * 0.34,
                child: const FourPointStar(size: 38, color: kPrimaryRed),
              ),

              // Subtle Staff Exit Lock Button (Top-Left)
              Positioned(
                top: 14,
                left: 14,
                child: IconButton(
                  icon: Icon(Icons.lock_outline_rounded, color: kPrimaryRed.withAlpha(90), size: 22),
                  tooltip: 'Kembali ke Dashboard (Perlu Password)',
                  onPressed: _confirmExitWithPassword,
                ),
              ),

              // Center PIXYBOX Oval Logo + PHOTO BOOTH + START Button
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 16),
                    const PixyboxOvalLogo(
                      width: 560,
                      height: 205,
                      fontSize: 68,
                      color: kPrimaryRed,
                    ),
                    const SizedBox(height: 22),
                    const Text(
                      'PHOTO BOOTH',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 7.5,
                        color: kPrimaryRed,
                      ),
                    ),
                    const SizedBox(height: 68),

                    // START 3D Red Pill Button
                    _SessionStartPillButton(
                      onTap: _goToPaymentStage,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // =========================================================================
  // TAHAP 1: PEMBAYARAN QRIS (SIMPLE WHITE & RED THEME + SPARKLE STARS)
  // =========================================================================
  Widget _buildPaymentStage(String formattedPrice) {
    final String mm = (_paymentCountdown ~/ 60).toString().padLeft(2, '0');
    final String ss = (_paymentCountdown % 60).toString().padLeft(2, '0');
    final bool isPaid = _paymentStatus == 'settlement' || _paymentStatus == 'capture';
    final bool isExpiredOrFailed = !_isGeneratingQR &&
        (_qrisUrl == null && _qrisString == null ||
            _paymentStatus == 'expire' ||
            _paymentStatus == 'cancel' ||
            _paymentCountdown <= 0);

    return Container(
      margin: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFDFC),
        border: Border.all(
          color: kPrimaryRed,
          width: 6,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;

          return Stack(
            children: [
              // Soft pinkish-red radial glow behind the center card
              Center(
                child: Container(
                  width: w * 0.65,
                  height: h * 0.85,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        kPrimaryRed.withAlpha(24),
                        kPrimaryRed.withAlpha(10),
                        Colors.white.withAlpha(0),
                      ],
                      stops: const [0.0, 0.55, 1.0],
                    ),
                  ),
                ),
              ),

              // 5 Four-point sparkle stars in the background (matching Welcome Screen)
              Positioned(
                left: w * 0.08,
                top: h * 0.22,
                child: const FourPointStar(size: 38, color: kPrimaryRed),
              ),
              Positioned(
                left: w * 0.24,
                top: h * 0.14,
                child: const FourPointStar(size: 20, color: kPrimaryRed),
              ),
              Positioned(
                right: w * 0.22,
                top: h * 0.18,
                child: const FourPointStar(size: 26, color: kPrimaryRed),
              ),
              Positioned(
                left: w * 0.18,
                bottom: h * 0.18,
                child: const FourPointStar(size: 26, color: kPrimaryRed),
              ),
              Positioned(
                right: w * 0.11,
                bottom: h * 0.30,
                child: const FourPointStar(size: 34, color: kPrimaryRed),
              ),

              // Top-Left PIXYBOX Oval Badge
              Positioned(
                left: 36,
                top: 28,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(40),
                    border: Border.all(color: kPrimaryRed, width: 1.8),
                  ),
                  child: const Text(
                    'PIXYBOX',
                    style: TextStyle(
                      color: kPrimaryRed,
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.8,
                    ),
                  ),
                ),
              ),

              // Subtle Staff Lock Button at Top-Right
              Positioned(
                top: 20,
                right: 24,
                child: IconButton(
                  onPressed: _confirmExitWithPassword,
                  tooltip: 'Keluar Sesi (Khusus Staff)',
                  icon: Icon(
                    Icons.lock_outline_rounded,
                    color: kPrimaryRed.withAlpha(90),
                    size: 22,
                  ),
                ),
              ),

              // Main Centered Content (Title, Subtitle, and QRIS Card)
              Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Step 2: Pembayaran QRIS',
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w900,
                          color: kPrimaryRed,
                          letterSpacing: 0.4,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Scan QRIS dengan e-wallet atau mobile banking Anda',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFFA63A40),
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Center White Card with Red Border & Glow
                      Container(
                        width: 640,
                        padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(32),
                          border: Border.all(color: kPrimaryRed, width: 2.5),
                          boxShadow: [
                            BoxShadow(
                              color: kPrimaryRed.withAlpha(35),
                              blurRadius: 45,
                              spreadRadius: 4,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'Q R I S',
                              style: TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w900,
                                color: kPrimaryRed,
                                letterSpacing: 4,
                              ),
                            ),
                            if (_priceList.length > 1) ...[
                              const SizedBox(height: 14),
                              Wrap(
                                spacing: 12,
                                runSpacing: 10,
                                alignment: WrapAlignment.center,
                                children: List.generate(_priceList.length, (idx) {
                                  final item = _priceList[idx];
                                  final int cnt = item['print_count'] as int;
                                  final double prc = (item['price'] as num).toDouble();
                                  final String prcStr = 'Rp ${prc.toInt().toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]}.')}';
                                  final bool isSelected = _selectedPriceIndex == idx;

                                  return GestureDetector(
                                    onTap: () {
                                      if (_selectedPriceIndex != idx) {
                                        setState(() {
                                          _selectedPriceIndex = idx;
                                          _updatePrice();
                                        });
                                        _generateQrisPayment(refreshFromDb: false);
                                      }
                                    },
                                    child: AnimatedContainer(
                                      duration: const Duration(milliseconds: 200),
                                      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
                                      decoration: BoxDecoration(
                                        color: isSelected ? kPrimaryRed : Colors.white,
                                        borderRadius: BorderRadius.circular(30),
                                        border: Border.all(color: kPrimaryRed, width: 2),
                                        boxShadow: [
                                          BoxShadow(
                                            color: isSelected ? kDarkRed : kPrimaryRed.withAlpha(70),
                                            offset: const Offset(0, 3),
                                            blurRadius: 0,
                                          ),
                                        ],
                                      ),
                                      child: Text(
                                        '${cnt}x Cetak • $prcStr',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w800,
                                          color: isSelected ? Colors.white : kPrimaryRed,
                                        ),
                                      ),
                                    ),
                                  );
                                }),
                              ),
                            ],
                            const SizedBox(height: 18),

                            // Enlarged QR Box
                            Container(
                              width: 340,
                              height: 340,
                              padding: const EdgeInsets.all(18),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(22),
                                border: Border.all(color: kPrimaryRed, width: 3),
                              ),
                              child: Center(
                                child: _isGeneratingQR
                                    ? const CircularProgressIndicator(color: kPrimaryRed)
                                    : _qrisString != null && _qrisString!.isNotEmpty
                                        ? QrImageView(
                                            data: _qrisString!,
                                            version: QrVersions.auto,
                                            size: 300,
                                            backgroundColor: Colors.white,
                                            eyeStyle: const QrEyeStyle(
                                              eyeShape: QrEyeShape.square,
                                              color: Color(0xFF981B1E),
                                            ),
                                            dataModuleStyle: const QrDataModuleStyle(
                                              dataModuleShape: QrDataModuleShape.square,
                                              color: Color(0xFF981B1E),
                                            ),
                                          )
                                        : _qrisUrl != null
                                            ? (_qrisUrl!.contains('generate-qr-code') ||
                                                    _qrisUrl!.endsWith('.png') ||
                                                    _qrisUrl!.endsWith('.jpg')
                                                ? Image.network(
                                                    _qrisUrl!,
                                                    width: double.infinity,
                                                    height: double.infinity,
                                                    fit: BoxFit.contain,
                                                    errorBuilder: (context, error, stackTrace) {
                                                      return const Column(
                                                        mainAxisAlignment: MainAxisAlignment.center,
                                                        children: [
                                                          Icon(Icons.broken_image, color: kPrimaryRed, size: 52),
                                                          SizedBox(height: 8),
                                                          Text(
                                                            'Gagal memuat QR',
                                                            style: TextStyle(
                                                              color: kPrimaryRed,
                                                              fontSize: 13,
                                                              fontWeight: FontWeight.bold,
                                                            ),
                                                          ),
                                                        ],
                                                      );
                                                    },
                                                  )
                                                : QrImageView(
                                                    data: _qrisUrl!,
                                                    version: QrVersions.auto,
                                                    size: 300,
                                                    backgroundColor: Colors.white,
                                                    eyeStyle: const QrEyeStyle(
                                                      eyeShape: QrEyeShape.square,
                                                      color: Color(0xFF981B1E),
                                                    ),
                                                    dataModuleStyle: const QrDataModuleStyle(
                                                      dataModuleShape: QrDataModuleShape.square,
                                                      color: Color(0xFF981B1E),
                                                    ),
                                                  ))
                                            : const Column(
                                                mainAxisAlignment: MainAxisAlignment.center,
                                                children: [
                                                  Icon(
                                                    Icons.qr_code_scanner,
                                                    size: 88,
                                                    color: kPrimaryRed,
                                                  ),
                                                  SizedBox(height: 10),
                                                  Text(
                                                    'QRIS belum tersedia',
                                                    style: TextStyle(
                                                      color: kTextMuted,
                                                      fontSize: 13,
                                                      fontWeight: FontWeight.w600,
                                                    ),
                                                  ),
                                                ],
                                              ),
                              ),
                            ),
                            const SizedBox(height: 22),

                            Text(
                              'Total Pembayaran (${_selectedPrintCount}x Cetak)',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF9E353A),
                              ),
                            ),
                            const SizedBox(height: 4),

                            _isLoadingPrice
                                ? const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 8),
                                    child: SizedBox(
                                      width: 28,
                                      height: 28,
                                      child: CircularProgressIndicator(color: kPrimaryRed, strokeWidth: 2.5),
                                    ),
                                  )
                                : Text(
                                    formattedPrice,
                                    style: const TextStyle(
                                      fontSize: 44,
                                      fontWeight: FontWeight.w900,
                                      color: kPrimaryRed,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                            const SizedBox(height: 20),

                            // Status / Countdown Pill (clickable to regenerate when expired/failed)
                            GestureDetector(
                              onTap: isExpiredOrFailed ? () => _generateQrisPayment(refreshFromDb: true) : null,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 12),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(30),
                                  border: Border.all(
                                    color: isPaid ? Colors.green : kPrimaryRed,
                                    width: 2,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: (isPaid ? Colors.green : kPrimaryRed).withAlpha(90),
                                      offset: const Offset(0, 3),
                                      blurRadius: 0,
                                    ),
                                  ],
                                ),
                                child: Text(
                                  _isGeneratingQR
                                      ? 'Menyiapkan QRIS...'
                                      : isPaid
                                          ? 'Pembayaran Sukses!'
                                          : isExpiredOrFailed
                                              ? 'QRIS Kedaluwarsa - Ketuk Muat Ulang'
                                              : 'Menunggu pembayaran... $mm:$ss',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800,
                                    color: isPaid ? Colors.green.shade700 : kPrimaryRed,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Bottom-Left "← Kembali" Pill Button
              Positioned(
                left: 36,
                bottom: 28,
                child: GestureDetector(
                  onTap: _backToWelcomeStage,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(color: kPrimaryRed, width: 2),
                        boxShadow: [
                          BoxShadow(
                            color: kPrimaryRed.withAlpha(95),
                            offset: const Offset(0, 4),
                            blurRadius: 0,
                          ),
                        ],
                      ),
                      child: const Text(
                        '← Kembali',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: kPrimaryRed,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // Subtle Debug Skip Button at Bottom-Right (Debug Mode only)
              if (kDebugMode)
                Positioned(
                  right: 36,
                  bottom: 28,
                  child: TextButton.icon(
                    onPressed: _skipPaymentForDebug,
                    style: TextButton.styleFrom(
                      foregroundColor: kPrimaryRed.withAlpha(180),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    ),
                    icon: const Icon(Icons.fast_forward_rounded, size: 16),
                    label: const Text(
                      'Skip (Debug)',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  // =========================================================================
  // TAHAP 2: KAMERA VIEW & AMBIL FOTO (WHITE & RED THEME)
  // =========================================================================
  Widget _buildShootingStage() {
    final String minutes = (_overallTimeRemaining ~/ 60).toString().padLeft(2, '0');
    final String seconds = (_overallTimeRemaining % 60).toString().padLeft(2, '0');

    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. Fullscreen Camera Preview
        if (_isCameraInitialized && _cameraController != null)
          SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.cover,
              alignment: Alignment.center,
              child: SizedBox(
                width: 1000 * _cameraController!.value.aspectRatio,
                height: 1000,
                // Pada Windows (camera_windows), CameraPreview secara native sudah mirror (mirror_preview_ = true),
                // sedangkan file hasil takePicture() disimpan tanpa mirror (asli/raw sensor).
                // Maka saat Mirror aktif (_isCameraMirrored == true), preview dibiarkan 0.0 (tetap mirror)
                // dan hasil foto di-flip horizontal agar sama persis; saat No Mirror (_isCameraMirrored == false),
                // preview diputar math.pi (menjadi asli) dan hasil foto tidak di-flip.
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(
                    end: _isCameraMirrored ? 0.0 : math.pi,
                  ),
                  duration: const Duration(milliseconds: 600),
                  curve: Curves.easeInOutCubic,
                  builder: (context, angle, child) {
                    final transform = Matrix4.identity()
                      ..setEntry(3, 2, 0.001)
                      ..rotateY(angle);
                    return Transform(
                      alignment: Alignment.center,
                      transform: transform,
                      child: child,
                    );
                  },
                  child: CameraPreview(_cameraController!),
                ),
              ),
            ),
          )
        else
          Container(
            color: kSoftRedBg,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.videocam_off_outlined, size: 70, color: kPrimaryRed.withAlpha(110)),
                  const SizedBox(height: 12),
                  const Text(
                    'MENGHUBUNGKAN KE KAMERA...',
                    style: TextStyle(color: kPrimaryRed, fontSize: 13, fontWeight: FontWeight.w900, letterSpacing: 1),
                  ),
                ],
              ),
            ),
          ),

        // Red frame border around the fullscreen camera view
        IgnorePointer(
          child: Container(
            margin: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              border: Border.all(color: kPrimaryRed, width: 5),
            ),
          ),
        ),

        // 2. Floating Top HUD Bar (Timer & Shot Progress)
        Positioned(
          top: 24,
          left: 24,
          right: 24,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Camera Flip / Mirror Toggle Button
              GestureDetector(
                onTap: _toggleCameraMirror,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  decoration: BoxDecoration(
                    color: _isCameraMirrored ? kPrimaryRed : Colors.white,
                    borderRadius: BorderRadius.circular(32),
                    border: Border.all(
                      color: kPrimaryRed,
                      width: 2.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: kDarkRed.withAlpha(110),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedRotation(
                        turns: _isCameraMirrored ? 0.5 : 0.0,
                        duration: const Duration(milliseconds: 600),
                        curve: Curves.easeInOutBack,
                        child: Icon(
                          Icons.flip_camera_android_rounded,
                          color: _isCameraMirrored ? Colors.white : kPrimaryRed,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        _isCameraMirrored ? 'MIRROR (CERMIN)' : 'NO MIRROR (ASLI)',
                        style: TextStyle(
                          color: _isCameraMirrored ? Colors.white : kPrimaryRed,
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Session Timer Pill
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: kPrimaryRed, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: kPrimaryRed.withAlpha(60),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.timer_outlined, color: kPrimaryRed, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      'Sisa Waktu: $minutes:$seconds',
                      style: const TextStyle(
                        color: kPrimaryRed,
                        fontWeight: FontWeight.w900,
                        fontSize: 14,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),

              // Photo Progress Badge & Indicator Dots
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(
                    color: kPrimaryRed,
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: kPrimaryRed.withAlpha(60),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _isRetakeMode ? Icons.replay_rounded : Icons.camera_alt_outlined,
                      color: kPrimaryRed,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isRetakeMode
                          ? 'Foto Ulang ${_currentRetakeIndex + (_hasStartedShooting && _currentRetakeIndex < _retakeTargetIndices.length ? 1 : 0)} / ${_retakeTargetIndices.length} (Foto #${_retakeTargetIndices[_currentRetakeIndex < _retakeTargetIndices.length ? _currentRetakeIndex : _retakeTargetIndices.length - 1] + 1})'
                          : 'Foto ${_takenPhotosCount + (_hasStartedShooting && _takenPhotosCount < 5 ? 1 : 0)} / 5',
                      style: const TextStyle(
                        color: kPrimaryRed,
                        fontWeight: FontWeight.w900,
                        fontSize: 14,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (_isRetakeMode)
                      for (int i = 0; i < _retakeTargetIndices.length; i++)
                        Container(
                          width: 9,
                          height: 9,
                          margin: const EdgeInsets.only(left: 4),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: i < _currentRetakeIndex
                                ? kPrimaryRed
                                : (i == _currentRetakeIndex && _hasStartedShooting)
                                    ? kDarkRed
                                    : kBorderRed,
                          ),
                        )
                    else
                      for (int i = 0; i < 5; i++)
                        Container(
                          width: 9,
                          height: 9,
                          margin: const EdgeInsets.only(left: 4),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: i < _takenPhotosCount
                                ? kPrimaryRed
                                : (i == _takenPhotosCount && _hasStartedShooting)
                                    ? kDarkRed
                                    : kBorderRed,
                          ),
                        ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // 3. Floating Thumbnail Sidebar (Right side, showing recent shots)
        Positioned(
          top: 86,
          right: 24,
          bottom: 24,
          child: Container(
            width: 96,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(235),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: kPrimaryRed, width: 2),
              boxShadow: [
                BoxShadow(
                  color: kPrimaryRed.withAlpha(50),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              children: [
                const Text(
                  'JEPRETAN',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    color: kPrimaryRed,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: ListView.builder(
                    itemCount: 5,
                    physics: const NeverScrollableScrollPhysics(),
                    itemBuilder: (context, index) {
                      final bool isTaken = _capturedPhotos.length > index;
                      final bool isBeingRetaken = _isRetakeMode &&
                          _currentRetakeIndex < _retakeTargetIndices.length &&
                          _retakeTargetIndices[_currentRetakeIndex] == index &&
                          _hasStartedShooting;
                      final bool isWaitingRetake = _isRetakeMode &&
                          _retakeTargetIndices.contains(index) &&
                          !isBeingRetaken;
                      final bool isCurrent = !_isRetakeMode &&
                          _takenPhotosCount == index &&
                          _hasStartedShooting;

                      return Container(
                        height: 88,
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: kSoftRedBg,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: (isBeingRetaken || isCurrent || isTaken)
                                ? kPrimaryRed
                                : kBorderRed,
                            width: (isCurrent || isBeingRetaken) ? 2.5 : 1.5,
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8.5),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              isTaken
                                  ? (_capturedPhotos[index].path.isNotEmpty
                                      ? Transform.scale(
                                          scaleX: _isCameraMirrored ? -1 : 1,
                                          child: Image.file(
                                            File(_capturedPhotos[index].path),
                                            fit: BoxFit.cover,
                                            width: double.infinity,
                                            height: double.infinity,
                                          ),
                                        )
                                      : const Center(
                                          child: Icon(Icons.broken_image, color: kBorderRed, size: 20),
                                        ))
                                  : Center(
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Icon(
                                            isCurrent ? Icons.videocam_rounded : Icons.camera_alt_outlined,
                                            color: isCurrent ? kPrimaryRed : kBorderRed,
                                            size: 20,
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            isCurrent ? 'FOTO...' : '#${index + 1}',
                                            style: TextStyle(
                                              color: isCurrent ? kPrimaryRed : kTextMuted,
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                              if (isBeingRetaken)
                                Container(
                                  color: kPrimaryRed.withAlpha(180),
                                  child: const Center(
                                    child: Text(
                                      'RETAKE\nNOW',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 9,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  ),
                                ),
                              if (isWaitingRetake)
                                Positioned(
                                  top: 3,
                                  right: 3,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: kPrimaryRed,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text(
                                      'Antri',
                                      style: TextStyle(color: Colors.white, fontSize: 7.5, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),

        // 4. Center Countdown Overlay
        if (_hasStartedShooting)
          Center(
            child: Container(
              width: 170,
              height: 170,
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(230),
                shape: BoxShape.circle,
                border: Border.all(
                  color: kPrimaryRed,
                  width: 5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: kPrimaryRed.withAlpha(110),
                    blurRadius: 36,
                    spreadRadius: 6,
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  '$_shotCountdown',
                  style: const TextStyle(
                    fontSize: 90,
                    fontWeight: FontWeight.w900,
                    color: kPrimaryRed,
                  ),
                ),
              ),
            ),
          ),

        // 5. Fullscreen Flash Animation
        if (_isFlashActive)
          Positioned.fill(
            child: Container(
              color: Colors.white,
              child: const Center(
                child: Icon(Icons.flash_on, size: 120, color: kPrimaryRed),
              ),
            ),
          ),

        // 6. Pre-Shooting Welcome Card
        if (!_hasStartedShooting)
          Positioned.fill(
            child: Container(
              color: Colors.white.withAlpha(150),
              child: Center(
                child: Container(
                  constraints: const BoxConstraints(minWidth: 660, maxWidth: 760),
                  padding: const EdgeInsets.symmetric(horizontal: 64, vertical: 48),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(32),
                    border: Border.all(color: kPrimaryRed, width: 3.5),
                    boxShadow: [
                      BoxShadow(
                        color: kPrimaryRed.withAlpha(55),
                        blurRadius: 42,
                        spreadRadius: 2,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(22),
                        decoration: BoxDecoration(
                          color: kSoftRedBg,
                          shape: BoxShape.circle,
                          border: Border.all(color: kPrimaryRed, width: 2.5),
                        ),
                        child: const Icon(Icons.camera_alt, size: 64, color: kPrimaryRed),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        _isRetakeMode
                            ? 'FOTO ULANG (${_retakeTargetIndices.length} FOTO)'
                            : 'KAMERA SIAP!',
                        style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: kPrimaryRed, letterSpacing: 2),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _isRetakeMode
                            ? 'Akan mengambil ${_retakeTargetIndices.length} foto baru untuk menggantikan foto #${_retakeTargetIndices.map((i) => (i + 1).toString()).join(', ')}.\nInterval 5 detik per foto. Bersiaplah!'
                            : 'Sesi 5 foto otomatis dengan interval 5 detik per foto.\nBersiaplah dan tunjukkan pose terbaikmu!',
                        style: const TextStyle(fontSize: 16, color: kTextDark, height: 1.5, fontWeight: FontWeight.w600),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 28),
                      // Mirror / No Mirror Pre-shooting Selector (Enlarged Card & Buttons)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: kSoftRedBg,
                          borderRadius: BorderRadius.circular(32),
                          border: Border.all(color: kPrimaryRed.withAlpha(110), width: 2),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            GestureDetector(
                              onTap: () {
                                if (!_isCameraMirrored) _toggleCameraMirror();
                              },
                              child: MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 220),
                                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
                                  decoration: BoxDecoration(
                                    color: _isCameraMirrored ? kPrimaryRed : Colors.white,
                                    borderRadius: BorderRadius.circular(24),
                                    border: Border.all(
                                      color: _isCameraMirrored ? kPrimaryRed : kBorderRed,
                                      width: 2,
                                    ),
                                    boxShadow: _isCameraMirrored
                                        ? const [
                                            BoxShadow(
                                              color: kDarkRed,
                                              offset: Offset(0, 3),
                                              blurRadius: 0,
                                            ),
                                          ]
                                        : null,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.flip_rounded,
                                        size: 24,
                                        color: _isCameraMirrored ? Colors.white : kPrimaryRed,
                                      ),
                                      const SizedBox(width: 10),
                                      Text(
                                        'Mirror (Cermin)',
                                        style: TextStyle(
                                          color: _isCameraMirrored ? Colors.white : kPrimaryRed,
                                          fontWeight: FontWeight.w900,
                                          fontSize: 16,
                                          letterSpacing: 0.4,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            GestureDetector(
                              onTap: () {
                                if (_isCameraMirrored) _toggleCameraMirror();
                              },
                              child: MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 220),
                                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
                                  decoration: BoxDecoration(
                                    color: !_isCameraMirrored ? kPrimaryRed : Colors.white,
                                    borderRadius: BorderRadius.circular(24),
                                    border: Border.all(
                                      color: !_isCameraMirrored ? kPrimaryRed : kBorderRed,
                                      width: 2,
                                    ),
                                    boxShadow: !_isCameraMirrored
                                        ? const [
                                            BoxShadow(
                                              color: kDarkRed,
                                              offset: Offset(0, 3),
                                              blurRadius: 0,
                                            ),
                                          ]
                                        : null,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.crop_original_rounded,
                                        size: 24,
                                        color: !_isCameraMirrored ? Colors.white : kPrimaryRed,
                                      ),
                                      const SizedBox(width: 10),
                                      Text(
                                        'No Mirror (Asli)',
                                        style: TextStyle(
                                          color: !_isCameraMirrored ? Colors.white : kPrimaryRed,
                                          fontWeight: FontWeight.w900,
                                          fontSize: 16,
                                          letterSpacing: 0.4,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 32),
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(36),
                          boxShadow: const [
                            BoxShadow(
                              color: kDarkRed,
                              offset: Offset(0, 6),
                              blurRadius: 0,
                            ),
                          ],
                        ),
                        child: ElevatedButton.icon(
                          onPressed: _startShootingFlow,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: kPrimaryRed,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 56, vertical: 24),
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(36),
                            ),
                          ),
                          icon: const Icon(Icons.play_arrow_rounded, size: 36),
                          label: Text(
                            _isRetakeMode ? 'MULAI FOTO ULANG' : 'MULAI BERGAYA & FOTO',
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 1.5),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  // =========================================================================
  // TAHAP 3: ALUR 3 LANGKAH (SIMPLE 3-COLUMN LAYOUT & 3D PREVIEW)
  // =========================================================================
  Widget _buildSelectionStage() {
    final activePreset = kPhotoFilterPresets.firstWhere(
      (p) => p.id == _selectedFilterId,
      orElse: () => kPhotoFilterPresets.first,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. SIMPLE STEP NAVIGATION BAR
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: kPrimaryRed, width: 2),
              boxShadow: [
                BoxShadow(
                  color: kPrimaryRed.withAlpha(18),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: _buildSubStepIndicator(
                    stepNumber: 1,
                    title: '1. FOTO & TEMPLATE',
                    icon: Icons.photo_library_rounded,
                    isCompleted: _selectedPhotosIndices.length == 3,
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Icon(Icons.arrow_forward_ios_rounded, color: kPrimaryRed, size: 12),
                ),
                Expanded(
                  child: _buildSubStepIndicator(
                    stepNumber: 2,
                    title: '2. FILTER & EFEK',
                    icon: Icons.palette_rounded,
                    isCompleted: _selectionSubStep >= 2,
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Icon(Icons.arrow_forward_ios_rounded, color: kPrimaryRed, size: 12),
                ),
                Expanded(
                  child: _buildSubStepIndicator(
                    stepNumber: 3,
                    title: '3. PREVIEW & CETAK',
                    icon: Icons.print_rounded,
                    isCompleted: _selectionSubStep == 3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // 2. ACTIVE STEP CONTENT
          Expanded(
            child: _selectionSubStep == 1
                ? _buildSubStep1PhotosAndTemplate(activePreset)
                : _selectionSubStep == 2
                    ? _buildSubStep2FiltersAndEffects(activePreset)
                    : _buildSubStep3FullPreviewAndPrint(activePreset),
          ),
        ],
      ),
    );
  }

  Widget _buildSubStepIndicator({
    required int stepNumber,
    required String title,
    required IconData icon,
    required bool isCompleted,
  }) {
    final bool isActive = _selectionSubStep == stepNumber;

    return GestureDetector(
      onTap: () {
        if (stepNumber > 1 && _selectedPhotosIndices.length < 3) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Silakan pilih 3 foto terlebih dahulu.'),
              duration: Duration(seconds: 2),
              backgroundColor: kPrimaryRed,
            ),
          );
          return;
        }
        setState(() {
          _selectionSubStep = stepNumber;
        });
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isActive
                ? kPrimaryRed
                : (isCompleted ? kSoftRedBg : Colors.transparent),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isActive
                  ? kPrimaryRed
                  : (isCompleted ? kBorderRed : Colors.transparent),
              width: 1.5,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 18,
                color: isActive ? Colors.white : kPrimaryRed,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  title,
                  style: TextStyle(
                    color: isActive ? Colors.white : kPrimaryRed,
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
                    letterSpacing: 0.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSimple3PhotoPreview({
    String? filterIdOverride,
    double? intensityOverride,
  }) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(6),
      child: Column(
        children: [
          for (int i = 0; i < 3; i++)
            Expanded(
              child: Container(
                margin: EdgeInsets.only(bottom: i < 2 ? 6 : 0),
                decoration: BoxDecoration(
                  color: kSoftRedBg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: kBorderRed),
                ),
                child: _selectedPhotosIndices.length > i
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(5),
                        child: _applyLiveFilter(
                          Transform.scale(
                            scaleX: _isCameraMirrored ? -1 : 1,
                            child: _capturedPhotos[_selectedPhotosIndices[i]].path.isNotEmpty
                                ? Image.file(
                                    File(_capturedPhotos[_selectedPhotosIndices[i]].path),
                                    fit: BoxFit.cover,
                                    width: double.infinity,
                                    height: double.infinity,
                                  )
                                : const Center(
                                    child: Icon(Icons.broken_image, color: kBorderRed),
                                  ),
                          ),
                          filterIdOverride: filterIdOverride,
                          intensityOverride: intensityOverride,
                        ),
                      )
                    : Center(
                        child: Text(
                          'Foto ${i + 1}',
                          style: const TextStyle(color: kTextMuted, fontSize: 11, fontWeight: FontWeight.w700),
                        ),
                      ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLivePreviewSheet({
    Map<String, dynamic>? templateOverride,
    String? filterIdOverride,
    double? intensityOverride,
    bool useTemplateOverrideNullAsPolos = false,
  }) {
    final Map<String, dynamic>? targetTemplate =
        useTemplateOverrideNullAsPolos ? templateOverride : (templateOverride ?? _selectedTemplate);

    return AspectRatio(
      aspectRatio: _getTemplateSheetAspectRatio(targetTemplate),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kPrimaryRed, width: 2.5),
          boxShadow: [
            BoxShadow(
              color: kPrimaryRed.withAlpha(35),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: targetTemplate != null
            ? LayoutBuilder(
                builder: (context, constraints) {
                  return _buildCompositePreview(
                    constraints.maxWidth,
                    constraints.maxHeight,
                    templateOverride: targetTemplate,
                    filterIdOverride: filterIdOverride,
                    intensityOverride: intensityOverride,
                  );
                },
              )
            : _buildSimple3PhotoPreview(
                filterIdOverride: filterIdOverride,
                intensityOverride: intensityOverride,
              ),
      ),
    );
  }

  // =========================================================================
  // LANGKAH 1: KIRI = FOTO (1 KOLOM KE BAWAH), TENGAH = LIVE PREVIEW BESAR,
  //            KANAN = TEMPLATE BESAR (1 KOLOM KE BAWAH)
  // =========================================================================
  Widget _buildSubStep1PhotosAndTemplate(PhotoFilterPreset activePreset) {
    return Row(
      key: const ValueKey(1),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. KOLOM KIRI: PILIHAN FOTO (1 KOLOM MENJAJAR KE BAWAH)
        Expanded(
          flex: 3,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: kPrimaryRed, width: 2),
              boxShadow: [
                BoxShadow(
                  color: kPrimaryRed.withAlpha(18),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'PILIH FOTO (${_selectedPhotosIndices.length}/3)',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        color: kPrimaryRed,
                        letterSpacing: 0.6,
                      ),
                    ),
                    if (_remainingRetakes > 0)
                      TextButton.icon(
                        onPressed: _handleRetake,
                        style: TextButton.styleFrom(
                          foregroundColor: kPrimaryRed,
                          backgroundColor: kSoftRedBg,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                            side: const BorderSide(color: kPrimaryRed, width: 1.5),
                          ),
                        ),
                        icon: const Icon(Icons.replay_rounded, size: 15),
                        label: Text(
                          'Ulang ($_remainingRetakes)',
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.builder(
                    physics: const BouncingScrollPhysics(),
                    itemCount: _capturedPhotos.length,
                    itemBuilder: (context, index) {
                      final XFile file = _capturedPhotos[index];
                      final int selectedIndex = _selectedPhotosIndices.indexOf(index);
                      final bool isSelected = selectedIndex != -1;

                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            if (isSelected) {
                              _selectedPhotosIndices.removeAt(selectedIndex);
                            } else if (_selectedPhotosIndices.length < 3) {
                              _selectedPhotosIndices.add(index);
                            }
                          });
                        },
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            child: AspectRatio(
                              aspectRatio: 4 / 3,
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                decoration: BoxDecoration(
                                  color: kSoftRedBg,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: isSelected ? kPrimaryRed : kBorderRed,
                                    width: isSelected ? 3.5 : 1.5,
                                  ),
                                  boxShadow: isSelected
                                      ? [
                                          BoxShadow(
                                            color: kPrimaryRed.withAlpha(85),
                                            blurRadius: 10,
                                            offset: const Offset(0, 4),
                                          ),
                                        ]
                                      : null,
                                ),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(12.5),
                                      child: file.path.isNotEmpty
                                          ? _applyLiveFilter(
                                              Transform.scale(
                                                scaleX: _isCameraMirrored ? -1 : 1,
                                                child: Image.file(
                                                  File(file.path),
                                                  fit: BoxFit.cover,
                                                ),
                                              ),
                                            )
                                          : const Center(
                                              child: Icon(Icons.broken_image, color: kBorderRed, size: 32),
                                            ),
                                    ),
                                    if (!isSelected && _selectedPhotosIndices.length == 3)
                                      Container(
                                        decoration: BoxDecoration(
                                          color: Colors.white.withAlpha(150),
                                          borderRadius: BorderRadius.circular(12.5),
                                        ),
                                      ),
                                    if (isSelected)
                                      Positioned(
                                        top: 10,
                                        right: 10,
                                        child: Container(
                                          width: 36,
                                          height: 36,
                                          decoration: const BoxDecoration(
                                            color: kPrimaryRed,
                                            shape: BoxShape.circle,
                                          ),
                                          child: Center(
                                            child: Text(
                                              '${selectedIndex + 1}',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.w900,
                                                fontSize: 18,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 14),

        // 2. KOLOM TENGAH: LIVE PREVIEW SEMENTARA BESAR
        Expanded(
          flex: 5,
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: kPrimaryRed, width: 2),
              boxShadow: [
                BoxShadow(
                  color: kPrimaryRed.withAlpha(18),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(
                  child: Text(
                    'LIVE PREVIEW',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: kPrimaryRed,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: Center(
                    child: _buildLivePreviewSheet(),
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: _selectedPhotosIndices.length == 3
                        ? const [
                            BoxShadow(
                              color: kDarkRed,
                              offset: Offset(0, 4),
                              blurRadius: 0,
                            ),
                          ]
                        : null,
                  ),
                  child: ElevatedButton.icon(
                    onPressed: _selectedPhotosIndices.length == 3
                        ? () {
                            setState(() {
                              _selectionSubStep = 2;
                            });
                          }
                        : null,
                    icon: const Icon(Icons.arrow_forward_rounded, size: 20),
                    label: const Text(
                      'LANJUT KE FILTER',
                      style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, letterSpacing: 1),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kPrimaryRed,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: kBorderRed,
                      disabledForegroundColor: Colors.white70,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 14),

        // 3. KOLOM KANAN: PILIHAN TEMPLATE DARI DATABASE ONLINE (1 KOLOM MENJAJAR KE BAWAH)
        Expanded(
          flex: 3,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: kPrimaryRed, width: 2),
              boxShadow: [
                BoxShadow(
                  color: kPrimaryRed.withAlpha(18),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'PILIH TEMPLATE (${_templatesList.length})',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        color: kPrimaryRed,
                        letterSpacing: 0.6,
                      ),
                    ),
                    IconButton(
                      onPressed: _isLoadingTemplates ? null : _fetchTemplates,
                      tooltip: 'Muat ulang template dari database online',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.refresh_rounded, color: kPrimaryRed, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: _isLoadingTemplates && _templatesList.isEmpty
                      ? const Center(child: CircularProgressIndicator(color: kPrimaryRed))
                      : _templatesList.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.photo_album_outlined, color: kPrimaryRed, size: 38),
                                  const SizedBox(height: 10),
                                  const Text(
                                    'Belum ada template di database online untuk booth ini.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: kTextMuted,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  ElevatedButton.icon(
                                    onPressed: _fetchTemplates,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: kPrimaryRed,
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(18),
                                      ),
                                    ),
                                    icon: const Icon(Icons.refresh_rounded, size: 16),
                                    label: const Text(
                                      'Muat Ulang',
                                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              physics: const BouncingScrollPhysics(),
                              itemCount: _templatesList.length,
                              itemBuilder: (context, index) {
                                final Map<String, dynamic> template = _templatesList[index];
                                final bool isSelected = _selectedTemplate != null &&
                                    _selectedTemplate!['id_template'] == template['id_template'];

                                return GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      _selectedTemplate = template;
                                    });
                                  },
                                  child: MouseRegion(
                                    cursor: SystemMouseCursors.click,
                                    child: AnimatedContainer(
                                      duration: const Duration(milliseconds: 180),
                                      margin: const EdgeInsets.only(bottom: 14),
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: isSelected ? kSoftRedBg : Colors.white,
                                        borderRadius: BorderRadius.circular(18),
                                        border: Border.all(
                                          color: isSelected ? kPrimaryRed : kBorderRed,
                                          width: isSelected ? 3.5 : 1.5,
                                        ),
                                        boxShadow: isSelected
                                            ? [
                                                BoxShadow(
                                                  color: kPrimaryRed.withAlpha(75),
                                                  blurRadius: 10,
                                                  offset: const Offset(0, 4),
                                                ),
                                              ]
                                            : null,
                                      ),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          AspectRatio(
                                            aspectRatio: _getTemplateSheetAspectRatio(template),
                                            child: ClipRRect(
                                              borderRadius: BorderRadius.circular(10),
                                              child: LayoutBuilder(
                                                builder: (context, constraints) {
                                                  return _buildCompositePreview(
                                                    constraints.maxWidth,
                                                    constraints.maxHeight,
                                                    templateOverride: template,
                                                  );
                                                },
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          Text(
                                            template['name'] as String,
                                            style: TextStyle(
                                              color: kPrimaryRed,
                                              fontWeight: isSelected ? FontWeight.w900 : FontWeight.bold,
                                              fontSize: 13,
                                            ),
                                            textAlign: TextAlign.center,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // =========================================================================
  // LANGKAH 2: KIRI = PILIHAN FILTER BERUPA HASIL TEMPLATE+FOTO YG SUDAH DIFILTER (1 KOLOM KE BAWAH),
  //            TENGAH = LIVE PREVIEW BESAR, KANAN = INTENSITAS & KECERAHAN
  // =========================================================================
  Widget _buildSubStep2FiltersAndEffects(PhotoFilterPreset activePreset) {
    return Row(
      key: const ValueKey(2),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. KOLOM KIRI: PILIHAN FILTER BERUPA PREVIEW TEMPLATE & FOTO (1 KOLOM MENJAJAR KE BAWAH)
        Expanded(
          flex: 3,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: kPrimaryRed, width: 2),
              boxShadow: [
                BoxShadow(
                  color: kPrimaryRed.withAlpha(18),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(
                  child: Text(
                    'PILIH FILTER',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                      color: kPrimaryRed,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.builder(
                    physics: const BouncingScrollPhysics(),
                    itemCount: kPhotoFilterPresets.length,
                    itemBuilder: (context, index) {
                      final preset = kPhotoFilterPresets[index];
                      final bool isCurrent = _selectedFilterId == preset.id;

                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            _selectedFilterId = preset.id;
                            if (preset.id != 'normal' && _filterIntensity == 0.0) {
                              _filterIntensity = 1.0;
                            }
                          });
                        },
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            margin: const EdgeInsets.only(bottom: 14),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: isCurrent ? kSoftRedBg : Colors.white,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: isCurrent ? kPrimaryRed : kBorderRed,
                                width: isCurrent ? 3.5 : 1.5,
                              ),
                              boxShadow: isCurrent
                                  ? [
                                      BoxShadow(
                                        color: kPrimaryRed.withAlpha(75),
                                        blurRadius: 10,
                                        offset: const Offset(0, 4),
                                      ),
                                    ]
                                  : null,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AspectRatio(
                                  aspectRatio: _getTemplateSheetAspectRatio(),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: _selectedTemplate != null
                                        ? LayoutBuilder(
                                            builder: (context, constraints) {
                                              return _buildCompositePreview(
                                                constraints.maxWidth,
                                                constraints.maxHeight,
                                                filterIdOverride: preset.id,
                                                intensityOverride: preset.id == 'normal' ? 0.0 : 1.0,
                                              );
                                            },
                                          )
                                        : _buildSimple3PhotoPreview(
                                            filterIdOverride: preset.id,
                                            intensityOverride: preset.id == 'normal' ? 0.0 : 1.0,
                                          ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  preset.name,
                                  style: TextStyle(
                                    color: kPrimaryRed,
                                    fontWeight: isCurrent ? FontWeight.w900 : FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 14),

        // 2. KOLOM TENGAH: LIVE PREVIEW SEMENTARA BESAR
        Expanded(
          flex: 5,
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: kPrimaryRed, width: 2),
              boxShadow: [
                BoxShadow(
                  color: kPrimaryRed.withAlpha(18),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(
                  child: Text(
                    'LIVE PREVIEW',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: kPrimaryRed,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: Center(
                    child: _buildLivePreviewSheet(),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 14),

        // 3. KOLOM KANAN: INTENSITAS EFEK & KECERAHAN
        Expanded(
          flex: 3,
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: kPrimaryRed, width: 2),
              boxShadow: [
                BoxShadow(
                  color: kPrimaryRed.withAlpha(18),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(
                  child: Text(
                    'PENGATURAN EFEK',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                      color: kPrimaryRed,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // INTENSITAS EFEK
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: kSoftRedBg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: kBorderRed, width: 1.5),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'INTENSITAS EFEK',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                              color: _selectedFilterId == 'normal' ? kTextMuted : kPrimaryRed,
                            ),
                          ),
                          Text(
                            _selectedFilterId == 'normal' ? '0%' : '${(_filterIntensity * 100).round()}%',
                            style: TextStyle(
                              color: _selectedFilterId == 'normal' ? kTextMuted : kPrimaryRed,
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 6,
                          activeTrackColor: _selectedFilterId == 'normal' ? kBorderRed : kPrimaryRed,
                          inactiveTrackColor: kBorderRed,
                          thumbColor: _selectedFilterId == 'normal' ? kBorderRed : kPrimaryRed,
                          overlayColor: kPrimaryRed.withAlpha(30),
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
                        ),
                        child: Slider(
                          value: _filterIntensity,
                          min: 0.0,
                          max: 1.0,
                          divisions: 100,
                          onChanged: _selectedFilterId == 'normal'
                              ? null
                              : (val) {
                                  setState(() {
                                    _filterIntensity = val;
                                  });
                                },
                        ),
                      ),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final step in [0.0, 0.25, 0.50, 0.75, 1.0])
                            GestureDetector(
                              onTap: _selectedFilterId == 'normal'
                                  ? null
                                  : () {
                                      setState(() {
                                        _filterIntensity = step;
                                      });
                                    },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: (_filterIntensity == step && _selectedFilterId != 'normal')
                                      ? kPrimaryRed
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: (_filterIntensity == step && _selectedFilterId != 'normal')
                                        ? kPrimaryRed
                                        : kBorderRed,
                                  ),
                                ),
                                child: Text(
                                  '${(step * 100).round()}%',
                                  style: TextStyle(
                                    color: (_filterIntensity == step && _selectedFilterId != 'normal')
                                        ? Colors.white
                                        : kPrimaryRed,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // KECERAHAN
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: kSoftRedBg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: kBorderRed, width: 1.5),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'KECERAHAN',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                              color: kPrimaryRed,
                            ),
                          ),
                          Text(
                            _photoBrightness == 0.0
                                ? '0%'
                                : (_photoBrightness > 0.0
                                    ? '+${(_photoBrightness * 100).round()}%'
                                    : '${(_photoBrightness * 100).round()}%'),
                            style: const TextStyle(
                              color: kPrimaryRed,
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 6,
                          activeTrackColor: kPrimaryRed,
                          inactiveTrackColor: kBorderRed,
                          thumbColor: kPrimaryRed,
                          overlayColor: kPrimaryRed.withAlpha(30),
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
                        ),
                        child: Slider(
                          value: _photoBrightness,
                          min: -0.40,
                          max: 0.40,
                          divisions: 16,
                          onChanged: (val) {
                            setState(() {
                              _photoBrightness = val;
                            });
                          },
                        ),
                      ),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final item in [
                            {'label': '-20%', 'val': -0.20},
                            {'label': '-10%', 'val': -0.10},
                            {'label': '0%', 'val': 0.0},
                            {'label': '+15%', 'val': 0.15},
                            {'label': '+30%', 'val': 0.30},
                          ])
                            GestureDetector(
                              onTap: () {
                                setState(() {
                                  _photoBrightness = (item['val'] as num).toDouble();
                                });
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: ((_photoBrightness - (item['val'] as num).toDouble()).abs() < 0.01)
                                      ? kPrimaryRed
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: ((_photoBrightness - (item['val'] as num).toDouble()).abs() < 0.01)
                                        ? kPrimaryRed
                                        : kBorderRed,
                                  ),
                                ),
                                child: Text(
                                  item['label'] as String,
                                  style: TextStyle(
                                    color: ((_photoBrightness - (item['val'] as num).toDouble()).abs() < 0.01)
                                        ? Colors.white
                                        : kPrimaryRed,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),

                const Spacer(),

                // TOMBOL NAVIGASI BAWAH
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: const [
                      BoxShadow(
                        color: kDarkRed,
                        offset: Offset(0, 4),
                        blurRadius: 0,
                      ),
                    ],
                  ),
                  child: ElevatedButton.icon(
                    onPressed: () => setState(() => _selectionSubStep = 3),
                    icon: const Icon(Icons.arrow_forward_rounded, size: 20),
                    label: const Text(
                      'PREVIEW & CETAK',
                      style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, letterSpacing: 0.8),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kPrimaryRed,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () => setState(() => _selectionSubStep = 1),
                  icon: const Icon(Icons.arrow_back_rounded, size: 18),
                  label: const Text(
                    'KEMBALI',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900, letterSpacing: 0.6),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kPrimaryRed,
                    side: const BorderSide(color: kPrimaryRed, width: 2),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // =========================================================================
  // LANGKAH 3: PREVIEW 3D BERGOYANG HALUS (TIDAK 360 DERAJAT) & CETAK
  // =========================================================================
  Widget _buildSubStep3FullPreviewAndPrint(PhotoFilterPreset activePreset) {
    return Container(
      key: const ValueKey(3),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: kPrimaryRed, width: 2.5),
        boxShadow: [
          BoxShadow(
            color: kPrimaryRed.withAlpha(20),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Center(
              child: _ThreeDPreviewWrapper(
                child: _buildLivePreviewSheet(),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: () => setState(() => _selectionSubStep = 2),
                icon: const Icon(Icons.arrow_back_rounded, size: 20),
                label: const Text(
                  'KEMBALI',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, letterSpacing: 0.8),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: kPrimaryRed,
                  side: const BorderSide(color: kPrimaryRed, width: 2),
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 18),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                ),
              ),
              const SizedBox(width: 20),
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: const [
                    BoxShadow(
                      color: kDarkRed,
                      offset: Offset(0, 5),
                      blurRadius: 0,
                    ),
                  ],
                ),
                child: ElevatedButton.icon(
                  onPressed: _selectedPhotosIndices.length == 3 ? _triggerRealPrint : null,
                  icon: const Icon(Icons.print_rounded, size: 24),
                  label: Text(
                    'CETAK SEKARANG ($_selectedPrintCount LEMBAR)',
                    style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1, fontSize: 16),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kPrimaryRed,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: kBorderRed,
                    disabledForegroundColor: Colors.white70,
                    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 18),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                    elevation: 0,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // =========================================================================
  // TAHAP 4: PRINTING & QR SOFTFILE (WHITE & RED THEME)
  // =========================================================================
  Widget _buildPrintingStage() {
    final bool canShowQr = _isSoftfileUploaded && !_isUploadingSoftfile && _softfileDownloadUrl != null;

    return Center(
      child: Container(
        width: 560,
        padding: const EdgeInsets.symmetric(horizontal: 44, vertical: 38),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: kPrimaryRed, width: 2.5),
          boxShadow: [
            BoxShadow(
              color: kPrimaryRed.withAlpha(25),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 52,
              height: 52,
              child: CircularProgressIndicator(color: kPrimaryRed, strokeWidth: 4.5),
            ),
            const SizedBox(height: 22),
            const Text(
              'SEDANG MENCETAK & MENYIAPKAN SOFT FILE...',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: kPrimaryRed, letterSpacing: 1.2),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            if (canShowQr) ...[
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: kPrimaryRed, width: 2.5),
                ),
                child: QrImageView(
                  data: _softfileDownloadUrl!,
                  version: QrVersions.auto,
                  size: 200,
                  backgroundColor: Colors.white,
                  eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: Color(0xFF981B1E),
                  ),
                  dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Color(0xFF981B1E),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Scan QR untuk Download Soft File Hasil Foto',
                style: TextStyle(fontSize: 13, color: kPrimaryRed, fontWeight: FontWeight.w800),
                textAlign: TextAlign.center,
              ),
            ] else ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                decoration: BoxDecoration(
                  color: kSoftRedBg,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: kBorderRed, width: 1.5),
                ),
                child: const Text(
                  'Mengunggah 5 foto & hasil template HD ke server...\nQR Code akan tampil otomatis setelah unggahan selesai.',
                  style: TextStyle(fontSize: 13, color: kTextDark, fontWeight: FontWeight.w700, height: 1.5),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // =========================================================================
  // TAHAP 5: SELESAI & QR LINK DOWNLOAD SOFT FILE (WHITE & RED THEME)
  // =========================================================================
  Widget _buildDoneStage() {
    final bool canShowQr = _isSoftfileUploaded && !_isUploadingSoftfile && _softfileDownloadUrl != null;

    return Center(
      child: SingleChildScrollView(
        child: Container(
          width: 600,
          padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: kPrimaryRed, width: 2.5),
            boxShadow: [
              BoxShadow(
                color: kPrimaryRed.withAlpha(25),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const PixyboxOvalLogo(
                width: 220,
                height: 78,
                fontSize: 25,
              ),
              const SizedBox(height: 16),
              const Text(
                'SESI FOTO SELESAI!',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: kPrimaryRed, letterSpacing: 1.5),
              ),
              const SizedBox(height: 6),
              Text(
                canShowQr
                    ? 'Scan QR di bawah untuk mengunduh 5 foto & template HD Anda'
                    : (_isUploadingSoftfile
                        ? 'Mohon tunggu sebentar, sedang mengunggah 5 foto & template HD ke server...'
                        : 'Unggahan soft file belum selesai, silakan coba unggah ulang.'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13.5, color: kTextDark, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 20),

              // QR Code Download Softfile (hanya tampil jika upload ke server sudah selesai 100%)
              Container(
                width: 260,
                height: 260,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: canShowQr ? Colors.white : kSoftRedBg,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: kPrimaryRed, width: 3),
                  boxShadow: [
                    BoxShadow(
                      color: kPrimaryRed.withAlpha(30),
                      blurRadius: 20,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Center(
                  child: canShowQr
                      ? QrImageView(
                          data: _softfileDownloadUrl!,
                          version: QrVersions.auto,
                          size: 224,
                          backgroundColor: Colors.white,
                          eyeStyle: const QrEyeStyle(
                            eyeShape: QrEyeShape.square,
                            color: Color(0xFF981B1E),
                          ),
                          dataModuleStyle: const QrDataModuleStyle(
                            dataModuleShape: QrDataModuleShape.square,
                            color: Color(0xFF981B1E),
                          ),
                        )
                      : (_isUploadingSoftfile
                          ? const Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: CircularProgressIndicator(color: kPrimaryRed, strokeWidth: 4),
                                ),
                                SizedBox(height: 16),
                                Text(
                                  'MENGUNGGAH\nSOFT FILE HD...',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w900,
                                    color: kPrimaryRed,
                                    letterSpacing: 0.8,
                                    height: 1.4,
                                  ),
                                ),
                                SizedBox(height: 6),
                                Text(
                                  'QR akan muncul otomatis',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 11, color: kTextMuted, fontWeight: FontWeight.w700),
                                ),
                              ],
                            )
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.cloud_off_rounded, color: kPrimaryRed, size: 46),
                                const SizedBox(height: 10),
                                const Text(
                                  'Gagal Mengunggah Soft File',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w900, color: kPrimaryRed),
                                ),
                                const SizedBox(height: 12),
                                ElevatedButton.icon(
                                  onPressed: _retryUploadSoftfile,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: kPrimaryRed,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                                  ),
                                  icon: const Icon(Icons.refresh_rounded, size: 16),
                                  label: const Text(
                                    'Coba Lagi',
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                                  ),
                                ),
                              ],
                            )),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                canShowQr
                    ? _softfileDownloadUrl!
                    : (_isUploadingSoftfile
                        ? 'Harap tunggu hingga unggahan ke server online selesai...'
                        : 'Periksa koneksi internet dan tekan Coba Lagi'),
                style: const TextStyle(fontSize: 11.5, color: kTextMuted, fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),

              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: const [
                    BoxShadow(
                      color: kDarkRed,
                      offset: Offset(0, 5),
                      blurRadius: 0,
                    ),
                  ],
                ),
                child: ElevatedButton(
                  onPressed: _resetToStart,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kPrimaryRed,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 18),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                  child: Text(
                    _isUploadingSoftfile ? 'MULAI SESI BARU' : 'MULAI SESI BARU ($_doneCountdown s)',
                    style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.2, fontSize: 15),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThreeDPreviewWrapper extends StatefulWidget {
  final Widget child;

  const _ThreeDPreviewWrapper({required this.child});

  @override
  State<_ThreeDPreviewWrapper> createState() => _ThreeDPreviewWrapperState();
}

class _ThreeDPreviewWrapperState extends State<_ThreeDPreviewWrapper>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final double t = Curves.easeInOutSine.transform(_controller.value);
        // Smoothly tilt between -14 degrees (-0.24 rad) and +14 degrees (+0.24 rad) on Y-axis
        final double rotateY = (t - 0.5) * 0.48;
        // Subtle vertical tilt on X-axis (-3.5 to +3.5 degrees)
        final double rotateX = math.sin(t * math.pi) * 0.06;

        final Matrix4 transform = Matrix4.identity()
          ..setEntry(3, 2, 0.0014)
          ..rotateX(rotateX)
          ..rotateY(rotateY);

        return Transform(
          alignment: Alignment.center,
          transform: transform,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFD3242B).withAlpha(45),
                  blurRadius: 32,
                  spreadRadius: 2,
                  offset: Offset(-rotateY * 55, 14),
                ),
              ],
            ),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

class _SessionStartPillButton extends StatefulWidget {
  final VoidCallback onTap;

  const _SessionStartPillButton({required this.onTap});

  @override
  State<_SessionStartPillButton> createState() => _SessionStartPillButtonState();
}

class _SessionStartPillButtonState extends State<_SessionStartPillButton> {
  bool _isPressed = false;

  static const Color kPrimaryRed = Color(0xFFD3242B);
  static const Color kDarkRed = Color(0xFF94151A);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) {
        setState(() => _isPressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _isPressed = false),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          width: 245,
          height: 66,
          transform: Matrix4.translationValues(0, _isPressed ? 4 : 0, 0),
          decoration: BoxDecoration(
            color: kPrimaryRed,
            borderRadius: BorderRadius.circular(36),
            border: Border.all(color: kDarkRed, width: 1.5),
            boxShadow: _isPressed
                ? [
                    const BoxShadow(
                      color: kDarkRed,
                      offset: Offset(0, 2),
                      blurRadius: 0,
                    ),
                  ]
                : [
                    const BoxShadow(
                      color: kDarkRed,
                      offset: Offset(0, 6),
                      blurRadius: 0,
                    ),
                    BoxShadow(
                      color: kPrimaryRed.withAlpha(45),
                      offset: const Offset(0, 12),
                      blurRadius: 20,
                    ),
                  ],
          ),
          child: const Center(
            child: Text(
              'START',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: 3.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StaffAuthDialog extends StatefulWidget {
  final Map<String, dynamic> user;

  const _StaffAuthDialog({required this.user});

  @override
  State<_StaffAuthDialog> createState() => _StaffAuthDialogState();
}

class _StaffAuthDialogState extends State<_StaffAuthDialog> {
  static const Color kPrimaryRed = Color(0xFFD3242B);
  static const Color kSoftRedBg = Color(0xFFFFF5F5);
  static const Color kBorderRed = Color(0xFFF3C6C8);

  late final TextEditingController _passwordController;
  String? _errorMessage;
  bool _obscurePassword = true;
  bool _isVerifying = false;

  @override
  void initState() {
    super.initState();
    _passwordController = TextEditingController();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleSubmit() async {
    final password = _passwordController.text.trim();
    if (password.isEmpty) {
      setState(() {
        _errorMessage = 'Password tidak boleh kosong';
      });
      return;
    }

    setState(() {
      _isVerifying = true;
      _errorMessage = null;
    });

    final int idUser = widget.user['id_user'] is int
        ? widget.user['id_user']
        : int.tryParse(widget.user['id_user']?.toString() ?? '') ?? 0;
    final String username = widget.user['username']?.toString() ?? '';

    final isValid = await MySqlHelper.verifyStaffOrAdminPassword(
      idUser: idUser,
      username: username,
      password: password,
    );

    if (!mounted) return;

    if (isValid) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _isVerifying = false;
        _errorMessage = 'Password salah! Akses ke dashboard ditolak.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: kPrimaryRed, width: 2.5),
      ),
      child: Container(
        width: 440,
        padding: const EdgeInsets.all(32),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: kSoftRedBg,
                  shape: BoxShape.circle,
                  border: Border.all(color: kPrimaryRed, width: 2),
                ),
                child: const Icon(
                  Icons.lock_outline_rounded,
                  size: 38,
                  color: kPrimaryRed,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'AUTENTIKASI PETUGAS',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2,
                  color: kPrimaryRed,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Masukkan password akun untuk kembali ke Dashboard Pengaturan.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Color(0xFF7A6869),
                  height: 1.4,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                autofocus: true,
                style: const TextStyle(color: Color(0xFF1F1F1F), fontSize: 15, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: kSoftRedBg,
                  hintText: 'Password',
                  hintStyle: const TextStyle(color: Color(0xFF7A6869)),
                  prefixIcon: const Icon(Icons.password_rounded, color: kPrimaryRed, size: 20),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                      color: kPrimaryRed,
                      size: 20,
                    ),
                    onPressed: () {
                      setState(() {
                        _obscurePassword = !_obscurePassword;
                      });
                    },
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: kBorderRed, width: 1.5),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: kPrimaryRed, width: 2),
                  ),
                ),
                onSubmitted: (_) {
                  if (!_isVerifying) _handleSubmit();
                },
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.error_outline_rounded, color: kPrimaryRed, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: kPrimaryRed, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 28),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _isVerifying
                          ? null
                          : () => Navigator.of(context).pop(false),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: kPrimaryRed,
                        side: const BorderSide(color: kPrimaryRed, width: 1.5),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                      child: const Text('Batal', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _isVerifying ? null : _handleSubmit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kPrimaryRed,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                      child: _isVerifying
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : const Text(
                              'Kembali ke Dashboard',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RetakeSelectionDialog extends StatefulWidget {
  final List<XFile> capturedPhotos;
  final List<int> selectedPhotosIndices;
  final bool isCameraMirrored;
  final int remainingRetakes;
  final int maxRetakeLimit;
  final Widget Function(Widget) applyLiveFilter;

  const _RetakeSelectionDialog({
    required this.capturedPhotos,
    required this.selectedPhotosIndices,
    required this.isCameraMirrored,
    required this.remainingRetakes,
    required this.maxRetakeLimit,
    required this.applyLiveFilter,
  });

  @override
  State<_RetakeSelectionDialog> createState() => _RetakeSelectionDialogState();
}

class _RetakeSelectionDialogState extends State<_RetakeSelectionDialog> {
  static const Color kPrimaryRed = Color(0xFFD3242B);
  static const Color kSoftRedBg = Color(0xFFFFF5F5);
  static const Color kBorderRed = Color(0xFFF3C6C8);

  final Set<int> _selectedIndicesToRetake = {};

  void _toggleSelectAll() {
    setState(() {
      if (_selectedIndicesToRetake.length == widget.capturedPhotos.length) {
        _selectedIndicesToRetake.clear();
      } else {
        _selectedIndicesToRetake.addAll(List.generate(widget.capturedPhotos.length, (i) => i));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool isAllSelected = _selectedIndicesToRetake.length == widget.capturedPhotos.length;
    final int count = _selectedIndicesToRetake.length;

    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: kPrimaryRed, width: 2.5),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: kSoftRedBg,
                          shape: BoxShape.circle,
                          border: Border.all(color: kPrimaryRed, width: 1.5),
                        ),
                        child: const Icon(Icons.replay_rounded, color: kPrimaryRed, size: 24),
                      ),
                      const SizedBox(width: 14),
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'PILIH FOTO UNTUK DI-RETAKE',
                            style: TextStyle(
                              color: kPrimaryRed,
                              fontWeight: FontWeight.w900,
                              fontSize: 17,
                              letterSpacing: 0.8,
                            ),
                          ),
                          SizedBox(height: 3),
                          Text(
                            'Pilih foto yang ingin diganti (misal pilih 2 foto = kamera jepret 2 kali).',
                            style: TextStyle(color: Color(0xFF7A6869), fontSize: 11, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: kSoftRedBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: kPrimaryRed, width: 1.5),
                    ),
                    child: Text(
                      'Sisa Kesempatan: ${widget.remainingRetakes}x dari ${widget.maxRetakeLimit}x',
                      style: const TextStyle(
                        color: kPrimaryRed,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),

              Row(
                children: [
                  TextButton.icon(
                    onPressed: _toggleSelectAll,
                    icon: Icon(
                      isAllSelected ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                      size: 18,
                      color: kPrimaryRed,
                    ),
                    label: Text(
                      isAllSelected ? 'Batalkan Pilih Semua' : 'Pilih Semua (${widget.capturedPhotos.length} Foto)',
                      style: const TextStyle(color: kPrimaryRed, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    count == 0
                        ? 'Ketuk foto di bawah untuk memilih'
                        : '$count Foto dipilih ($count kali jepretan)',
                    style: TextStyle(
                      color: count > 0 ? kPrimaryRed : const Color(0xFF7A6869),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: Row(
                  children: List.generate(widget.capturedPhotos.length, (index) {
                    final photo = widget.capturedPhotos[index];
                    final bool isSelected = _selectedIndicesToRetake.contains(index);
                    final int collagePos = widget.selectedPhotosIndices.indexOf(index);
                    final bool isInCollage = collagePos != -1;

                    return GestureDetector(
                      onTap: () {
                        setState(() {
                          if (isSelected) {
                            _selectedIndicesToRetake.remove(index);
                          } else {
                            _selectedIndicesToRetake.add(index);
                          }
                        });
                      },
                      child: Container(
                        width: 135,
                        height: 195,
                        margin: const EdgeInsets.only(right: 12),
                        decoration: BoxDecoration(
                          color: kSoftRedBg,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isSelected ? kPrimaryRed : kBorderRed,
                            width: isSelected ? 3 : 1.5,
                          ),
                          boxShadow: isSelected
                              ? [
                                  BoxShadow(
                                    color: kPrimaryRed.withAlpha(90),
                                    blurRadius: 12,
                                    offset: const Offset(0, 3),
                                  ),
                                ]
                              : null,
                        ),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(13),
                              child: photo.path.isNotEmpty
                                  ? widget.applyLiveFilter(
                                      Transform.scale(
                                        scaleX: widget.isCameraMirrored ? -1 : 1,
                                        child: Image.file(
                                          File(photo.path),
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                    )
                                  : const Center(
                                      child: Icon(Icons.broken_image, color: kBorderRed),
                                    ),
                            ),

                            if (isSelected)
                              Container(
                                decoration: BoxDecoration(
                                  color: kPrimaryRed.withAlpha(65),
                                  borderRadius: BorderRadius.circular(13),
                                ),
                              ),

                            Positioned(
                              top: 8,
                              left: 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: kPrimaryRed),
                                ),
                                child: Text(
                                  'Foto #${index + 1}',
                                  style: const TextStyle(color: kPrimaryRed, fontSize: 10, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),

                            Positioned(
                              top: 8,
                              right: 8,
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: isSelected ? kPrimaryRed : Colors.white,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: kPrimaryRed,
                                    width: 1.5,
                                  ),
                                ),
                                child: Icon(
                                  isSelected ? Icons.check : Icons.add,
                                  size: 14,
                                  color: isSelected ? Colors.white : kPrimaryRed,
                                ),
                              ),
                            ),

                            Positioned(
                              bottom: 8,
                              left: 8,
                              right: 8,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (isInCollage)
                                    Container(
                                      margin: const EdgeInsets.only(bottom: 4),
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(color: kPrimaryRed),
                                      ),
                                      child: Text(
                                        'Di Kolase #${collagePos + 1}',
                                        style: const TextStyle(color: kPrimaryRed, fontSize: 8.5, fontWeight: FontWeight.bold),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                                    decoration: BoxDecoration(
                                      color: isSelected ? kPrimaryRed : Colors.white,
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: kPrimaryRed,
                                      ),
                                    ),
                                    child: Text(
                                      isSelected ? 'AKAN DI-RETAKE' : 'TETAP SIMPAN',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: isSelected ? Colors.white : kPrimaryRed,
                                        fontSize: 9,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 0.4,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ),
              ),
              const SizedBox(height: 20),

              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(null),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: kPrimaryRed,
                      side: const BorderSide(color: kPrimaryRed, width: 1.5),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                    ),
                    child: const Text('Batal', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 14),
                  ElevatedButton.icon(
                    onPressed: count > 0
                        ? () {
                            Navigator.of(context).pop(_selectedIndicesToRetake.toList()..sort());
                          }
                        : null,
                    icon: const Icon(Icons.camera_alt_rounded, size: 18),
                    label: Text(
                      count > 0 ? 'Mulai Foto Ulang ($count Foto)' : 'Pilih Foto Terlebih Dahulu',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kPrimaryRed,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: kBorderRed,
                      disabledForegroundColor: Colors.white70,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
