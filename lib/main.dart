import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:csv/csv.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:file_picker/file_picker.dart';
import 'ocr_service.dart';
import 'models/absence_record.dart';
import 'services/storage_service.dart';

void main() {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
  };
  runApp(const AbsenceScannerApp());
}

class AbsenceScannerApp extends StatelessWidget {
  const AbsenceScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Scan d'Absences",
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF00BFA6),
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF161B22),
          elevation: 0,
          centerTitle: true,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF161B22),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 4,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 0.5),
          ),
        ),
      ),
      home: const ScannerScreen(),
    );
  }
}

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen>
    with SingleTickerProviderStateMixin {
  final OCRService _ocrService = OCRService();
  final ImagePicker _picker = ImagePicker();
  final StorageService _storageService = StorageService();

  bool _isProcessing = false;
  bool _isModelLoading = false;
  List<StudentAbsence> _students = [];
  String _rawText = '';
  File? _selectedImage;
  List<WeeklyScanSession> _history = [];
  String _searchQuery = '';
  bool _showOnlyAbsences = false;

  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _loadHistory();
  }

  @override
  void dispose() {
    _ocrService.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final history = await _storageService.loadHistory();
    setState(() => _history = history);
  }

  Future<void> _saveToHistory(WeeklyScanSession session) async {
    await _storageService.saveToHistory(session);
    _loadHistory();
  }

  void _deleteHistoryItem(int index) async {
    await _storageService.deleteHistoryItem(index);
    _loadHistory();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Élément supprimé')),
      );
    }
  }

  void _clearHistory() async {
    await _storageService.clearHistory();
    setState(() => _history = []);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Historique effacé')),
      );
    }
  }

  Future<void> _exportHistory() async {
    try {
      final path = await _storageService.exportHistoryToJson();
      await Share.shareXFiles([XFile(path)], subject: 'Export absences');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Export réussi')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export échoué: $e')),
        );
      }
    }
  }

  Future<void> _importHistory() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      
      if (result != null && result.files.single.path != null) {
        final count = await _storageService.importHistoryFromJson(result.files.single.path!);
        _loadHistory();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$count éléments importés')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import échoué: $e')),
        );
      }
    }
  }

  Future<void> _pickAndScan() async {
    final source = await _showImageSourceSheet();
    if (source == null) return;

    final XFile? pickedFile = await _picker.pickImage(
      source: source,
      imageQuality: 90,
    );
    if (pickedFile == null) return;

    setState(() {
      _isProcessing = true;
      _isModelLoading = true;
      _students = [];
      _rawText = '';
      _selectedImage = File(pickedFile.path);
    });

    try {
      await Future.delayed(const Duration(milliseconds: 600));
      setState(() => _isModelLoading = false);

      final recognizedText = await _ocrService.extractText(_selectedImage!);
      final students = _ocrService.findWeeklyAbsences(recognizedText);

      setState(() {
        _rawText = recognizedText.text;
        _students = students;
        _isProcessing = false;
      });

      if (_students.isNotEmpty) {
        _showVerificationScreen();
      }
    } catch (e) {
      setState(() => _isProcessing = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Échec de l'OCR : $e"),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  void _showVerificationScreen() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => VerificationScreen(
          students: List.from(_students),
          image: _selectedImage,
          rawText: _rawText,
          onSave: (students) {
            setState(() => _students = students);
            final session = WeeklyScanSession(
              scanDate: DateTime.now(),
              students: students,
              rawText: _rawText,
            );
            _saveToHistory(session);
          },
          onCancel: () {
            setState(() {
              _students = [];
              _rawText = '';
              _selectedImage = null;
            });
          },
        ),
      ),
    );
  }

  Future<void> _shareResults() async {
    if (_students.isEmpty) return;
    final buffer = StringBuffer();
    buffer.writeln('Absences hebdomadaire');
    buffer.writeln('Durée par case: 150 min (2h30)');
    buffer.writeln('');

    for (final student in _students) {
      if (!student.hasAnyAbsence) continue;
      final total = student.formatTotalDuration();
      buffer.writeln('${student.number}. ${student.name} - $total');
      for (final day in student.week) {
        final mins = day.getTotalMinutes();
        if (mins > 0) {
          final hours = mins ~/ 60;
          final min = mins % 60;
          final duration = hours > 0 ? '${hours}h ${min}min' : '${min}min';
          buffer.writeln('   ${day.dayName}: $duration (${day.getDisplayMarks()})');
        }
      }
      buffer.writeln('');
    }

    await Share.share(buffer.toString(), subject: "Absences Hebdomadaire");
  }

  Future<void> _exportToCsv() async {
    if (_students.isEmpty) return;
    
    final rows = <List<dynamic>>[
      ['N°', 'Nom', 'LUN', 'MAR', 'MER', 'JEU', 'VEN', 'SAM', 'Total Heures'],
    ];
    
    for (final student in _students) {
      final row = <dynamic>[
        student.number,
        student.name,
      ];
      
      for (final day in student.week) {
        row.add(day.markedCount > 0 ? '${day.markedCount}x (${day.getDisplayMarks()})' : '-');
      }
      
      final total = student.formatTotalDuration();
      row.add(total);
      
      rows.add(row);
    }
    
    final csv = const ListToCsvConverter().convert(rows);
    final directory = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final file = File('${directory.path}/absences_$timestamp.csv');
    await file.writeAsString(csv);
    
    await Share.shareXFiles([XFile(file.path)], subject: 'Export CSV');
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Export CSV réussi')),
      );
    }
  }

  Future<void> _exportToPdf() async {
    if (_students.isEmpty) return;
    
    final pdf = pw.Document();
    
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Header(
                level: 0,
                child: pw.Text('Feuille d\'Absences Hebdomadaire', 
                  style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
              ),
              pw.SizedBox(height: 10),
              pw.Text('Date: ${DateTime.now().day}/${DateTime.now().month}/${DateTime.now().year}'),
              pw.Text('Durée par case: 2h30 (150 min)'),
              pw.SizedBox(height: 20),
              pw.Table.fromTextArray(
                headers: ['N°', 'Nom', 'LUN', 'MAR', 'MER', 'JEU', 'VEN', 'SAM', 'Total'],
                data: _students.where((s) => s.hasAnyAbsence).map((student) {
                  return [
                    student.number.toString(),
                    student.name,
                    student.week[0].markedCount.toString(),
                    student.week[1].markedCount.toString(),
                    student.week[2].markedCount.toString(),
                    student.week[3].markedCount.toString(),
                    student.week[4].markedCount.toString(),
                    student.week[5].markedCount.toString(),
                    student.formatTotalDuration(),
                  ];
                }).toList(),
              ),
            ],
          );
        },
      ),
    );
    
    final directory = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final file = File('${directory.path}/absences_$timestamp.pdf');
    await file.writeAsBytes(await pdf.save());
    
    await Share.shareXFiles([XFile(file.path)], subject: 'Export PDF');
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Export PDF réussi')),
      );
    }
  }

  void _showStatistics() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _StatisticsSheet(students: _students, history: _history),
    );
  }

  Future<ImageSource?> _showImageSourceSheet() async {
    return showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Choisir la source',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
                ),
                const SizedBox(height: 20),
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00BFA6).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.camera_alt_rounded, color: Color(0xFF00BFA6)),
                  ),
                  title: const Text('Prendre une photo', style: TextStyle(color: Colors.white)),
                  onTap: () => Navigator.pop(ctx, ImageSource.camera),
                ),
                const SizedBox(height: 8),
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF448AFF).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.photo_library_rounded, color: Color(0xFF448AFF)),
                  ),
                  title: const Text('Choisir dans la galerie', style: TextStyle(color: Colors.white)),
                  onTap: () => Navigator.pop(ctx, ImageSource.gallery),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showDataManagement() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Gestion des données',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
              ),
              const SizedBox(height: 20),
              ListTile(
                leading: const Icon(Icons.upload_rounded, color: Color(0xFF00BFA6)),
                title: const Text('Exporter l\'historique', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _exportHistory();
                },
              ),
              ListTile(
                leading: const Icon(Icons.download_rounded, color: Color(0xFF448AFF)),
                title: const Text('Importer un fichier', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _importHistory();
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_sweep_rounded, color: Colors.redAccent),
                title: const Text('Effacer l\'historique', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _clearHistory();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<StudentAbsence> get _filteredStudents {
    var list = _students.where((s) {
      if (_searchQuery.isNotEmpty) {
        return s.name.toLowerCase().contains(_searchQuery.toLowerCase());
      }
      return true;
    }).where((s) {
      if (_showOnlyAbsences) {
        return s.hasAnyAbsence;
      }
      return true;
    }).toList();
    
    list.sort((a, b) => a.number.compareTo(b.number));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final hasResults = _students.isNotEmpty || _rawText.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.document_scanner_rounded, size: 22),
            SizedBox(width: 10),
            Text("Scan d'Absences", style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.5)),
          ],
        ),
        actions: [
          if (hasResults) ...[
            IconButton(
              icon: const Icon(Icons.bar_chart_rounded),
              tooltip: 'Statistiques',
              onPressed: _showStatistics,
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (value) {
                switch (value) {
                  case 'csv':
                    _exportToCsv();
                    break;
                  case 'pdf':
                    _exportToPdf();
                    break;
                  case 'share':
                    _shareResults();
                    break;
                }
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem(value: 'csv', child: Text('Exporter CSV')),
                const PopupMenuItem(value: 'pdf', child: Text('Exporter PDF')),
                const PopupMenuItem(value: 'share', child: Text('Partager')),
              ],
            ),
          ],
          IconButton(
            icon: const Icon(Icons.settings_rounded),
            tooltip: 'Gestion données',
            onPressed: _showDataManagement,
          ),
        ],
      ),
      body: SafeArea(
        child: _isProcessing ? _buildLoadingView() : _buildContentView(),
      ),
    );
  }

  Widget _buildLoadingView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, child) {
              return Transform.scale(
                scale: 1.0 + (_pulseController.value * 0.15),
                child: child,
              );
            },
            child: Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [
                  const Color(0xFF00BFA6).withValues(alpha: 0.3),
                  const Color(0xFF448AFF).withValues(alpha: 0.3),
                ]),
              ),
              child: const Icon(Icons.document_scanner_rounded, size: 48, color: Color(0xFF00BFA6)),
            ),
          ),
          const SizedBox(height: 28),
          Text(
            _isModelLoading
                ? 'Téléchargement du modèle OCR…'
                : 'Analyse en cours…',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white70),
          ),
          if (!_isModelLoading) ...[
            const SizedBox(height: 12),
            const SizedBox(
              width: 140,
              child: LinearProgressIndicator(
                backgroundColor: Color(0xFF1E252E),
                color: Color(0xFF00BFA6),
                minHeight: 3,
              ),
            ),
          ],
          if (_isModelLoading) ...[
            const SizedBox(height: 12),
            const Text(
              'Première utilisation : téléchargement\ndu modèle de reconnaissance…',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.white38),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildContentView() {
    final hasResults = _students.isNotEmpty || _rawText.isNotEmpty;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      physics: const BouncingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_selectedImage != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.file(
                _selectedImage!,
                height: 180,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: 16),
          ],

          if (!hasResults) ...[
            const SizedBox(height: 60),
            _buildHeroSection(),
          ],

          _buildScanButton(),
          const SizedBox(height: 24),

          if (hasResults) ...[
            _buildInfoBar(),
            const SizedBox(height: 16),
            _buildSearchBar(),
            const SizedBox(height: 12),
            _buildStudentsCard(),
            const SizedBox(height: 16),
            _buildRawTextCard(),
          ],

          if (_history.isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildHistoryCard(),
          ],
        ],
      ),
    );
  }

  Widget _buildHeroSection() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFF00BFA6).withValues(alpha: 0.2),
                const Color(0xFF448AFF).withValues(alpha: 0.2),
              ],
            ),
          ),
          child: const Icon(Icons.document_scanner_rounded, size: 64, color: Color(0xFF00BFA6)),
        ),
        const SizedBox(height: 24),
        const Text(
          "Scanner une feuille d'absences",
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.5, color: Colors.white),
        ),
        const SizedBox(height: 10),
        const Text(
          'Prenez une photo ou Choose une image\npour détecter les élèves absents.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, color: Colors.white54, height: 1.5),
        ),
        const SizedBox(height: 40),
      ],
    );
  }

  Widget _buildScanButton() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(colors: [Color(0xFF00BFA6), Color(0xFF448AFF)]),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00BFA6).withValues(alpha: 0.35),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ElevatedButton.icon(
        onPressed: _pickAndScan,
        icon: Icon(
          _students.isEmpty ? Icons.document_scanner_rounded : Icons.refresh_rounded,
          size: 22,
        ),
        label: Text(_students.isEmpty ? 'Scanner' : 'Scanner à nouveau'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 54),
        ),
      ),
    );
  }

  Widget _buildInfoBar() {
    final absentCount = _students.where((s) => s.hasAnyAbsence).length;
    final totalMinutes = _students.fold(0, (sum, s) => sum + s.getTotalMinutes());
    final totalHours = totalMinutes ~/ 60;
    final totalMins = totalMinutes % 60;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildInfoItem(Icons.people_rounded, '$absentCount', 'Absents'),
            Container(width: 1, height: 40, color: Colors.white12),
            _buildInfoItem(Icons.timer_rounded, '${totalHours}h ${totalMins}min', 'Total'),
            Container(width: 1, height: 40, color: Colors.white12),
            _buildInfoItem(Icons.access_time_rounded, '2h30', 'Par case'),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoItem(IconData icon, String value, String label) {
    return Column(
      children: [
        Icon(icon, color: const Color(0xFF00BFA6), size: 24),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.white54)),
      ],
    );
  }

  Widget _buildSearchBar() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            onChanged: (value) => setState(() => _searchQuery = value),
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Rechercher un élève...',
              hintStyle: const TextStyle(color: Colors.white38),
              prefixIcon: const Icon(Icons.search, color: Colors.white38),
              filled: true,
              fillColor: const Color(0xFF161B22),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
          ),
        ),
        const SizedBox(width: 12),
        GestureDetector(
          onTap: () => setState(() => _showOnlyAbsences = !_showOnlyAbsences),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _showOnlyAbsences ? const Color(0xFFFF5252) : const Color(0xFF161B22),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _showOnlyAbsences ? Colors.transparent : Colors.white12),
            ),
            child: Icon(
              Icons.filter_list_rounded,
              color: _showOnlyAbsences ? Colors.white : Colors.white54,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStudentsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _students.any((s) => s.hasAnyAbsence)
                        ? const Color(0xFFFF5252).withValues(alpha: 0.15)
                        : const Color(0xFF00E676).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    _students.any((s) => s.hasAnyAbsence)
                        ? Icons.person_off_rounded
                        : Icons.check_circle_outline_rounded,
                    color: _students.any((s) => s.hasAnyAbsence)
                        ? const Color(0xFFFF5252)
                        : const Color(0xFF00E676),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _filteredStudents.isNotEmpty && _filteredStudents.any((s) => s.hasAnyAbsence)
                        ? 'Élèves absents (${_filteredStudents.where((s) => s.hasAnyAbsence).length})'
                        : 'Aucune absence détectée',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                ),
              ],
            ),
            if (_filteredStudents.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Divider(color: Colors.white12, height: 1),
              const SizedBox(height: 8),
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _filteredStudents.length,
                separatorBuilder: (context, index) => const Divider(color: Colors.white12, height: 1),
                itemBuilder: (context, index) {
                  final student = _filteredStudents[index];
                  return _StudentListItem(
                    student: student,
                    onTap: () => _showStudentDetail(student),
                    onTogglePresence: () {
                      setState(() {
                        if (student.hasAnyAbsence) {
                          student.markAllPresent();
                        } else {
                          student.markAllAbsent();
                        }
                      });
                    },
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showStudentDetail(StudentAbsence student) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _StudentDetailSheet(
        student: student,
        onSlotToggle: (dayIndex, slotIndex) {
          student.toggleSlot(dayIndex, slotIndex);
          setState(() {});
        },
        onDayToggle: (dayIndex) {
          student.toggleDay(dayIndex);
          setState(() {});
        },
      ),
    );
  }

  Widget _buildRawTextCard() {
    return Card(
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 20),
        childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFF448AFF).withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.text_snippet_rounded, color: Color(0xFF448AFF), size: 20),
        ),
        title: const Text('Texte OCR brut', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
        iconColor: Colors.white54,
        collapsedIconColor: Colors.white54,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF0D1117),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white12),
            ),
            child: SelectableText(
              _rawText.isNotEmpty ? _rawText : '(aucun texte détecté)',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13, color: Colors.white70, height: 1.6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryCard() {
    return Card(
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 20),
        childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFF00BFA6).withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.history_rounded, color: Color(0xFF00BFA6), size: 20),
        ),
        title: Row(
          children: [
            const Expanded(
              child: Text('Historique', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
            ),
            GestureDetector(
              onTap: _clearHistory,
              child: const Text('Effacer', style: TextStyle(fontSize: 13, color: Colors.white38)),
            ),
          ],
        ),
        iconColor: Colors.white54,
        collapsedIconColor: Colors.white54,
        children: _history.take(5).toList().asMap().entries.map((entry) {
          final index = entry.key;
          final session = entry.value;
          final date = session.scanDate;
          final dateStr = '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
          final absentCount = session.studentsWithAbsences;
          final totalMinutes = session.getTotalAbsenceMinutes();
          final totalHours = totalMinutes ~/ 60;
          
          return Dismissible(
            key: ValueKey('history_$index'),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 16),
              child: const Icon(Icons.delete_outline, color: Color(0xFFFF5252)),
            ),
            onDismissed: (_) => _deleteHistoryItem(index),
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                radius: 14,
                backgroundColor: const Color(0xFFFF5252).withValues(alpha: 0.15),
                child: Text(
                  '$absentCount',
                  style: const TextStyle(color: Color(0xFFFF5252), fontSize: 11, fontWeight: FontWeight.w700),
                ),
              ),
              title: Text(
                session.students.where((s) => s.hasAnyAbsence).map((s) => s.name).join(', '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              subtitle: Text('$dateStr | ${totalHours}h', style: const TextStyle(color: Colors.white38, fontSize: 11)),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _StudentListItem extends StatelessWidget {
  final StudentAbsence student;
  final VoidCallback onTap;
  final VoidCallback onTogglePresence;

  const _StudentListItem({
    required this.student,
    required this.onTap,
    required this.onTogglePresence,
  });

  @override
  Widget build(BuildContext context) {
    final hasAbsence = student.hasAnyAbsence;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: GestureDetector(
        onTap: onTogglePresence,
        child: Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
            color: hasAbsence ? const Color(0xFFFF5252).withValues(alpha: 0.2) : const Color(0xFF00E676).withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            hasAbsence ? Icons.close_rounded : Icons.check_rounded,
            color: hasAbsence ? const Color(0xFFFF5252) : const Color(0xFF00E676),
            size: 18,
          ),
        ),
      ),
      title: Text(
        '${student.number}. ${student.name}',
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500, fontSize: 15),
      ),
      subtitle: hasAbsence
          ? Text(
              student.formatTotalDuration(),
              style: const TextStyle(color: Color(0xFFFF5252), fontSize: 12),
            )
          : null,
      trailing: hasAbsence
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFFF5252).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                student.formatTotalDuration(),
                style: const TextStyle(
                  color: Color(0xFFFF5252),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          : null,
      onTap: onTap,
    );
  }
}

