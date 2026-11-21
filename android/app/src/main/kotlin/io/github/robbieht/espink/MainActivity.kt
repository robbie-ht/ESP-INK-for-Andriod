package io.github.robbieht.espink

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var ble: EspInkBleBridge? = null
    private var imageExport: EspInkImageExportBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ble = EspInkBleBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        imageExport?.dispose()
        imageExport = EspInkImageExportBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        imageExport?.dispose()
        imageExport = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        ble?.onPermissionsResult(requestCode, grantResults)
        imageExport?.onPermissionsResult(requestCode, grantResults)
    }

    override fun onDestroy() {
        ble?.dispose()
        ble = null
        imageExport?.dispose()
        imageExport = null
        super.onDestroy()
    }
}
