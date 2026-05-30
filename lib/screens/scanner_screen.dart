import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:csv/csv.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../ocr_service.dart';
import '../models/absence_record.dart';
import '../models/class_model.dart';
import '../models/profile.dart';
import '../services/absence_repository.dart';
import 'auth_gate.dart';

String _cleanError(Object e) {
  final s = e.toString();
  return s.startsWith('Exception: ') ? s.substring(11) : s;
}

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen>
    with SingleTickerProviderStateMixin {
  late OCRService _ocrService;
  final ImagePicker _picker = ImagePicker();
  final AbsenceRepository _repository = AbsenceRepository();

  Profile? _profile;
  List<ClassModel> _classes = [];
  ClassModel? _selectedClass;

  bool _isProcessing = false;
  bool _isExporting = false;
  List<StudentAbsence> _students = [];
  String _rawText = '';
  File? _selectedImage;
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
    _ocrService = OCRService();
    _loadProfileAndClasses();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _loadProfileAndClasses() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    try {
      final profileResponse = await Supabase.instance.client
          .from('profiles')
          .select()
          .eq('id', user.id)
          .single();

      _profile = Profile.fromJson(profileResponse);

      final classes = await _repository.loadClasses(_profile!.schoolId);
      if (mounted) {
        setState(() {
          _classes = classes;
          if (classes.isNotEmpty) {
            _selectedClass = classes.first;
          }
        });
        _loadHistory();
      }
    } catch (e) {
      debugPrint('Error loading profile: $e');
    }
  }

  Future<void> _loadHistory() async {
    if (_profile == null) return;
    await _repository.loadHistory(_profile!.schoolId);
    if (mounted) setState(() {});
  }

  void _showSnackBar(String message, {Color? backgroundColor}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: backgroundColor),
    );
  }

  Future<void> _pickAndScan() async {
    if (_selectedClass == null) {
      _showSnackBar('Veuillez sélectionner une classe', backgroundColor: Colors.orange);
      return;
    }

    final source = await _showImageSourceSheet();
    if (source == null) return;

    final XFile? pickedFile = await _picker.pickImage(
      source: source,
      imageQuality: 90,
    );
    if (pickedFile == null) return;

    setState(() {
      _isProcessing = true;
      _students = [];
      _rawText = '';
      _selectedImage = File(pickedFile.path);
    });

    try {
      final result = await _ocrService.analyzeSheet(_selectedImage!);

      if (!mounted) return;
      setState(() {
        _rawText = result.rawText;
        _students = result.students;
        _isProcessing = false;
      });

      if (_students.isNotEmpty) {
        _showVerificationScreen();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isProcessing = false);
      _showSnackBar(
        "Échec de l'analyse : ${_cleanError(e)}",
        backgroundColor: Colors.redAccent,
      );
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
          onSave: (students) async {
            setState(() => _students = students);

            if (_profile == null || _selectedClass == null) return;

            final user = Supabase.instance.client.auth.currentUser;
            if (user == null) return;

            final result = ScanResult(
              scannedDate: DateTime.now().toIso8601String(),
              totalStudentsCount: students.length,
              students: students,
              rawText: _rawText,
            );

            final logId = await _repository.saveScan(
              schoolId: _profile!.schoolId,
              classId: _selectedClass!.id,
              teacherId: user.id,
              scanResult: result,
            );

            if (logId != null) {
              _showSnackBar('Scan enregistré', backgroundColor: const Color(0xFF00BFA6));
              _loadHistory();
            } else {
              _showSnackBar('Erreur lors de l\'enregistrement', backgroundColor: Colors.redAccent);
            }
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
    try {
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

      await SharePlus.instance.share(ShareParams(text: buffer.toString(), subject: "Absences Hebdomadaire"));
    } catch (e) {
      _showSnackBar('Partage échoué: ${_cleanError(e)}', backgroundColor: Colors.redAccent);
    }
  }

  Future<void> _exportDetailedCsv() async {
    if (_students.isEmpty) return;
    try {
      final rows = <List<dynamic>>[
        ['N°', 'Nom', 'LUN', 'MAR', 'MER', 'JEU', 'VEN', 'SAM', 'Total Heures'],
      ];

      for (final student in _students) {
        final row = <dynamic>[student.number, student.name];
        for (final day in student.week) {
          row.add(day.markedCount > 0 ? '${day.markedCount}x (${day.getDisplayMarks()})' : '-');
        }
        row.add(student.formatTotalDuration());
        rows.add(row);
      }

      final csv = const CsvEncoder().convert(rows);
      final directory = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final file = File('${directory.path}/absences_$timestamp.csv');
      await file.writeAsString(csv);

      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], subject: 'Export CSV'));
      _showSnackBar('Export CSV détaillé réussi');
    } catch (e) {
      _showSnackBar('Export CSV échoué: ${_cleanError(e)}', backgroundColor: Colors.redAccent);
    }
  }

  Future<void> _exportSessionToCSV() async {
    if (_students.isEmpty) return;
    setState(() => _isExporting = true);

    try {
      final rows = <List<dynamic>>[
        ['Nom de l\'élève', 'Statut', 'Nombre d\'absences', 'Total heures absent'],
      ];

      for (final student in _students) {
        rows.add([
          student.name,
          student.hasAnyAbsence ? 'Absent' : 'Présent',
          student.totalMarkedSlots,
          (student.getTotalMinutes() / 60.0).toStringAsFixed(1),
        ]);
      }

      final csv = const CsvEncoder().convert(rows);
      final directory = Directory.systemTemp;
      final now = DateTime.now();
      final timestamp = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
      final file = File('${directory.path}/absence_export_$timestamp.csv');
      await file.writeAsString(csv);

      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], subject: 'Export CSV'));
      _showSnackBar('Export CSV réussi');
    } catch (e) {
      _showSnackBar('Export CSV échoué: ${_cleanError(e)}', backgroundColor: Colors.redAccent);
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _exportToPdf() async {
    if (_students.isEmpty) return;
    try {
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
                pw.TableHelper.fromTextArray(
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

      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], subject: 'Export PDF'));
      _showSnackBar('Export PDF réussi');
    } catch (e) {
      _showSnackBar('Export PDF échoué: ${_cleanError(e)}', backgroundColor: Colors.redAccent);
    }
  }

  void _showStatistics() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _StatisticsSheet(students: _students, history: _repository.history),
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

  void _showSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20, right: 20, top: 20,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
        ),
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
            Row(
              children: [
                const Icon(Icons.settings_rounded, color: Color(0xFF00BFA6), size: 20),
                const SizedBox(width: 10),
                const Text(
                  'Paramètres',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.pop(ctx),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.close_rounded, color: Colors.white54, size: 18),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            if (_profile != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: const Color(0xFF00BFA6).withValues(alpha: 0.2),
                      child: Text(
                        _profile!.fullName.isNotEmpty ? _profile!.fullName[0].toUpperCase() : '?',
                        style: const TextStyle(color: Color(0xFF00BFA6), fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_profile!.fullName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                          Text(_profile!.isAdmin ? 'Administrateur' : 'Enseignant', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],

            const Text('Gestion des données', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white54)),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.history_rounded, color: Color(0xFF00BFA6), size: 20),
              title: const Text('Voir tout l\'historique', style: TextStyle(color: Colors.white, fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                _showFullHistory();
              },
            ),
            const Divider(color: Colors.white12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.logout_rounded, color: Colors.redAccent, size: 20),
              title: const Text('Se déconnecter', style: TextStyle(color: Colors.redAccent, fontSize: 14)),
              onTap: () async {
                Navigator.pop(ctx);
                await Supabase.instance.client.auth.signOut();
                if (mounted) {
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => const AuthGate()),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showFullHistory() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  const Icon(Icons.history_rounded, color: Color(0xFF00BFA6)),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text('Historique complet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white54),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _repository.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _repository.history.isEmpty
                      ? const Center(child: Text('Aucun scan enregistré', style: TextStyle(color: Colors.white54)))
                      : ListView.builder(
                          controller: scrollController,
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          itemCount: _repository.history.length,
                          itemBuilder: (context, index) {
                            final record = _repository.history[index];
                            return _buildHistoryTile(record);
                          },
                        ),
            ),
          ],
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
      if (_showOnlyAbsences) return s.hasAnyAbsence;
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
                    _exportSessionToCSV();
                    break;
                  case 'csv_detailed':
                    _exportDetailedCsv();
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
                const PopupMenuItem(value: 'csv', child: Text('Exporter CSV (simple)')),
                const PopupMenuItem(value: 'csv_detailed', child: Text('Exporter CSV (détaillé)')),
                const PopupMenuItem(value: 'pdf', child: Text('Exporter PDF')),
                const PopupMenuItem(value: 'share', child: Text('Partager')),
              ],
            ),
          ],
          IconButton(
            icon: const Icon(Icons.settings_rounded),
            tooltip: 'Paramètres',
            onPressed: _showSettings,
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
          const Text(
            'Analyse en cours…',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white70),
          ),
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
          _buildClassSelector(),
          const SizedBox(height: 12),

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
            const SizedBox(height: 40),
            _buildHeroSection(),
          ],

          _buildScanButton(),
          const SizedBox(height: 24),

          if (hasResults) ...[
            _buildInfoBar(),
            const SizedBox(height: 12),
            _buildExportActions(),
            const SizedBox(height: 12),
            _buildSearchBar(),
            const SizedBox(height: 12),
            _buildStudentsCard(),
            const SizedBox(height: 16),
            _buildRawTextCard(),
          ],

          if (_repository.history.isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildHistoryCard(),
          ],
        ],
      ),
    );
  }

  Widget _buildClassSelector() {
    if (_classes.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
        ),
        child: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 20),
            SizedBox(width: 8),
            Text('Aucune classe disponible', style: TextStyle(color: Colors.orange, fontSize: 13)),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          const Icon(Icons.class_rounded, color: Color(0xFF00BFA6), size: 20),
          const SizedBox(width: 12),
          const Text('Classe:', style: TextStyle(color: Colors.white54, fontSize: 13)),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<ClassModel>(
                value: _selectedClass,
                isExpanded: true,
                dropdownColor: const Color(0xFF161B22),
                style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white54),
                items: _classes.map((c) {
                  return DropdownMenuItem<ClassModel>(
                    value: c,
                    child: Text(c.name),
                  );
                }).toList(),
                onChanged: (ClassModel? value) {
                  setState(() => _selectedClass = value);
                },
              ),
            ),
          ),
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
          'Prenez une photo ou choisissez une image\npour détecter les élèves absents.',
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

  Widget _buildExportActions() {
    return ElevatedButton.icon(
      onPressed: (_students.isEmpty || _isExporting) ? null : _exportSessionToCSV,
      icon: _isExporting
          ? const SizedBox(
              width: 18, height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            )
          : const Icon(Icons.file_download_rounded, size: 20),
      label: Text(_isExporting ? 'Exportation...' : 'Exporter en CSV'),
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF00BFA6),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 14),
        minimumSize: const Size(double.infinity, 48),
      ),
    );
  }

  Widget _buildInfoBar() {
    final absentCount = _students.where((s) => s.hasAnyAbsence).length;
    final totalStudents = _students.length;
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
            _buildInfoItem(Icons.people_outline_rounded, '$totalStudents', 'Élèves'),
            Container(width: 1, height: 40, color: Colors.white12),
            _buildInfoItem(Icons.timer_rounded, '${totalHours}h ${totalMins}min', 'Total'),
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _students.any((s) => s.hasAnyAbsence)
                            ? '${_students.where((s) => s.hasAnyAbsence).length} absent(s)'
                            : 'Aucune absence détectée',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white),
                      ),
                      if (_students.isNotEmpty)
                        Text(
                          'sur ${_students.length} élève(s)',
                          style: const TextStyle(fontSize: 13, color: Colors.white38),
                        ),
                    ],
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
              onTap: _showFullHistory,
              child: const Text('Voir tout', style: TextStyle(fontSize: 13, color: Color(0xFF00BFA6))),
            ),
          ],
        ),
        iconColor: Colors.white54,
        collapsedIconColor: Colors.white54,
        children: _repository.history.take(5).toList().map((record) {
          return _buildHistoryTile(record);
        }).toList(),
      ),
    );
  }

  Widget _buildHistoryTile(AbsenceLogRecord record) {
    final date = record.scannedAt;
    final dateStr = '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    final absentCount = record.studentsWithAbsences;
    final totalMinutes = record.totalAbsenceMinutes;
    final totalHours = totalMinutes ~/ 60;
    final absentNames = record.students.where((s) => s.hasAnyAbsence).map((s) => s.name).join(', ');

    return Dismissible(
      key: ValueKey(record.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: const Icon(Icons.delete_outline, color: Color(0xFFFF5252)),
      ),
      onDismissed: (_) async {
        await _repository.deleteScan(record.id);
        _showSnackBar('Scan supprimé');
      },
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
          absentNames.isNotEmpty ? absentNames : 'Aucune absence',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        subtitle: Text('$dateStr | ${totalHours}h', style: const TextStyle(color: Colors.white38, fontSize: 11)),
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
          ? Text(student.formatTotalDuration(), style: const TextStyle(color: Color(0xFFFF5252), fontSize: 12))
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
                style: const TextStyle(color: Color(0xFFFF5252), fontSize: 11, fontWeight: FontWeight.w700),
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
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: const Color(0xFFFF5252).withValues(alpha: 0.15),
                  child: Text('${student.number}', style: const TextStyle(color: Color(0xFFFF5252), fontWeight: FontWeight.w700)),
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
                      border: Border.all(color: isAbsent ? const Color(0xFFFF5252).withValues(alpha: 0.3) : Colors.white12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        GestureDetector(
                          onTap: () => onDayToggle(dayIndex),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(day.dayName, style: TextStyle(color: isAbsent ? const Color(0xFFFF5252) : Colors.white54, fontWeight: FontWeight.w600, fontSize: 16)),
                              Text(isAbsent ? '${dayMinutes ~/ 60}h ${dayMinutes % 60}min' : 'Present', style: TextStyle(color: isAbsent ? const Color(0xFFFF5252) : Colors.white38, fontSize: 14)),
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
                                    color: slot.isMarked ? const Color(0xFFFF5252).withValues(alpha: 0.3) : Colors.white.withValues(alpha: 0.05),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: slot.isMarked ? const Color(0xFFFF5252) : Colors.white12),
                                  ),
                                  child: Center(
                                    child: Text(
                                      slot.isMarked ? (slot.markType.isEmpty ? 'X' : slot.markType) : '-',
                                      style: TextStyle(color: slot.isMarked ? const Color(0xFFFF5252) : Colors.white38, fontWeight: FontWeight.w600),
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
  final List<AbsenceLogRecord> history;

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
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
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
      decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
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
    _students = widget.students.map((s) => StudentAbsence(
      number: s.number,
      name: s.name,
      week: s.week.map((d) => DailyAbsence(
        dayName: d.dayName,
        slots: d.slots.map((slot) => AbsenceSlot(isMarked: slot.isMarked, markType: slot.markType)).toList(),
      )).toList(),
    )).toList();
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
              if (mounted) setState(() {});
            },
            child: const Text('Tout present', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              for (var student in _students) {
                student.markAllAbsent();
              }
              if (mounted) setState(() {});
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
                image: DecorationImage(image: FileImage(widget.image!), fit: BoxFit.cover),
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
                    if (mounted) setState(() {});
                  },
                  onDayToggle: (dayIndex) {
                    student.toggleDay(dayIndex);
                    if (mounted) setState(() {});
                  },
                  onTogglePresence: () {
                    if (student.hasAnyAbsence) {
                      student.markAllPresent();
                    } else {
                      student.markAllAbsent();
                    }
                    if (mounted) setState(() {});
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
                      child: Text('${student.number}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
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
