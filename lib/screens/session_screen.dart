import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:image/image.dart' as img;
import '../mysql_helper.dart';
import '../midtrans_service.dart';

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
  // Stages: PAYMENT, SHOOTING, SELECTION, PRINTING, DONE
  String _currentStage = 'PAYMENT';

  // Midtrans QRIS variables
  String? _qrisUrl;
  String? _currentOrderId;
  Timer? _qrisPollingTimer;
  bool _isGeneratingQR = false;
  String _paymentStatus = 'pending';

  int _selectedPrintCount = 1;
  double _price = 0.0;
  bool _isLoadingPrice = true;
  List<Map<String, dynamic>> _priceList = [];

  // Camera Controller
  CameraController? _cameraController;
  List<CameraDescription> _camerasList = [];
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
  int _shotCountdown = 10; // 10 detik per foto
  int _takenPhotosCount = 0; // Target 5 foto
  bool _isFlashActive = false;

  Timer? _overallTimer;
  Timer? _shotTimer;

  // List menyimpan file foto asli
  List<XFile> _capturedPhotos = [];

  // Pilihan 3 foto (menyimpan indeks foto dari _capturedPhotos)
  // Indeks pertama = paling atas, kedua = tengah, ketiga = paling bawah
  final List<int> _selectedPhotosIndices = [];

  @override
  void initState() {
    super.initState();
    _loadCalibrationSettings();
    _fetchPricing();
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
    // Tunggu agar OS/driver Windows melepas kunci hardware kamera dari screen sebelumnya
    await Future.delayed(const Duration(milliseconds: 1500));

    final newController = CameraController(
      widget.camera,
      ResolutionPreset.medium,
      enableAudio: false,
    );
    _cameraController = newController;

    int retryCount = 0;
    bool success = false;
    while (retryCount < 5 && !success && mounted) {
      try {
        await newController.initialize();
        success = true;
      } catch (e) {
        debugPrint('Session camera initialization failed with exception (attempt ${retryCount + 1}): $e');
        retryCount++;
        await Future.delayed(const Duration(milliseconds: 1000));
      }
    }

    if (mounted && _cameraController == newController) {
      setState(() {
        _isCameraInitialized = success;
      });
    } else {
      try {
        newController.dispose();
      } catch (_) {}
    }
  }

  Future<void> _fetchPricing() async {
    setState(() {
      _isLoadingPrice = true;
    });

    final userId = widget.user['id_user'] as int;
    final prices = await MySqlHelper.getPricesForUser(userId);

    setState(() {
      _priceList = prices;
      _updatePrice();
      _isLoadingPrice = false;
    });

    _generateQrisPayment();
  }

  Future<void> _generateQrisPayment() async {
    _qrisPollingTimer?.cancel();
    
    setState(() {
      _isGeneratingQR = true;
      _qrisUrl = null;
      _paymentStatus = 'pending';
    });

    final orderId = 'PB-${widget.user['id_user']}-${DateTime.now().millisecondsSinceEpoch}';
    _currentOrderId = orderId;

    final result = await MidtransService.generateQRIS(
      orderId: orderId,
      amount: _price.toInt(),
      itemName: "PixyBox ${_selectedPrintCount}x cetak",
    );

    if (result != null && mounted && _currentOrderId == orderId) {
      setState(() {
        _qrisUrl = result['qr_url'];
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
    _qrisPollingTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (_currentStage != 'PAYMENT') {
        timer.cancel();
        return;
      }
      final status = await MidtransService.checkPaymentStatus(orderId);
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _paymentStatus = status;
      });

      if (status == 'settlement' || status == 'capture') {
        timer.cancel();
        _goToShootingStage();
      }
    });
  }

  void _updatePrice() {
    final match = _priceList.firstWhere(
      (p) => p['print_count'] == _selectedPrintCount,
      orElse: () => {'print_count': _selectedPrintCount, 'price': _selectedPrintCount == 1 ? 25000.0 : 35000.0},
    );
    setState(() {
      _price = match['price'] as double;
    });
  }

  Future<void> _fetchTemplates() async {
    setState(() {
      _isLoadingTemplates = true;
    });
    try {
      final userId = widget.user['id_user'] as int;
      final role = widget.user['role'] as String;
      final temps = await MySqlHelper.getTemplatesForUser(userId, role);
      setState(() {
        _templatesList = temps;
        if (temps.isNotEmpty) {
          _selectedTemplate = temps.first;
        }
        _isLoadingTemplates = false;
      });
    } catch (e) {
      debugPrint('Error fetching templates: $e');
      setState(() {
        _isLoadingTemplates = false;
      });
    }
  }

  Widget _buildCompositePreview(double width, double height) {
    if (_selectedTemplate == null) return const SizedBox();
    
    final t = _selectedTemplate!;
    final double slot1X = t['slot1_x'];
    final double slot1Y = t['slot1_y'];
    final double slot1W = t['slot1_w'];
    final double slot1H = t['slot1_h'];

    final double slot2X = t['slot2_x'];
    final double slot2Y = t['slot2_y'];
    final double slot2W = t['slot2_w'];
    final double slot2H = t['slot2_h'];

    final double slot3X = t['slot3_x'];
    final double slot3Y = t['slot3_y'];
    final double slot3W = t['slot3_w'];
    final double slot3H = t['slot3_h'];

    return Stack(
      children: [
        // Slot 1
        _buildPreviewSlot(0, slot1X, slot1Y, slot1W, slot1H, width, height, 'Foto 1 (Atas)'),
        // Slot 2
        _buildPreviewSlot(1, slot2X, slot2Y, slot2W, slot2H, width, height, 'Foto 2 (Tengah)'),
        // Slot 3
        _buildPreviewSlot(2, slot3X, slot3Y, slot3W, slot3H, width, height, 'Foto 3 (Bawah)'),
        
        // Template overlay
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

  Widget _buildPreviewSlot(int index, double x, double y, double w, double h, double canvasW, double canvasH, String placeholder) {
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
          color: const Color(0xFF0F0F0F),
          border: Border.all(color: Colors.white10),
        ),
        child: _selectedPhotosIndices.length > index
            ? ClipRRect(
                child: Transform.scale(
                  scaleX: -1,
                  child: _capturedPhotos[_selectedPhotosIndices[index]].path.isNotEmpty
                      ? Image.file(
                          File(_capturedPhotos[_selectedPhotosIndices[index]].path),
                          fit: BoxFit.cover,
                          width: double.infinity,
                          height: double.infinity,
                        )
                      : const Center(
                          child: Icon(Icons.broken_image, color: Colors.white24),
                        ),
                ),
              )
            : Center(
                child: Text(
                  placeholder,
                  style: const TextStyle(color: Colors.white12, fontSize: 10),
                  textAlign: TextAlign.center,
                ),
              ),
      ),
    );
  }

  void _goToShootingStage() {
    setState(() {
      _currentStage = 'SHOOTING';
      _hasStartedShooting = false;
      _overallTimeRemaining = 120;
      _shotCountdown = 10;
      _takenPhotosCount = 0;
      _capturedPhotos.clear();
      _selectedPhotosIndices.clear();
      _isFlashActive = false;
    });
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
        _goToSelectionStage();
      }
    });

    _startNextShotTimer();
  }

  void _startNextShotTimer() {
    setState(() {
      _shotCountdown = 10; // 10 detik per foto
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

    setState(() {
      _capturedPhotos.add(file!);
      _takenPhotosCount++;
    });

    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        setState(() {
          _isFlashActive = false;
        });

        if (_takenPhotosCount < 5) {
          _startNextShotTimer();
        } else {
          _stopTimers();
          _goToSelectionStage();
        }
      }
    });
  }

  void _goToSelectionStage() {
    setState(() {
      _currentStage = 'SELECTION';
    });
  }

  // Melakukan print riil ke printer dengan size A6 Portrait
  Future<void> _triggerRealPrint() async {
    setState(() {
      _currentStage = 'PRINTING';
    });

    try {
      // Memuat file-file foto terpilih
      final List<File> imageFiles = _selectedPhotosIndices
          .map((idx) => File(_capturedPhotos[idx].path))
          .toList();

      List<pw.MemoryImage> pdfImages = [];
      for (var f in imageFiles) {
        if (await f.exists()) {
          final bytes = await f.readAsBytes();
          try {
            // Mirror gambar secara horisontal agar sesuai dengan layar preview/jepretan
            final decoded = img.decodeImage(bytes);
            if (decoded != null) {
              img.flipHorizontal(decoded);
              final flippedBytes = img.encodeJpg(decoded);
              pdfImages.add(pw.MemoryImage(Uint8List.fromList(flippedBytes)));
            } else {
              pdfImages.add(pw.MemoryImage(bytes));
            }
          } catch (e) {
            debugPrint('Error mirroring print image: $e');
            pdfImages.add(pw.MemoryImage(bytes));
          }
        }
      }

      // Cari printer sistem sesuai konfigurasi dashboard
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

      // Kirim dokumen langsung ke spooler cetak menggunakan format printer
      await Printing.directPrintPdf(
        printer: targetPrinter,
        onLayout: (PdfPageFormat format) async {
          debugPrint('Printer layout format: $format');
          
          final doc = pw.Document();
          // Gunakan format native dari printer driver (A4) agar driver memetakan area cetak dengan benar
          final pageFormat = format;

          final double leftPadding = _printOffsetX > 0 ? _printOffsetX * 2.83464567 : 0.0;
          final double rightPadding = _printOffsetX < 0 ? -_printOffsetX * 2.83464567 : 0.0;
          final double topPadding = 28.0 + (_printOffsetY * 2.83464567);

          final double paperWidth = 11.5 * 28.3464567; // ~326 pt
          final double paperHeight = 14.7 * 28.3464567; // ~417 pt

          doc.addPage(
            pw.Page(
              pageFormat: pageFormat,
              margin: pw.EdgeInsets.zero, // Zero margin agar kontrol posisi presisi
              build: (pw.Context context) {
                return pw.Align(
                  alignment: pw.Alignment.topCenter, // Horisontal: tengah, Vertikal: atas
                  child: pw.Padding(
                    padding: pw.EdgeInsets.only(
                      top: topPadding >= 0 ? topPadding : 0,
                      left: leftPadding,
                      right: rightPadding,
                    ),
                    child: _selectedTemplate != null
                        ? pw.Container(
                            width: paperWidth,
                            height: paperHeight,
                            child: pw.Stack(
                              children: [
                                if (pdfImages.isNotEmpty)
                                  pw.Positioned(
                                    left: _selectedTemplate!['slot1_x'] * paperWidth,
                                    top: _selectedTemplate!['slot1_y'] * paperHeight,
                                    child: pw.SizedBox(
                                      width: _selectedTemplate!['slot1_w'] * paperWidth,
                                      height: _selectedTemplate!['slot1_h'] * paperHeight,
                                      child: pw.Image(pdfImages[0], fit: pw.BoxFit.cover),
                                    ),
                                  ),
                                if (pdfImages.length > 1)
                                  pw.Positioned(
                                    left: _selectedTemplate!['slot2_x'] * paperWidth,
                                    top: _selectedTemplate!['slot2_y'] * paperHeight,
                                    child: pw.SizedBox(
                                      width: _selectedTemplate!['slot2_w'] * paperWidth,
                                      height: _selectedTemplate!['slot2_h'] * paperHeight,
                                      child: pw.Image(pdfImages[1], fit: pw.BoxFit.cover),
                                    ),
                                  ),
                                if (pdfImages.length > 2)
                                  pw.Positioned(
                                    left: _selectedTemplate!['slot3_x'] * paperWidth,
                                    top: _selectedTemplate!['slot3_y'] * paperHeight,
                                    child: pw.SizedBox(
                                      width: _selectedTemplate!['slot3_w'] * paperWidth,
                                      height: _selectedTemplate!['slot3_h'] * paperHeight,
                                      child: pw.Image(pdfImages[2], fit: pw.BoxFit.cover),
                                    ),
                                  ),
                                pw.Positioned.fill(
                                  child: pw.Image(
                                    pw.MemoryImage(_selectedTemplate!['image_data']),
                                    fit: pw.BoxFit.fill,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : pw.Column(
                            mainAxisAlignment: pw.MainAxisAlignment.start,
                            crossAxisAlignment: pw.CrossAxisAlignment.center,
                            children: [
                              for (int i = 0; i < pdfImages.length; i++)
                                pw.Container(
                                  width: 115, // Lebar foto 1:1
                                  height: 115, // 1:1 Square
                                  margin: pw.EdgeInsets.only(bottom: i < pdfImages.length - 1 ? 8 : 0),
                                  decoration: pw.BoxDecoration(
                                    border: pw.Border.all(color: PdfColors.black, width: 2),
                                  ),
                                  child: pw.Image(pdfImages[i], fit: pw.BoxFit.cover),
                                ),
                            ],
                          ),
                  ),
                );
              },
            ),
          );
          return doc.save();
        },
      );
    } catch (e) {
      debugPrint("Gagal melakukan pencetakan: $e");
    }

    // Tunggu simulasi visual sebelum selesai
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() {
          _currentStage = 'DONE';
        });
      }
    });
  }

  void _stopTimers() {
    _overallTimer?.cancel();
    _shotTimer?.cancel();
    _qrisPollingTimer?.cancel();
  }

  void _resetToStart() {
    setState(() {
      _currentStage = 'PAYMENT';
      _selectedPrintCount = 1;
      _updatePrice();
    });
  }

  Future<void> _goBack() async {
    if (_cameraController != null) {
      await _cameraController!.dispose();
      _cameraController = null;
    }
    if (mounted) {
      Navigator.pop(context);
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

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        title: Text(
          _currentStage == 'PAYMENT'
              ? 'TAHAP 1: PEMBAYARAN & CETAK'
              : _currentStage == 'SHOOTING'
                  ? 'TAHAP 2: AMBIL FOTO'
                  : _currentStage == 'SELECTION'
                      ? 'TAHAP 3: PILIH 3 FOTO ANDALAN'
                      : _currentStage == 'PRINTING'
                          ? 'TAHAP 4: MENCETAK'
                          : 'SESI SELESAI',
          style: const TextStyle(fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 1),
        ),
        backgroundColor: const Color(0xFF161616),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: (_currentStage == 'PAYMENT') ? _goBack : null,
        ),
      ),
      body: Container(
        color: const Color(0xFF0F0F0F),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: _buildStageContent(formattedPrice),
        ),
      ),
    );
  }

  Widget _buildStageContent(String formattedPrice) {
    switch (_currentStage) {
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

  // TAHAP 1: Pembayaran & Pilihan Print
  Widget _buildPaymentStage(String formattedPrice) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Left Column: QRIS Payment Box
        Expanded(
          flex: 3,
          child: Container(
            padding: const EdgeInsets.all(40),
            decoration: BoxDecoration(
              color: const Color(0xFF161616),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white12),
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.qr_code_2_outlined, size: 80, color: Colors.white),
                  const SizedBox(height: 16),
                  const Text(
                    'QRIS PAYMENT GATEWAY',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 2),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Scan QR di bawah untuk menyelesaikan pembayaran sesi photobox',
                    style: TextStyle(fontSize: 12, color: Colors.white54),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  
                  Container(
                    width: 500,
                    height: 500,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white24, width: 4),
                    ),
                    child: Center(
                      child: _isGeneratingQR
                          ? const CircularProgressIndicator(color: Colors.black)
                          : _qrisUrl != null
                              ? Image.network(
                                  _qrisUrl!,
                                  width: double.infinity,
                                  height: double.infinity,
                                  fit: BoxFit.contain,
                                  errorBuilder: (context, error, stackTrace) {
                                    return const Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.broken_image, color: Colors.black, size: 48),
                                        SizedBox(height: 8),
                                        Text(
                                          'Gagal memuat QR',
                                          style: TextStyle(color: Colors.black, fontSize: 11),
                                        ),
                                      ],
                                    );
                                  },
                                )
                              : const Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.qr_code_scanner,
                                      size: 80,
                                      color: Colors.black,
                                    ),
                                    SizedBox(height: 8),
                                    Text(
                                      'QRIS belum dibuat',
                                      style: TextStyle(color: Colors.black54, fontSize: 11),
                                    ),
                                  ],
                                ),
                    ),
                  ),
                const SizedBox(height: 20),
                Text(
                  _isGeneratingQR
                      ? 'Menyiapkan QRIS...'
                      : _paymentStatus == 'settlement' || _paymentStatus == 'capture'
                          ? 'Pembayaran Sukses!'
                          : 'Status: Menunggu Pembayaran...',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: _paymentStatus == 'settlement' || _paymentStatus == 'capture'
                        ? Colors.green
                        : Colors.white70,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
        const SizedBox(width: 28),

        // Right Column: Sesi Setup & Lanjutkan
        Expanded(
          flex: 2,
          child: Container(
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: const Color(0xFF161616),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'RINGKASAN SESI',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 24),

                _buildInfoTile(Icons.videocam_outlined, 'Input Kamera', widget.camera.name),
                const SizedBox(height: 12),
                _buildInfoTile(Icons.print_outlined, 'Output Printer', widget.printer),

                const SizedBox(height: 28),
                const Divider(color: Colors.white24),
                const SizedBox(height: 28),

                const Text(
                  'PILIH JUMLAH CETAK (PRINT)',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white60),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(child: _buildPrintCountOption(1, '1x Cetak')),
                    const SizedBox(width: 12),
                    Expanded(child: _buildPrintCountOption(2, '2x Cetak')),
                  ],
                ),

                const SizedBox(height: 32),

                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(8),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('TOTAL TARIF SESI', style: TextStyle(fontSize: 10, color: Colors.white38, letterSpacing: 1)),
                      const SizedBox(height: 4),
                      _isLoadingPrice
                          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : Text(
                              formattedPrice,
                              style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: Colors.white),
                            ),
                    ],
                  ),
                ),

                const Spacer(),

                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(5),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.orangeAccent, size: 24),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Silakan lakukan pembayaran melalui QRIS di samping. Kamera akan terbuka secara otomatis setelah pembayaran sukses dideteksi.',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        )
      ],
    );
  }

  // TAHAP 2: Kamera View & Ambil Foto
  Widget _buildShootingStage() {
    final String minutes = (_overallTimeRemaining ~/ 60).toString().padLeft(2, '0');
    final String seconds = (_overallTimeRemaining % 60).toString().padLeft(2, '0');

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Camera View (Left side)
        Expanded(
          flex: 3,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white24, width: 1.5),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _isCameraInitialized && _cameraController != null
                      ? Center(
                          child: AspectRatio(
                            aspectRatio: 1.0,
                            child: ClipRect(
                              child: FittedBox(
                                fit: BoxFit.cover,
                                alignment: Alignment.center,
                                child: Container(
                                  width: 400,
                                  height: 400 / _cameraController!.value.aspectRatio,
                                  child: CameraPreview(_cameraController!),
                                ),
                              ),
                            ),
                          ),
                        )
                      : Container(
                          color: const Color(0xFF0F0F0F),
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.videocam_off_outlined, size: 70, color: Colors.white.withAlpha(30)),
                                const SizedBox(height: 12),
                                const Text(
                                  'MENGHUBUNGKAN KE CAMERA...',
                                  style: TextStyle(color: Colors.white30, fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                        ),

                  if (!_hasStartedShooting)
                    Positioned.fill(
                      child: Container(
                        color: Colors.black54,
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.all(32),
                            decoration: BoxDecoration(
                              color: const Color(0xFF161616),
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(color: Colors.white24),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text(
                                  'KAMERA SIAP!',
                                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 2),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'Sesi foto 5 kali dengan interval 10 detik per foto.',
                                  style: TextStyle(fontSize: 13, color: Colors.white54),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 32),
                                ElevatedButton.icon(
                                  onPressed: _startShootingFlow,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.white,
                                    foregroundColor: Colors.black,
                                    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                  ),
                                  icon: const Icon(Icons.play_arrow, size: 24),
                                  label: const Text(
                                    'MULAI BERGAYA & FOTO',
                                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                  if (_hasStartedShooting)
                    Positioned(
                      top: 24,
                      left: 24,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black.withAlpha(200),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.timer_outlined, color: Colors.white, size: 16),
                            const SizedBox(width: 8),
                            Text(
                              'Sisa Waktu Sesi: $minutes:$seconds',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ),

                  if (_hasStartedShooting)
                    Center(
                      child: Container(
                        width: 130,
                        height: 130,
                        decoration: BoxDecoration(
                          color: Colors.black.withAlpha(180),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white38, width: 3),
                        ),
                        child: Center(
                          child: Text(
                            '$_shotCountdown',
                            style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w900, color: Colors.white),
                          ),
                        ),
                      ),
                    ),

                  if (_isFlashActive)
                    Positioned.fill(
                      child: Container(
                        color: Colors.white,
                        child: const Center(
                          child: Icon(Icons.flash_on, size: 100, color: Colors.black),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 28),

        // Photo Grid / Result (Right side)
        Expanded(
          flex: 2,
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF161616),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'HASIL FOTO JEPRETAN',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 1.5),
                ),
                const SizedBox(height: 16),
                
                Expanded(
                  child: GridView.builder(
                    itemCount: 5,
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: 0.8,
                    ),
                    itemBuilder: (context, index) {
                      final bool isTaken = _capturedPhotos.length > index;
                      final bool isCurrent = _takenPhotosCount == index && _hasStartedShooting;
                      
                      if (isTaken) {
                        final XFile file = _capturedPhotos[index];
                        return Container(
                          decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10.5),
                            child: file.path.isNotEmpty
                                ? Transform.scale(
                                    scaleX: -1,
                                    child: Image.file(
                                      File(file.path),
                                      fit: BoxFit.cover,
                                    ),
                                  )
                                : const Center(child: Icon(Icons.broken_image, color: Colors.white30)),
                          ),
                        );
                      } else {
                        return Container(
                          decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isCurrent ? Colors.white : Colors.white24,
                              width: isCurrent ? 2 : 1,
                            ),
                          ),
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  isCurrent ? Icons.videocam_rounded : Icons.photo_outlined,
                                  color: isCurrent ? Colors.white : Colors.white12,
                                  size: 28,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  isCurrent ? 'MEMBIDIK' : 'FOTO ${index + 1}',
                                  style: TextStyle(
                                    color: isCurrent ? Colors.white : Colors.white12,
                                    fontSize: 11,
                                    fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }
                    },
                  ),
                ),

                const SizedBox(height: 12),
                Text(
                  _hasStartedShooting 
                      ? 'Proses: $_takenPhotosCount dari 5 Foto Terkumpul' 
                      : 'Menunggu Sesi Pengambilan Foto Dimulai...',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // TAHAP 3: Memilih 3 Foto Terbaik untuk Kolase A6
  Widget _buildSelectionStage() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Left Column: 5 Photos Gallery & Template Picker
        Expanded(
          flex: 3,
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF161616),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'PILIH 3 FOTO TERBAIK',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 1),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Klik foto sesuai urutan yang Anda inginkan: ke-1 (atas), ke-2 (tengah), dan ke-3 (bawah).',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
                const SizedBox(height: 16),
                
                Expanded(
                  child: GridView.builder(
                    itemCount: _capturedPhotos.length,
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 16,
                      mainAxisSpacing: 16,
                      childAspectRatio: 0.85,
                    ),
                    itemBuilder: (context, index) {
                      final XFile file = _capturedPhotos[index];
                      final int selectedIndex = _selectedPhotosIndices.indexOf(index);
                      final bool isSelected = selectedIndex != -1;
                      
                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            if (isSelected) {
                              _selectedPhotosIndices.removeAt(selectedIndex);
                            } else {
                              if (_selectedPhotosIndices.length < 3) {
                                _selectedPhotosIndices.add(index);
                              }
                            }
                          });
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isSelected ? Colors.white : Colors.white24,
                              width: isSelected ? 3 : 1,
                            ),
                          ),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              // Image
                              ClipRRect(
                                borderRadius: BorderRadius.circular(13),
                                child: file.path.isNotEmpty
                                    ? Transform.scale(
                                        scaleX: -1,
                                        child: Image.file(
                                          File(file.path),
                                          fit: BoxFit.cover,
                                        ),
                                      )
                                    : const Center(child: Icon(Icons.broken_image, color: Colors.white24)),
                              ),
                              
                              // Dark overlay for unselected when 3 are already selected
                              if (!isSelected && _selectedPhotosIndices.length == 3)
                                Container(
                                  decoration: BoxDecoration(
                                    color: Colors.black54,
                                    borderRadius: BorderRadius.circular(13),
                                  ),
                                ),
                              
                              // Selection Badge Overlay
                              if (isSelected)
                                Positioned(
                                  top: 12,
                                  right: 12,
                                  child: Container(
                                    width: 32,
                                    height: 32,
                                    decoration: const BoxDecoration(
                                      color: Colors.white,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Center(
                                      child: Text(
                                        '${selectedIndex + 1}',
                                        style: const TextStyle(
                                          color: Colors.black,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              
                              // Visual position label
                              if (isSelected)
                                Positioned(
                                  bottom: 12,
                                  left: 12,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withAlpha(200),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      selectedIndex == 0
                                          ? 'ATAS'
                                          : selectedIndex == 1
                                              ? 'TENGAH'
                                              : 'BAWAH',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
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
                const Divider(color: Colors.white24, height: 24),
                const Text(
                  'PILIH TEMPLATE BINGKAI',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 1),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 100,
                  child: _isLoadingTemplates
                      ? const Center(child: CircularProgressIndicator(color: Colors.white))
                      : ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: _templatesList.length + 1, // +1 for "No Template" option
                          itemBuilder: (context, index) {
                            final bool isNoTemplate = index == 0;
                            final template = isNoTemplate ? null : _templatesList[index - 1];
                            final bool isSelected = isNoTemplate
                                ? _selectedTemplate == null
                                : _selectedTemplate != null && _selectedTemplate!['id_template'] == template!['id_template'];

                            return GestureDetector(
                              onTap: () {
                                setState(() {
                                  _selectedTemplate = template;
                                });
                              },
                              child: Container(
                                width: 80,
                                margin: const EdgeInsets.only(right: 12),
                                decoration: BoxDecoration(
                                  color: Colors.black,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: isSelected ? Colors.white : Colors.white24,
                                    width: isSelected ? 2 : 1,
                                  ),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: isNoTemplate
                                      ? Center(
                                          child: Column(
                                            mainAxisAlignment: MainAxisAlignment.center,
                                            children: const [
                                              Icon(Icons.block, color: Colors.white54, size: 24),
                                              SizedBox(height: 4),
                                              Text(
                                                'Tanpa Bingkai',
                                                style: TextStyle(color: Colors.white54, fontSize: 9),
                                                textAlign: TextAlign.center,
                                              ),
                                            ],
                                          ),
                                        )
                                      : Stack(
                                          fit: StackFit.expand,
                                          children: [
                                            Image.memory(
                                              template!['image_data'] as Uint8List,
                                              fit: BoxFit.contain,
                                            ),
                                            Positioned(
                                              bottom: 0,
                                              left: 0,
                                              right: 0,
                                              child: Container(
                                                color: Colors.black87,
                                                padding: const EdgeInsets.symmetric(vertical: 2),
                                                child: Text(
                                                  template['name'] as String,
                                                  style: const TextStyle(color: Colors.white, fontSize: 8),
                                                  textAlign: TextAlign.center,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
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
        const SizedBox(width: 28),

        // Right Column: Layout Preview & Print Button
        Expanded(
          flex: 2,
          child: Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: const Color(0xFF161616),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'PREVIEW CETAK A6',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 1),
                ),
                const SizedBox(height: 16),

                // Simulated portrait A6 vertical strip (1:1 aspect ratio layout)
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: _selectedTemplate != null
                        ? Center(
                            child: AspectRatio(
                              aspectRatio: 11.5 / 14.7,
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  return _buildCompositePreview(constraints.maxWidth, constraints.maxHeight);
                                },
                              ),
                            ),
                          )
                        : Column(
                            children: [
                              for (int i = 0; i < 3; i++)
                                Expanded(
                                  child: Container(
                                    margin: EdgeInsets.only(bottom: i < 2 ? 8 : 0),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF0F0F0F),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: Colors.white10),
                                    ),
                                    child: _selectedPhotosIndices.length > i
                                        ? ClipRRect(
                                            borderRadius: BorderRadius.circular(7),
                                            child: Transform.scale(
                                              scaleX: -1,
                                              child: Image.file(
                                                File(_capturedPhotos[_selectedPhotosIndices[i]].path),
                                                fit: BoxFit.cover,
                                                width: double.infinity,
                                              ),
                                            ),
                                          )
                                        : Center(
                                            child: Text(
                                              i == 0
                                                  ? 'Foto 1 (Atas)'
                                                  : i == 1
                                                      ? 'Foto 2 (Tengah)'
                                                      : 'Foto 3 (Bawah)',
                                              style: const TextStyle(color: Colors.white12, fontSize: 11),
                                            ),
                                          ),
                                  ),
                                )
                            ],
                          ),
                  ),
                ),

                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: _selectedPhotosIndices.length == 3 ? _triggerRealPrint : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    disabledBackgroundColor: Colors.white12,
                    disabledForegroundColor: Colors.white30,
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  icon: const Icon(Icons.print),
                  label: const Text(
                    'CETAK SEKARANG',
                    style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // TAHAP 4: Mencetak
  Widget _buildPrintingStage() {
    return Center(
      child: Container(
        width: 500,
        padding: const EdgeInsets.all(48),
        decoration: BoxDecoration(
          color: const Color(0xFF161616),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 60,
              height: 60,
              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 4),
            ),
            const SizedBox(height: 32),
            const Text(
              'SEDANG MENCETAK FOTO...',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 1),
            ),
            const SizedBox(height: 8),
            Text(
              'Mengirim layout A6 Portrait ke printer: ${widget.printer}',
              style: const TextStyle(fontSize: 12, color: Colors.white38),
            ),
          ],
        ),
      ),
    );
  }

  // TAHAP 5: Selesai
  Widget _buildDoneStage() {
    return Center(
      child: Container(
        width: 500,
        padding: const EdgeInsets.all(48),
        decoration: BoxDecoration(
          color: const Color(0xFF161616),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline, size: 80, color: Colors.white),
            const SizedBox(height: 24),
            const Text(
              'SESI FOTO SELESAI!',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 1),
            ),
            const SizedBox(height: 8),
            Text(
              'Silakan ambil hasil foto A6 Anda pada printer: ${widget.printer}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Colors.white54, height: 1.4),
            ),
            const SizedBox(height: 40),
            ElevatedButton(
              onPressed: _resetToStart,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('MULAI SESI BARU', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoTile(IconData icon, String title, String value) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(8),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 10, color: Colors.white38)),
                Text(
                  value,
                  style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildPrintCountOption(int count, String label) {
    final bool isSelected = _selectedPrintCount == count;
    return GestureDetector(
      onTap: () {
        if (_currentStage == 'PAYMENT') {
          setState(() {
            _selectedPrintCount = count;
            _updatePrice();
          });
          _generateQrisPayment();
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: isSelected ? Colors.white10 : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? Colors.white : Colors.white24,
            width: 1.5,
          ),
        ),
        child: Column(
          children: [
            Icon(
              isSelected ? Icons.check_circle : Icons.circle_outlined,
              color: isSelected ? Colors.white : Colors.white24,
              size: 20,
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.white54,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
