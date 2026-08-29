/// 动态分类项（MacCMS `ac=list` 的 `class` 字段）。
library;

class CategoryEntry {
  final String id;
  final String title;

  const CategoryEntry({required this.id, required this.title});

  factory CategoryEntry.fromJson(Map<String, dynamic> json) => CategoryEntry(
        id: json['id']?.toString() ?? json['type_id']?.toString() ?? '',
        // 键名容错：不同源分别用 `title` / `name` / `type_name`，缺一容错
        // 会让整批分类变成空白项（用户可见：一排可点但无字的按钮）。
        title: json['title']?.toString() ??
            json['name']?.toString() ??
            json['type_name']?.toString() ??
            '',
      );
}
