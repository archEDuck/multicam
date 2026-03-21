package com.example.multicam

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.BatteryManager
import android.os.Build
import android.os.Debug
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.RandomAccessFile
import java.util.Locale
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
	private val fotChannel = "multicam/fot_sensor"
	private val camera2BridgeChannel = "multicam/camera2_bridge"
	private val dualCameraChannel = "multicam/dual_camera"
	private val systemStatsChannel = "multicam/system_stats"
	private val stereoPreprocessChannel = "multicam/stereo_preprocess"

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

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, stereoPreprocessChannel)
			.setMethodCallHandler(StereoPreprocessHandler(this))
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
	private companion object {
		private const val TAG = "DualCameraHandler"
	}

	private val dualCameraManager = DualCameraManager(context)
	private val executor = java.util.concurrent.Executors.newSingleThreadExecutor()
	private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

	private fun runOnBackground(result: MethodChannel.Result, block: () -> Any?) {
		executor.execute {
			try {
				val value = block()
				mainHandler.post { result.success(value) }
			} catch (throwable: Throwable) {
				Log.e(TAG, "Dual camera background task failed", throwable)
				val errorType = throwable.javaClass.name
				val errorMessage = throwable.message ?: "Bilinmeyen hata"
				mainHandler.post {
					result.error("CAMERA_ERROR", "$errorType: $errorMessage", null)
				}
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

			"getLatestPreviewFrames" -> {
				runOnBackground(result) {
					dualCameraManager.getLatestPreviewFrames()
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

private class StereoPreprocessHandler(
	context: Context,
) : MethodChannel.MethodCallHandler {
	private companion object {
		private const val TAG = "StereoPreprocessHandler"
	}

	private val manager = StereoPreprocessManager(context)
	private val executor = java.util.concurrent.Executors.newSingleThreadExecutor()
	private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

	private fun runOnBackground(result: MethodChannel.Result, block: () -> Any?) {
		executor.execute {
			try {
				val value = block()
				mainHandler.post { result.success(value) }
			} catch (throwable: Throwable) {
				Log.e(TAG, "Stereo preprocess background task failed", throwable)
				val errorType = throwable.javaClass.name
				val errorMessage = throwable.message ?: "Bilinmeyen hata"
				mainHandler.post {
					result.error(
						"STEREO_PREPROCESS_ERROR",
						"$errorType: $errorMessage",
						mapOf(
							"type" to errorType,
							"stacktrace" to Log.getStackTraceString(throwable),
						),
					)
				}
			}
		}
	}

	override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
		when (call.method) {
			"calibrateSession" -> {
				val sessionDir = call.argument<String>("sessionDir")
				if (sessionDir.isNullOrBlank()) {
					result.error("INVALID_ARGS", "sessionDir is required", null)
					return
				}
				runOnBackground(result) {
					manager.calibrateSession(sessionDir)
				}
			}

			"checkCheckerboard" -> {
				val cam1Path = call.argument<String>("cam1Path")
				val cam2Path = call.argument<String>("cam2Path")
				if (cam1Path.isNullOrBlank() || cam2Path.isNullOrBlank()) {
					result.error("INVALID_ARGS", "cam1Path and cam2Path are required", null)
					return
				}
				runOnBackground(result) {
					manager.checkCheckerboard(cam1Path, cam2Path)
				}
			}

			"getCalibrationStatus" -> {
				runOnBackground(result) {
					manager.getCalibrationStatus()
				}
			}

			"rectifySession" -> {
				val sessionDir = call.argument<String>("sessionDir")
				if (sessionDir.isNullOrBlank()) {
					result.error("INVALID_ARGS", "sessionDir is required", null)
					return
				}
				runOnBackground(result) {
					manager.rectifySession(sessionDir)
				}
			}

			"rectifyFramePair" -> {
				val cam1Bytes = call.argument<ByteArray>("cam1Bytes")
				val cam2Bytes = call.argument<ByteArray>("cam2Bytes")
				if (cam1Bytes == null || cam2Bytes == null || cam1Bytes.isEmpty() || cam2Bytes.isEmpty()) {
					result.error("INVALID_ARGS", "cam1Bytes and cam2Bytes are required", null)
					return
				}
				runOnBackground(result) {
					manager.rectifyFramePair(cam1Bytes, cam2Bytes)
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
		val logicalBackIds = mutableSetOf<String>()
		val physicalBackIds = mutableSetOf<String>()

		for (cameraId in cameraManager.cameraIdList) {
			val chars = cameraManager.getCameraCharacteristics(cameraId)
			if (chars.get(CameraCharacteristics.LENS_FACING) != CameraCharacteristics.LENS_FACING_BACK) {
				continue
			}

			logicalBackIds.add(cameraId)
			if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
				for (physicalId in chars.physicalCameraIds) {
					if (isBackCamera(physicalId)) {
						physicalBackIds.add(physicalId)
					}
				}
			}
		}

		val inspectIds = (if (physicalBackIds.isNotEmpty()) physicalBackIds else logicalBackIds)
			.toList()
			.sorted()

		val rawBackOptions = mutableListOf<MutableMap<String, Any>>()

		for (cameraId in inspectIds) {
			val chars = cameraManager.getCameraCharacteristics(cameraId)
			if (chars.get(CameraCharacteristics.LENS_FACING) != CameraCharacteristics.LENS_FACING_BACK) {
				continue
			}

			val capabilities = chars
				.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)
				?.toList()
				?: emptyList()

			val streamMap = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
			val jpegSizes = streamMap?.getOutputSizes(ImageFormat.JPEG)?.toList() ?: emptyList()
			val hasJpegOutput = jpegSizes.isNotEmpty()
			val isBackwardCompatible = capabilities.contains(
				CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_BACKWARD_COMPATIBLE,
			)
			val colorFilter = chars.get(CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT) ?: -1
			val isMono = colorFilter == CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_MONO

			if (!hasJpegOutput || !isBackwardCompatible || isMono) {
				continue
			}

			val focalMm = chars
				.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
				?.minOrNull()
				?.toDouble()
				?: 0.0
			if (focalMm <= 0.0) {
				continue
			}

			val pixelArray = chars.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE)
			val megapixels = if (pixelArray != null) {
				(pixelArray.width.toDouble() * pixelArray.height.toDouble()) / 1_000_000.0
			} else {
				0.0
			}

			val sensorSize = chars.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
			val minFocusDistance = chars.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE)
			val oisModes = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION)
			val hasOis = oisModes?.contains(CameraCharacteristics.LENS_OPTICAL_STABILIZATION_MODE_ON) == true

			rawBackOptions.add(
				mutableMapOf(
					"id" to cameraId,
					"focalMm" to focalMm,
					"megapixels" to megapixels,
					"hardwareLevel" to (chars.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)
						?: -1),
					"hardwareLevelName" to hardwareLevelName(
						chars.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL) ?: -1,
					),
					"supportsLogicalMultiCamera" to capabilities.contains(
						CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA,
					),
					"supportsDepthOutput" to capabilities.contains(
						CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_DEPTH_OUTPUT,
					),
					"supportsRaw" to capabilities.contains(
						CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_RAW,
					),
					"hasOis" to hasOis,
					"minFocusDistance" to (minFocusDistance?.toDouble() ?: -1.0),
					"pixelArrayWidth" to (pixelArray?.width ?: 0),
					"pixelArrayHeight" to (pixelArray?.height ?: 0),
					"sensorPhysicalWidthMm" to (sensorSize?.width?.toDouble() ?: 0.0),
					"sensorPhysicalHeightMm" to (sensorSize?.height?.toDouble() ?: 0.0),
					"maxJpegWidth" to (jpegSizes.maxOfOrNull { it.width } ?: 0),
					"maxJpegHeight" to (jpegSizes.maxOfOrNull { it.height } ?: 0),
				),
			)
		}

		val dedupedBackOptions = rawBackOptions
			.groupBy { ((it["focalMm"] as Double) * 10.0).roundToInt() }
			.map { (_, group) -> group.maxByOrNull { (it["megapixels"] as Double) }!! }
			.sortedBy { it["focalMm"] as Double }

		val mainFocalMm = if (dedupedBackOptions.isNotEmpty()) {
			dedupedBackOptions[dedupedBackOptions.size / 2]["focalMm"] as Double
		} else {
			1.0
		}

		for (option in dedupedBackOptions) {
			val focal = option["focalMm"] as Double
			val mp = option["megapixels"] as Double
			val lensType = classifyLensType(focal, mainFocalMm)
			option["lensType"] = lensType
			option["displayName"] = String.format(
				Locale.US,
				"%s • %.1fMP • %.1fmm • id=%s",
				lensType,
				mp,
				focal,
				option["id"],
			)
		}

		val filteredBackIds = dedupedBackOptions.map { it["id"].toString() }
		val selectableIdSet = filteredBackIds.toSet()

		val concurrentBackPairs = mutableListOf<List<String>>()
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
			for (group in cameraManager.concurrentCameraIds) {
				val backInGroup = group.filter { selectableIdSet.contains(it) }
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
			"backCameraIds" to filteredBackIds,
			"rawBackCameraIds" to inspectIds,
			"concurrentBackCameraPairs" to concurrentBackPairs,
			"backCameraOptions" to dedupedBackOptions,
		)
	}

	private fun classifyLensType(focalMm: Double, mainFocalMm: Double): String {
		val ratio = if (mainFocalMm > 0.0) focalMm / mainFocalMm else 1.0
		return when {
			ratio < 0.72 -> "Ultra Wide"
			ratio > 2.2 -> "Periscope Tele"
			ratio > 1.35 -> "Tele"
			else -> "Wide/Main"
		}
	}

	private fun hardwareLevelName(level: Int): String {
		return when (level) {
			CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY -> "LEGACY"
			CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED -> "LIMITED"
			CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_FULL -> "FULL"
			CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_3 -> "LEVEL_3"
			CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_EXTERNAL -> "EXTERNAL"
			else -> "UNKNOWN"
		}
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
	private val context: Context,
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
		val cpuPercent = readCpuPercent()

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
		val batteryTempC = readBatteryTemperatureC()

		return mapOf(
			"cpuPercent" to cpuPercent,
			"totalRamMB" to totalRamMB,
			"availRamMB" to availRamMB,
			"usedRamMB" to usedRamMB,
			"appHeapMB" to appHeapMB,
			"appNativeMB" to nativeHeapMB,
			"batteryTempC" to batteryTempC,
		)
	}

	private fun readCpuPercent(): Double {
		return try {
			val line = RandomAccessFile("/proc/stat", "r").use { it.readLine() }
				?: return -1.0

			val parts = line.trim().split("\\s+".toRegex())
			// parts[0]="cpu", parts[1..]=user, nice, system, idle, iowait, irq, softirq, ...
			if (parts.size < 5 || parts[0] != "cpu") {
				return -1.0
			}

			var total = 0L
			for (i in 1 until parts.size) {
				total += parts[i].toLongOrNull() ?: 0L
			}
			val idle = parts[4].toLongOrNull() ?: 0L

			val cpuPercent = if (lastCpuTotal > 0) {
				val diffTotal = total - lastCpuTotal
				val diffIdle = idle - lastCpuIdle
				if (diffTotal > 0) {
					((diffTotal - diffIdle).toDouble() / diffTotal) * 100.0
				} else {
					0.0
				}
			} else {
				0.0
			}

			lastCpuTotal = total
			lastCpuIdle = idle
			cpuPercent.coerceIn(0.0, 100.0)
		} catch (_: Exception) {
			-1.0
		}
	}

	private fun readBatteryTemperatureC(): Double {
		val batteryIntent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
		val tenthsC = batteryIntent?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
		return if (tenthsC == null || tenthsC == Int.MIN_VALUE) {
			-1.0
		} else {
			tenthsC / 10.0
		}
	}
}
