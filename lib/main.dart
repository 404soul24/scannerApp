import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
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
  int _minutesPerSlot = 30;

  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _loadHistory();
    _loadSettings();
  }

  @override
  void dispose() {
    _ocrService.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final minutes = await _storageService.getMinutesPerSlot();
    setState(() => _minutesPerSlot = minutes);
  }

  Future<void> _loadHistory() async {
    final history = await _storageService.loadHistory();
    setState(() => _history = history);
  }

  Future<void> _saveToHistory() async {
    if (_students.isEmpty) return;
    final session = WeeklyScanSession(
      scanDate: DateTime.now(),
      students: List.from(_students),
      minutesPerSlot: _minutesPerSlot,
      rawText: _rawText,
    );
    await _storageService.saveToHistory(session);
    _loadHistory();
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

  Future<void> _showSettings() async {
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => _SettingsDialog(initialMinutes: _minutesPerSlot),
    );
    if (result != null && result != _minutesPerSlot) {
      setState(() => _minutesPerSlot = result);
      await _storageService.setMinutesPerSlot(result);
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

      _saveToHistory();
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

  Future<void> _shareResults() async {
    if (_students.isEmpty) return;
    final buffer = StringBuffer();
    buffer.writeln('Absences hebdomadaire');
    buffer.writeln('Durée par case: $_minutesPerSlot min');
    buffer.writeln('');

    for (final student in _students) {
      final total = student.formatTotalDuration(_minutesPerSlot);
      buffer.writeln('${student.number}. ${student.name} - $total');
      for (final day in student.week) {
        final mins = day.getTotalMinutes(_minutesPerSlot);
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

  void _updateStudentMinutes(int studentIndex, int dayIndex, int slotIndex, bool isMarked, String markType) {
    setState(() {
      _students[studentIndex].week[dayIndex].slots[slotIndex] = AbsenceSlot(
        isMarked: isMarked,
        markType: markType,
      );
    });
  }

  void _toggleDayPresent(int studentIndex, int dayIndex) {
    setState(() {
      final day = _students[studentIndex].week[dayIndex];
      bool allPresent = true;
      for (var slot in day.slots) {
        if (slot.isMarked) {
          allPresent = false;
          break;
        }
      }
      final newMarked = !allPresent;
      final mark = newMarked ? 'X' : '';
      _students[studentIndex].week[dayIndex] = day.copyWith(
        slots: List.generate(4, (_) => AbsenceSlot(isMarked: newMarked, markType: newMarked ? mark : '')),
      );
    });
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
                  subtitle: const Text("Utilisez l'appareil photo", style: TextStyle(color: Colors.white54)),
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
                  subtitle: const Text('Sélectionner une image', style: TextStyle(color: Colors.white54)),
                  onTap: () => Navigator.pop(ctx, ImageSource.gallery),
                ),
              ],
            ),
          ),
        );
      },
    );
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
          IconButton(
            icon: const Icon(Icons.settings_rounded),
            tooltip: 'Paramètres',
            onPressed: _showSettings,
          ),
          if (hasResults)
            IconButton(
              icon: const Icon(Icons.share_rounded),
              tooltip: 'Partager',
              onPressed: _shareResults,
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
                height: 220,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: 20),
          ],

          if (!hasResults) ...[
            const SizedBox(height: 60),
            _buildHeroSection(),
          ],

          _buildScanButton(),
          const SizedBox(height: 24),

          if (hasResults) ...[
            _buildSettingsBar(),
            const SizedBox(height: 16),
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

  Widget _buildSettingsBar() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF448AFF).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.timer_rounded, color: Color(0xFF448AFF), size: 20),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Durée par case',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF448AFF).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$_minutesPerSlot min',
                style: const TextStyle(color: Color(0xFF448AFF), fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _showSettings,
              child: const Icon(Icons.edit_rounded, color: Colors.white38, size: 20),
            ),
          ],
        ),
      ),
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
                    color: _students.any((s) => s.getTotalMinutes(_minutesPerSlot) > 0)
                        ? const Color(0xFFFF5252).withValues(alpha: 0.15)
                        : const Color(0xFF00E676).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    _students.any((s) => s.getTotalMinutes(_minutesPerSlot) > 0)
                        ? Icons.person_off_rounded
                        : Icons.check_circle_outline_rounded,
                    color: _students.any((s) => s.getTotalMinutes(_minutesPerSlot) > 0)
                        ? const Color(0xFFFF5252)
                        : const Color(0xFF00E676),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _students.isNotEmpty && _students.any((s) => s.getTotalMinutes(_minutesPerSlot) > 0)
                        ? 'Élèves absents (${_students.where((s) => s.getTotalMinutes(_minutesPerSlot) > 0).length})'
                        : 'Aucune absence détectée',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                ),
              ],
            ),
            if (_students.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Divider(color: Colors.white12, height: 1),
              const SizedBox(height: 8),
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _students.length,
                separatorBuilder: (context, index) => const Divider(color: Colors.white12, height: 1),
                itemBuilder: (context, index) {
                  return _StudentCard(
                    student: _students[index],
                    minutesPerSlot: _minutesPerSlot,
                    onSlotToggle: (dayIndex, slotIndex, isMarked, markType) {
                      _updateStudentMinutes(index, dayIndex, slotIndex, isMarked, markType);
                    },
                    onDayToggle: (dayIndex) {
                      _toggleDayPresent(index, dayIndex);
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
        children: _history.take(5).map((session) {
          final date = session.scanDate;
          final dateStr = '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
          final absentCount = session.students.where((s) => s.getTotalMinutes(session.minutesPerSlot) > 0).length;
          
          return ListTile(
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
              session.students.where((s) => s.getTotalMinutes(session.minutesPerSlot) > 0).map((s) => s.name).join(', '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            subtitle: Text('$dateStr | ${session.minutesPerSlot}min/case', style: const TextStyle(color: Colors.white38, fontSize: 11)),
          );
        }).toList(),
      ),
    );
  }
}

class _StudentCard extends StatefulWidget {
  final StudentAbsence student;
  final int minutesPerSlot;
  final Function(int dayIndex, int slotIndex, bool isMarked, String markType) onSlotToggle;
  final Function(int dayIndex) onDayToggle;

  const _StudentCard({
    required this.student,
    required this.minutesPerSlot,
    required this.onSlotToggle,
    required this.onDayToggle,
  });

  @override
  State<_StudentCard> createState() => _StudentCardState();
}

class _StudentCardState extends State<_StudentCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final totalMinutes = widget.student.getTotalMinutes(widget.minutesPerSlot);
    final hasAbsence = totalMinutes > 0;

    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: CircleAvatar(
            radius: 18,
            backgroundColor: hasAbsence
                ? const Color(0xFFFF5252).withValues(alpha: 0.15)
                : const Color(0xFF00E676).withValues(alpha: 0.15),
            child: Text(
              '${widget.student.number}',
              style: TextStyle(
                color: hasAbsence ? const Color(0xFFFF5252) : const Color(0xFF00E676),
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
          title: Text(
            widget.student.name,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500, fontSize: 15),
          ),
          subtitle: hasAbsence
              ? Text(
                  widget.student.formatTotalDuration(widget.minutesPerSlot),
                  style: const TextStyle(color: Color(0xFFFF5252), fontSize: 12),
                )
              : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasAbsence)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF5252).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    widget.student.formatTotalDuration(widget.minutesPerSlot),
                    style: const TextStyle(
                      color: Color(0xFFFF5252),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Icon(
                  _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  color: Colors.white54,
                ),
              ),
            ],
          ),
          onTap: () => setState(() => _expanded = !_expanded),
        ),
        if (_expanded) ...[
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.only(left: 40),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: List.generate(6, (dayIndex) {
                final day = widget.student.week[dayIndex];
                final dayMinutes = day.getTotalMinutes(widget.minutesPerSlot);
                final isAbsent = dayMinutes > 0;

                return GestureDetector(
                  onTap: () => widget.onDayToggle(dayIndex),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: isAbsent
                          ? const Color(0xFFFF5252).withValues(alpha: 0.15)
                          : Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isAbsent ? const Color(0xFFFF5252).withValues(alpha: 0.3) : Colors.white12,
                      ),
                    ),
                    child: Column(
                      children: [
                        Text(
                          day.dayName,
                          style: TextStyle(
                            color: isAbsent ? const Color(0xFFFF5252) : Colors.white54,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          day.getDisplayMarks(),
                          style: TextStyle(
                            color: isAbsent ? const Color(0xFFFF5252) : Colors.white38,
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                        if (isAbsent) ...[
                          const SizedBox(height: 2),
                          Text(
                            '${dayMinutes ~/ 60}h ${dayMinutes % 60}min',
                            style: const TextStyle(
                              color: Color(0xFFFF5252),
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ],
    );
  }
}

class _SettingsDialog extends StatefulWidget {
  final int initialMinutes;

  const _SettingsDialog({required this.initialMinutes});

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late int _selectedMinutes;

  @override
  void initState() {
    super.initState();
    _selectedMinutes = widget.initialMinutes;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF161B22),
      title: const Text('Paramètres', style: TextStyle(color: Colors.white)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Durée par case cochée',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [15, 20, 30, 45, 60].map((mins) {
              final isSelected = _selectedMinutes == mins;
              return GestureDetector(
                onTap: () => setState(() => _selectedMinutes = mins),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: isSelected ? const Color(0xFF00BFA6).withValues(alpha: 0.2) : Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isSelected ? const Color(0xFF00BFA6) : Colors.white12,
                    ),
                  ),
                  child: Text(
                    '$mins min',
                    style: TextStyle(
                      color: isSelected ? const Color(0xFF00BFA6) : Colors.white70,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          Text(
            '示例: 4 cases = ${_selectedMinutes * 4} min (${_selectedMinutes * 4 ~/ 60}h ${_selectedMinutes * 4 % 60}min)',
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler', style: TextStyle(color: Colors.white54)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _selectedMinutes),
          child: const Text('Enregistrer', style: TextStyle(color: Color(0xFF00BFA6))),
        ),
      ],
    );
  }
}