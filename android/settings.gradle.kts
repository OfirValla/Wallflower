pluginManagement {
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        val path = properties.getProperty("flutter.sdk")
        require(path != null) { "flutter.sdk not set in android/local.properties" }
        path
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // Bump these two with the Android Studio upgrade assistant; they are the
    // only hard-pinned toolchain versions in the project.
    //
    // Floors are set by Flutter, not by us: DependencyVersionChecker in the
    // Flutter Gradle plugin hard-fails the build below AGP 8.11.1, Kotlin
    // 2.2.20, Gradle 8.14.0 (see gradle/wrapper) or Java 17. Staying on AGP 8
    // keeps the legacy `android { }` DSL and `kotlinOptions` in app/ valid;
    // moving to AGP 9 means adopting the new DSL as well.
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

include(":app")
