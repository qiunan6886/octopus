# ML Kit 的 Flutter 插件在生成的注册代码里引用了**所有语种**的文字识别器
# （天城文、日文、韩文……），而 APK 里只打包了中文模型。R8 在压缩时找不到那些
# 类，构建就会失败。
#
# 这些类我们不会用到——settings 里只提供中文识别——所以标记为「可以缺失」，
# 而不是把所有语种的模型都打进来（那会让 APK 再大十几 MB）。
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.**

# 保留实际用到的 ML Kit 类，避免被 R8 裁掉导致运行时找不到。
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
