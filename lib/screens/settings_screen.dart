import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'session_screen.dart';
import 'welcome_screen.dart';
import '../mysql_helper.dart';
import '../payment_config.dart';

class SettingsScreen extends StatefulWidget {
  final Map<String, dynamic> user;

  const SettingsScreen({super.key, required this.user});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const Color kPrimaryRed = Color(0xFFD3242B);
  static const Color kDarkRed = Color(0xFF94151A);
  static const Color kSoftRedBg = Color(0xFFFFF5F5);
  static const Color kBorderRed = Color(0xFFF3C6C8);
  static const Color kTextDark = Color(0xFF1F1F1F);
  static const Color kTextMuted = Color(0xFF7A6869);

  CameraDescription? _selectedCameraDescription;
  String? _selectedPrinter;

  List<CameraDescription> _cameras = [];
  List<String> _printers = [];
  bool _isLoadingDevices = true;

  // Live preview inside settings
  CameraController? _previewController;
  bool _isCameraPreviewInitialized = false;
  bool _isCameraLoading = false;

  // Kalibrasi Posisi Cetak
  double _printOffsetX = 0.0; // mm
  double _printOffsetY = 0.0; // mm
  final TextEditingController _offsetXController = TextEditingController();
  final TextEditingController _offsetYController = TextEditingController();

  // Navigation & Template Settings State
  String _activeTab = 'dashboard'; // 'dashboard' or 'templates'
  List<Map<String, dynamic>> _userTemplates = [];
  bool _isLoadingTemplates = false;

  // Booth Users Assignment State
  List<Map<String, dynamic>> _boothUsersList = [];
  List<int> _selectedBoothIds = [];
  bool _isLoadingBoothUsers = false;

  // Template Editor State
  bool _isEditingTemplate = false;
  int? _editingTemplateId;
  String _templateNameInput = '';
  Uint8List? _uploadedPngBytes;
  String _uploadedPngFileName = '';
  String _templateMode = '4r'; // '4r', 'strip', or 'strip_semi_4r'

  // Slot coordinates (normalized 0.0 to 1.0)
  // Sisi Kiri (Foto 1, 2, 3)
  double _s1x = 0.1, _s1y = 0.1, _s1w = 0.8, _s1h = 0.23;
  double _s2x = 0.1, _s2y = 0.38, _s2w = 0.8, _s2h = 0.23;
  double _s3x = 0.1, _s3y = 0.66, _s3w = 0.8, _s3h = 0.23;
  // Sisi Kanan (Foto 1, 2, 3 Kanan pada mode Strip Semi 4R - dapat diposisikan manual)
  double _s4x = 0.55, _s4y = 0.1, _s4w = 0.4, _s4h = 0.23;
  double _s5x = 0.55, _s5y = 0.38, _s5w = 0.4, _s5h = 0.23;
  double _s6x = 0.55, _s6y = 0.66, _s6w = 0.4, _s6h = 0.23;

