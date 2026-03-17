package com.example.multicam

import android.app.ActivityManager
import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.Debug
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.RandomAccessFile

class MainActivity : FlutterActivity() {
	private val fotChannel = "multicam/fot_sensor"
	private val camera2BridgeChannel = "multicam/camera2_bridge"
	private val dualCameraChannel = "multicam/dual_camera"
	private val systemStatsChannel = "multicam/system_stats"

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		EventChannel(flutterEngine.dartExecutor.binaryMessenger, fotChannel)
			.setStreamHandler(FotSensorStreamHandler(this))

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, camera2BridgeChannel)
			.setMethodCallHandler(Camera2BridgeHandler(this))

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, dualCameraChannel)
			.setMethodCallHandler(DualCameraHandler(this))

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, systemStatsChannel)
			.setMethodCallHandler(SystemStatsHandler(this))
	}
}

/**
 * MethodChannel handler for dual camera operations.
 * All blocking camera operations run on a background thread to avoid ANR.
 * Results are delivered back on the main thread.
 */
private class DualCameraHandler(
	context: Context,
) : MethodChannel.MethodCallHandler {
	private val dualCameraManager = DualCameraManager(context)
	private val executor = java.util.concurrent.Executors.newSingleThreadExecutor()
	private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

	private fun runOnBackground(result: MethodChannel.Result, block: () -> Any?) {
		executor.execute {
			try {
				val value = block()
				mainHandler.post { result.success(value) }
			} catch (e: Exception) {
				mainHandler.post { result.error("CAMERA_ERROR", e.message, null) }
			}
		}
	}

	override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
		when (call.method) {
			"findBestPair" -> {
				runOnBackground(result) {
					dualCameraManager.findBestConcurrentPair()
				}
			}

			"openDualCameras" -> {
				val cam1Id = call.argument<String>("cam1Id")
				val cam2Id = call.argument<String>("cam2Id")
				if (cam1Id == null || cam2Id == null) {
					result.error("INVALID_ARGS", "cam1Id and cam2Id are required", null)
					return
				}
				runOnBackground(result) {
					dualCameraManager.openCameras(cam1Id, cam2Id)
				}
			}

			"captureDualFrame" -> {
				val cam1Path = call.argument<String>("cam1Path")
				val cam2Path = call.argument<String>("cam2Path")
				if (cam1Path == null || cam2Path == null) {
					result.error("INVALID_ARGS", "cam1Path and cam2Path are required", null)
					return
				}
				runOnBackground(result) {
					dualCameraManager.captureDualFrame(cam1Path, cam2Path)
				}
			}

			"closeDualCameras" -> {
				runOnBackground(result) {
					dualCameraManager.closeCameras()
					mapOf("success" to true)
				}
			}

			"getCameraStatus" -> {
				runOnBackground(result) {
					dualCameraManager.getStatus()
				}
			}

			else -> result.notImplemented()
		}
	}
}


private class Camera2BridgeHandler(
	context: Context,
) : MethodChannel.MethodCallHandler {
	private val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

	override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
		when (call.method) {
			"getBackCameraReport" -> {
				try {
					result.success(buildBackCameraReport())
				} catch (error: Exception) {
					result.error("CAMERA2_REPORT_ERROR", error.message, null)
				}
			}

			else -> result.notImplemented()
		}
	}

	private fun buildBackCameraReport(): Map<String, Any> {
		val cameras = mutableListOf<Map<String, Any>>()
		val backIds = mutableListOf<String>()

		for (cameraId in cameraManager.cameraIdList) {
			val characteristics = cameraManager.getCameraCharacteristics(cameraId)
			val lensFacing = characteristics.get(CameraCharacteristics.LENS_FACING)
			if (lensFacing == CameraCharacteristics.LENS_FACING_BACK) {
				backIds.add(cameraId)
			}

			val capabilities = characteristics
				.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)
				?.toList()
				?: emptyList()
			val focalLengths = characteristics
				.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
				?.map { it.toDouble() }
				?: emptyList()

			cameras.add(
				mapOf(
					"id" to cameraId,
					"isBack" to (lensFacing == CameraCharacteristics.LENS_FACING_BACK),
					"hardwareLevel" to (characteristics.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)
						?: -1),
					"capabilities" to capabilities,
					"focalLengths" to focalLengths,
					"supportsDepthOutput" to capabilities.contains(
						CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_DEPTH_OUTPUT,
					),
				),
			)
		}

		val concurrentBackPairs = mutableListOf<List<String>>()
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
			for (group in cameraManager.concurrentCameraIds) {
				val backInGroup = group.filter { isBackCamera(it) }
				if (backInGroup.size >= 2) {
					for (i in 0 until backInGroup.size - 1) {
						for (j in i + 1 until backInGroup.size) {
							concurrentBackPairs.add(listOf(backInGroup[i], backInGroup[j]))
						}
					}
				}
			}
		}

		return mapOf(
			"apiLevel" to Build.VERSION.SDK_INT,
			"backCameraIds" to backIds,
			"concurrentBackCameraPairs" to concurrentBackPairs,
			"cameras" to cameras,
		)
	}

	private fun isBackCamera(cameraId: String): Boolean {
		val characteristics = cameraManager.getCameraCharacteristics(cameraId)
		return characteristics.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
	}
}

