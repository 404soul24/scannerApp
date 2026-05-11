# ============================================================================
# ProGuard / R8 rules for google_mlkit_text_recognition
#
# The Flutter plugin references all script-specific recognizer classes
# (Chinese, Japanese, Korean, Devanagari) even if you only use Latin.
# These classes are in optional dependencies that are not included by default,
# so R8 reports them as missing. The rules below tell R8 to ignore them.
# ============================================================================

-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

-keep class com.google.mlkit.vision.text.chinese.** { *; }
-keep class com.google.mlkit.vision.text.devanagari.** { *; }
-keep class com.google.mlkit.vision.text.japanese.** { *; }
-keep class com.google.mlkit.vision.text.korean.** { *; }
