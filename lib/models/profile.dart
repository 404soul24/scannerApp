class Profile {
  final String id;
  final String schoolId;
  final String role;
  final String fullName;

  Profile({
    required this.id,
    required this.schoolId,
    required this.role,
    required this.fullName,
  });

  bool get isAdmin => role == 'admin';
  bool get isTeacher => role == 'teacher';

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
        id: json['id'] as String,
        schoolId: json['school_id'] as String,
        role: json['role'] as String,
        fullName: json['full_name'] as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'school_id': schoolId,
        'role': role,
        'full_name': fullName,
      };
}