private class FotSensorStreamHandler(
	context: Context,
) : EventChannel.StreamHandler, SensorEventListener {
	private val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
	private val sensor: Sensor? = sensorManager.getDefaultSensor(Sensor.TYPE_PROXIMITY)
	private var eventSink: EventChannel.EventSink? = null

	override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
		eventSink = events

		if (sensor == null) {
			events?.error("SENSOR_UNAVAILABLE", "TYPE_PROXIMITY sensor not found.", null)
			return
		}

		sensorManager.registerListener(this, sensor, SensorManager.SENSOR_DELAY_NORMAL)
	}

	override fun onCancel(arguments: Any?) {
		sensorManager.unregisterListener(this)
		eventSink = null
	}

	override fun onSensorChanged(event: SensorEvent?) {
		val value = event?.values?.firstOrNull() ?: return
		eventSink?.success(value.toDouble())
	}

	override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
		// No-op
	}
}

/**
 * Provides system stats (CPU usage, RAM usage) via MethodChannel.
 */
private class SystemStatsHandler(
	context: Context,
) : MethodChannel.MethodCallHandler {
	private val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
	private var lastCpuIdle: Long = 0
	private var lastCpuTotal: Long = 0

	override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
		when (call.method) {
			"getSystemStats" -> {
				try {
					result.success(buildStats())
				} catch (e: Exception) {
					result.error("STATS_ERROR", e.message, null)
				}
			}
			else -> result.notImplemented()
		}
	}

	private fun buildStats(): Map<String, Any> {
		// --- CPU usage from /proc/stat ---
		var cpuPercent = 0.0
		try {
			val reader = RandomAccessFile("/proc/stat", "r")
			val line = reader.readLine() // first line: cpu  user nice system idle ...
			reader.close()

			val parts = line.split("\\s+".toRegex())
			// parts[0]="cpu", parts[1..]=user, nice, system, idle, iowait, irq, softirq, ...
			if (parts.size >= 5) {
				var total = 0L
				for (i in 1 until parts.size) {
					total += parts[i].toLongOrNull() ?: 0
				}
				val idle = parts[4].toLongOrNull() ?: 0

				if (lastCpuTotal > 0) {
					val diffTotal = total - lastCpuTotal
					val diffIdle = idle - lastCpuIdle
					if (diffTotal > 0) {
						cpuPercent = ((diffTotal - diffIdle).toDouble() / diffTotal) * 100.0
					}
				}
				lastCpuTotal = total
				lastCpuIdle = idle
			}
		} catch (_: Exception) {
			cpuPercent = -1.0
		}

		// --- RAM usage ---
		val memInfo = ActivityManager.MemoryInfo()
		activityManager.getMemoryInfo(memInfo)

		val totalRamMB = memInfo.totalMem / (1024.0 * 1024.0)
		val availRamMB = memInfo.availMem / (1024.0 * 1024.0)
		val usedRamMB = totalRamMB - availRamMB

		// App-specific memory
		val rt = Runtime.getRuntime()
		val appHeapMB = (rt.totalMemory() - rt.freeMemory()) / (1024.0 * 1024.0)
		val nativeHeapMB = Debug.getNativeHeapAllocatedSize() / (1024.0 * 1024.0)

		return mapOf(
			"cpuPercent" to String.format("%.1f", cpuPercent).toDouble(),
			"totalRamMB" to String.format("%.0f", totalRamMB).toDouble(),
			"availRamMB" to String.format("%.0f", availRamMB).toDouble(),
			"usedRamMB" to String.format("%.0f", usedRamMB).toDouble(),
			"appHeapMB" to String.format("%.1f", appHeapMB).toDouble(),
			"appNativeMB" to String.format("%.1f", nativeHeapMB).toDouble(),
		)
	}
}
