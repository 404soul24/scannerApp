class ClassModel {
  final String id;
  final String schoolId;
  final String name;

  ClassModel({
    required this.id,
    required this.schoolId,
    required this.name,
  });

  factory ClassModel.fromJson(Map<String, dynamic> json) => ClassModel(
        id: json['id'] as String,
        schoolId: json['school_id'] as String,
        name: json['name'] as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'school_id': schoolId,
        'name': name,
      };

  @override
  String toString() => name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClassModel && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
