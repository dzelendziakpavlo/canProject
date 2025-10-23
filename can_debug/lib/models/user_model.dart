class UserModel {
  final int? id;
  final String username;
  final String passwordHash;
  final String createdAt; // ISO 8601 string

  UserModel({this.id, required this.username, required this.passwordHash, required this.createdAt});

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'username': username,
      'passwordHash': passwordHash,
      'createdAt': createdAt,
    };
  }

  factory UserModel.fromMap(Map<String, dynamic> map) {
    return UserModel(
      id: map['id'] as int?,
      username: map['username'] as String,
      passwordHash: map['passwordHash'] as String,
      createdAt: map['createdAt'] as String,
    );
  }
}
