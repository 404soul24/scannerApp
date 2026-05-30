class School {
  final String id;
  final String name;
  final DateTime createdAt;

  School({
    required this.id,
    required this.name,
    required this.createdAt,
  });

  factory School.fromJson(Map<String, dynamic> json) => School(
        id: json['id'] as String,
        name: json['name'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'created_at': createdAt.toIso8601String(),
      };
}