class _StudentDetailSheet extends StatelessWidget {
  final StudentAbsence student;
  final Function(int dayIndex, int slotIndex) onSlotToggle;
  final Function(int dayIndex) onDayToggle;

  const _StudentDetailSheet({
    required this.student,
    required this.onSlotToggle,
    required this.onDayToggle,
  });

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.5,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: const Color(0xFFFF5252).withValues(alpha: 0.15),
                  child: Text(
                    '${student.number}',
                    style: const TextStyle(color: Color(0xFFFF5252), fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(student.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
                      Text(student.formatTotalDuration(), style: const TextStyle(color: Color(0xFFFF5252), fontSize: 14)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: 6,
                itemBuilder: (context, dayIndex) {
                  final day = student.week[dayIndex];
                  final dayMinutes = day.getTotalMinutes();
                  final isAbsent = dayMinutes > 0;

                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isAbsent ? const Color(0xFFFF5252).withValues(alpha: 0.1) : Colors.white.withValues(alpha: 0.03),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isAbsent ? const Color(0xFFFF5252).withValues(alpha: 0.3) : Colors.white12,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        GestureDetector(
                          onTap: () => onDayToggle(dayIndex),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                day.dayName,
                                style: TextStyle(
                                  color: isAbsent ? const Color(0xFFFF5252) : Colors.white54,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16,
                                ),
                              ),
                              Text(
                                isAbsent ? '${dayMinutes ~/ 60}h ${dayMinutes % 60}min' : 'Present',
                                style: TextStyle(
                                  color: isAbsent ? const Color(0xFFFF5252) : Colors.white38,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: List.generate(4, (slotIndex) {
                            final slot = day.slots[slotIndex];
                            return Expanded(
                              child: GestureDetector(
                                onTap: () => onSlotToggle(dayIndex, slotIndex),
                                child: Container(
                                  margin: const EdgeInsets.symmetric(horizontal: 2),
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  decoration: BoxDecoration(
                                    color: slot.isMarked
                                        ? const Color(0xFFFF5252).withValues(alpha: 0.3)
                                        : Colors.white.withValues(alpha: 0.05),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: slot.isMarked
                                          ? const Color(0xFFFF5252)
                                          : Colors.white12,
                                    ),
                                  ),
                                  child: Center(
                                    child: Text(
                                      slot.isMarked ? (slot.markType.isEmpty ? 'X' : slot.markType) : '-',
                                      style: TextStyle(
                                        color: slot.isMarked ? const Color(0xFFFF5252) : Colors.white38,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatisticsSheet extends StatelessWidget {
  final List<StudentAbsence> students;
  final List<WeeklyScanSession> history;

  const _StatisticsSheet({required this.students, required this.history});

  @override
  Widget build(BuildContext context) {
    final absentStudents = students.where((s) => s.hasAnyAbsence).toList();
    final totalMinutes = students.fold(0, (sum, s) => sum + s.getTotalMinutes());
    final totalHours = totalMinutes ~/ 60;
    final totalMins = totalMinutes % 60;
    
    final sortedByAbsence = List<StudentAbsence>.from(absentStudents)
      ..sort((a, b) => b.getTotalMinutes().compareTo(a.getTotalMinutes()));

    final Map<String, int> dayStats = {};
    for (final dayName in ['LUN', 'MAR', 'MER', 'JEU', 'VEN', 'SAM']) {
      dayStats[dayName] = 0;
    }
    for (final student in students) {
      for (final day in student.week) {
        dayStats[day.dayName] = (dayStats[day.dayName] ?? 0) + day.markedCount;
      }
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text('Statistiques', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Colors.white)),
            const SizedBox(height: 20),
            
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatCard('${absentStudents.length}', 'Absents', const Color(0xFFFF5252)),
                _buildStatCard('${totalHours}h ${totalMins}min', 'Total', const Color(0xFF00BFA6)),
                _buildStatCard('${students.length}', 'Total eleves', const Color(0xFF448AFF)),
              ],
            ),
            
            const SizedBox(height: 24),
            const Text('Absences par jour', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white)),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: dayStats.entries.map((e) => _buildDayStat(e.key, e.value)).toList(),
            ),
            
            const SizedBox(height: 24),
            if (sortedByAbsence.isNotEmpty) ...[
              const Text('Top absents', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white)),
              const SizedBox(height: 12),
              ...sortedByAbsence.take(5).map((s) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('${s.number}. ${s.name}', style: const TextStyle(color: Colors.white70)),
                    Text(s.formatTotalDuration(), style: const TextStyle(color: Color(0xFFFF5252), fontWeight: FontWeight.w600)),
                  ],
                ),
              )),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard(String value, String label, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: color)),
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.white54)),
        ],
      ),
    );
  }

  Widget _buildDayStat(String day, int count) {
    return Column(
      children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: count > 0 ? const Color(0xFFFF5252).withValues(alpha: 0.2) : Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Text('$count', style: TextStyle(color: count > 0 ? const Color(0xFFFF5252) : Colors.white38, fontWeight: FontWeight.w600)),
          ),
        ),
        const SizedBox(height: 4),
        Text(day, style: const TextStyle(fontSize: 11, color: Colors.white54)),
      ],
    );
  }
}

