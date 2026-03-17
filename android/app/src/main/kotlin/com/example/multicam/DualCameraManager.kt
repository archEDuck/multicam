package com.example.multicam

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.*
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit

/**
 * Manages dual back-camera capture using Android's Logical Multi-Camera API.
 *
 * Strategy:
 * 1. Open a logical multi-camera (single CameraDevice)
 * 2. Configure two outputs bound to two physical cameras
 * 3. Run a REPEATING preview request to keep the pipeline warm
 * 4. On captureDualFrame(), grab latest frames from ImageReaders
 *
 * Fallback: alternating capture if no logical multi-camera found.
 */
class DualCameraManager(private val context: Context) {
    companion object {
        private const val TAG = "DualCameraManager"
        private const val IMAGE_WIDTH = 640
        private const val IMAGE_HEIGHT = 480
        private const val OPEN_TIMEOUT_MS = 5000L
        private const val CAPTURE_TIMEOUT_MS = 3000L
    }

    enum class CaptureMode {
        LOGICAL_MULTI_CAMERA,
        ALTERNATING
    }

    data class LogicalCameraInfo(
        val logicalId: String,
        val physicalId1: String,
        val physicalId2: String,
    )

    private val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    private var backgroundThread: HandlerThread? = null
    private var backgroundHandler: Handler? = null

    // For LOGICAL_MULTI_CAMERA mode
    private var logicalDevice: CameraDevice? = null
    private var logicalSession: CameraCaptureSession? = null
    private var reader1: ImageReader? = null
    private var reader2: ImageReader? = null

    // Latest frame byte buffers (written by ImageReader listener, read by captureDualFrame)
    @Volatile private var latestBytes1: ByteArray? = null
    @Volatile private var latestBytes2: ByteArray? = null

    // For ALTERNATING mode
    private var altCam1Id: String? = null
    private var altCam2Id: String? = null

    var captureMode: CaptureMode? = null
        private set
    var physicalId1: String? = null
        private set
    var physicalId2: String? = null
        private set
    var isOpen: Boolean = false
        private set

    // ─── Background Thread ───

    private fun startBackgroundThread() {
        backgroundThread = HandlerThread("DualCameraThread").also { it.start() }
        backgroundHandler = Handler(backgroundThread!!.looper)
    }

    private fun stopBackgroundThread() {
        backgroundThread?.quitSafely()
        try { backgroundThread?.join() } catch (_: InterruptedException) {}
        backgroundThread = null
        backgroundHandler = null
    }

    // ─── Find Logical Multi-Camera ───

    fun findLogicalMultiCamera(): LogicalCameraInfo? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return null

