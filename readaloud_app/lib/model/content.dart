import 'package:uuid/uuid.dart';

class Content {
  final String id;
  final String title;
  final String body;
  final String sourceType;
  final String? sourceUrl;
  final String? sourceFilename;
  final int charCount;
  final String status;
  final int createdAt;
  final int updatedAt;
  final int? syncedAt;
  // 外部連携先（例: 'obsidian'）。sourceTypeとは独立させ、後から手動で紐付けるケースにも対応する
  final String? externalType;
  // 取り込み当時のObsidian Vault名（Vaultのフォルダ名変更に影響されないようContentごとに保持）
  final String? vaultName;
  // 取り込み時点でのVaultルートからの相対パス（sourceFilenameとは目的が異なるため分離）
  // Obsidian側でファイルが後から移動・リネームされてもDBの値は更新されない
  final String? relativePath;

  // 文字数上限
  static const int maxTitleLength = 100;
  static const int maxBodyLength = 100000;

  Content({
    String? id,
    required String title,
    required String body,
    required this.sourceType,
    this.sourceUrl,
    this.sourceFilename,
    int? charCount,
    this.status = 'unread',
    int? createdAt,
    int? updatedAt,
    this.syncedAt,
    this.externalType,
    this.vaultName,
    this.relativePath,
  })  : assert(title.length <= maxTitleLength,
            'タイトルは${maxTitleLength}文字以内にしてください'),
        assert(body.length <= maxBodyLength,
            '本文は${maxBodyLength}文字以内にしてください'),
        id = id ?? const Uuid().v4(),
        title = title,
        body = body,
        charCount = charCount ?? body.length,
        createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'body': body,
        'source_type': sourceType,
        'source_url': sourceUrl,
        'source_filename': sourceFilename,
        'char_count': charCount,
        'status': status,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'synced_at': syncedAt,
        'external_type': externalType,
        'vault_name': vaultName,
        'relative_path': relativePath,
      };

  factory Content.fromMap(Map<String, dynamic> map) => Content(
        id: map['id'],
        title: map['title'],
        body: map['body'],
        sourceType: map['source_type'],
        sourceUrl: map['source_url'],
        sourceFilename: map['source_filename'],
        charCount: map['char_count'],
        status: map['status'],
        createdAt: map['created_at'],
        updatedAt: map['updated_at'],
        syncedAt: map['synced_at'],
        externalType: map['external_type'],
        vaultName: map['vault_name'],
        relativePath: map['relative_path'],
      );

  Content copyWith({
    String? title,
    String? body,
    String? status,
    int? updatedAt,
  }) =>
      Content(
        id: id,
        title: title ?? this.title,
        body: body ?? this.body,
        sourceType: sourceType,
        sourceUrl: sourceUrl,
        sourceFilename: sourceFilename,
        charCount: body != null ? body.length : charCount,
        status: status ?? this.status,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now().millisecondsSinceEpoch,
        syncedAt: syncedAt,
        externalType: externalType,
        vaultName: vaultName,
        relativePath: relativePath,
      );
}
