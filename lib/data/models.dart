/// 数据模型。
///
/// 从 drift 换成 sqflite 之后，这些不再由代码生成，而是手写。代价是失去编译期
/// 的查询检查，换来的是**构建不依赖网络**——drift 2.32+ 会在编译时从 GitHub
/// 下载预编译的 SQLite 库，网络不通就构建失败。
///
/// 每个类都提供 `fromMap`，字段名与建表语句里的列名一一对应。
library;

class Profile {
  const Profile({
    required this.id,
    required this.name,
    required this.grade,
    required this.createdAt,
  });

  final int id;
  final String name;
  final int grade;
  final DateTime createdAt;

  factory Profile.fromMap(Map<String, Object?> m) => Profile(
    id: m['id']! as int,
    name: m['name']! as String,
    grade: m['grade']! as int,
    createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at']! as int),
  );
}

/// 一次录入（拍一张或几张照片）。承载「待确认」环节。
class IntakeBatch {
  const IntakeBatch({
    required this.id,
    required this.profileId,
    required this.status,
    required this.createdAt,
  });

  final int id;
  final int profileId;
  final String status;
  final DateTime createdAt;

  factory IntakeBatch.fromMap(Map<String, Object?> m) => IntakeBatch(
    id: m['id']! as int,
    profileId: m['profile_id']! as int,
    status: m['status']! as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at']! as int),
  );
}

/// 待确认的题目。用户在审核页看到的就是这些。
class DraftQuestion {
  const DraftQuestion({
    required this.id,
    required this.batchId,
    required this.originalImagePath,
    required this.content,
    required this.subject,
    required this.reviewStatus,
    required this.acceptedQuestionId,
    required this.sortOrder,
    this.gradeResult,
    this.correctAnswer,
    this.gradeSource,
  });

  final int id;
  final int batchId;
  final String originalImagePath;

  /// 识别出来的题干文字，用户可编辑。
  final String content;

  final String? subject;

  /// pending / accepted / discarded
  final String reviewStatus;

  /// 通过之后写进错题库的那条题的 id。
  final int? acceptedQuestionId;

  final int sortOrder;

  /// 批改结果：correct / wrong / null（还没判断）。
  ///
  /// 批改和录入是同一条流程——「错题」的定义就是做错的题，所以批改只是多了一步
  /// 判断对错，而不是另开一个入口。
  final String? gradeResult;

  /// 批改给出的正确答案。做错的题尤其需要，孩子重做时可以直接对照。
  final String? correctAnswer;

  /// 判断来自哪里：ai（模型看的图）/ manual（家长自己标的）。
  ///
  /// 分开记是因为两者的可信度不同——AI 判断错的题值得复核，手动标记不用。
  final String? gradeSource;

  bool get isCorrect => gradeResult == 'correct';
  bool get isWrong => gradeResult == 'wrong';
  bool get isGraded => gradeResult != null;

  factory DraftQuestion.fromMap(Map<String, Object?> m) => DraftQuestion(
    id: m['id']! as int,
    batchId: m['batch_id']! as int,
    originalImagePath: m['original_image_path']! as String,
    content: (m['content'] as String?) ?? '',
    subject: m['subject'] as String?,
    reviewStatus: (m['review_status'] as String?) ?? 'pending',
    acceptedQuestionId: m['accepted_question_id'] as int?,
    sortOrder: (m['sort_order'] as int?) ?? 0,
    gradeResult: m['grade_result'] as String?,
    correctAnswer: m['correct_answer'] as String?,
    gradeSource: m['grade_source'] as String?,
  );
}

/// 错题。
class Question {
  const Question({
    required this.id,
    required this.profileId,
    required this.content,
    required this.originalImagePath,
    required this.subject,
    required this.knowledgeTags,
    required this.source,
    required this.mastery,
    required this.usesAiRedrawnFigure,
    required this.reviewCount,
    required this.createdAt,
    required this.lastReviewedAt,
    this.correctAnswer,
    this.gradeResult,
  });

  final int id;

  /// ★ 必填。所有查询都带这个条件，隔离在存储层而不只是界面层。
  final int profileId;

  final String content;
  final String? originalImagePath;
  final String? subject;
  final String? knowledgeTags;
  final String? source;

  /// new / reviewing / mastered
  final String mastery;

  /// 用了 AI 重绘的图形。打印时会在卷子上标记，提示家长核对。
  final bool usesAiRedrawnFigure;

  final int reviewCount;
  final DateTime createdAt;
  final DateTime? lastReviewedAt;

  /// 这道题对应的正确答案（批改时给出的）。孩子重做后可以对照。
  final String? correctAnswer;

  /// 这道题当初被判定的结果。入库的题基本是 wrong，但如果设置里允许保留做对的
  /// 题，也会有 correct。
  final String? gradeResult;

  factory Question.fromMap(Map<String, Object?> m) => Question(
    id: m['id']! as int,
    profileId: m['profile_id']! as int,
    content: (m['content'] as String?) ?? '',
    originalImagePath: m['original_image_path'] as String?,
    subject: m['subject'] as String?,
    knowledgeTags: m['knowledge_tags'] as String?,
    source: m['source'] as String?,
    mastery: (m['mastery'] as String?) ?? 'new',
    usesAiRedrawnFigure: (m['uses_ai_redrawn_figure'] as int? ?? 0) == 1,
    reviewCount: (m['review_count'] as int?) ?? 0,
    createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at']! as int),
    lastReviewedAt: m['last_reviewed_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(m['last_reviewed_at']! as int),
    correctAnswer: m['correct_answer'] as String?,
    gradeResult: m['grade_result'] as String?,
  );
}

/// 题干的组成单元：文字段 / 图形段 / 公式段。
///
/// 一道题不是一张图，而是一串元素。这样文字可以重排、图形可以单独决定保留
/// 原图还是用 AI 重绘，最后再拼装回一道题。
class QuestionElement {
  const QuestionElement({
    required this.id,
    required this.questionId,
    required this.kind,
    required this.sortOrder,
    required this.content,
    required this.originalImagePath,
    required this.generatedSource,
    required this.chosen,
  });

  final int id;
  final int questionId;

  /// text / figure / formula
  final String kind;

  final int sortOrder;

  /// kind = text 时的文字。
  final String? content;

  /// kind = figure / formula 时的原图裁剪。
  final String? originalImagePath;

  /// AI 生成的结果：图形是 SVG 源码，公式是 LaTeX。
  final String? generatedSource;

  /// original / ai
  final String chosen;

  factory QuestionElement.fromMap(Map<String, Object?> m) => QuestionElement(
    id: m['id']! as int,
    questionId: m['question_id']! as int,
    kind: m['kind']! as String,
    sortOrder: (m['sort_order'] as int?) ?? 0,
    content: m['content'] as String?,
    originalImagePath: m['original_image_path'] as String?,
    generatedSource: m['generated_source'] as String?,
    chosen: (m['chosen'] as String?) ?? 'original',
  );
}

/// 练习卷（一批挑出来要打印的题）。
class Worksheet {
  const Worksheet({
    required this.id,
    required this.profileId,
    required this.name,
    required this.layoutJson,
    required this.createdAt,
  });

  final int id;
  final int profileId;
  final String name;
  final String? layoutJson;
  final DateTime createdAt;

  factory Worksheet.fromMap(Map<String, Object?> m) => Worksheet(
    id: m['id']! as int,
    profileId: m['profile_id']! as int,
    name: (m['name'] as String?) ?? '',
    layoutJson: m['layout_json'] as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at']! as int),
  );
}