        for (cameraId in cameraManager.cameraIdList) {
            val chars = cameraManager.getCameraCharacteristics(cameraId)
            val facing = chars.get(CameraCharacteristics.LENS_FACING)
            if (facing != CameraCharacteristics.LENS_FACING_BACK) continue

            val caps = chars.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES) ?: continue
            if (!caps.contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA)) continue

            val physicalIds = chars.physicalCameraIds.toList()
            val backPhysicalIds = physicalIds.filter { isBackCamera(it) }

            if (backPhysicalIds.size >= 2) {
                Log.i(TAG, "Found logical multi-camera: $cameraId with physical back cameras: $backPhysicalIds")
                return LogicalCameraInfo(cameraId, backPhysicalIds[0], backPhysicalIds[1])
            }
        }

        Log.w(TAG, "No logical multi-camera with >=2 back physical cameras found")
        return null
    }

    fun findBestConcurrentPair(): Map<String, Any> {
        val logicalInfo = findLogicalMultiCamera()
        if (logicalInfo != null) {
            return mapOf(
                "found" to true,
                "cam1Id" to logicalInfo.physicalId1,
                "cam2Id" to logicalInfo.physicalId2,
                "logicalId" to logicalInfo.logicalId,
                "mode" to "logical_multi_camera",
            )
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val backIds = getBackCameraIds()
            for (group in cameraManager.concurrentCameraIds) {
                val backInGroup = group.filter { backIds.contains(it) }
                if (backInGroup.size >= 2) {
                    return mapOf(
                        "found" to true,
                        "cam1Id" to backInGroup[0],
                        "cam2Id" to backInGroup[1],
                        "mode" to "concurrent",
                    )
                }
            }
        }

        val backIds = getBackCameraIds()
        return if (backIds.size >= 2) {
            mapOf(
                "found" to true,
                "cam1Id" to backIds[0],
                "cam2Id" to backIds[1],
                "mode" to "alternating",
            )
        } else {
            mapOf("found" to false)
        }
    }

    // ─── Open Cameras ───

    @SuppressLint("MissingPermission")
    fun openCameras(cam1Id: String, cam2Id: String): Map<String, Any> {
        if (isOpen) closeCameras()
        startBackgroundThread()

        val logicalInfo = findLogicalMultiCameraContaining(cam1Id, cam2Id)
        if (logicalInfo != null) {
            val result = openLogicalMultiCamera(logicalInfo)
            if (result["success"] == true) return result
            Log.w(TAG, "Logical multi-camera failed, falling back to alternating")
        }

        return openAlternating(cam1Id, cam2Id)
    }

    private fun findLogicalMultiCameraContaining(phys1: String, phys2: String): LogicalCameraInfo? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return null

        for (cameraId in cameraManager.cameraIdList) {
            val chars = cameraManager.getCameraCharacteristics(cameraId)
            val caps = chars.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES) ?: continue
            if (!caps.contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA)) continue

            val physicalIds = chars.physicalCameraIds
            if (physicalIds.contains(phys1) && physicalIds.contains(phys2)) {
                return LogicalCameraInfo(cameraId, phys1, phys2)
            }
        }

        return findLogicalMultiCamera()
    }

    @SuppressLint("MissingPermission")
    private fun openLogicalMultiCamera(info: LogicalCameraInfo): Map<String, Any> {
        Log.i(TAG, "Opening logical multi-camera: ${info.logicalId} (physical: ${info.physicalId1}, ${info.physicalId2})")

        captureMode = CaptureMode.LOGICAL_MULTI_CAMERA
        physicalId1 = info.physicalId1
        physicalId2 = info.physicalId2

        try {
            // Create ImageReaders with extra buffer for repeating request
            reader1 = ImageReader.newInstance(IMAGE_WIDTH, IMAGE_HEIGHT, ImageFormat.JPEG, 4)
            reader2 = ImageReader.newInstance(IMAGE_WIDTH, IMAGE_HEIGHT, ImageFormat.JPEG, 4)

            // Set up continuous frame listeners that buffer the latest bytes
            reader1!!.setOnImageAvailableListener({ reader ->
                val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
                try {
                    val buffer = image.planes[0].buffer
                    val bytes = ByteArray(buffer.remaining())
                    buffer.get(bytes)
                    latestBytes1 = bytes
                } catch (e: Exception) {
                    Log.e(TAG, "Error reading cam1 image", e)
                } finally {
                    image.close()
                }
            }, backgroundHandler)

            reader2!!.setOnImageAvailableListener({ reader ->
                val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
                try {
                    val buffer = image.planes[0].buffer
                    val bytes = ByteArray(buffer.remaining())
                    buffer.get(bytes)
                    latestBytes2 = bytes
                } catch (e: Exception) {
                    Log.e(TAG, "Error reading cam2 image", e)
                } finally {
                    image.close()
                }
            }, backgroundHandler)

            // Open logical camera device
            val openLatch = CountDownLatch(1)
            var openError: String? = null

            cameraManager.openCamera(info.logicalId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    logicalDevice = camera
                    Log.i(TAG, "Logical camera ${info.logicalId} opened")
                    openLatch.countDown()
                }
                override fun onDisconnected(camera: CameraDevice) {
                    logicalDevice = null
                    openError = "disconnected"
                    openLatch.countDown()
                }
                override fun onError(camera: CameraDevice, errorCode: Int) {
                    logicalDevice = null
                    openError = "error=$errorCode"
                    openLatch.countDown()
                }
            }, backgroundHandler)

            if (!openLatch.await(OPEN_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                closeCameras()
                return mapOf("success" to false, "error" to "Camera open timeout")
            }
            if (openError != null) {
                closeCameras()
                return mapOf("success" to false, "error" to "Camera open: $openError")
            }

            // Create session with physical-camera-bound outputs
            val output1 = OutputConfiguration(reader1!!.surface)
            output1.setPhysicalCameraId(info.physicalId1)

            val output2 = OutputConfiguration(reader2!!.surface)
            output2.setPhysicalCameraId(info.physicalId2)

            val sessionLatch = CountDownLatch(1)
            var sessionError: String? = null

            val executor = Executor { command -> backgroundHandler?.post(command) }

            val sessionConfig = SessionConfiguration(
                SessionConfiguration.SESSION_REGULAR,
                listOf(output1, output2),
                executor,
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        logicalSession = session
                        Log.i(TAG, "Session configured")
                        sessionLatch.countDown()
                    }
                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        sessionError = "session config failed"
                        Log.e(TAG, "Session configuration failed")
                        sessionLatch.countDown()
                    }
                },
            )

            logicalDevice!!.createCaptureSession(sessionConfig)

            if (!sessionLatch.await(OPEN_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                closeCameras()
                return mapOf("success" to false, "error" to "Session timeout")
            }
            if (sessionError != null) {
                closeCameras()
                return mapOf("success" to false, "error" to sessionError!!)
            }

            // Start REPEATING preview request to keep the pipeline warm and flowing
            val previewRequest = logicalDevice!!.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                addTarget(reader1!!.surface)
                addTarget(reader2!!.surface)
                set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
            }.build()

            logicalSession!!.setRepeatingRequest(previewRequest, null, backgroundHandler)
            Log.i(TAG, "Repeating preview started for both physical cameras")

            // Wait a moment for auto-exposure/focus to converge
            Thread.sleep(500)

            isOpen = true
            return mapOf(
                "success" to true,
                "mode" to "logical_multi_camera",
                "logicalId" to info.logicalId,
                "cam1Id" to info.physicalId1,
                "cam2Id" to info.physicalId2,
            )

        } catch (e: Exception) {
            Log.e(TAG, "Failed to open logical multi-camera", e)
            closeCameras()
            return mapOf("success" to false, "error" to "Exception: ${e.message}")
        }
    }

    private fun openAlternating(cam1Id: String, cam2Id: String): Map<String, Any> {
        Log.i(TAG, "Using alternating capture mode: $cam1Id, $cam2Id")
        captureMode = CaptureMode.ALTERNATING
        altCam1Id = cam1Id
        altCam2Id = cam2Id
        physicalId1 = cam1Id
        physicalId2 = cam2Id
        isOpen = true
        return mapOf(
            "success" to true,
            "mode" to "alternating",
            "cam1Id" to cam1Id,
            "cam2Id" to cam2Id,
        )
    }

    // ─── Capture ───

    fun captureDualFrame(cam1Path: String, cam2Path: String): Map<String, Any> {
        if (!isOpen) {
            return mapOf("success" to false, "error" to "Not open", "cam1Saved" to false, "cam2Saved" to false)
        }

        return when (captureMode) {
            CaptureMode.LOGICAL_MULTI_CAMERA -> captureLogicalMultiCamera(cam1Path, cam2Path)
            CaptureMode.ALTERNATING -> captureAlternating(cam1Path, cam2Path)
            else -> mapOf("success" to false, "error" to "Unknown mode", "cam1Saved" to false, "cam2Saved" to false)
        }
    }

    /**
     * Grabs the latest buffered frames from the repeating preview.
     * No need for a separate capture request — the ImageReader listeners
     * continuously update latestBytes1/latestBytes2.
     */
    private fun captureLogicalMultiCamera(cam1Path: String, cam2Path: String): Map<String, Any> {
        var cam1Saved = false
        var cam2Saved = false

        val bytes1 = latestBytes1
        val bytes2 = latestBytes2

        if (bytes1 != null) {
            try {
                saveJpeg(bytes1, cam1Path)
                cam1Saved = true
            } catch (e: Exception) {
                Log.e(TAG, "Error saving cam1 frame", e)
            }
        } else {
            Log.w(TAG, "No cam1 frame available yet")
        }

        if (bytes2 != null) {
            try {
                saveJpeg(bytes2, cam2Path)
                cam2Saved = true
            } catch (e: Exception) {
                Log.e(TAG, "Error saving cam2 frame", e)
            }
        } else {
            Log.w(TAG, "No cam2 frame available yet")
        }

        return mapOf(
            "success" to (cam1Saved || cam2Saved),
            "cam1Saved" to cam1Saved,
            "cam2Saved" to cam2Saved,
        )
    }

    /**
     * Alternating capture: opens each camera, captures, closes, then next.
     */
    @SuppressLint("MissingPermission")
    private fun captureAlternating(cam1Path: String, cam2Path: String): Map<String, Any> {
        val results = mutableMapOf<String, Any>("success" to true, "cam1Saved" to false, "cam2Saved" to false)
        val id1 = altCam1Id ?: return mapOf("success" to false, "error" to "cam1Id null", "cam1Saved" to false, "cam2Saved" to false)
        val id2 = altCam2Id ?: return mapOf("success" to false, "error" to "cam2Id null", "cam1Saved" to false, "cam2Saved" to false)

        try {
            results["cam1Saved"] = captureSingleCamera(id1, cam1Path)
        } catch (e: Exception) {
            Log.e(TAG, "Alternating cam1 error", e)
        }
        try {
            results["cam2Saved"] = captureSingleCamera(id2, cam2Path)
        } catch (e: Exception) {
            Log.e(TAG, "Alternating cam2 error", e)
        }

        results["success"] = (results["cam1Saved"] == true) || (results["cam2Saved"] == true)
        return results
    }

    @SuppressLint("MissingPermission")
    private fun captureSingleCamera(cameraId: String, outputPath: String): Boolean {
        var device: CameraDevice? = null
        var session: CameraCaptureSession? = null
        var reader: ImageReader? = null

        try {
            reader = ImageReader.newInstance(IMAGE_WIDTH, IMAGE_HEIGHT, ImageFormat.JPEG, 2)

            val openLatch = CountDownLatch(1)
            var openError: String? = null

            cameraManager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) { device = camera; openLatch.countDown() }
                override fun onDisconnected(camera: CameraDevice) { openError = "disconnected"; openLatch.countDown() }
                override fun onError(camera: CameraDevice, errorCode: Int) { openError = "error=$errorCode"; openLatch.countDown() }
            }, backgroundHandler)

            if (!openLatch.await(OPEN_TIMEOUT_MS, TimeUnit.MILLISECONDS) || openError != null) return false

            val sessionLatch = CountDownLatch(1)
            var sessionFailed = false

            device!!.createCaptureSession(
                listOf(reader.surface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(s: CameraCaptureSession) { session = s; sessionLatch.countDown() }
                    override fun onConfigureFailed(s: CameraCaptureSession) { sessionFailed = true; sessionLatch.countDown() }
                },
                backgroundHandler,
            )

            if (!sessionLatch.await(OPEN_TIMEOUT_MS, TimeUnit.MILLISECONDS) || sessionFailed) return false

            // Fire a few preview frames first to warm up AE/AF
            val previewRequest = device!!.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                addTarget(reader.surface)
            }.build()
            session!!.setRepeatingRequest(previewRequest, null, backgroundHandler)
            Thread.sleep(300) // Let AE/AF converge
            session!!.stopRepeating()

            // Now take the actual still capture
            val captureLatch = CountDownLatch(1)
            var saved = false

            reader.setOnImageAvailableListener({ r ->
                val image = r.acquireLatestImage()
                if (image != null) {
                    try {
                        val buffer = image.planes[0].buffer
                        val bytes = ByteArray(buffer.remaining())
                        buffer.get(bytes)
                        saveJpeg(bytes, outputPath)
                        saved = true
                    } finally {
                        image.close()
                        captureLatch.countDown()
                    }
                } else {
                    captureLatch.countDown()
                }
            }, backgroundHandler)

            val stillRequest = device!!.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE).apply {
                addTarget(reader.surface)
                set(CaptureRequest.JPEG_QUALITY, 80.toByte())
            }.build()

            session!!.capture(stillRequest, null, backgroundHandler)
            captureLatch.await(CAPTURE_TIMEOUT_MS, TimeUnit.MILLISECONDS)

            return saved

        } finally {
            try { session?.close() } catch (_: Exception) {}
            try { device?.close() } catch (_: Exception) {}
            try { reader?.close() } catch (_: Exception) {}
        }
    }

    // ─── Utilities ───

    private fun saveJpeg(bytes: ByteArray, path: String) {
        val file = File(path)
        file.parentFile?.mkdirs()
        FileOutputStream(file).use { it.write(bytes) }
    }

    fun closeCameras() {
        try {
            logicalSession?.stopRepeating()
        } catch (_: Exception) {}
        try {
            logicalSession?.close()
            logicalDevice?.close()
            reader1?.close()
            reader2?.close()
        } catch (e: Exception) {
            Log.e(TAG, "Error closing cameras", e)
        } finally {
            logicalSession = null
            logicalDevice = null
            reader1 = null
            reader2 = null
            latestBytes1 = null
            latestBytes2 = null
            altCam1Id = null
            altCam2Id = null
            isOpen = false
            captureMode = null
            stopBackgroundThread()
            Log.i(TAG, "All cameras closed")
        }
    }

    fun getStatus(): Map<String, Any?> {
        return mapOf(
            "isOpen" to isOpen,
            "mode" to captureMode?.name,
            "physicalId1" to physicalId1,
            "physicalId2" to physicalId2,
            "logicalDeviceOpen" to (logicalDevice != null),
            "sessionActive" to (logicalSession != null),
            "hasCam1Frame" to (latestBytes1 != null),
            "hasCam2Frame" to (latestBytes2 != null),
        )
    }

    private fun isBackCamera(cameraId: String): Boolean {
        return try {
            val characteristics = cameraManager.getCameraCharacteristics(cameraId)
            characteristics.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
        } catch (_: Exception) {
            false
        }
    }

    private fun getBackCameraIds(): List<String> {
        return cameraManager.cameraIdList.filter { isBackCamera(it) }
    }
}
