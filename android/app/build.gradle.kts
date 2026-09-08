plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // Must be applied after the Android and Kotlin plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.auradisplay.kiosk"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId = "com.auradisplay.kiosk"
        // API 26 is the floor: Lock Task feature flags (setLockTaskFeatures)
        // need 28 and are feature-detected, but notification channels and
        // ImageAnalysis output formats below 26 are not worth supporting.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            // Replace with a real signing config before shipping. Kiosk builds
            // are usually side-loaded, so a stable key matters for updates.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    packaging {
        resources.excludes += setOf("META-INF/*.kotlin_module")
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")

    // Motion engine: CameraX analysis pipeline.
    implementation("androidx.camera:camera-core:1.4.2")
    implementation("androidx.camera:camera-camera2:1.4.2")
    implementation("androidx.camera:camera-lifecycle:1.4.2")

    // LifecycleService gives the foreground service a real Lifecycle, which is
    // what CameraX bindToLifecycle() needs while the display is off.
    implementation("androidx.lifecycle:lifecycle-service:2.8.7")
}
