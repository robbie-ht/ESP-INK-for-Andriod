package io.github.robbieht.espink

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque
import java.util.UUID

/** All mutable link state and platform calls run on the main looper. */
@SuppressLint("MissingPermission")
class EspInkBleBridge(private val activity: Activity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    companion object {
        private val SERVICE = UUID.fromString("6d6f496e-4b00-4000-8000-000000000000")
        private val CTRL = UUID.fromString("6d6f496e-4b00-4000-8000-000000000001")
        private val DATA = UUID.fromString("6d6f496e-4b00-4000-8000-000000000002")
        private val EVT = UUID.fromString("6d6f496e-4b00-4000-8000-000000000003")
        private val CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private const val PERMISSION_REQUEST = 8423
        private const val WRITE_TIMEOUT_MS = 10000L
    }

    private enum class Stage { IDLE, CONNECTING, SERVICES, CCCD, MTU, READY }
    private data class PendingPermission(
        val kind: String, val result: MethodChannel.Result, val action: () -> Unit
    )
    private class WriteOp(
        val characteristic: BluetoothGattCharacteristic,
        val value: ByteArray,
        val writeType: Int,
        val result: MethodChannel.Result
    ) {
        var timeout: Runnable? = null
        var retry: Runnable? = null
        var localRetries = 0
    }

    private val main = Handler(Looper.getMainLooper())
    private val methods = MethodChannel(messenger, "io.github.robbieht.espink/ble")
    private val events = EventChannel(messenger, "io.github.robbieht.espink/ble_events")
    private val manager = activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private var sink: EventChannel.EventSink? = null
    private var pendingPermission: PendingPermission? = null
    private var gatt: BluetoothGatt? = null
    private var ctrl: BluetoothGattCharacteristic? = null
    private var data: BluetoothGattCharacteristic? = null
    private var evt: BluetoothGattCharacteristic? = null
    private var stage = Stage.IDLE
    private var mtu = 23
    private var connecting: MethodChannel.Result? = null
    private var stageTimeout: Runnable? = null
    private var scanning = false
    private var scanStop: Runnable? = null
    private val found = linkedMapOf<String, Map<String, Any>>()
    private val writes = ArrayDeque<WriteOp>()
    private var activeWrite: WriteOp? = null
    private var disposed = false

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
        sink = eventSink
        emit(mapOf("type" to "ready"))
        emit(mapOf("type" to "connection", "connected" to (stage == Stage.READY), "mtu" to mtu))
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        stopScan()
        cancelPermission("cancelled", "蓝牙服务已关闭。")
        closeLink("cancelled", "蓝牙服务已关闭。", false)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            result.error("disposed", "蓝牙服务已关闭。", null)
            return
        }
        when (call.method) {
            "startScan" -> withPermissions("scan", result) { startScan(result) }
            "stopScan" -> {
                if (pendingPermission?.kind == "scan") cancelPermission("cancelled", "扫描已取消。")
                stopScan()
                result.success(null)
            }
            "connect" -> {
                val id = call.argument<String>("id")
                if (id == null || !BluetoothAdapter.checkBluetoothAddress(id)) {
                    result.error("invalid_device", "设备地址无效，请重新扫描。", null)
                } else {
                    withPermissions("connect", result) { connect(id, result) }
                }
            }
            "writeCtrl" -> enqueueWrite(call.arguments, true, result)
            "writeData" -> enqueueWrite(call.arguments, false, result)
            "disconnect" -> {
                stopScan()
                cancelPermission("cancelled", "连接已取消。")
                closeLink("disconnected", "蓝牙已断开，请重新连接。", false)
                result.success(null)
            }
            "openBluetoothSettings" -> {
                try {
                    activity.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
                    result.success(null)
                } catch (_: Exception) {
                    result.error("settings_unavailable", "无法打开蓝牙设置，请在系统设置中开启蓝牙。", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun requiredPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun withPermissions(kind: String, result: MethodChannel.Result, action: () -> Unit) {
        if (pendingPermission != null) {
            result.error("permission_pending", "请先完成当前蓝牙权限请求。", null)
            return
        }
        if (sink == null) {
            result.error("events_not_ready", "蓝牙事件通道尚未就绪，请重新打开设备页面。", null)
            return
        }
        val missing = requiredPermissions().filter {
            activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            guarded(result, action)
        } else {
            pendingPermission = PendingPermission(kind, result, action)
            try {
                activity.requestPermissions(missing.toTypedArray(), PERMISSION_REQUEST)
            } catch (_: Exception) {
                cancelPermission("permission_failed", "系统无法打开蓝牙权限请求，请在应用权限设置中授权。")
            }
        }
    }

    fun onPermissionsResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != PERMISSION_REQUEST) return
        val pending = pendingPermission ?: return
        pendingPermission = null
        if (grantResults.isNotEmpty() && requiredPermissions().all {
                activity.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
            }) {
            guarded(pending.result, pending.action)
        } else {
            val message = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                "需要“附近的设备”权限才能扫描与连接，请在系统应用权限中允许后重试。"
            } else {
                "Android 11 及以下扫描蓝牙需要定位权限，请允许权限并开启系统定位。"
            }
            pending.result.error("permission_denied", message, null)
        }
    }

    private fun guarded(result: MethodChannel.Result, action: () -> Unit) {
        try { action() } catch (_: SecurityException) {
            result.error("permission_denied", "蓝牙权限已被撤销，请重新授权后连接。", null)
        } catch (error: Exception) {
            result.error("bluetooth_error", "蓝牙操作失败：${error.message ?: "系统服务不可用"}", null)
        }
    }

    private fun adapter(result: MethodChannel.Result): BluetoothAdapter? {
        val adapter = manager?.adapter
        if (adapter == null) {
            result.error("unsupported", "这台设备没有可用的蓝牙适配器。", null)
            return null
        }
        if (!adapter.isEnabled) {
            result.error("bluetooth_off", "手机蓝牙未开启，请打开系统蓝牙后重试。", null)
            return null
        }
        return adapter
    }

    private fun startScan(result: MethodChannel.Result) {
        if (gatt != null) {
            result.error("busy", "已有设备连接，请断开后重新扫描。", null)
            return
        }
        val adapter = adapter(result) ?: return
        if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.R) {
            val location = activity.getSystemService(Context.LOCATION_SERVICE) as LocationManager
            val enabled = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                location.isLocationEnabled
            } else {
                location.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                    location.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
            }
            if (!enabled) {
                result.error("location_off", "此 Android 版本需开启系统定位才能扫描蓝牙；应用不会读取位置。", null)
                return
            }
        }
        val scanner = adapter.bluetoothLeScanner
        if (scanner == null) {
            result.error("scanner_unavailable", "系统蓝牙扫描暂不可用，请重新开启蓝牙。", null)
            return
        }
        stopScan()
        found.clear()
        emit(mapOf("type" to "scan", "devices" to emptyList<Any>()))
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE)).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        scanner.startScan(listOf(filter), settings, scanCallback)
        scanning = true
        emit(mapOf("type" to "scanState", "scanning" to true))
        scanStop = Runnable { stopScan() }.also { main.postDelayed(it, 12000) }
        result.success(null)
    }

    private fun stopScan() {
        scanStop?.let { main.removeCallbacks(it) }
        scanStop = null
        if (scanning) {
            scanning = false
            try { manager?.adapter?.bluetoothLeScanner?.stopScan(scanCallback) } catch (_: Exception) { }
            emit(mapOf("type" to "scanState", "scanning" to false))
        }
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            main.post { acceptScanResult(result) }
        }
        override fun onBatchScanResults(results: MutableList<ScanResult>) {
            main.post { results.forEach { acceptScanResult(it) } }
        }
        override fun onScanFailed(errorCode: Int) {
            main.post {
                if (!scanning) return@post
                stopScan()
                emitError("扫描失败（$errorCode），请稍后重试或重新开启蓝牙。")
            }
        }
    }

    private fun acceptScanResult(result: ScanResult) {
        if (!scanning || disposed) return
        try {
            // Match identity by advertised service, never by a mutable name prefix.
            val id = result.device.address
            val oldName = found[id]?.get("name") as? String
            val name = result.scanRecord?.deviceName?.takeIf { it.isNotBlank() }
                ?: result.device.name?.takeIf { it.isNotBlank() } ?: oldName ?: "未命名 ESP-INK"
            found[id] = mapOf("id" to id, "name" to name, "rssi" to result.rssi)
            emit(mapOf("type" to "scan", "devices" to found.values.toList()))
        } catch (_: SecurityException) {
            stopScan()
            emitError("蓝牙权限已被撤销，请重新授权。")
        }
    }

    private fun connect(id: String, result: MethodChannel.Result) {
        if (gatt != null || connecting != null) {
            result.error("busy", "已有连接或正在连接，请先断开。", null)
            return
        }
        val adapter = adapter(result) ?: return
        stopScan()
        connecting = result
        stage = Stage.CONNECTING
        mtu = 23
        armStageTimeout(20000, "连接超时，请唤醒设备后重试。")
        try {
            gatt = adapter.getRemoteDevice(id).connectGatt(
                activity, false, gattCallback, android.bluetooth.BluetoothDevice.TRANSPORT_LE
            )
            if (gatt == null) failLink("connect_failed", "系统未能创建蓝牙连接，请重试。")
        } catch (_: SecurityException) {
            failLink("permission_denied", "蓝牙权限已被撤销，请重新授权。")
        } catch (error: Exception) {
            failLink("connect_failed", "无法连接设备：${error.message ?: "系统连接失败"}")
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(link: BluetoothGatt, status: Int, newState: Int) {
            main.post {
                if (link !== gatt) return@post
                if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) {
                    failLink("disconnected", "设备蓝牙已断开（$status）；未完成任务的结果需要重新确认。")
                } else if (newState == BluetoothProfile.STATE_CONNECTED && stage == Stage.CONNECTING) {
                    stage = Stage.SERVICES
                    armStageTimeout(12000, "发现服务超时，请重新连接。")
                    try {
                        if (!link.discoverServices()) failLink("discover_failed", "无法开始发现设备服务。")
                    } catch (_: SecurityException) {
                        failLink("permission_denied", "蓝牙权限已被撤销。")
                    } catch (_: Exception) {
                        failLink("discover_failed", "系统蓝牙无法发现服务，请重新连接。")
                    }
                }
            }
        }

        override fun onServicesDiscovered(link: BluetoothGatt, status: Int) {
            main.post {
                if (link !== gatt || stage != Stage.SERVICES) return@post
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    failLink("discover_failed", "发现服务失败（$status），请重新连接。")
                    return@post
                }
                val service = link.getService(SERVICE)
                ctrl = service?.getCharacteristic(CTRL)
                data = service?.getCharacteristic(DATA)
                evt = service?.getCharacteristic(EVT)
                val control = ctrl
                val payload = data
                val notification = evt
                if (control == null || payload == null || notification == null ||
                    control.properties and BluetoothGattCharacteristic.PROPERTY_WRITE == 0 ||
                    payload.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE == 0 ||
                    notification.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY == 0) {
                    failLink("incompatible_device", "设备缺少 ESP-INK 所需服务或特征，请核对固件版本。")
                    return@post
                }
                val cccd = notification.getDescriptor(CCCD)
                if (cccd == null) {
                    failLink("notify_unavailable", "设备缺少通知订阅描述符，无法接收命令回执。")
                    return@post
                }
                stage = Stage.CCCD
                armStageTimeout(8000, "订阅通知超时，请重新连接。")
                try {
                    if (!link.setCharacteristicNotification(notification, true) || !writeCccd(link, cccd)) {
                        failLink("notify_failed", "无法订阅设备通知，请重新连接。")
                    }
                } catch (_: SecurityException) {
                    failLink("permission_denied", "蓝牙权限已被撤销。")
                } catch (_: Exception) {
                    failLink("notify_failed", "系统蓝牙无法订阅通知，请重新连接。")
                }
            }
        }

        override fun onDescriptorWrite(link: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            main.post {
                if (link !== gatt || stage != Stage.CCCD || descriptor.uuid != CCCD) return@post
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    failLink("notify_failed", "订阅设备通知失败（$status）。")
                    return@post
                }
                stage = Stage.MTU
                armStageTimeout(10000, "协商 MTU 超时，请重新连接。")
                try {
                    if (!link.requestMtu(517)) failLink("mtu_failed", "无法协商 MTU，当前链路不能读取完整设备状态。")
                } catch (_: SecurityException) {
                    failLink("permission_denied", "蓝牙权限已被撤销。")
                } catch (_: Exception) {
                    failLink("mtu_failed", "系统蓝牙无法协商 MTU，请重新连接。")
                }
            }
        }

        override fun onMtuChanged(link: BluetoothGatt, actualMtu: Int, status: Int) {
            main.post {
                if (link !== gatt || (stage != Stage.MTU && stage != Stage.READY)) return@post
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    failLink("mtu_failed", "协商 MTU 失败（$status），请重新连接。")
                    return@post
                }
                mtu = actualMtu
                if (mtu < 39) {
                    failLink("mtu_too_small", "当前 MTU 为 $mtu，低于读取设备状态所需的 39，请换用兼容手机或重新连接。")
                    return@post
                }
                clearStageTimeout()
                stage = Stage.READY
                emit(mapOf("type" to "connection", "connected" to true, "mtu" to mtu))
                val result = connecting
                connecting = null
                result?.success(mapOf("mtu" to mtu))
                if (mtu < 48) emitError("当前 MTU 为 $mtu，较长设备名称的设置查询可能不受支持；建议 MTU 至少为 48。")
            }
        }

        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(link: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            // Android 13+ delivers the value-bearing overload below.
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                forwardNotification(link, characteristic.uuid, characteristic.value?.copyOf() ?: byteArrayOf())
            }
        }

        override fun onCharacteristicChanged(
            link: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray
        ) { forwardNotification(link, characteristic.uuid, value.copyOf()) }

        override fun onCharacteristicWrite(link: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            main.post {
                if (link !== gatt) return@post
                val operation = activeWrite ?: return@post
                if (operation.characteristic.uuid != characteristic.uuid) {
                    failLink("write_order", "蓝牙写入回调顺序异常，已停止传输，请重新连接。")
                    return@post
                }
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    failLink("write_failed", "蓝牙写入失败（$status）；传输已停止，请重新连接。")
                    return@post
                }
                activeWrite = null
                operation.timeout?.let { main.removeCallbacks(it) }
                operation.retry?.let { main.removeCallbacks(it) }
                // For DATA this confirms the local stack write, not remote delivery.
                operation.result.success(null)
                pumpWrites()
            }
        }
    }

    private fun forwardNotification(link: BluetoothGatt, uuid: UUID, value: ByteArray) {
        main.post {
            if (link === gatt && uuid == EVT && stage != Stage.IDLE) {
                emit(mapOf("type" to "notification", "value" to value))
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun writeCccd(link: BluetoothGatt, descriptor: BluetoothGattDescriptor): Boolean {
        val value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            link.writeDescriptor(descriptor, value) == BluetoothStatusCodes.SUCCESS
        } else {
            descriptor.value = value
            link.writeDescriptor(descriptor)
        }
    }

    private fun enqueueWrite(arguments: Any?, isControl: Boolean, result: MethodChannel.Result) {
        val characteristic = if (isControl) ctrl else data
        if (stage != Stage.READY || gatt == null || characteristic == null) {
            result.error("not_connected", "蓝牙未就绪，请重新连接。", null)
            return
        }
        val value = arguments as? ByteArray
        // Android BluetoothGatt limits the entire attribute value to 512 bytes,
        // independently of a negotiated MTU of 517 or larger.
        val maxLength = minOf(mtu - 3, 512)
        if (value == null || value.isEmpty() || value.size > maxLength) {
            result.error("invalid_payload", "数据包不能为空或超过当前蓝牙写入上限 $maxLength 字节，请重新协商分片。", null)
            return
        }
        if (writes.size >= 256) {
            result.error("queue_full", "蓝牙写入队列已满，请等待当前传输完成。", null)
            return
        }
        val writeType = if (isControl) BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            else BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        val operation = WriteOp(characteristic, value.copyOf(), writeType, result)
        operation.timeout = Runnable {
            if (activeWrite === operation || writes.contains(operation)) {
                failLink("write_timeout", "蓝牙写入或队列等待超时，已停止传输；请重新连接后重新开始。")
            }
        }.also { main.postDelayed(it, WRITE_TIMEOUT_MS) }
        writes.addLast(operation)
        pumpWrites()
    }

    private fun pumpWrites() {
        if (activeWrite != null || stage != Stage.READY) return
        val link = gatt ?: return
        val operation = writes.pollFirst() ?: return
        activeWrite = operation
        startWrite(link, operation)
    }

    @Suppress("DEPRECATION")
    private fun startWrite(link: BluetoothGatt, operation: WriteOp) {
        if (link !== gatt || stage != Stage.READY || activeWrite !== operation) return
        try {
            val localBusy: Boolean
            val accepted: Boolean
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val status = link.writeCharacteristic(
                    operation.characteristic, operation.value, operation.writeType
                )
                accepted = status == BluetoothStatusCodes.SUCCESS
                localBusy = status == BluetoothStatusCodes.ERROR_GATT_WRITE_REQUEST_BUSY
            } else {
                operation.characteristic.writeType = operation.writeType
                operation.characteristic.value = operation.value
                accepted = link.writeCharacteristic(operation.characteristic)
                // false means this legacy API did not initiate the write.
                localBusy = !accepted
            }
            if (!accepted) {
                if (localBusy && operation.writeType == BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE &&
                    operation.localRetries < 3) {
                    operation.localRetries++
                    // Retry only local rejection of DATA. Never retry a failed
                    // asynchronous callback or CTRL with possible side effects.
                    // The original queue/write deadline remains in force.
                    operation.retry = Runnable {
                        operation.retry = null
                        startWrite(link, operation)
                    }.also { main.postDelayed(it, 30) }
                } else {
                    failLink("write_rejected", "系统蓝牙拒绝写入，已停止传输，请重新连接。")
                }
            }
        } catch (_: SecurityException) {
            failLink("permission_denied", "蓝牙权限已被撤销，传输已停止。")
        } catch (error: Exception) {
            failLink("write_failed", "蓝牙写入异常：${error.message ?: "系统错误"}")
        }
    }

    private fun armStageTimeout(delay: Long, message: String) {
        clearStageTimeout()
        stageTimeout = Runnable { failLink("timeout", message) }.also { main.postDelayed(it, delay) }
    }

    private fun clearStageTimeout() {
        stageTimeout?.let { main.removeCallbacks(it) }
        stageTimeout = null
    }

    private fun failLink(code: String, message: String) {
        val wasReady = stage == Stage.READY
        closeLink(code, message, wasReady)
    }

    private fun closeLink(code: String, message: String, reportError: Boolean) {
        clearStageTimeout()
        val link = gatt
        gatt = null // Ignore callbacks from this closed connection immediately.
        stage = Stage.IDLE
        mtu = 23
        ctrl = null
        data = null
        evt = null
        val pending = connecting
        connecting = null
        pending?.error(code, message, null)
        val current = activeWrite
        activeWrite = null
        if (current != null) failWrite(current, code, message)
        while (writes.isNotEmpty()) failWrite(writes.removeFirst(), code, message)
        try { link?.disconnect() } catch (_: Exception) { }
        try { link?.close() } catch (_: Exception) { }
        emit(mapOf("type" to "connection", "connected" to false, "mtu" to 23))
        if (reportError) emitError(message)
    }

    private fun failWrite(operation: WriteOp, code: String, message: String) {
        operation.timeout?.let { main.removeCallbacks(it) }
        operation.retry?.let { main.removeCallbacks(it) }
        operation.result.error(code, message, null)
    }

    private fun cancelPermission(code: String, message: String) {
        val pending = pendingPermission
        pendingPermission = null
        pending?.result?.error(code, message, null)
    }

    private fun emit(value: Map<String, Any>) { sink?.success(value) }
    private fun emitError(message: String) { emit(mapOf("type" to "error", "message" to message)) }

    fun dispose() {
        if (disposed) return
        stopScan()
        cancelPermission("disposed", "应用已关闭。")
        closeLink("disposed", "应用已关闭，未完成操作已停止。", false)
        disposed = true
        sink = null
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }
}
