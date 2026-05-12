class AbsenceSlot {
  bool isMarked;
  String markType;

  AbsenceSlot({
    this.isMarked = false,
    this.markType = '',
  });

  Map<String, dynamic> toJson() => {
        'isMarked': isMarked,
        'markType': markType,
      };

  factory AbsenceSlot.fromJson(Map<String, dynamic> json) => AbsenceSlot(
        isMarked: json['isMarked'] ?? false,
        markType: json['markType'] ?? '',
      );

  AbsenceSlot copyWith({bool? isMarked, String? markType}) => AbsenceSlot(
        isMarked: isMarked ?? this.isMarked,
        markType: markType ?? this.markType,
      );
}

class DailyAbsence {
  String dayName;
  List<AbsenceSlot> slots;

  DailyAbsence({
    required this.dayName,
    List<AbsenceSlot>? slots,
  }) : slots = slots ?? List.generate(4, (_) => AbsenceSlot());

  int getTotalMinutes(int minutesPerSlot) {
    int total = 0;
    bool isFullDay = false;

    for (var slot in slots) {
      if (slot.markType == 'A') {
        isFullDay = true;
        break;
      }
    }

    if (isFullDay) {
      return 4 * minutesPerSlot;
    }

    for (var slot in slots) {
      if (slot.isMarked && (slot.markType == 'X' || slot.markType == '/')) {
        total += minutesPerSlot;
      }
    }

    return total;
  }

  String getDisplayMarks() {
    return slots.map((s) => s.markType.isEmpty ? '-' : s.markType).join();
  }

  Map<String, dynamic> toJson() => {
        'dayName': dayName,
        'slots': slots.map((s) => s.toJson()).toList(),
      };

  factory DailyAbsence.fromJson(Map<String, dynamic> json) => DailyAbsence(
        dayName: json['dayName'] ?? '',
        slots: (json['slots'] as List?)
                ?.map((s) => AbsenceSlot.fromJson(s))
                .toList() ??
            List.generate(4, (_) => AbsenceSlot()),
      );

  DailyAbsence copyWith({
    String? dayName,
    List<AbsenceSlot>? slots,
  }) =>
      DailyAbsence(
        dayName: dayName ?? this.dayName,
        slots: slots ?? List.from(this.slots.map((s) => s.copyWith())),
      );
}

class StudentAbsence {
  int number;
  String name;
  List<DailyAbsence> week;

  StudentAbsence({
    this.number = 0,
    this.name = '',
    List<DailyAbsence>? week,
  }) : week = week ??
            [
              DailyAbsence(dayName: 'LUN'),
              DailyAbsence(dayName: 'MAR'),
              DailyAbsence(dayName: 'MER'),
              DailyAbsence(dayName: 'JEU'),
              DailyAbsence(dayName: 'VEN'),
              DailyAbsence(dayName: 'SAM'),
            ];

  int getTotalMinutes(int minutesPerSlot) {
    return week.fold(0, (sum, day) => sum + day.getTotalMinutes(minutesPerSlot));
  }

  String formatTotalDuration(int minutesPerSlot) {
    final total = getTotalMinutes(minutesPerSlot);
    final hours = total ~/ 60;
    final mins = total % 60;
    if (hours == 0) return '${mins}min';
    if (mins == 0) return '${hours}h';
    return '${hours}h ${mins}min';
  }

  Map<String, dynamic> toJson() => {
        'number': number,
        'name': name,
        'week': week.map((d) => d.toJson()).toList(),
      };

  factory StudentAbsence.fromJson(Map<String, dynamic> json) => StudentAbsence(
        number: json['number'] ?? 0,
        name: json['name'] ?? '',
        week: (json['week'] as List?)
                ?.map((d) => DailyAbsence.fromJson(d))
                .toList() ??
            [
              DailyAbsence(dayName: 'LUN'),
              DailyAbsence(dayName: 'MAR'),
              DailyAbsence(dayName: 'MER'),
              DailyAbsence(dayName: 'JEU'),
              DailyAbsence(dayName: 'VEN'),
              DailyAbsence(dayName: 'SAM'),
            ],
      );

  StudentAbsence copyWith({
    int? number,
    String? name,
    List<DailyAbsence>? week,
  }) =>
      StudentAbsence(
        number: number ?? this.number,
        name: name ?? this.name,
        week: week ??
            this.week.map((d) => d.copyWith()).toList(),
      );
}

class WeeklyScanSession {
  DateTime scanDate;
  List<StudentAbsence> students;
  int minutesPerSlot;
  String rawText;

  WeeklyScanSession({
    DateTime? scanDate,
    List<StudentAbsence>? students,
    this.minutesPerSlot = 30,
    this.rawText = '',
  })  : scanDate = scanDate ?? DateTime.now(),
        students = students ?? List.generate(15, (_) => StudentAbsence());

  int getTotalAbsenceMinutes() {
    return students.fold(0, (sum, s) => sum + s.getTotalMinutes(minutesPerSlot));
  }

  Map<String, dynamic> toJson() => {
        'scanDate': scanDate.toIso8601String(),
        'students': students.map((s) => s.toJson()).toList(),
        'minutesPerSlot': minutesPerSlot,
        'rawText': rawText,
      };

  factory WeeklyScanSession.fromJson(Map<String, dynamic> json) =>
      WeeklyScanSession(
        scanDate: json['scanDate'] != null
            ? DateTime.parse(json['scanDate'])
            : DateTime.now(),
        students: (json['students'] as List?)
                ?.map((s) => StudentAbsence.fromJson(s))
                .toList() ??
            List.generate(15, (_) => StudentAbsence()),
        minutesPerSlot: json['minutesPerSlot'] ?? 30,
        rawText: json['rawText'] ?? '',
      );
}