  final TextEditingController _templateNameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadCalibrationSettings();
    _loadSystemDevices();
    final role = widget.user['role'] as String;
    if (role == 'admin') {
      _activeTab = 'templates';
    } else {
      _activeTab = 'dashboard';
    }
    _loadTemplatesFromDb();
    _loadBoothUsers();
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
          _offsetXController.text = _printOffsetX.toStringAsFixed(1);
          _offsetYController.text = _printOffsetY.toStringAsFixed(1);
        });
      } else {
        _offsetXController.text = '0.0';
        _offsetYController.text = '0.0';
      }
    } catch (e) {
      debugPrint('Error loading calibration: $e');
    }
  }

  Future<void> _saveCalibrationSettings() async {
    try {
      final file = File('print_calibration.json');
      final data = {
        'offsetX': _printOffsetX,
        'offsetY': _printOffsetY,
      };
      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      debugPrint('Error saving calibration: $e');
    }
  }

  Future<void> _loadTemplatesFromDb() async {
    setState(() {
      _isLoadingTemplates = true;
    });
    try {
      final userId = widget.user['id_user'] as int;
      final role = widget.user['role'] as String;
      final templates = await MySqlHelper.getTemplatesForUser(userId, role);
      setState(() {
        _userTemplates = templates;
      });
    } catch (e) {
      debugPrint('Error loading templates: $e');
    } finally {
      setState(() {
        _isLoadingTemplates = false;
      });
    }
  }

  Future<void> _loadBoothUsers() async {
    setState(() {
      _isLoadingBoothUsers = true;
    });
    try {
      final list = await MySqlHelper.getBoothUsers();
      setState(() {
        _boothUsersList = list;
      });
    } catch (e) {
      debugPrint('Error loading booth users: $e');
    } finally {
      setState(() {
        _isLoadingBoothUsers = false;
      });
    }
  }

  Future<void> _pickTemplateFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['png'],
      );
      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final bytes = await file.readAsBytes();

        // Auto-detect mode jika rasio gambar mendekati strip (51mm x 152mm = rasio ~0.335)
        try {
          final decoded = img.decodeImage(bytes);
          if (decoded != null && decoded.height > 0) {
            final ratio = decoded.width / decoded.height;
            if (ratio < 0.50) {
              setState(() {
                _templateMode = 'strip';
              });
            } else if (_templateMode == 'strip') {
              setState(() {
                _templateMode = '4r';
              });
            }
          }
        } catch (_) {}

        if (!mounted) return;
        final croppedBytes = await showDialog<Uint8List>(
          context: context,
          barrierDismissible: false,
          builder: (context) => ImageCropDialog(
            imageBytes: bytes,
            templateMode: _templateMode,
          ),
        );

        if (croppedBytes != null) {
          setState(() {
            _uploadedPngBytes = croppedBytes;
            _uploadedPngFileName = result.files.single.name;
          });
        }
      }
    } catch (e) {
      debugPrint('Error picking file: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal memilih file: $e'), backgroundColor: kPrimaryRed),
      );
    }
  }

  Future<void> _saveTemplateToDb() async {
    if (_templateNameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nama template tidak boleh kosong!'), backgroundColor: kPrimaryRed),
      );
      return;
    }
    if (_uploadedPngBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Anda harus mengupload gambar template PNG!'), backgroundColor: kPrimaryRed),
      );
      return;
    }
    if (_selectedBoothIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pilih minimal satu booth user untuk template ini!'), backgroundColor: kPrimaryRed),
      );
      return;
    }

    try {
      final userId = widget.user['id_user'] as int;
      await MySqlHelper.saveTemplate(
        idUser: userId,
        name: _templateNameController.text.trim(),
        imageData: _uploadedPngBytes!,
        templateMode: _templateMode,
        slot1X: _s1x, slot1Y: _s1y, slot1W: _s1w, slot1H: _s1h,
        slot2X: _s2x, slot2Y: _s2y, slot2W: _s2w, slot2H: _s2h,
        slot3X: _s3x, slot3Y: _s3y, slot3W: _s3w, slot3H: _s3h,
        slot4X: _s4x, slot4Y: _s4y, slot4W: _s4w, slot4H: _s4h,
        slot5X: _s5x, slot5Y: _s5y, slot5W: _s5w, slot5H: _s5h,
        slot6X: _s6x, slot6Y: _s6y, slot6W: _s6w, slot6H: _s6h,
        assignedBoothIds: _selectedBoothIds,
      );

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Template berhasil disimpan!'), backgroundColor: Colors.green),
      );

      setState(() {
        _isEditingTemplate = false;
        _uploadedPngBytes = null;
        _uploadedPngFileName = '';
        _templateNameController.clear();
        _selectedBoothIds.clear();
      });

      _loadTemplatesFromDb();
    } catch (e) {
      debugPrint('Error saving template: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal menyimpan template: $e'), backgroundColor: kPrimaryRed),
      );
    }
  }

  Future<void> _deleteTemplateFromDb(int idTemplate) async {
    try {
      await MySqlHelper.deleteTemplate(idTemplate);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Template berhasil dihapus!'), backgroundColor: Colors.green),
      );
      _loadTemplatesFromDb();
    } catch (e) {
      debugPrint('Error deleting template: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal menghapus template: $e'), backgroundColor: kPrimaryRed),
      );
    }
  }

  void _startNewTemplate() {
    setState(() {
      _isEditingTemplate = true;
      _editingTemplateId = null;
      _templateMode = '4r';
      _templateNameController.clear();
      _uploadedPngBytes = null;
      _uploadedPngFileName = '';
      _selectedBoothIds.clear();

      // Reset slots ke default
      _s1x = 0.1; _s1y = 0.08; _s1w = 0.8; _s1h = 0.25;
      _s2x = 0.1; _s2y = 0.36; _s2w = 0.8; _s2h = 0.25;
      _s3x = 0.1; _s3y = 0.64; _s3w = 0.8; _s3h = 0.25;
      _s4x = 0.55; _s4y = 0.08; _s4w = 0.40; _s4h = 0.25;
      _s5x = 0.55; _s5y = 0.36; _s5w = 0.40; _s5h = 0.25;
      _s6x = 0.55; _s6y = 0.64; _s6w = 0.40; _s6h = 0.25;
    });
  }

  void _cancelEditingTemplate() {
    setState(() {
      _isEditingTemplate = false;
      _uploadedPngBytes = null;
      _uploadedPngFileName = '';
      _templateNameController.clear();
      _selectedBoothIds.clear();
    });
  }

  int _cameraSessionId = 0;

  Future<void> _loadSystemDevices() async {
    setState(() {
      _isLoadingDevices = true;
      _isCameraPreviewInitialized = false;
    });

    List<String> detectedPrinters = [];
    List<CameraDescription> detectedCameras = [];

    try {
      final printerResult = await Process.run('powershell', [
        '-Command',
        'Get-Printer | Select-Object -ExpandProperty Name'
      ]);
      if (printerResult.exitCode == 0) {
        detectedPrinters = printerResult.stdout
            .toString()
            .split('\n')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
      }
    } catch (e) {
      debugPrint('Error loading printers: $e');
    }

    try {
      detectedCameras = await availableCameras();
    } catch (e) {
      debugPrint('Error loading cameras: $e');
    }

    if (detectedPrinters.isEmpty) {
      detectedPrinters = ['Printer Default (Simulasi)', 'Microsoft Print to PDF'];
    }

    if (!mounted) return;

    setState(() {
      _printers = detectedPrinters;
      _selectedPrinter = _printers.first;
      _cameras = detectedCameras;
      _isLoadingDevices = false;
    });

    CameraDescription? cameraToSelect;
    if (_selectedCameraDescription != null && _cameras.isNotEmpty) {
      final exists = _cameras.any((c) => c.name == _selectedCameraDescription!.name);
      if (exists) {
        cameraToSelect = _cameras.firstWhere((c) => c.name == _selectedCameraDescription!.name);
      }
    }
    cameraToSelect ??= _cameras.isNotEmpty ? _cameras.first : null;

    if (cameraToSelect != null) {
      _onCameraSelected(cameraToSelect);
    }
  }

  Future<void> _onCameraSelected(CameraDescription camera) async {
    final sessionId = ++_cameraSessionId;

    setState(() {
      _selectedCameraDescription = camera;
      _isCameraPreviewInitialized = false;
      _isCameraLoading = true;
    });

    if (_previewController != null) {
      final oldController = _previewController;
      _previewController = null;
      try {
        await oldController!.dispose();
      } catch (e) {
        debugPrint('Error disposing preview camera: $e');
      }
    }

    if (sessionId != _cameraSessionId) return;

    await Future.delayed(const Duration(milliseconds: 1500));
    if (sessionId != _cameraSessionId) return;

    final newController = CameraController(
      camera,
      ResolutionPreset.veryHigh,
      enableAudio: false,
    );

    if (sessionId != _cameraSessionId) {
      try {
        await newController.dispose();
      } catch (_) {}
      return;
    }

    _previewController = newController;

    int retryCount = 0;
    bool success = false;
    while (retryCount < 5 && !success && sessionId == _cameraSessionId) {
      try {
        await newController.initialize();
        if (sessionId == _cameraSessionId) {
          success = true;
        }
      } catch (e) {
        debugPrint('Camera initialization failed with exception (attempt ${retryCount + 1}): $e');
        if (sessionId != _cameraSessionId) {
          break;
        }
        retryCount++;
        await Future.delayed(const Duration(milliseconds: 1000));
      }
    }

    if (sessionId != _cameraSessionId) {
      try {
        await newController.dispose();
      } catch (_) {}
      return;
    }

    if (mounted && _previewController == newController) {
      setState(() {
        _isCameraLoading = false;
        if (success) {
          _isCameraPreviewInitialized = true;
        } else {
          _previewController = null;
          try {
            newController.dispose();
          } catch (_) {}
        }
      });
    }
  }

  void _startSession() {
    if (_selectedCameraDescription != null && _selectedPrinter != null) {
      final sessionId = ++_cameraSessionId;

      final Future<void> disposeFuture = _previewController?.dispose() ?? Future.value();
      _previewController = null;
      _isCameraPreviewInitialized = false;

      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      windowManager.setFullScreen(true);

      disposeFuture.then((_) {
        if (mounted && sessionId == _cameraSessionId) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => SessionScreen(
                user: widget.user,
                camera: _selectedCameraDescription!,
                printer: _selectedPrinter!,
              ),
            ),
          ).then((_) {
            SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
            windowManager.setFullScreen(false);
            _loadSystemDevices();
          });
        }
      });
    }
  }

  void _logout() {
    _previewController?.dispose();
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const WelcomeScreen()),
      (route) => false,
    );
  }

  @override
  void dispose() {
    _previewController?.dispose();
    _offsetXController.dispose();
    _offsetYController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final username = widget.user['username'] ?? 'User';
    final role = widget.user['role'] ?? 'booth';
    final alamat = widget.user['alamat_photobox'] ?? 'Tidak ada alamat';

    return Scaffold(
      backgroundColor: const Color(0xFFFFFDFC),
      body: Row(
        children: [
          // SIDEBAR (Informasi Akun - White & Red Theme)
          Material(
            color: kSoftRedBg,
            child: Container(
              width: 300,
              decoration: const BoxDecoration(
                border: Border(right: BorderSide(color: kPrimaryRed, width: 2.5)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Center(
                    child: PixyboxOvalLogo(
                      width: 210,
                      height: 76,
                      fontSize: 24,
                    ),
                  ),
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: kPrimaryRed,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: kPrimaryRed.withAlpha(60),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: const Icon(Icons.admin_panel_settings, size: 26, color: Colors.white),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              username.toUpperCase(),
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w900,
                                color: kPrimaryRed,
                              ),
                            ),
                            Text(
                              'ROLE: ${role.toUpperCase()}',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: kTextMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  const Divider(color: kBorderRed, thickness: 1.5),
                  const SizedBox(height: 20),
                  const Text(
                    'LOKASI UNIT PHOTOBOX',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      color: kPrimaryRed,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.location_on_outlined, size: 16, color: kPrimaryRed),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          alamat,
                          style: const TextStyle(fontSize: 13, color: kTextDark, height: 1.4, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  const Divider(color: kBorderRed, thickness: 1.5),
                  const SizedBox(height: 20),
                  const Text(
                    'MENU NAVIGASI',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      color: kPrimaryRed,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (role != 'admin')
                    Container(
                      decoration: BoxDecoration(
                        color: _activeTab == 'dashboard' ? kPrimaryRed : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _activeTab == 'dashboard' ? kPrimaryRed : kBorderRed,
                        ),
                      ),
                      child: ListTile(
                        dense: true,
                        leading: Icon(
                          Icons.tune,
                          color: _activeTab == 'dashboard' ? Colors.white : kPrimaryRed,
                        ),
                        title: Text(
                          'SETUP PERANGKAT',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                            color: _activeTab == 'dashboard' ? Colors.white : kPrimaryRed,
                          ),
                        ),
                        onTap: () {
                          setState(() {
                            _activeTab = 'dashboard';
                          });
                        },
                      ),
                    ),
                  if (role == 'admin')
                    Container(
                      decoration: BoxDecoration(
                        color: _activeTab == 'templates' ? kPrimaryRed : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _activeTab == 'templates' ? kPrimaryRed : kBorderRed,
                        ),
                      ),
                      child: ListTile(
                        dense: true,
                        leading: Icon(
                          Icons.layers,
                          color: _activeTab == 'templates' ? Colors.white : kPrimaryRed,
                        ),
                        title: Text(
                          'KELOLA TEMPLATE',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                            color: _activeTab == 'templates' ? Colors.white : kPrimaryRed,
                          ),
                        ),
                        onTap: () {
                          setState(() {
                            _activeTab = 'templates';
                          });
                          _loadTemplatesFromDb();
                        },
                      ),
                    ),
                  const Spacer(),
                  ElevatedButton.icon(
                    onPressed: _logout,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: kPrimaryRed,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: const BorderSide(color: kPrimaryRed, width: 1.5),
                      ),
                    ),
                    icon: const Icon(Icons.logout, size: 18),
                    label: const SizedBox(
                      width: double.infinity,
                      child: Text(
                        'KELUAR (LOGOUT)',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // MAIN PANEL (Dashboard or Templates)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(40.0),
              child: _activeTab == 'dashboard'
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'DASHBOARD UTAMA',
                                  style: TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.w900,
                                    color: kPrimaryRed,
                                    letterSpacing: 1,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Status Sistem: ${_isLoadingDevices ? "Mendeteksi Perangkat..." : "Online & Siap"}',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: kTextMuted,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            Container(
                              decoration: BoxDecoration(
                                color: kSoftRedBg,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: kBorderRed),
                              ),
                              child: IconButton(
                                onPressed: _loadSystemDevices,
                                icon: const Icon(Icons.refresh, color: kPrimaryRed),
                                tooltip: 'Pindai Ulang Perangkat',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),

                        // Card Payment Gateway Switcher
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                          margin: const EdgeInsets.only(bottom: 24),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: kPrimaryRed.withAlpha(110), width: 1.5),
                            boxShadow: [
                              BoxShadow(
                                color: kPrimaryRed.withAlpha(18),
                                blurRadius: 14,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: kSoftRedBg,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: kBorderRed),
                                ),
                                child: const Icon(Icons.qr_code_scanner, color: kPrimaryRed, size: 22),
                              ),
                              const SizedBox(width: 16),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Text(
                                        'PAYMENT GATEWAY (QRIS)',
                                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: kPrimaryRed, letterSpacing: 0.5),
                                      ),
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: kSoftRedBg,
                                          borderRadius: BorderRadius.circular(6),
                                          border: Border.all(
                                            color: kPrimaryRed,
                                            width: 1,
                                          ),
                                        ),
                                        child: Text(
                                          PaymentConfig.activeGateway == PaymentGateway.doku ? 'DOKU (PROD)' : 'MIDTRANS (SANDBOX)',
                                          style: const TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            color: kPrimaryRed,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  const Text(
                                    'Pilih penyedia QRIS yang aktif untuk melayani pembayaran sesi booth',
                                    style: TextStyle(fontSize: 11, color: kTextMuted),
                                  ),
                                ],
                              ),
                              const Spacer(),
                              Container(
                                decoration: BoxDecoration(
                                  color: kSoftRedBg,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: kBorderRed),
                                ),
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                                child: Row(
                                  children: [
                                    InkWell(
                                      onTap: () {
                                        setState(() {
                                          PaymentConfig.saveConfig(PaymentGateway.doku);
                                        });
                                      },
                                      borderRadius: BorderRadius.circular(8),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                        decoration: BoxDecoration(
                                          color: PaymentConfig.activeGateway == PaymentGateway.doku ? kPrimaryRed : Colors.transparent,
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          'DOKU',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                            color: PaymentConfig.activeGateway == PaymentGateway.doku ? Colors.white : kPrimaryRed,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    InkWell(
                                      onTap: () {
                                        setState(() {
                                          PaymentConfig.saveConfig(PaymentGateway.midtrans);
                                        });
                                      },
                                      borderRadius: BorderRadius.circular(8),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                        decoration: BoxDecoration(
                                          color: PaymentConfig.activeGateway == PaymentGateway.midtrans ? kPrimaryRed : Colors.transparent,
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          'MIDTRANS',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                            color: PaymentConfig.activeGateway == PaymentGateway.midtrans ? Colors.white : kPrimaryRed,
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

                        if (_isLoadingDevices)
                          const Expanded(
                            child: Center(
                              child: CircularProgressIndicator(color: kPrimaryRed),
                            ),
                          )
                        else
                          Expanded(
                            child: GridView.count(
                              crossAxisCount: 2,
                              crossAxisSpacing: 24,
                              mainAxisSpacing: 24,
                              childAspectRatio: 0.65,
                              children: [
                                // Card Setting Kamera
                                Container(
                                  padding: const EdgeInsets.all(24),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(color: kPrimaryRed.withAlpha(110), width: 1.5),
                                    boxShadow: [
                                      BoxShadow(
                                        color: kPrimaryRed.withAlpha(18),
                                        blurRadius: 16,
                                        offset: const Offset(0, 6),
                                      ),
                                    ],
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Row(
                                        children: [
                                          Icon(Icons.camera_alt, color: kPrimaryRed, size: 24),
                                          SizedBox(width: 12),
                                          Text(
                                            'KAMERA UTAMA',
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w900,
                                              color: kPrimaryRed,
                                              letterSpacing: 1,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 16),
                                      const Text(
                                        'Pilih Input Kamera Aktif:',
                                        style: TextStyle(fontSize: 12, color: kTextMuted, fontWeight: FontWeight.w600),
                                      ),
                                      const SizedBox(height: 8),
                                      DropdownButtonFormField<CameraDescription>(
                                        isExpanded: true,
                                        dropdownColor: Colors.white,
                                        value: _selectedCameraDescription,
                                        style: const TextStyle(color: kTextDark, fontSize: 13, fontWeight: FontWeight.w600),
                                        decoration: InputDecoration(
                                          filled: true,
                                          fillColor: kSoftRedBg,
                                          enabledBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(12),
                                            borderSide: const BorderSide(color: kBorderRed, width: 1.5),
                                          ),
                                          focusedBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(12),
                                            borderSide: const BorderSide(color: kPrimaryRed, width: 2),
                                          ),
                                        ),
                                        items: _cameras.map((camera) {
                                          return DropdownMenuItem(
                                            value: camera,
                                            child: Text(camera.name.isNotEmpty ? camera.name : 'Camera Device', overflow: TextOverflow.ellipsis),
                                          );
                                        }).toList(),
                                        onChanged: (val) {
                                          if (val != null) {
                                            _onCameraSelected(val);
                                          }
                                        },
                                      ),
                                      const SizedBox(height: 20),
                                      // Real Live Preview inside Settings Screen
                                      Expanded(
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: kSoftRedBg,
                                            borderRadius: BorderRadius.circular(12),
                                            border: Border.all(color: kBorderRed, width: 1.5),
                                          ),
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(11),
                                            child: _isCameraLoading
                                                ? const Center(
                                                    child: Column(
                                                      mainAxisAlignment: MainAxisAlignment.center,
                                                      children: [
                                                        SizedBox(
                                                          width: 30,
                                                          height: 30,
                                                          child: CircularProgressIndicator(color: kPrimaryRed, strokeWidth: 2.5),
                                                        ),
                                                        SizedBox(height: 16),
                                                        Text(
                                                          'Menghubungkan ke Kamera...',
                                                          style: TextStyle(color: kPrimaryRed, fontSize: 12, fontWeight: FontWeight.w600),
                                                        )
                                                      ],
                                                    ),
                                                  )
                                                : (_isCameraPreviewInitialized && _previewController != null
                                                    ? CameraPreview(_previewController!)
                                                    : Center(
                                                        child: Column(
                                                          mainAxisAlignment: MainAxisAlignment.center,
                                                          children: [
                                                            Icon(Icons.videocam_off, color: kPrimaryRed.withAlpha(110), size: 36),
                                                            const SizedBox(height: 8),
                                                            Text(
                                                              'Preview Tidak Aktif',
                                                              style: TextStyle(color: kPrimaryRed.withAlpha(150), fontSize: 11, fontWeight: FontWeight.w600),
                                                            )
                                                          ],
                                                        ),
                                                      )),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                // Card Setting Printer
                                Container(
                                  padding: const EdgeInsets.all(24),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(color: kPrimaryRed.withAlpha(110), width: 1.5),
                                    boxShadow: [
                                      BoxShadow(
                                        color: kPrimaryRed.withAlpha(18),
                                        blurRadius: 16,
                                        offset: const Offset(0, 6),
                                      ),
                                    ],
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Row(
                                        children: [
                                          Icon(Icons.print, color: kPrimaryRed, size: 24),
                                          SizedBox(width: 12),
                                          Text(
                                            'PRINTER UTAMA',
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w900,
                                              color: kPrimaryRed,
                                              letterSpacing: 1,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 16),
                                      const Text(
                                        'Pilih Printer Cetak Foto:',
                                        style: TextStyle(fontSize: 12, color: kTextMuted, fontWeight: FontWeight.w600),
                                      ),
                                      const SizedBox(height: 8),
                                      DropdownButtonFormField<String>(
                                        isExpanded: true,
                                        dropdownColor: Colors.white,
                                        value: _selectedPrinter,
                                        style: const TextStyle(color: kTextDark, fontSize: 13, fontWeight: FontWeight.w600),
                                        decoration: InputDecoration(
                                          filled: true,
                                          fillColor: kSoftRedBg,
                                          enabledBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(12),
                                            borderSide: const BorderSide(color: kBorderRed, width: 1.5),
                                          ),
                                          focusedBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(12),
                                            borderSide: const BorderSide(color: kPrimaryRed, width: 2),
                                          ),
                                        ),
                                        items: _printers.map((printer) {
                                          return DropdownMenuItem(
                                            value: printer,
                                            child: Text(printer, overflow: TextOverflow.ellipsis),
                                          );
                                        }).toList(),
                                        onChanged: (val) {
                                          setState(() {
                                            _selectedPrinter = val;
                                          });
                                        },
                                      ),
                                      const SizedBox(height: 20),
                                      const Divider(color: kBorderRed, thickness: 1.5),
                                      const SizedBox(height: 12),
                                      const Row(
                                        children: [
                                          Icon(Icons.tune, color: kPrimaryRed, size: 20),
                                          SizedBox(width: 8),
                                          Text(
                                            'KALIBRASI POSISI CETAK',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w900,
                                              color: kPrimaryRed,
                                              letterSpacing: 1,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                const Text(
                                                  'Horizontal (X) mm',
                                                  style: TextStyle(fontSize: 11, color: kTextMuted, fontWeight: FontWeight.w600),
                                                ),
                                                const SizedBox(height: 6),
                                                TextField(
                                                  controller: _offsetXController,
                                                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                                                  style: const TextStyle(color: kTextDark, fontSize: 13, fontWeight: FontWeight.bold),
                                                  decoration: InputDecoration(
                                                    filled: true,
                                                    fillColor: kSoftRedBg,
                                                    isDense: true,
                                                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                                    enabledBorder: OutlineInputBorder(
                                                      borderRadius: BorderRadius.circular(8),
                                                      borderSide: const BorderSide(color: kBorderRed, width: 1.5),
                                                    ),
                                                    focusedBorder: OutlineInputBorder(
                                                      borderRadius: BorderRadius.circular(8),
                                                      borderSide: const BorderSide(color: kPrimaryRed, width: 2),
                                                    ),
                                                  ),
                                                  onChanged: (val) {
                                                    final d = double.tryParse(val) ?? 0.0;
                                                    _printOffsetX = d;
                                                    _saveCalibrationSettings();
                                                  },
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 16),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                const Text(
                                                  'Vertikal (Y) mm',
                                                  style: TextStyle(fontSize: 11, color: kTextMuted, fontWeight: FontWeight.w600),
                                                ),
                                                const SizedBox(height: 6),
                                                TextField(
                                                  controller: _offsetYController,
                                                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                                                  style: const TextStyle(color: kTextDark, fontSize: 13, fontWeight: FontWeight.bold),
                                                  decoration: InputDecoration(
                                                    filled: true,
                                                    fillColor: kSoftRedBg,
                                                    isDense: true,
                                                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                                    enabledBorder: OutlineInputBorder(
                                                      borderRadius: BorderRadius.circular(8),
                                                      borderSide: const BorderSide(color: kBorderRed, width: 1.5),
                                                    ),
                                                    focusedBorder: OutlineInputBorder(
                                                      borderRadius: BorderRadius.circular(8),
                                                      borderSide: const BorderSide(color: kPrimaryRed, width: 2),
                                                    ),
                                                  ),
                                                  onChanged: (val) {
                                                    final d = double.tryParse(val) ?? 0.0;
                                                    _printOffsetY = d;
                                                    _saveCalibrationSettings();
                                                  },
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      const Text(
                                        '* Nilai (+) geser Kanan/Bawah, (-) geser Kiri/Atas.',
                                        style: TextStyle(fontSize: 10, color: kTextMuted, fontStyle: FontStyle.italic),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),

                        if (!_isLoadingDevices && role != 'admin')
                          Container(
                            width: double.infinity,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(32),
                              boxShadow: const [
                                BoxShadow(
                                  color: kDarkRed,
                                  offset: Offset(0, 5),
                                  blurRadius: 0,
                                ),
                              ],
                            ),
                            child: ElevatedButton.icon(
                              onPressed: _startSession,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: kPrimaryRed,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 22),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(32),
                                ),
                                elevation: 0,
                              ),
                              icon: const Icon(Icons.play_circle_fill, size: 28),
                              label: const Text(
                                'MULAI SESI PHOTOBOX',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 2,
                                ),
                              ),
                            ),
                          ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Templates Panel Header
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _isEditingTemplate ? 'EDITOR TEMPLATE FOTO' : 'KELOLA TEMPLATE OVERLAY',
                                  style: const TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.w900,
                                    color: kPrimaryRed,
                                    letterSpacing: 1,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _isEditingTemplate
                                      ? 'Geser dan atur letak 3 foto pada template PNG transparan'
                                      : 'Daftar template cetak bingkai photobox Anda',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: kTextMuted,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 32),
                        _isEditingTemplate ? _buildTemplateDesigner() : _buildTemplatesList(),
                      ],
                    ),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildTemplatesList() {
    return Expanded(
      child: _isLoadingTemplates
          ? const Center(child: CircularProgressIndicator(color: kPrimaryRed))
          : (_userTemplates.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.layers_clear_outlined, size: 70, color: kPrimaryRed.withAlpha(100)),
                      const SizedBox(height: 16),
                      const Text(
                        'Belum ada template terdaftar.',
                        style: TextStyle(color: kTextMuted, fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: _startNewTemplate,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: kPrimaryRed,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                        ),
                        icon: const Icon(Icons.add),
                        label: const Text('BUAT TEMPLATE BARU', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        ElevatedButton.icon(
                          onPressed: _startNewTemplate,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: kPrimaryRed,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                          ),
                          icon: const Icon(Icons.add),
                          label: const Text('BUAT TEMPLATE', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Expanded(
                      child: GridView.builder(
                        itemCount: _userTemplates.length,
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          crossAxisSpacing: 20,
                          mainAxisSpacing: 20,
                          childAspectRatio: 0.7,
                        ),
                        itemBuilder: (context, index) {
                          final template = _userTemplates[index];
                          final id = template['id_template'] as int;
                          final name = template['name'] as String;
                          final bytes = template['image_data'] as Uint8List;

                          return Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: kBorderRed, width: 1.5),
                              boxShadow: [
                                BoxShadow(
                                  color: kPrimaryRed.withAlpha(15),
                                  blurRadius: 12,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  child: Container(
                                    decoration: const BoxDecoration(
                                      color: kSoftRedBg,
                                      borderRadius: BorderRadius.vertical(top: Radius.circular(15)),
                                    ),
                                    child: ClipRRect(
                                      borderRadius: const BorderRadius.vertical(top: Radius.circular(14.5)),
                                      child: Image.memory(bytes, fit: BoxFit.contain),
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.all(16.0),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              name,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                                color: kTextDark,
                                                fontSize: 13,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: kSoftRedBg,
                                              borderRadius: BorderRadius.circular(4),
                                              border: Border.all(
                                                color: kPrimaryRed,
                                                width: 0.8,
                                              ),
                                            ),
                                            child: Text(
                                              (template['template_mode'] == 'strip')
                                                  ? 'STRIP (2X)'
                                                  : ((template['template_mode'] == 'strip_semi_4r')
                                                      ? 'SEMI 4R'
                                                      : '4R'),
                                              style: const TextStyle(
                                                color: kPrimaryRed,
                                                fontSize: 9,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      FutureBuilder<List<int>>(
                                        future: MySqlHelper.getTemplateAssignments(id),
                                        builder: (context, snapshot) {
                                          if (snapshot.connectionState == ConnectionState.waiting) {
                                            return const SizedBox(
                                              height: 12,
                                              child: LinearProgressIndicator(color: kPrimaryRed, backgroundColor: Colors.transparent),
                                            );
                                          }
                                          final assignedIds = snapshot.data ?? [];
                                          final names = assignedIds.map((bid) {
                                            final match = _boothUsersList.firstWhere(
                                              (b) => b['id_user'] == bid,
                                              orElse: () => {'username': '?'},
                                            );
                                            return match['username'] as String;
                                          }).join(', ');

                                          return Text(
                                            'Booths: ${names.isEmpty ? "Tidak ada" : names}',
                                            style: const TextStyle(fontSize: 10, color: kTextMuted),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          );
                                        },
                                      ),
                                      const SizedBox(height: 12),
                                      SizedBox(
                                        width: double.infinity,
                                        child: ElevatedButton.icon(
                                          onPressed: () => _deleteTemplateFromDb(id),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: kSoftRedBg,
                                            foregroundColor: kPrimaryRed,
                                            elevation: 0,
                                            padding: const EdgeInsets.symmetric(vertical: 10),
                                            shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(8),
                                              side: const BorderSide(color: kPrimaryRed, width: 1),
                                            ),
                                          ),
                                          icon: const Icon(Icons.delete_outline, size: 16),
                                          label: const Text('HAPUS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                )),
    );
  }

  Widget _buildTemplateDesigner() {
    final bool isStripMode = _templateMode == 'strip';
    final bool isStripSemi4R = _templateMode == 'strip_semi_4r';
    const double designerHeight = 500.0;
    double designerWidth;

    if (_uploadedPngBytes != null) {
      try {
        final decoded = img.decodeImage(_uploadedPngBytes!);
        if (decoded != null && decoded.height > 0) {
          designerWidth = designerHeight * (decoded.width / decoded.height);
        } else {
          designerWidth = isStripMode ? designerHeight * (51.0 / 152.0) : designerHeight * (102.0 / 152.0);
        }
      } catch (_) {
        designerWidth = isStripMode ? designerHeight * (51.0 / 152.0) : designerHeight * (102.0 / 152.0);
      }
    } else {
      designerWidth = isStripMode ? designerHeight * (51.0 / 152.0) : designerHeight * (102.0 / 152.0);
    }

    return Expanded(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Sisi Kiri: Kanvas Visual Interaktif
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: kSoftRedBg,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: kPrimaryRed),
                    ),
                    child: Text(
                      isStripMode
                          ? 'KANVAS STRIP (51 mm x 152 mm / Setengah 4R)'
                          : (isStripSemi4R
                              ? 'KANVAS STRIP SEMI 4R (102 mm x 152 mm / 6 Foto)'
                              : 'KANVAS 4R FULL (102 mm x 152 mm)'),
                      style: const TextStyle(
                        color: kPrimaryRed,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (isStripSemi4R) ...[
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: () {
                        setState(() {
                          _s4x = (_s1x + 0.5).clamp(0.5, 0.95);
                          _s4y = _s1y;
                          _s4w = _s1w;
                          _s4h = _s1h;
                          _s5x = (_s2x + 0.5).clamp(0.5, 0.95);
                          _s5y = _s2y;
                          _s5w = _s2w;
                          _s5h = _s2h;
                          _s6x = (_s3x + 0.5).clamp(0.5, 0.95);
                          _s6y = _s3y;
                          _s6w = _s3w;
                          _s6h = _s3h;
                        });
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Posisi slot kanan berhasil disamakan dengan slot kiri!'),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      },
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: kSoftRedBg,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: kPrimaryRed, width: 0.8),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.copy_rounded, size: 12, color: kPrimaryRed),
                            SizedBox(width: 4),
                            Text(
                              'Samakan Kiri ke Kanan',
                              style: TextStyle(color: kPrimaryRed, fontSize: 10, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 10),
              Container(
                width: designerWidth,
                height: designerHeight,
                decoration: BoxDecoration(
                  color: const Color(0xFF222222),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: kPrimaryRed, width: 2),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14.5),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_uploadedPngBytes != null)
                        Image.memory(_uploadedPngBytes!, fit: BoxFit.fill)
                      else
                        Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.image_outlined, size: 50, color: Colors.white54),
                              const SizedBox(height: 12),
                              Text(
                                isStripMode
                                    ? 'Pilih PNG Strip (51 mm x 152 mm) di kanan'
                                    : (isStripSemi4R
                                        ? 'Pilih PNG 4R (102 mm x 152 mm) di kanan'
                                        : 'Silakan pilih file PNG di kanan'),
                                style: const TextStyle(color: Colors.white70, fontSize: 13),
                                textAlign: TextAlign.center,
                              )
                            ],
                          ),
                        ),

                      if (isStripSemi4R)
                        Positioned(
                          left: designerWidth * 0.5 - 0.5,
                          top: 0,
                          bottom: 0,
                          width: 1,
                          child: Container(color: Colors.white38),
                        ),

                      if (isStripSemi4R)
                        Positioned(
                          left: 8,
                          top: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: kPrimaryRed,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text('Strip Kiri (Utama)', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                          ),
                        ),
                      if (isStripSemi4R)
                        Positioned(
                          right: 8,
                          top: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: kDarkRed,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text('Strip Kanan (Manual)', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                          ),
                        ),

                      _buildDraggableSlot(
                        label: isStripSemi4R ? 'FOTO 1 (KIRI)' : 'FOTO 1 (ATAS)',
                        color: Colors.blueAccent,
                        x: _s1x,
                        y: _s1y,
                        w: _s1w,
                        h: _s1h,
                        minX: 0.0,
                        maxX: isStripSemi4R ? 0.5 : 1.0,
                        canvasW: designerWidth,
                        canvasH: designerHeight,
                        onUpdate: (newX, newY, newW, newH) {
                          setState(() {
                            _s1x = newX;
                            _s1y = newY;
                            _s1w = newW;
                            _s1h = newH;
                          });
                        },
                      ),

                      if (isStripSemi4R)
                        _buildDraggableSlot(
                          label: 'FOTO 1 (KANAN)',
                          color: Colors.cyanAccent,
                          x: _s4x,
                          y: _s4y,
                          w: _s4w,
                          h: _s4h,
                          minX: 0.5,
                          maxX: 1.0,
                          canvasW: designerWidth,
                          canvasH: designerHeight,
                          onUpdate: (newX, newY, newW, newH) {
                            setState(() {
                              _s4x = newX;
                              _s4y = newY;
                              _s4w = newW;
                              _s4h = newH;
                            });
                          },
                        ),

                      _buildDraggableSlot(
                        label: isStripSemi4R ? 'FOTO 2 (KIRI)' : 'FOTO 2 (TENGAH)',
                        color: Colors.greenAccent,
                        x: _s2x,
                        y: _s2y,
                        w: _s2w,
                        h: _s2h,
                        minX: 0.0,
                        maxX: isStripSemi4R ? 0.5 : 1.0,
                        canvasW: designerWidth,
                        canvasH: designerHeight,
                        onUpdate: (newX, newY, newW, newH) {
                          setState(() {
                            _s2x = newX;
                            _s2y = newY;
                            _s2w = newW;
                            _s2h = newH;
                          });
                        },
                      ),

                      if (isStripSemi4R)
                        _buildDraggableSlot(
                          label: 'FOTO 2 (KANAN)',
                          color: Colors.limeAccent,
                          x: _s5x,
                          y: _s5y,
                          w: _s5w,
                          h: _s5h,
                          minX: 0.5,
                          maxX: 1.0,
                          canvasW: designerWidth,
                          canvasH: designerHeight,
                          onUpdate: (newX, newY, newW, newH) {
                            setState(() {
                              _s5x = newX;
                              _s5y = newY;
                              _s5w = newW;
                              _s5h = newH;
                            });
                          },
                        ),

                      _buildDraggableSlot(
                        label: isStripSemi4R ? 'FOTO 3 (KIRI)' : 'FOTO 3 (BAWAH)',
                        color: Colors.redAccent,
                        x: _s3x,
                        y: _s3y,
                        w: _s3w,
                        h: _s3h,
                        minX: 0.0,
                        maxX: isStripSemi4R ? 0.5 : 1.0,
                        canvasW: designerWidth,
                        canvasH: designerHeight,
                        onUpdate: (newX, newY, newW, newH) {
                          setState(() {
                            _s3x = newX;
                            _s3y = newY;
                            _s3w = newW;
                            _s3h = newH;
                          });
                        },
                      ),

                      if (isStripSemi4R)
                        _buildDraggableSlot(
                          label: 'FOTO 3 (KANAN)',
                          color: Colors.orangeAccent,
                          x: _s6x,
                          y: _s6y,
                          w: _s6w,
                          h: _s6h,
                          minX: 0.5,
                          maxX: 1.0,
                          canvasW: designerWidth,
                          canvasH: designerHeight,
                          onUpdate: (newX, newY, newW, newH) {
                            setState(() {
                              _s6x = newX;
                              _s6y = newY;
                              _s6w = newW;
                              _s6h = newH;
                            });
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 48),

          // Sisi Kanan: Kontrol & Upload Gambar
          Expanded(
            child: SingleChildScrollView(
              child: Container(
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: kPrimaryRed.withAlpha(110), width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: kPrimaryRed.withAlpha(18),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'PENGATURAN TEMPLATE BARU',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: kPrimaryRed,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Pilih mode template dan rancang tata letak 3 slot foto Anda.',
                      style: TextStyle(fontSize: 12, color: kTextMuted),
                    ),
                    const SizedBox(height: 24),

                    const Text(
                      'MODE TEMPLATE',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: kPrimaryRed, letterSpacing: 1),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        // 1. Mode 4R FULL
                        Expanded(
                          child: InkWell(
                            onTap: () {
                              setState(() {
                                _templateMode = '4r';
                                if (_s1w < 0.5) {
                                  _s1x = 0.1; _s1y = 0.08; _s1w = 0.8; _s1h = 0.25;
                                  _s2x = 0.1; _s2y = 0.36; _s2w = 0.8; _s2h = 0.25;
                                  _s3x = 0.1; _s3y = 0.64; _s3w = 0.8; _s3h = 0.25;
                                }
                              });
                            },
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                              decoration: BoxDecoration(
                                color: _templateMode == '4r' ? kPrimaryRed : kSoftRedBg,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: _templateMode == '4r' ? kPrimaryRed : kBorderRed,
                                  width: 1.5,
                                ),
                              ),
                              child: Column(
                                children: [
                                  Icon(
                                    Icons.crop_portrait_rounded,
                                    color: _templateMode == '4r' ? Colors.white : kPrimaryRed,
                                    size: 20,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '4R FULL',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: _templateMode == '4r' ? Colors.white : kPrimaryRed,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '102x152 mm',
                                    style: TextStyle(
                                      fontSize: 9,
                                      color: _templateMode == '4r' ? Colors.white70 : kTextMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // 2. Mode STRIP 2X
                        Expanded(
                          child: InkWell(
                            onTap: () {
                              setState(() {
                                _templateMode = 'strip';
                                if (_s1w < 0.5) {
                                  _s1x = 0.1; _s1y = 0.08; _s1w = 0.8; _s1h = 0.25;
                                  _s2x = 0.1; _s2y = 0.36; _s2w = 0.8; _s2h = 0.25;
                                  _s3x = 0.1; _s3y = 0.64; _s3w = 0.8; _s3h = 0.25;
                                }
                              });
                            },
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                              decoration: BoxDecoration(
                                color: _templateMode == 'strip' ? kPrimaryRed : kSoftRedBg,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: _templateMode == 'strip' ? kPrimaryRed : kBorderRed,
                                  width: 1.5,
                                ),
                              ),
                              child: Column(
                                children: [
                                  Icon(
                                    Icons.view_column_rounded,
                                    color: _templateMode == 'strip' ? Colors.white : kPrimaryRed,
                                    size: 20,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'STRIP 2X',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: _templateMode == 'strip' ? Colors.white : kPrimaryRed,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '51x152 mm',
                                    style: TextStyle(
                                      fontSize: 9,
                                      color: _templateMode == 'strip' ? Colors.white70 : kTextMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // 3. Mode STRIP SEMI 4R
                        Expanded(
                          child: InkWell(
                            onTap: () {
                              setState(() {
                                _templateMode = 'strip_semi_4r';
                                if (_s1w > 0.45 || _s1x > 0.45) {
                                  _s1x = 0.05; _s1y = 0.08; _s1w = 0.40; _s1h = 0.25;
                                  _s2x = 0.05; _s2y = 0.36; _s2w = 0.40; _s2h = 0.25;
                                  _s3x = 0.05; _s3y = 0.64; _s3w = 0.40; _s3h = 0.25;
                                }
                                if (_s4w > 0.45 || _s4x < 0.50) {
                                  _s4x = (_s1x + 0.5).clamp(0.5, 0.95); _s4y = _s1y; _s4w = _s1w; _s4h = _s1h;
                                  _s5x = (_s2x + 0.5).clamp(0.5, 0.95); _s5y = _s2y; _s5w = _s2w; _s5h = _s2h;
                                  _s6x = (_s3x + 0.5).clamp(0.5, 0.95); _s6y = _s3y; _s6w = _s3w; _s6h = _s6h;
                                }
                              });
                            },
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                              decoration: BoxDecoration(
                                color: _templateMode == 'strip_semi_4r' ? kPrimaryRed : kSoftRedBg,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: _templateMode == 'strip_semi_4r' ? kPrimaryRed : kBorderRed,
                                  width: 1.5,
                                ),
                              ),
                              child: Column(
                                children: [
                                  Icon(
                                    Icons.flip_rounded,
                                    color: _templateMode == 'strip_semi_4r' ? Colors.white : kPrimaryRed,
                                    size: 20,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'SEMI 4R',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: _templateMode == 'strip_semi_4r' ? Colors.white : kPrimaryRed,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Upload 4R • 6 Foto',
                                    style: TextStyle(
                                      fontSize: 9,
                                      color: _templateMode == 'strip_semi_4r' ? Colors.white70 : kTextMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _templateMode == 'strip'
                          ? '• Desain strip (51 mm x 152 mm). Saat dicetak ke kertas 4R (102 mm x 152 mm), otomatis di-copy kanan-kiri menjadi 2 lembar strip kembar.'
                          : (_templateMode == 'strip_semi_4r'
                              ? '• Desain 4R (102 mm x 152 mm) dengan 2 strip (6 foto total). Posisi 3 slot kiri dan 3 slot kanan dapat digeser & disesuaikan ukurannya secara bebas dan manual.'
                              : '• Desain 4R penuh (102 mm x 152 mm pada kertas foto 4R standar, 3 foto penuh).'),
                      style: const TextStyle(
                        fontSize: 11,
                        color: kTextMuted,
                      ),
                    ),
                    const SizedBox(height: 24),

                    const Text(
                      'NAMA TEMPLATE',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: kPrimaryRed, letterSpacing: 1),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _templateNameController,
                      style: const TextStyle(color: kTextDark, fontSize: 13, fontWeight: FontWeight.w600),
                      decoration: InputDecoration(
                        hintText: 'Misal: Template Ulang Tahun Merah',
                        hintStyle: const TextStyle(color: kTextMuted),
                        filled: true,
                        fillColor: kSoftRedBg,
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: kBorderRed, width: 1.5),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: kPrimaryRed, width: 2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    const Text(
                      'GAMBAR OVERLAY PNG (TRANSPARAN)',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: kPrimaryRed, letterSpacing: 1),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                            decoration: BoxDecoration(
                              color: kSoftRedBg,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: kBorderRed, width: 1.5),
                            ),
                            child: Text(
                              _uploadedPngFileName.isNotEmpty ? _uploadedPngFileName : 'Belum ada file dipilih',
                              style: TextStyle(
                                color: _uploadedPngFileName.isNotEmpty ? kTextDark : kTextMuted,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        ElevatedButton.icon(
                          onPressed: _pickTemplateFile,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: kPrimaryRed,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          icon: const Icon(Icons.file_upload_outlined, size: 18),
                          label: const Text('PILIH PNG', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    const Text(
                      'TUGASKAN KE USER BOOTH',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: kPrimaryRed, letterSpacing: 1),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 180),
                      decoration: BoxDecoration(
                        color: kSoftRedBg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: kBorderRed, width: 1.5),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(11),
                        child: _isLoadingBoothUsers
                            ? const Center(child: CircularProgressIndicator(color: kPrimaryRed))
                            : _boothUsersList.isEmpty
                                ? const Center(
                                    child: Padding(
                                      padding: EdgeInsets.all(16.0),
                                      child: Text(
                                        'Tidak ada akun booth terdaftar!',
                                        style: TextStyle(color: kTextMuted, fontSize: 12),
                                      ),
                                    ),
                                  )
                                : ListView.builder(
                                    shrinkWrap: true,
                                    physics: const ClampingScrollPhysics(),
                                    itemCount: _boothUsersList.length,
                                    itemBuilder: (context, index) {
                                      final booth = _boothUsersList[index];
                                      final id = booth['id_user'] as int;
                                      final name = booth['username'] as String;
                                      final alamat = booth['alamat_photobox'] ?? 'No Address';
                                      final isChecked = _selectedBoothIds.contains(id);

                                      return CheckboxListTile(
                                        value: isChecked,
                                        activeColor: kPrimaryRed,
                                        checkColor: Colors.white,
                                        title: Text(
                                          name,
                                          style: const TextStyle(color: kTextDark, fontSize: 13, fontWeight: FontWeight.bold),
                                        ),
                                        subtitle: Text(
                                          alamat,
                                          style: const TextStyle(color: kTextMuted, fontSize: 11),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        controlAffinity: ListTileControlAffinity.leading,
                                        onChanged: (bool? val) {
                                          setState(() {
                                            if (val == true) {
                                              _selectedBoothIds.add(id);
                                            } else {
                                              _selectedBoothIds.remove(id);
                                            }
                                          });
                                        },
                                      );
                                    },
                                  ),
                      ),
                    ),
                    const SizedBox(height: 28),
                    const Divider(color: kBorderRed, thickness: 1.5),
                    const SizedBox(height: 20),

                    const Text(
                      'PETUNJUK EDITOR:',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: kPrimaryRed, letterSpacing: 1),
                    ),
                    const SizedBox(height: 8),
                    const BulletPoint(text: 'Geser/drag box berwarna untuk memindahkan posisi slot foto.'),
                    const BulletPoint(text: 'Tarik lingkaran putih kecil di ujung kanan-bawah box untuk mengubah ukuran slot.'),
                    const BulletPoint(text: 'Gunakan PNG transparan agar foto di belakangnya terlihat.'),
                    const SizedBox(height: 36),

                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _cancelEditingTemplate,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: kPrimaryRed,
                              side: const BorderSide(color: kPrimaryRed, width: 1.5),
                              padding: const EdgeInsets.symmetric(vertical: 18),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(24),
                              ),
                            ),
                            child: const Text('BATAL', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: _saveTemplateToDb,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: kPrimaryRed,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 18),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(24),
                              ),
                            ),
                            child: const Text('SIMPAN LAYOUT', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildDraggableSlot({
    required String label,
    required Color color,
    required double x,
    required double y,
    required double w,
    required double h,
    required double canvasW,
    required double canvasH,
    required Function(double x, double y, double w, double h) onUpdate,
    double minX = 0.0,
    double maxX = 1.0,
  }) {
    final double left = x * canvasW;
    final double top = y * canvasH;
    final double width = w * canvasW;
    final double height = h * canvasH;

    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          width: width,
          height: height,
          child: GestureDetector(
            onPanUpdate: (details) {
              final double newX = (left + details.delta.dx) / canvasW;
              final double newY = (top + details.delta.dy) / canvasH;
              onUpdate(
                newX.clamp(minX, maxX - w),
                newY.clamp(0.0, 1.0 - h),
                w,
                h,
              );
            },
            child: Container(
              decoration: BoxDecoration(
                color: color.withAlpha(35),
                border: Border.all(color: color, width: 2),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Center(
                child: Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.bold,
                    fontSize: 10,
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: left + width - 18,
          top: top + height - 18,
          child: GestureDetector(
            onPanUpdate: (details) {
              final double newW = (width + details.delta.dx) / canvasW;
              final double newH = (height + details.delta.dy) / canvasH;
              onUpdate(
                x,
                y,
                newW.clamp(0.05, maxX - x),
                newH.clamp(0.05, 1.0 - y),
              );
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeUpLeftDownRight,
              child: Container(
                width: 18,
                height: 18,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2)),
                  ],
                ),
                child: const Center(
                  child: Icon(Icons.open_in_full, size: 10, color: Colors.black),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class BulletPoint extends StatelessWidget {
  final String text;
  const BulletPoint({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('• ', style: TextStyle(color: Color(0xFFD3242B), fontSize: 13, fontWeight: FontWeight.bold)),
          Expanded(child: Text(text, style: const TextStyle(color: Color(0xFF7A6869), fontSize: 12))),
        ],
      ),
    );
  }
}

class ImageCropDialog extends StatefulWidget {
  final Uint8List imageBytes;
  final String templateMode;

  const ImageCropDialog({
    super.key,
    required this.imageBytes,
    this.templateMode = '4r',
  });

  @override
  State<ImageCropDialog> createState() => _ImageCropDialogState();
}

class _ImageCropDialogState extends State<ImageCropDialog> {
  static const Color kPrimaryRed = Color(0xFFD3242B);

  img.Image? _decodedImage;
  bool _isDecoding = true;

  double cropLeft = 0;
  double cropTop = 0;
  double cropWidth = 100;
  double cropHeight = 100;

  bool _initialized = false;
  bool _isCropping = false;

  double containerW = 0;
  double containerH = 0;
  double _activeTargetRatio = 102.0 / 152.0;

  @override
  void initState() {
    super.initState();
    _decodeImage();
  }

  Future<void> _decodeImage() async {
    try {
      final decoded = img.decodeImage(widget.imageBytes);
      if (mounted) {
        setState(() {
          _decodedImage = decoded;
          _isDecoding = false;
        });
      }
    } catch (e) {
      debugPrint('Error decoding image for crop: $e');
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Gagal membaca gambar PNG'), backgroundColor: kPrimaryRed),
        );
      }
    }
  }

  void _initCropBox(double displayW, double displayH) {
    if (_initialized) return;
    _initialized = true;

    final double imgRatio = displayW / displayH;
    if (widget.templateMode == 'strip') {
      _activeTargetRatio = 51.0 / 152.0;
    } else {
      _activeTargetRatio = 102.0 / 152.0;
    }

    if (imgRatio > _activeTargetRatio) {
      cropHeight = displayH * 0.9;
      cropWidth = cropHeight * _activeTargetRatio;
      cropLeft = (displayW - cropWidth) / 2;
      cropTop = (displayH - cropHeight) / 2;
    } else {
      cropWidth = displayW * 0.9;
      cropHeight = cropWidth / _activeTargetRatio;
      cropLeft = (displayW - cropWidth) / 2;
      cropTop = (displayH - cropHeight) / 2;
    }
  }

  void _onCropConfirmed(double displayW, double displayH) {
    if (_decodedImage == null || _isCropping) return;

    setState(() {
      _isCropping = true;
    });

    Future.delayed(const Duration(milliseconds: 100), () {
      try {
        final double scaleX = _decodedImage!.width / displayW;
        final double scaleY = _decodedImage!.height / displayH;

        final int cropX = (cropLeft * scaleX).round().clamp(0, _decodedImage!.width - 1);
        final int cropY = (cropTop * scaleY).round().clamp(0, _decodedImage!.height - 1);
        final int cropW = (cropWidth * scaleX).round().clamp(1, _decodedImage!.width - cropX);
        final int cropH = (cropHeight * scaleY).round().clamp(1, _decodedImage!.height - 1);

        final croppedImage = img.copyCrop(
          _decodedImage!,
          x: cropX,
          y: cropY,
          width: cropW,
          height: cropH,
        );

        var finalImage = croppedImage;
        if (croppedImage.height > 2400) {
          finalImage = img.copyResize(
            croppedImage,
            height: 2400,
            interpolation: img.Interpolation.cubic,
          );
        }

        final croppedBytes = Uint8List.fromList(img.encodePng(finalImage));
        if (mounted) {
          Navigator.pop(context, croppedBytes);
        }
      } catch (e) {
        debugPrint('Error cropping image: $e');
        if (mounted) {
          setState(() {
            _isCropping = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Gagal melakukan crop: $e'), backgroundColor: kPrimaryRed),
          );
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: kPrimaryRed, width: 2),
      ),
      child: Container(
        width: 800,
        height: 650,
        padding: const EdgeInsets.all(28),
        child: _isDecoding
            ? const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: kPrimaryRed),
                    SizedBox(height: 16),
                    Text('Mendekode gambar PNG...', style: TextStyle(color: kPrimaryRed, fontWeight: FontWeight.w600)),
                  ],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.templateMode == 'strip'
                                ? 'CROP TEMPLATE STRIP (51 mm x 152 mm)'
                                : (widget.templateMode == 'strip_semi_4r'
                                    ? 'CROP TEMPLATE STRIP SEMI 4R (102 mm x 152 mm)'
                                    : 'CROP TEMPLATE OVERLAY (4R)'),
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              color: kPrimaryRed,
                              letterSpacing: 1,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            widget.templateMode == 'strip'
                                ? 'Sesuaikan bingkai ke rasio Strip (51 mm x 152 mm / Setengah 4R)'
                                : (widget.templateMode == 'strip_semi_4r'
                                    ? 'Sesuaikan bingkai ke rasio 4R (102 mm x 152 mm / 6 Foto Mirror)'
                                    : 'Sesuaikan bingkai ke rasio 4R (102 mm x 152 mm / Portrait)'),
                            style: const TextStyle(fontSize: 12, color: Color(0xFF7A6869)),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: kPrimaryRed),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Expanded(
                    child: Center(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          if (_decodedImage == null) return const SizedBox();

                          final double imgRatio = _decodedImage!.width / _decodedImage!.height;
                          double displayW = constraints.maxWidth;
                          double displayH = constraints.maxWidth / imgRatio;

                          if (displayH > constraints.maxHeight) {
                            displayH = constraints.maxHeight;
                            displayW = constraints.maxHeight * imgRatio;
                          }

                          _initCropBox(displayW, displayH);

                          containerW = displayW;
                          containerH = displayH;

                          return Container(
                            width: displayW,
                            height: displayH,
                            color: Colors.black,
                            child: Stack(
                              children: [
                                Image.memory(
                                  widget.imageBytes,
                                  width: displayW,
                                  height: displayH,
                                  fit: BoxFit.fill,
                                ),

                                Positioned(
                                  left: 0,
                                  top: 0,
                                  width: cropLeft.clamp(0.0, displayW),
                                  height: displayH,
                                  child: Container(color: Colors.black54),
                                ),
                                Positioned(
                                  left: (cropLeft + cropWidth).clamp(0.0, displayW),
                                  top: 0,
                                  width: (displayW - (cropLeft + cropWidth)).clamp(0.0, displayW),
                                  height: displayH,
                                  child: Container(color: Colors.black54),
                                ),
                                Positioned(
                                  left: cropLeft.clamp(0.0, displayW),
                                  top: 0,
                                  width: cropWidth.clamp(0.0, displayW),
                                  height: cropTop.clamp(0.0, displayH),
                                  child: Container(color: Colors.black54),
                                ),
                                Positioned(
                                  left: cropLeft.clamp(0.0, displayW),
                                  top: (cropTop + cropHeight).clamp(0.0, displayH),
                                  width: cropWidth.clamp(0.0, displayW),
                                  height: (displayH - (cropTop + cropHeight)).clamp(0.0, displayH),
                                  child: Container(color: Colors.black54),
                                ),

                                Positioned(
                                  left: cropLeft,
                                  top: cropTop,
                                  width: cropWidth,
                                  height: cropHeight,
                                  child: GestureDetector(
                                    onPanUpdate: (details) {
                                      setState(() {
                                        cropLeft = (cropLeft + details.delta.dx).clamp(0.0, displayW - cropWidth);
                                        cropTop = (cropTop + details.delta.dy).clamp(0.0, displayH - cropHeight);
                                      });
                                    },
                                    child: Container(
                                      decoration: BoxDecoration(
                                        border: Border.all(color: kPrimaryRed, width: 2.5),
                                        color: Colors.transparent,
                                      ),
                                      child: const Center(
                                        child: Icon(Icons.drag_indicator, color: Colors.white70, size: 24),
                                      ),
                                    ),
                                  ),
                                ),

                                Positioned(
                                  left: cropLeft + cropWidth - 14,
                                  top: cropTop + cropHeight - 14,
                                  child: GestureDetector(
                                    onPanUpdate: (details) {
                                      setState(() {
                                        final double newWidth = (cropWidth + details.delta.dx).clamp(40.0, displayW - cropLeft);
                                        final double newHeight = newWidth / _activeTargetRatio;
                                        if (cropTop + newHeight <= displayH) {
                                          cropWidth = newWidth;
                                          cropHeight = newHeight;
                                        }
                                      });
                                    },
                                    child: MouseRegion(
                                      cursor: SystemMouseCursors.resizeUpLeftDownRight,
                                      child: Container(
                                        width: 24,
                                        height: 24,
                                        decoration: const BoxDecoration(
                                          color: kPrimaryRed,
                                          shape: BoxShape.circle,
                                          boxShadow: [
                                            BoxShadow(color: Colors.black38, blurRadius: 4, offset: Offset(0, 2)),
                                          ],
                                        ),
                                        child: const Center(
                                          child: Icon(Icons.open_in_full, size: 12, color: Colors.white),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: kPrimaryRed,
                          side: const BorderSide(color: kPrimaryRed, width: 1.5),
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                        ),
                        child: const Text('Batal', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(width: 16),
                      ElevatedButton(
                        onPressed: _isCropping ? null : () => _onCropConfirmed(containerW, containerH),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: kPrimaryRed,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                        ),
                        child: _isCropping
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                              )
                            : const Text('Terapkan Crop', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}
