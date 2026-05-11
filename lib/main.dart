import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ocr_service.dart';

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

  bool _isProcessing = false;
  bool _isModelLoading = false;
  List<String> _absentees = [];
  String _rawText = '';
  File? _selectedImage;
  List<Map<String, dynamic>> _history = [];

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
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('scan_history');
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as List;
        setState(() {
          _history = decoded.cast<Map<String, dynamic>>();
        });
      }
    } catch (_) {}
  }

  Future<void> _saveToHistory() async {
    if (_absentees.isEmpty) return;
    final entry = {
      'date': DateTime.now().toIso8601String(),
      'absentees': List<String>.from(_absentees),
      'text': _rawText,
    };
    _history.insert(0, entry);
    if (_history.length > 20) _history = _history.sublist(0, 20);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('scan_history', jsonEncode(_history));
    if (mounted) setState(() {});
  }

  void _clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('scan_history');
    setState(() => _history = []);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Historique effacé')),
      );
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
      _absentees = [];
      _rawText = '';
      _selectedImage = File(pickedFile.path);
    });

    try {
      await Future.delayed(const Duration(milliseconds: 600));
      setState(() => _isModelLoading = false);

      final recognizedText = await _ocrService.extractText(_selectedImage!);
      final absentees = _ocrService.findAbsentees(recognizedText);

      setState(() {
        _rawText = recognizedText.text;
        _absentees = absentees;
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
    if (_absentees.isEmpty) return;
    final buffer = StringBuffer();
    buffer.writeln('Élèves absents :');
    buffer.writeln('');
    for (int i = 0; i < _absentees.length; i++) {
      buffer.writeln('${i + 1}. ${_absentees[i]}');
    }
    await Share.share(buffer.toString(), subject: "Scan d'Absences");
  }

  void _addAbsentee() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('Ajouter un élève absent',
            style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: "Nom de l'élève",
            hintStyle: TextStyle(color: Colors.white38),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white24),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF00BFA6)),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annuler', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                setState(() {
                  if (!_absentees.contains(name)) _absentees.add(name);
                });
              }
              Navigator.pop(ctx);
            },
            child: const Text('Ajouter', style: TextStyle(color: Color(0xFF00BFA6))),
          ),
        ],
      ),
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
    final hasResults = _absentees.isNotEmpty || _rawText.isNotEmpty;

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
    final hasResults = _absentees.isNotEmpty || _rawText.isNotEmpty;

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
            _buildAbsenteesCard(),
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
          _absentees.isEmpty ? Icons.document_scanner_rounded : Icons.refresh_rounded,
          size: 22,
        ),
        label: Text(_absentees.isEmpty ? 'Scanner' : 'Scanner à nouveau'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 54),
        ),
      ),
    );
  }

  Widget _buildAbsenteesCard() {
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
                    color: _absentees.isNotEmpty
                        ? const Color(0xFFFF5252).withValues(alpha: 0.15)
                        : const Color(0xFF00E676).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    _absentees.isNotEmpty
                        ? Icons.person_off_rounded
                        : Icons.check_circle_outline_rounded,
                    color: _absentees.isNotEmpty
                        ? const Color(0xFFFF5252)
                        : const Color(0xFF00E676),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _absentees.isNotEmpty
                        ? 'Élèves absents (${_absentees.length})'
                        : 'Aucune absence détectée',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                ),
                if (_absentees.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline, color: Color(0xFF00BFA6), size: 22),
                    tooltip: 'Ajouter manuellement',
                    onPressed: _addAbsentee,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
              ],
            ),
            if (_absentees.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Divider(color: Colors.white12, height: 1),
              const SizedBox(height: 8),
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _absentees.length,
                separatorBuilder: (context, index) =>
                    const Divider(color: Colors.white12, height: 1),
                itemBuilder: (context, index) {
                  return Dismissible(
                    key: ValueKey(_absentees[index]),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 16),
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.delete_outline, color: Color(0xFFFF5252)),
                    ),
                    onDismissed: (_) {
                      setState(() => _absentees.removeAt(index));
                    },
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        radius: 18,
                        backgroundColor: const Color(0xFFFF5252).withValues(alpha: 0.15),
                        child: Text(
                          '${index + 1}',
                          style: const TextStyle(
                            color: Color(0xFFFF5252),
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      title: Text(
                        _absentees[index],
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500, fontSize: 15),
                      ),
                      trailing: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF5252).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          'ABSENT',
                          style: TextStyle(
                            color: Color(0xFFFF5252),
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ),
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
        children: [
          ..._history.take(10).map((entry) {
            final date = DateTime.tryParse(entry['date'] ?? '');
            final dateStr = date != null
                ? '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}'
                : '';
            final names = (entry['absentees'] as List).cast<String>();

            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                radius: 14,
                backgroundColor: const Color(0xFFFF5252).withValues(alpha: 0.15),
                child: Text(
                  '${names.length}',
                  style: const TextStyle(color: Color(0xFFFF5252), fontSize: 11, fontWeight: FontWeight.w700),
                ),
              ),
              title: Text(
                names.join(', '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              subtitle: Text(dateStr, style: const TextStyle(color: Colors.white38, fontSize: 11)),
            );
          }),
        ],
      ),
    );
  }
}
