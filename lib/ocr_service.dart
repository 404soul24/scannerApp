import 'dart:io';
import 'dart:ui';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

class OCRService {
  final TextRecognizer _textRecognizer =
      TextRecognizer(script: TextRecognitionScript.latin);

  Future<RecognizedText> extractText(File imageFile) async {
    final inputImage = InputImage.fromFile(imageFile);
    return _textRecognizer.processImage(inputImage);
  }

  static const _headerWords = {
    'nom', 'prénom', 'prenom', 'prénoms', 'prenoms',
    'présent', 'present', 'présente', 'presente',
    'classe', 'date', 'note', 'observation',
    'justifié', 'justifie', 'non justifié', 'non justifie',
    'matière', 'matiere', 'total', 'groupe', 'filière', 'filiere',
    'niveau', 'salle', 'heure', 'signature', 'étudiant', 'etudiant',
    'élève', 'eleve', 'liste', 'numéro', 'numero',
    'n°', 'nº', 'no',
  };

  static const _presenceWords = {
    'présent', 'present', 'présente', 'presente',
    'p', 'v', 'vu',
  };

  List<String> findAbsentees(RecognizedText recognizedText) {
    // Absence markers: French variants + checkbox symbols.
    // NOTE: 'V' and '/' are NOT included — 'V' often means "Vu" (present) in French schools.
    const absenceMarkers = [
      'ABSENT', 'ABSENTE', 'ABSENTS', 'ABSENTES', 'ABS',
      'A', 'X', 'x',
      '☑', '☒', '✓', '✔',
      '[X]', '[x]', '[✓]', '[✔]',
    ];

    final markersPattern =
        absenceMarkers.map((m) => RegExp.escape(m)).join('|');

    final presencePattern =
        _presenceWords.map((m) => RegExp.escape(m)).join('|');

    final RegExp inlineSuffixPattern = RegExp(
      r'^(.*?)(?:\s+|-|\||\.|:|,|;)+\s*(' + markersPattern + r')\s*$',
      caseSensitive: false,
    );

    final RegExp inlinePrefixPattern = RegExp(
      r'^\s*(' + markersPattern + r')(?:\s+|-|\||\.|:|,|;)+\s*(.+)$',
      caseSensitive: false,
    );

    final RegExp exactMarkerPattern = RegExp(
      r'^\s*(' + markersPattern + r')\s*$',
      caseSensitive: false,
    );

    final RegExp containsAbsentPattern = RegExp(
      r'\babsent\b',
      caseSensitive: false,
    );

    final RegExp containsPresentPattern = RegExp(
      r'\b(' + presencePattern + r')\b',
      caseSensitive: false,
    );

    final List<TextLine> allLines = [];
    for (final block in recognizedText.blocks) {
      allLines.addAll(block.lines);
    }

    bool isHeader(String text) {
      final lower = text.trim().toLowerCase();
      return _headerWords.contains(lower);
    }

    bool isPresence(String text) {
      final lower = text.trim().toLowerCase();
      return _presenceWords.contains(lower);
    }

    bool isNoise(String text) {
      final t = text.trim();
      if (t.isEmpty) return true;
      if (t.length == 1 &&
          !absenceMarkers.any((m) =>
              m.toLowerCase() == t.toLowerCase() ||
              (m.length > 1 && t.toLowerCase() == m[0].toLowerCase()))) {
        if (!RegExp(r'^[a-zA-Z0-9]$').hasMatch(t)) return true;
      }
      if (RegExp(r"""^[\d\s.,;:!?'"\-_]+$""").hasMatch(t)) return true;
      return false;
    }

    String? cleanName(String text) {
      String name = text.trim();
      name = name.replaceFirst(RegExp(r'^[\d\s]+[.)]\s*'), '');
      name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (name.length > 2 && name.contains(RegExp(r'[a-zA-Z]'))) {
        return isHeader(name) ? null : name;
      }
      return null;
    }

    final List<String> absentees = [];

    // --- PASS 1: Row-based grouping ---
    if (allLines.isEmpty) return absentees;

    // Calculate median line height for dynamic row tolerance
    final heights = allLines.map((l) => l.boundingBox.height).toList()..sort();
    final medianHeight = heights[heights.length ~/ 2];
    final rowTolerance = medianHeight * 0.6;

    final List<List<TextLine>> rows = [];

    final sortedLines = List<TextLine>.from(allLines)
      ..sort((a, b) =>
          a.boundingBox.center.dy.compareTo(b.boundingBox.center.dy));

    for (final line in sortedLines) {
      final yCenter = line.boundingBox.center.dy;
      bool added = false;
      for (final row in rows) {
        if (row.isNotEmpty) {
          final rowYCenter = row.first.boundingBox.center.dy;
          if ((yCenter - rowYCenter).abs() <= rowTolerance) {
            row.add(line);
            added = true;
            break;
          }
        }
      }
      if (!added) {
        rows.add([line]);
      }
    }

    for (final row in rows) {
      String? rowMarker;
      bool rowIsPresent = false;
      final List<String> nameCandidates = [];

      for (final line in row) {
        final text = line.text.trim();
        if (text.isEmpty || isNoise(text)) continue;

        // Skip header-only rows
        final spaces = text.split(RegExp(r'\s+'));
        if (spaces.length <= 3 &&
            spaces.every(
                (w) => _headerWords.contains(w.toLowerCase().trim()))) {
          continue;
        }

        // Presence marker — this row is present, skip
        if (isPresence(text)) {
          rowIsPresent = true;
          continue;
        }
        if (exactMarkerPattern.hasMatch(text)) {
          rowMarker = text;
          continue;
        }

        // Inline suffix: "Name - A"
        final suffixMatch = inlineSuffixPattern.firstMatch(text);
        if (suffixMatch != null) {
          final name = cleanName(suffixMatch.group(1)!);
          if (name != null) {
            rowMarker = suffixMatch.group(2)!;
            nameCandidates.add(name);
            continue;
          }
        }

        // Inline prefix: "A - Name"
        final prefixMatch = inlinePrefixPattern.firstMatch(text);
        if (prefixMatch != null) {
          final name = cleanName(prefixMatch.group(2)!);
          if (name != null) {
            rowMarker = prefixMatch.group(1)!;
            nameCandidates.add(name);
            continue;
          }
        }

        // Contains presence word: skip this row
        if (containsPresentPattern.hasMatch(text)) {
          rowIsPresent = true;
          continue;
        }

        // Contains "absent" anywhere
        if (containsAbsentPattern.hasMatch(text)) {
          final match = containsAbsentPattern.firstMatch(text);
          if (match != null) {
            final before = text.substring(0, match.start).trim();
            final after = text.substring(match.end).trim();
            final name =
                cleanName(before.isNotEmpty ? before : after);
            if (name != null) {
              rowMarker = 'ABSENT';
              nameCandidates.add(name);
              continue;
            }
          }
        }

        // Restrict exact 'A' match to short lines only
        final lower = text.toLowerCase();
        if (lower == 'a' && text.length <= 3) {
          rowMarker = text;
          continue;
        }

        // General name candidate
        final name = cleanName(text);
        if (name != null) {
          nameCandidates.add(name);
        }
      }

      if (rowMarker != null && !rowIsPresent) {
        for (final name in nameCandidates) {
          if (!absentees.contains(name)) absentees.add(name);
        }
      }
    }

    // --- PASS 2: Spatial analysis for standalone markers ---
    for (int i = 0; i < allLines.length; i++) {
      final line = allLines[i];
      final text = line.text.trim();
      final cleanText = text.replaceAll(RegExp(r'[^\w\s]'), '').trim();
      if (text.isEmpty || isNoise(text)) continue;

      final extracted = cleanName(text);
      if (extracted != null && absentees.contains(extracted)) continue;

      if (exactMarkerPattern.hasMatch(text) ||
          exactMarkerPattern.hasMatch(cleanText)) {
        if (isHeader(text)) continue;

        final markerRect = line.boundingBox;

        TextLine? bestCandidate;
        double minDistance = double.infinity;

        for (int j = 0; j < allLines.length; j++) {
          if (i == j) continue;
          final candidateLine = allLines[j];
          final candidateRect = candidateLine.boundingBox;
          final candidateText = candidateLine.text.trim();

          if (isHeader(candidateText)) continue;
          if (isNoise(candidateText)) continue;
          if (exactMarkerPattern.hasMatch(candidateText)) continue;
          if (isPresence(candidateText)) continue;

          final overlap =
              _calculateVerticalOverlap(markerRect, candidateRect);
          final minHeight = markerRect.height < candidateRect.height
              ? markerRect.height
              : candidateRect.height;

          if (overlap > minHeight * 0.2) {
            if (candidateRect.right <= markerRect.left + 20) {
              final distance = markerRect.left - candidateRect.right;
              if (distance < minDistance) {
                minDistance = distance;
                bestCandidate = candidateLine;
              }
            } else if (candidateRect.left >= markerRect.right - 20) {
              final distance = candidateRect.left - markerRect.right;
              if (bestCandidate == null || distance < minDistance) {
                minDistance = distance;
                bestCandidate = candidateLine;
              }
            }
          }
        }

        if (bestCandidate != null) {
          final name = cleanName(bestCandidate.text.trim());
          if (name != null && !absentees.contains(name)) {
            absentees.add(name);
          }
        }
      }
    }

    return absentees;
  }

  double _calculateVerticalOverlap(Rect r1, Rect r2) {
    final top = r1.top > r2.top ? r1.top : r2.top;
    final bottom = r1.bottom < r2.bottom ? r1.bottom : r2.bottom;
    return (bottom - top) > 0 ? (bottom - top) : 0;
  }

  void dispose() {
    _textRecognizer.close();
  }
}
