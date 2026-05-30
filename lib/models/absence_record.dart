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
  static const int minutesPerSlot = 150; // 2.5 hours per checkbox

  String dayName;
  List<AbsenceSlot> slots;

  DailyAbsence({
    required this.dayName,
    List<AbsenceSlot>? slots,
  }) : slots = slots ?? List.generate(4, (_) => AbsenceSlot());

  int getTotalMinutes() {
    int total = 0;
    for (var slot in slots) {
      if (slot.isMarked) {
        total += minutesPerSlot;
      }
    }
    return total;
  }

  String getDisplayMarks() {
    return slots.map((s) => s.markType.isEmpty ? '-' : s.markType).join();
  }

  int get markedCount => slots.where((s) => s.isMarked).length;
  bool get hasAbsence => markedCount > 0;

  void markAllPresent() {
    for (int i = 0; i < slots.length; i++) {
      slots[i] = AbsenceSlot(isMarked: false, markType: '');
    }
  }

  void markAllAbsent() {
    for (int i = 0; i < slots.length; i++) {
      slots[i] = AbsenceSlot(isMarked: true, markType: 'X');
    }
  }

  void toggleSlot(int slotIndex) {
    if (slotIndex >= 0 && slotIndex < slots.length) {
      final current = slots[slotIndex];
      slots[slotIndex] = AbsenceSlot(
        isMarked: !current.isMarked,
        markType: !current.isMarked ? 'X' : '',
      );
    }
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
  static const int minutesPerSlot = 150;

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

  int getTotalMinutes() {
    return week.fold(0, (sum, day) => sum + day.getTotalMinutes());
  }

  String formatTotalDuration() {
    final total = getTotalMinutes();
    final hours = total ~/ 60;
    final mins = total % 60;
    if (hours == 0) return '${mins}min';
    if (mins == 0) return '${hours}h';
    return '${hours}h ${mins}min';
  }

  bool get hasAnyAbsence => week.any((d) => d.hasAbsence);

  int get totalMarkedSlots {
    int count = 0;
    for (var day in week) {
      count += day.markedCount;
    }
    return count;
  }

  void markAllPresent() {
    for (var day in week) {
      day.markAllPresent();
    }
  }

  void markAllAbsent() {
    for (var day in week) {
      day.markAllAbsent();
    }
  }

  void toggleSlot(int dayIndex, int slotIndex) {
    if (dayIndex >= 0 && dayIndex < 6 && slotIndex >= 0 && slotIndex < 4) {
      week[dayIndex].toggleSlot(slotIndex);
    }
  }

  void toggleDay(int dayIndex) {
    if (dayIndex >= 0 && dayIndex < 6) {
      final day = week[dayIndex];
      if (day.hasAbsence) {
        day.markAllPresent();
      } else {
        day.markAllAbsent();
      }
    }
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

  factory StudentAbsence.fromCounts({
    required int number,
    required String name,
    required int absenceCount,
  }) {
    const orderedDays = ['LUN', 'MAR', 'MER', 'JEU', 'VEN', 'SAM'];
    final week = orderedDays
        .map((dayName) => DailyAbsence(dayName: dayName))
        .toList();

    if (absenceCount > 0) {
      int slotsToMark = absenceCount > 24 ? 24 : absenceCount;
      int marked = 0;
      for (int d = 0; d < week.length && marked < slotsToMark; d++) {
        for (int s = 0; s < 4 && marked < slotsToMark; s++) {
          week[d].slots[s] = AbsenceSlot(isMarked: true, markType: 'X');
          marked++;
        }
      }
    }

    return StudentAbsence(number: number, name: name, week: week);
  }

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
  static const int minutesPerSlot = 150;

  DateTime scanDate;
  List<StudentAbsence> students;
  String rawText;

  WeeklyScanSession({
    DateTime? scanDate,
    List<StudentAbsence>? students,
    this.rawText = '',
  })  : scanDate = scanDate ?? DateTime.now(),
        students = students ?? [];

  int getTotalAbsenceMinutes() {
    return students.fold(0, (sum, s) => sum + s.getTotalMinutes());
  }

  int get studentsWithAbsences => students.where((s) => s.hasAnyAbsence).length;

  Map<String, dynamic> toJson() => {
        'scanDate': scanDate.toIso8601String(),
        'students': students.map((s) => s.toJson()).toList(),
        'rawText': rawText,
      };

  factory WeeklyScanSession.fromJson(Map<String, dynamic> json) =>
      WeeklyScanSession(
        scanDate: json['scanDate'] != null
            ? DateTime.parse(json['scanDate'])
            : DateTime.now(),
        students: (json['students'] as List?)
                ?.map((s) => StudentAbsence.fromJson(s))
                .toList(),
        rawText: json['rawText'] ?? '',
      );
}