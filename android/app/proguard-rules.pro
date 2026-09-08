# Components referenced only from the manifest / by the framework.
-keep class com.auradisplay.kiosk.MainActivity { *; }
-keep class com.auradisplay.kiosk.kiosk.AuraDeviceAdminReceiver { *; }
-keep class com.auradisplay.kiosk.service.AuraKioskService { *; }
-keep class com.auradisplay.kiosk.service.BootReceiver { *; }

# CameraX resolves camera implementations reflectively.
-keep class androidx.camera.camera2.** { *; }
-keep class androidx.camera.core.impl.** { *; }

# flutter_inappwebview keeps its own JS bridge entry points.
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}

-dontwarn androidx.window.**
