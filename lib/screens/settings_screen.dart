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

class SettingsScreen extends StatefulWidget {
  final Map<String, dynamic> user;

  const SettingsScreen({super.key, required this.user});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
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

  // Slot coordinates (normalized 0.0 to 1.0)
  double _s1x = 0.1, _s1y = 0.1, _s1w = 0.8, _s1h = 0.23;
  double _s2x = 0.1, _s2y = 0.38, _s2w = 0.8, _s2h = 0.23;
  double _s3x = 0.1, _s3y = 0.66, _s3w = 0.8, _s3h = 0.23;

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
        
        if (!mounted) return;
        final croppedBytes = await showDialog<Uint8List>(
          context: context,
          barrierDismissible: false,
          builder: (context) => ImageCropDialog(imageBytes: bytes),
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
        SnackBar(content: Text('Gagal memilih file: $e'), backgroundColor: Colors.redAccent),
      );
    }
  }

  Future<void> _saveTemplateToDb() async {
    if (_templateNameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nama template tidak boleh kosong!'), backgroundColor: Colors.redAccent),
      );
      return;
    }
    if (_uploadedPngBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Anda harus mengupload gambar template PNG!'), backgroundColor: Colors.redAccent),
      );
      return;
    }
    if (_selectedBoothIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pilih minimal satu booth user untuk template ini!'), backgroundColor: Colors.redAccent),
      );
      return;
    }

    try {
      final userId = widget.user['id_user'] as int;
      await MySqlHelper.saveTemplate(
        idUser: userId,
        name: _templateNameController.text.trim(),
        imageData: _uploadedPngBytes!,
        slot1X: _s1x, slot1Y: _s1y, slot1W: _s1w, slot1H: _s1h,
        slot2X: _s2x, slot2Y: _s2y, slot2W: _s2w, slot2H: _s2h,
        slot3X: _s3x, slot3Y: _s3y, slot3W: _s3w, slot3H: _s3h,
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
        SnackBar(content: Text('Gagal menyimpan template: $e'), backgroundColor: Colors.redAccent),
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
        SnackBar(content: Text('Gagal menghapus template: $e'), backgroundColor: Colors.redAccent),
      );
    }
  }

  void _startNewTemplate() {
    setState(() {
      _isEditingTemplate = true;
      _editingTemplateId = null;
      _templateNameController.clear();
      _uploadedPngBytes = null;
      _uploadedPngFileName = '';
      _selectedBoothIds.clear();
      
      // Reset slots ke default
      _s1x = 0.1; _s1y = 0.08; _s1w = 0.8; _s1h = 0.25;
      _s2x = 0.1; _s2y = 0.36; _s2w = 0.8; _s2h = 0.25;
      _s3x = 0.1; _s3y = 0.64; _s3w = 0.8; _s3h = 0.25;
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
      // Fetch all printers via PowerShell
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
      // Fetch cameras via availableCameras()
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
      _selectedCameraDescription = camera; // Set langsung agar tombol mulai sesi aktif
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

    // Tunggu 1500ms agar OS/driver Windows melepas kunci hardware kamera
    await Future.delayed(const Duration(milliseconds: 1500));
    if (sessionId != _cameraSessionId) return;

    final newController = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
    );

    if (sessionId != _cameraSessionId) {
      try {
        await newController.dispose();
      } catch (_) {}
      return;
    }

    _previewController = newController;

    // Retry loop untuk mengatasi lock kamera Windows
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
      final sessionId = ++_cameraSessionId; // Batalkan semua inisialisasi kamera yang berjalan di background
      
      // Dapatkan Future disposal, fallback ke Future.value jika controller null
      final Future<void> disposeFuture = _previewController?.dispose() ?? Future.value();
      _previewController = null;
      _isCameraPreviewInitialized = false;

      // Lock fullscreen mode
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
            // Restore normal screen mode when returning to dashboard
            SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
            windowManager.setFullScreen(false);
            // Re-initialize preview when returning to dashboard
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
      backgroundColor: const Color(0xFF0F0F0F),
      body: Row(
        children: [
          // SIDEBAR (Informasi Akun)
          Material(
            color: const Color(0xFF161616),
            child: Container(
              width: 300,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
              child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: const BoxDecoration(
                        color: Colors.white12,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.admin_panel_settings, size: 28, color: Colors.white),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            username.toUpperCase(),
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          Text(
                            'ROLE: ${role.toUpperCase()}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white54,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 40),
                const Divider(color: Colors.white24),
                const SizedBox(height: 24),
                const Text(
                  'LOKASI UNIT PHOTOBOX',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.white30,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.location_on_outlined, size: 16, color: Colors.white54),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        alamat,
                        style: const TextStyle(fontSize: 13, color: Colors.white70, height: 1.4),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                const Divider(color: Colors.white24),
                const SizedBox(height: 24),
                const Text(
                  'MENU NAVIGASI',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.white30,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 12),
                if (role != 'admin')
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Icons.tune, 
                      color: _activeTab == 'dashboard' ? Colors.white : Colors.white38
                    ),
                    title: Text(
                      'SETUP PERANGKAT',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: _activeTab == 'dashboard' ? Colors.white : Colors.white38
                      ),
                    ),
                    onTap: () {
                      setState(() {
                        _activeTab = 'dashboard';
                      });
                    },
                  ),
                if (role == 'admin')
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Icons.layers, 
                      color: _activeTab == 'templates' ? Colors.white : Colors.white38
                    ),
                    title: Text(
                      'KELOLA TEMPLATE',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: _activeTab == 'templates' ? Colors.white : Colors.white38
                      ),
                    ),
                    onTap: () {
                      setState(() {
                        _activeTab = 'templates';
                      });
                      _loadTemplatesFromDb();
                    },
                  ),
                const Spacer(),
                ElevatedButton.icon(
                  onPressed: _logout,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white10,
                    foregroundColor: Colors.redAccent,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: const BorderSide(color: Colors.redAccent, width: 0.5),
                    ),
                  ),
                  icon: const Icon(Icons.logout, size: 18),
                  label: const SizedBox(
                    width: double.infinity,
                    child: Text(
                      'KELUAR (LOGOUT)',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
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
              padding: const EdgeInsets.all(48.0),
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
                                    color: Colors.white,
                                    letterSpacing: 1,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Status Sistem: ${_isLoadingDevices ? "Mendeteksi Perangkat..." : "Online & Siap"}',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: _isLoadingDevices ? Colors.white30 : Colors.white54,
                                  ),
                                ),
                              ],
                            ),
                            IconButton(
                              onPressed: _loadSystemDevices,
                              icon: const Icon(Icons.refresh, color: Colors.white),
                              tooltip: 'Pindai Ulang Perangkat',
                            ),
                          ],
                        ),
                        const SizedBox(height: 32),
                        
                        if (_isLoadingDevices)
                          const Expanded(
                            child: Center(
                              child: CircularProgressIndicator(color: Colors.white),
                            ),
                          )
                        else
                          Expanded(
                            child: GridView.count(
                              crossAxisCount: 2,
                              crossAxisSpacing: 24,
                              mainAxisSpacing: 24,
                              childAspectRatio: 0.65, // Adjusted height to fit live preview and calibration options
                              children: [
                                // Card Setting Kamera
                                Container(
                                  padding: const EdgeInsets.all(24),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF161616),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(color: Colors.white12),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Row(
                                        children: [
                                          Icon(Icons.camera_alt, color: Colors.white, size: 24),
                                          const SizedBox(width: 12),
                                          const Text(
                                            'KAMERA UTAMA',
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.white,
                                              letterSpacing: 1,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 16),
                                      const Text(
                                        'Pilih Input Kamera Aktif:',
                                        style: TextStyle(fontSize: 12, color: Colors.white54),
                                      ),
                                      const SizedBox(height: 8),
                                      DropdownButtonFormField<CameraDescription>(
                                        isExpanded: true,
                                        dropdownColor: const Color(0xFF161616),
                                        value: _selectedCameraDescription,
                                        style: const TextStyle(color: Colors.white, fontSize: 13),
                                        decoration: InputDecoration(
                                          filled: true,
                                          fillColor: Colors.black,
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(12),
                                            borderSide: const BorderSide(color: Colors.white24),
                                          ),
                                          focusedBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(12),
                                            borderSide: const BorderSide(color: Colors.white),
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
                                      // Real Live Preview inside Settings Screen!
                                       Expanded(
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: Colors.black,
                                            borderRadius: BorderRadius.circular(12),
                                            border: Border.all(color: Colors.white12),
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
                                                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                                                        ),
                                                        SizedBox(height: 16),
                                                        Text(
                                                          'Menghubungkan ke Kamera...',
                                                          style: TextStyle(color: Colors.white54, fontSize: 12),
                                                        )
                                                      ],
                                                    ),
                                                  )
                                                : (_isCameraPreviewInitialized && _previewController != null
                                                    ? CameraPreview(_previewController!)
                                                    : const Center(
                                                        child: Column(
                                                          mainAxisAlignment: MainAxisAlignment.center,
                                                          children: [
                                                            Icon(Icons.videocam_off, color: Colors.white24, size: 36),
                                                            SizedBox(height: 8),
                                                            Text(
                                                              'Preview Tidak Aktif',
                                                              style: TextStyle(color: Colors.white24, fontSize: 11),
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
                                    color: const Color(0xFF161616),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(color: Colors.white12),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Row(
                                        children: [
                                          Icon(Icons.print, color: Colors.white, size: 24),
                                          const SizedBox(width: 12),
                                          const Text(
                                            'PRINTER UTAMA',
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.white,
                                              letterSpacing: 1,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 16),
                                      const Text(
                                        'Pilih Printer Cetak Foto:',
                                        style: TextStyle(fontSize: 12, color: Colors.white54),
                                      ),
                                      const SizedBox(height: 8),
                                      DropdownButtonFormField<String>(
                                        isExpanded: true,
                                        dropdownColor: const Color(0xFF161616),
                                        value: _selectedPrinter,
                                        style: const TextStyle(color: Colors.white, fontSize: 13),
                                        decoration: InputDecoration(
                                          filled: true,
                                          fillColor: Colors.black,
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(12),
                                            borderSide: const BorderSide(color: Colors.white24),
                                          ),
                                          focusedBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(12),
                                            borderSide: const BorderSide(color: Colors.white),
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
                                      const Divider(color: Colors.white24),
                                      const SizedBox(height: 12),
                                      const Row(
                                        children: [
                                          Icon(Icons.tune, color: Colors.white, size: 20),
                                          SizedBox(width: 8),
                                          Text(
                                            'KALIBRASI POSISI CETAK',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.white,
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
                                                  style: TextStyle(fontSize: 11, color: Colors.white70),
                                                ),
                                                const SizedBox(height: 6),
                                                TextField(
                                                  controller: _offsetXController,
                                                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                                                  style: const TextStyle(color: Colors.white, fontSize: 13),
                                                  decoration: InputDecoration(
                                                    filled: true,
                                                    fillColor: Colors.black,
                                                    isDense: true,
                                                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                                    enabledBorder: OutlineInputBorder(
                                                      borderRadius: BorderRadius.circular(8),
                                                      borderSide: const BorderSide(color: Colors.white24),
                                                    ),
                                                    focusedBorder: OutlineInputBorder(
                                                      borderRadius: BorderRadius.circular(8),
                                                      borderSide: const BorderSide(color: Colors.white),
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
                                                  style: TextStyle(fontSize: 11, color: Colors.white70),
                                                ),
                                                const SizedBox(height: 6),
                                                TextField(
                                                  controller: _offsetYController,
                                                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                                                  style: const TextStyle(color: Colors.white, fontSize: 13),
                                                  decoration: InputDecoration(
                                                    filled: true,
                                                    fillColor: Colors.black,
                                                    isDense: true,
                                                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                                    enabledBorder: OutlineInputBorder(
                                                      borderRadius: BorderRadius.circular(8),
                                                      borderSide: const BorderSide(color: Colors.white24),
                                                    ),
                                                    focusedBorder: OutlineInputBorder(
                                                      borderRadius: BorderRadius.circular(8),
                                                      borderSide: const BorderSide(color: Colors.white),
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
                                        style: TextStyle(fontSize: 10, color: Colors.white38, fontStyle: FontStyle.italic),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        
                        if (!_isLoadingDevices && role != 'admin')
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: _startSession,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(vertical: 24),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                elevation: 10,
                                shadowColor: Colors.white.withAlpha(30),
                              ),
                              icon: const Icon(Icons.play_circle_fill, size: 28),
                              label: const Text(
                                'MULAI SESI PHOTOBOX',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.5,
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
                                    color: Colors.white,
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
                                    color: Colors.white54,
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
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : (_userTemplates.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.layers_clear_outlined, size: 70, color: Colors.white24),
                      const SizedBox(height: 16),
                      const Text(
                        'Belum ada template terdaftar.',
                        style: TextStyle(color: Colors.white54, fontSize: 14),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: _startNewTemplate,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
                            backgroundColor: Colors.white,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
                              color: const Color(0xFF161616),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.white12),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // Thumbnail Preview of template
                                Expanded(
                                  child: Container(
                                    decoration: const BoxDecoration(
                                      color: Colors.black,
                                      borderRadius: BorderRadius.vertical(top: Radius.circular(15)),
                                    ),
                                    child: ClipRRect(
                                      borderRadius: const BorderRadius.vertical(top: Radius.circular(14.5)),
                                      child: Image.memory(bytes, fit: BoxFit.contain),
                                    ),
                                  ),
                                ),
                                // Information
                                Padding(
                                  padding: const EdgeInsets.all(16.0),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        name,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white,
                                          fontSize: 13,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 6),
                                      FutureBuilder<List<int>>(
                                        future: MySqlHelper.getTemplateAssignments(id),
                                        builder: (context, snapshot) {
                                          if (snapshot.connectionState == ConnectionState.waiting) {
                                            return const SizedBox(
                                              height: 12,
                                              child: LinearProgressIndicator(color: Colors.white24, backgroundColor: Colors.transparent),
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
                                            style: const TextStyle(fontSize: 10, color: Colors.white38),
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
                                            backgroundColor: Colors.white10,
                                            foregroundColor: Colors.redAccent,
                                            elevation: 0,
                                            padding: const EdgeInsets.symmetric(vertical: 10),
                                            shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(8),
                                              side: const BorderSide(color: Colors.redAccent, width: 0.5),
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
    // Ukuran kanvas desainer (sesuai rasio kertas custom 11.5 cm / 14.7 cm)
    const double designerHeight = 500.0;
    const double designerWidth = designerHeight * (11.5 / 14.7); // ~391.1 pixels

    return Expanded(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Sisi Kiri: Kanvas Visual Interaktif
          Container(
            width: designerWidth,
            height: designerHeight,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white24, width: 1.5),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14.5),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 1. Gambar Template PNG Transparan
                  if (_uploadedPngBytes != null)
                    Image.memory(_uploadedPngBytes!, fit: BoxFit.fill)
                  else
                    const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.image_outlined, size: 50, color: Colors.white24),
                          SizedBox(height: 12),
                          Text(
                            'Silakan pilih file PNG di kanan',
                            style: TextStyle(color: Colors.white38, fontSize: 13),
                          )
                        ],
                      ),
                    ),

                  // 2. Slot Foto 1 (Draggable/Resizable)
                  _buildDraggableSlot(
                    label: 'FOTO 1 (ATAS)',
                    color: Colors.blueAccent,
                    x: _s1x,
                    y: _s1y,
                    w: _s1w,
                    h: _s1h,
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

                  // 3. Slot Foto 2 (Draggable/Resizable)
                  _buildDraggableSlot(
                    label: 'FOTO 2 (TENGAH)',
                    color: Colors.greenAccent,
                    x: _s2x,
                    y: _s2y,
                    w: _s2w,
                    h: _s2h,
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

                  // 4. Slot Foto 3 (Draggable/Resizable)
                  _buildDraggableSlot(
                    label: 'FOTO 3 (BAWAH)',
                    color: Colors.redAccent,
                    x: _s3x,
                    y: _s3y,
                    w: _s3w,
                    h: _s3h,
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
                ],
              ),
            ),
          ),
          const SizedBox(width: 48),

          // Sisi Kanan: Kontrol & Upload Gambar
          Expanded(
            child: SingleChildScrollView(
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
                      'PENGATURAN TEMPLATE BARU',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Rancang tata letak 3 slot foto Anda di atas template PNG transparan.',
                      style: TextStyle(fontSize: 12, color: Colors.white54),
                    ),
                    const SizedBox(height: 28),

                    // Input Nama Template
                    const Text(
                      'NAMA TEMPLATE',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white30, letterSpacing: 1),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _templateNameController,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        hintText: 'Misal: Template Ulang Tahun Pink',
                        hintStyle: const TextStyle(color: Colors.white24),
                        filled: true,
                        fillColor: Colors.black,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.white24),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.white),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // File PNG Upload
                    const Text(
                      'GAMBAR OVERLAY PNG (TRANSPARAN)',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white30, letterSpacing: 1),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                            decoration: BoxDecoration(
                              color: Colors.black,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white12),
                            ),
                            child: Text(
                              _uploadedPngFileName.isNotEmpty ? _uploadedPngFileName : 'Belum ada file dipilih',
                              style: TextStyle(
                                color: _uploadedPngFileName.isNotEmpty ? Colors.white : Colors.white38,
                                fontSize: 12,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        ElevatedButton.icon(
                          onPressed: _pickTemplateFile,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white10,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          icon: const Icon(Icons.file_upload_outlined, size: 18),
                          label: const Text('PILIH PNG', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Checklist User Booth
                    const Text(
                      'TUGASKAN KE USER BOOTH',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white30, letterSpacing: 1),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 180),
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(11),
                        child: _isLoadingBoothUsers
                            ? const Center(child: CircularProgressIndicator(color: Colors.white))
                            : _boothUsersList.isEmpty
                                ? const Center(
                                    child: Padding(
                                      padding: EdgeInsets.all(16.0),
                                      child: Text(
                                        'Tidak ada akun booth terdaftar!',
                                        style: TextStyle(color: Colors.white38, fontSize: 12),
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
                                        activeColor: Colors.white,
                                        checkColor: Colors.black,
                                        title: Text(
                                          name,
                                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                                        ),
                                        subtitle: Text(
                                          alamat,
                                          style: const TextStyle(color: Colors.white38, fontSize: 11),
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
                    const SizedBox(height: 32),
                    const Divider(color: Colors.white24),
                    const SizedBox(height: 24),

                    // Manual Coordinates Info/Guide
                    const Text(
                      'PETUNJUK EDITOR:',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white30, letterSpacing: 1),
                    ),
                    const SizedBox(height: 8),
                    const BulletPoint(text: 'Geser/drag box berwarna untuk memindahkan posisi slot foto.'),
                    const BulletPoint(text: 'Tarik lingkaran putih kecil di ujung kanan-bawah box untuk mengubah ukuran slot.'),
                    const BulletPoint(text: 'Gunakan PNG transparan agar foto di belakangnya terlihat.'),
                    const SizedBox(height: 48),

                    // Action Buttons (Save/Cancel)
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _cancelEditingTemplate,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.redAccent,
                              side: const BorderSide(color: Colors.redAccent, width: 0.5),
                              padding: const EdgeInsets.symmetric(vertical: 18),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
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
                              backgroundColor: Colors.white,
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(vertical: 18),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
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
                newX.clamp(0.0, 1.0 - w),
                newY.clamp(0.0, 1.0 - h),
                w,
                h,
              );
            },
            child: Container(
              decoration: BoxDecoration(
                color: color.withAlpha(20),
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
                newW.clamp(0.05, 1.0 - x),
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
          const Text('• ', style: TextStyle(color: Colors.white54, fontSize: 13)),
          Expanded(child: Text(text, style: const TextStyle(color: Colors.white54, fontSize: 12))),
        ],
      ),
    );
  }
}

class ImageCropDialog extends StatefulWidget {
  final Uint8List imageBytes;
  const ImageCropDialog({super.key, required this.imageBytes});

  @override
  State<ImageCropDialog> createState() => _ImageCropDialogState();
}

class _ImageCropDialogState extends State<ImageCropDialog> {
  img.Image? _decodedImage;
  bool _isDecoding = true;

  // Crop frame dimensions in absolute pixels relative to display container
  double cropLeft = 0;
  double cropTop = 0;
  double cropWidth = 100;
  double cropHeight = 100;

  bool _initialized = false;
  bool _isCropping = false;

  double containerW = 0;
  double containerH = 0;

  @override
  void initState() {
    super.initState();
    _decodeImage();
  }

  Future<void> _decodeImage() async {
    try {
      final decoded = img.decodeImage(widget.imageBytes);
      if (decoded != null) {
        // Automatically make sure the image is in PNG format internally
        // (the image library handles it when we re-encode to PNG)
      }
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
          const SnackBar(content: Text('Gagal membaca gambar PNG'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  void _initCropBox(double displayW, double displayH) {
    if (_initialized) return;
    _initialized = true;

    final double targetRatio = 11.5 / 14.7;
    final double imgRatio = displayW / displayH;

    if (imgRatio > targetRatio) {
      cropHeight = displayH * 0.9;
      cropWidth = cropHeight * targetRatio;
      cropLeft = (displayW - cropWidth) / 2;
      cropTop = (displayH - cropHeight) / 2;
    } else {
      cropWidth = displayW * 0.9;
      cropHeight = cropWidth / targetRatio;
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
        final int cropH = (cropHeight * scaleY).round().clamp(1, _decodedImage!.height - cropY);

        final croppedImage = img.copyCrop(
          _decodedImage!,
          x: cropX,
          y: cropY,
          width: cropW,
          height: cropH,
        );

        // Downscale image if it is too high resolution to prevent MySQL max_allowed_packet socket errors
        var finalImage = croppedImage;
        if (croppedImage.height > 1200) {
          finalImage = img.copyResize(croppedImage, height: 1200);
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
            SnackBar(content: Text('Gagal melakukan crop: $e'), backgroundColor: Colors.redAccent),
          );
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF161616),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Container(
        width: 800,
        height: 650,
        padding: const EdgeInsets.all(28),
        child: _isDecoding
            ? const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 16),
                    Text('Mendekode gambar PNG...', style: TextStyle(color: Colors.white70)),
                  ],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'CROP TEMPLATE OVERLAY (A6)',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              letterSpacing: 1,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Sesuaikan bingkai ke rasio 11.5 cm x 14.7 cm (A6 Portrait)',
                            style: TextStyle(fontSize: 12, color: Colors.white54),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white60),
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
                                        border: Border.all(color: Colors.white, width: 2),
                                        color: Colors.transparent,
                                      ),
                                      child: const Center(
                                        child: Icon(Icons.drag_indicator, color: Colors.white54, size: 24),
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
                                        final double newHeight = newWidth / (11.5 / 14.7);
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
                                          color: Colors.white,
                                          shape: BoxShape.circle,
                                          boxShadow: [
                                            BoxShadow(color: Colors.black38, blurRadius: 4, offset: Offset(0, 2)),
                                          ],
                                        ),
                                        child: const Center(
                                          child: Icon(Icons.open_in_full, size: 12, color: Colors.black),
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
                          foregroundColor: Colors.white70,
                          side: const BorderSide(color: Colors.white24),
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('Batal'),
                      ),
                      const SizedBox(width: 16),
                      ElevatedButton(
                        onPressed: _isCropping ? null : () => _onCropConfirmed(containerW, containerH),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: _isCropping
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2),
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