class VerificationScreen extends StatefulWidget {
  final List<StudentAbsence> students;
  final File? image;
  final String rawText;
  final Function(List<StudentAbsence>) onSave;
  final VoidCallback onCancel;

  const VerificationScreen({
    super.key,
    required this.students,
    this.image,
    required this.rawText,
    required this.onSave,
    required this.onCancel,
  });

  @override
  State<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends State<VerificationScreen> {
  late List<StudentAbsence> _students;

  @override
  void initState() {
    super.initState();
    _students = widget.students;
  }

  @override
  Widget build(BuildContext context) {
    final absentCount = _students.where((s) => s.hasAnyAbsence).length;
    final totalMinutes = _students.fold(0, (sum, s) => sum + s.getTotalMinutes());

    return Scaffold(
      appBar: AppBar(
        title: const Text('Vérification'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () {
            Navigator.pop(context);
            widget.onCancel();
          },
        ),
        actions: [
          TextButton(
            onPressed: () {
              for (var student in _students) {
                student.markAllPresent();
              }
              setState(() {});
            },
            child: const Text('Tout present', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              for (var student in _students) {
                student.markAllAbsent();
              }
              setState(() {});
            },
            child: const Text('Tout absent', style: TextStyle(color: Color(0xFFFF5252))),
          ),
        ],
      ),
      body: Column(
        children: [
          if (widget.image != null)
            Container(
              height: 150,
              width: double.infinity,
              decoration: BoxDecoration(
                image: DecorationImage(
                  image: FileImage(widget.image!),
                  fit: BoxFit.cover,
                ),
              ),
            ),
          Container(
            padding: const EdgeInsets.all(16),
            color: const Color(0xFF161B22),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStat('$absentCount', 'Absents', const Color(0xFFFF5252)),
                _buildStat('${totalMinutes ~/ 60}h ${totalMinutes % 60}min', 'Total', const Color(0xFF00BFA6)),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _students.length,
              itemBuilder: (context, index) {
                final student = _students[index];
                return _VerificationStudentCard(
                  student: student,
                  onToggleSlot: (dayIndex, slotIndex) {
                    student.toggleSlot(dayIndex, slotIndex);
                    setState(() {});
                  },
                  onDayToggle: (dayIndex) {
                    student.toggleDay(dayIndex);
                    setState(() {});
                  },
                  onTogglePresence: () {
                    if (student.hasAnyAbsence) {
                      student.markAllPresent();
                    } else {
                      student.markAllAbsent();
                    }
                    setState(() {});
                  },
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        Navigator.pop(context);
                        widget.onCancel();
                      },
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        side: const BorderSide(color: Colors.white24),
                      ),
                      child: const Text('Annuler', style: TextStyle(color: Colors.white70)),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        widget.onSave(_students);
                        Navigator.pop(context);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00BFA6),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: const Text('Confirmer', style: TextStyle(color: Colors.white)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStat(String value, String label, Color color) {
    return Column(
      children: [
        Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: color)),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.white54)),
      ],
    );
  }
}

class _VerificationStudentCard extends StatelessWidget {
  final StudentAbsence student;
  final Function(int dayIndex, int slotIndex) onToggleSlot;
  final Function(int dayIndex) onDayToggle;
  final VoidCallback onTogglePresence;

  const _VerificationStudentCard({
    required this.student,
    required this.onToggleSlot,
    required this.onDayToggle,
    required this.onTogglePresence,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                GestureDetector(
                  onTap: onTogglePresence,
                  child: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: student.hasAnyAbsence ? const Color(0xFFFF5252) : const Color(0xFF00E676),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(
                      child: Text(
                        '${student.number}',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(student.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white)),
                      Text(student.formatTotalDuration(), style: const TextStyle(fontSize: 14, color: Color(0xFFFF5252))),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: List.generate(6, (dayIndex) {
                final day = student.week[dayIndex];
                final isAbsent = day.hasAbsence;

                return GestureDetector(
                  onTap: () => onDayToggle(dayIndex),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isAbsent ? const Color(0xFFFF5252).withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: isAbsent ? const Color(0xFFFF5252).withValues(alpha: 0.3) : Colors.white12),
                    ),
                    child: Column(
                      children: [
                        Text(day.dayName, style: TextStyle(color: isAbsent ? const Color(0xFFFF5252) : Colors.white54, fontSize: 12, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: List.generate(4, (slotIndex) {
                            final slot = day.slots[slotIndex];
                            return GestureDetector(
                              onTap: () => onToggleSlot(dayIndex, slotIndex),
                              child: Container(
                                width: 20, height: 20,
                                margin: const EdgeInsets.symmetric(horizontal: 1),
                                decoration: BoxDecoration(
                                  color: slot.isMarked ? const Color(0xFFFF5252) : Colors.transparent,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: slot.isMarked ? const Color(0xFFFF5252) : Colors.white24),
                                ),
                                child: Center(
                                  child: Text(
                                    slot.isMarked ? (slot.markType.isEmpty ? 'X' : slot.markType) : '-',
                                    style: TextStyle(fontSize: 10, color: slot.isMarked ? Colors.white : Colors.white38),
                                  ),
                                ),
                              ),
                            );
                          }),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}