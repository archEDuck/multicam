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
 * Instead of opening two separate CameraDevice sessions (which fails with
 * ERROR_MAX_CAMERAS_IN_USE on most devices), this opens a SINGLE logical
 * multi-camera and routes two ImageReader outputs to two different physical
 * cameras using OutputConfiguration.setPhysicalCameraId().
 *
 * Fallback: If no logical multi-camera is available, uses alternating capture
 * (open cam1 → capture → close → open cam2 → capture → close).
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

    /**
     * Searches for a logical multi-camera that contains at least two back-facing
     * physical cameras. Returns info about the best candidate, or null.
     */
    fun findLogicalMultiCamera(): LogicalCameraInfo? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return null // API 28+

        for (cameraId in cameraManager.cameraIdList) {
            val chars = cameraManager.getCameraCharacteristics(cameraId)

            // Check if it's a back-facing camera
            val facing = chars.get(CameraCharacteristics.LENS_FACING)
            if (facing != CameraCharacteristics.LENS_FACING_BACK) continue

            // Check if it has LOGICAL_MULTI_CAMERA capability
            val caps = chars.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES) ?: continue
            if (!caps.contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA)) continue

            // Get physical camera IDs
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

    /**
     * Finds the best camera pair for dual capture.
     * Returns a map with pair info and recommended mode.
     */
    fun findBestConcurrentPair(): Map<String, Any> {
        // Try logical multi-camera first (best approach)
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

        // Try concurrent camera IDs (API 30+)
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

        // Fall back to alternating with first two back cameras
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

        // Try logical multi-camera first
        val logicalInfo = findLogicalMultiCameraContaining(cam1Id, cam2Id)
        if (logicalInfo != null) {
            val result = openLogicalMultiCamera(logicalInfo)
            if (result["success"] == true) return result
            Log.w(TAG, "Logical multi-camera failed, falling back to alternating")
        }

        // Fall back to alternating mode
        return openAlternating(cam1Id, cam2Id)
    }

    /**
     * Find a logical multi-camera that contains both specified physical cameras.
     */
    private fun findLogicalMultiCameraContaining(phys1: String, phys2: String): LogicalCameraInfo? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return null

        for (cameraId in cameraManager.cameraIdList) {
            val chars = cameraManager.getCameraCharacteristics(cameraId)
            val caps = chars.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES) ?: continue
            if (!caps.contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA)) continue

            val physicalIds = chars.physicalCameraIds
            if (physicalIds.contains(phys1) && physicalIds.contains(phys2)) {
                Log.i(TAG, "Logical camera $cameraId contains both physical cameras $phys1 and $phys2")
                return LogicalCameraInfo(cameraId, phys1, phys2)
            }
        }

        // Also try any logical multi-camera with any 2 back physical cameras
        return findLogicalMultiCamera()
    }

    /**
     * Opens a logical multi-camera and configures two outputs bound to physical cameras.
     */
    @SuppressLint("MissingPermission")
    private fun openLogicalMultiCamera(info: LogicalCameraInfo): Map<String, Any> {
        Log.i(TAG, "Opening logical multi-camera: ${info.logicalId} (physical: ${info.physicalId1}, ${info.physicalId2})")

        captureMode = CaptureMode.LOGICAL_MULTI_CAMERA
        physicalId1 = info.physicalId1
        physicalId2 = info.physicalId2

        try {
            // Open the logical camera device
            val openLatch = CountDownLatch(1)
            var openError: String? = null

            reader1 = ImageReader.newInstance(IMAGE_WIDTH, IMAGE_HEIGHT, ImageFormat.JPEG, 2)
            reader2 = ImageReader.newInstance(IMAGE_WIDTH, IMAGE_HEIGHT, ImageFormat.JPEG, 2)

            cameraManager.openCamera(info.logicalId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    logicalDevice = camera
                    Log.i(TAG, "Logical camera ${info.logicalId} opened")
                    openLatch.countDown()
                }

                override fun onDisconnected(camera: CameraDevice) {
                    logicalDevice = null
                    openError = "Logical kamera bağlantısı kesildi"
                    openLatch.countDown()
                }

                override fun onError(camera: CameraDevice, errorCode: Int) {
                    logicalDevice = null
                    openError = "Logical kamera hatası: kod=$errorCode"
                    openLatch.countDown()
                }
            }, backgroundHandler)

            if (!openLatch.await(OPEN_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                closeCameras()
                return mapOf("success" to false, "error" to "Logical kamera açma zaman aşımı")
            }
            if (openError != null) {
                closeCameras()
                return mapOf("success" to false, "error" to openError!!)
            }

            // Create capture session with physical camera-bound outputs
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
                        Log.i(TAG, "Logical multi-camera session configured")
                        sessionLatch.countDown()
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        sessionError = "Session yapılandırma başarısız"
                        Log.e(TAG, "Logical multi-camera session configuration failed")
                        sessionLatch.countDown()
                    }
                },
            )

            logicalDevice!!.createCaptureSession(sessionConfig)

            if (!sessionLatch.await(OPEN_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                closeCameras()
                return mapOf("success" to false, "error" to "Session oluşturma zaman aşımı")
            }
            if (sessionError != null) {
                closeCameras()
                return mapOf("success" to false, "error" to sessionError!!)
            }

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
            return mapOf("success" to false, "error" to "Logical multi-camera hatası: ${e.message}")
        }
    }

    /**
     * Sets up alternating capture mode (no cameras opened yet, opened on-demand).
     */
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
            return mapOf("success" to false, "error" to "Kameralar açık değil", "cam1Saved" to false, "cam2Saved" to false)
        }

        return when (captureMode) {
            CaptureMode.LOGICAL_MULTI_CAMERA -> captureLogicalMultiCamera(cam1Path, cam2Path)
            CaptureMode.ALTERNATING -> captureAlternating(cam1Path, cam2Path)
            else -> mapOf("success" to false, "error" to "Bilinmeyen mod", "cam1Saved" to false, "cam2Saved" to false)
        }
    }

    /**
     * Captures from both physical cameras simultaneously through the logical camera.
     */
    private fun captureLogicalMultiCamera(cam1Path: String, cam2Path: String): Map<String, Any> {
        val device = logicalDevice ?: return mapOf("success" to false, "error" to "Logical kamera yok", "cam1Saved" to false, "cam2Saved" to false)
        val session = logicalSession ?: return mapOf("success" to false, "error" to "Session yok", "cam1Saved" to false, "cam2Saved" to false)
        val r1 = reader1 ?: return mapOf("success" to false, "error" to "Reader1 yok", "cam1Saved" to false, "cam2Saved" to false)
        val r2 = reader2 ?: return mapOf("success" to false, "error" to "Reader2 yok", "cam1Saved" to false, "cam2Saved" to false)

        val results = mutableMapOf<String, Any>("success" to true, "cam1Saved" to false, "cam2Saved" to false)
        val cam1Latch = CountDownLatch(1)
        val cam2Latch = CountDownLatch(1)

        // Set up image listeners
        r1.setOnImageAvailableListener({ reader ->
            val image = reader.acquireLatestImage()
            if (image != null) {
                try {
                    val buffer = image.planes[0].buffer
                    val bytes = ByteArray(buffer.remaining())
                    buffer.get(bytes)
                    saveJpeg(bytes, cam1Path)
                    results["cam1Saved"] = true
                } catch (e: Exception) {
                    Log.e(TAG, "Error saving cam1 frame", e)
                } finally {
                    image.close()
                    cam1Latch.countDown()
                }
            } else {
                cam1Latch.countDown()
            }
        }, backgroundHandler)

        r2.setOnImageAvailableListener({ reader ->
            val image = reader.acquireLatestImage()
            if (image != null) {
                try {
                    val buffer = image.planes[0].buffer
                    val bytes = ByteArray(buffer.remaining())
                    buffer.get(bytes)
                    saveJpeg(bytes, cam2Path)
                    results["cam2Saved"] = true
                } catch (e: Exception) {
                    Log.e(TAG, "Error saving cam2 frame", e)
                } finally {
                    image.close()
                    cam2Latch.countDown()
                }
            } else {
                cam2Latch.countDown()
            }
        }, backgroundHandler)

        // Single capture request targeting both surfaces
        try {
            val request = device.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE).apply {
                addTarget(r1.surface)
                addTarget(r2.surface)
                set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
                set(CaptureRequest.JPEG_QUALITY, 80.toByte())
            }.build()

            session.capture(request, null, backgroundHandler)
        } catch (e: Exception) {
            Log.e(TAG, "Logical capture request failed", e)
            cam1Latch.countDown()
            cam2Latch.countDown()
        }

        cam1Latch.await(CAPTURE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        cam2Latch.await(CAPTURE_TIMEOUT_MS, TimeUnit.MILLISECONDS)

        results["success"] = (results["cam1Saved"] == true) || (results["cam2Saved"] == true)
        return results
    }

    /**
     * Alternating capture: opens each camera, captures, closes, then next.
     * Slower but works on all devices.
     */
    @SuppressLint("MissingPermission")
    private fun captureAlternating(cam1Path: String, cam2Path: String): Map<String, Any> {
        val results = mutableMapOf<String, Any>("success" to true, "cam1Saved" to false, "cam2Saved" to false)
        val id1 = altCam1Id ?: return mapOf("success" to false, "error" to "cam1Id yok", "cam1Saved" to false, "cam2Saved" to false)
        val id2 = altCam2Id ?: return mapOf("success" to false, "error" to "cam2Id yok", "cam1Saved" to false, "cam2Saved" to false)

        // Capture from camera 1
        try {
            val saved = captureSingleCamera(id1, cam1Path)
            results["cam1Saved"] = saved
        } catch (e: Exception) {
            Log.e(TAG, "Alternating cam1 error", e)
        }

        // Capture from camera 2
        try {
            val saved = captureSingleCamera(id2, cam2Path)
            results["cam2Saved"] = saved
        } catch (e: Exception) {
            Log.e(TAG, "Alternating cam2 error", e)
        }

        results["success"] = (results["cam1Saved"] == true) || (results["cam2Saved"] == true)
        return results
    }

    /**
     * Opens a single camera, captures one frame, closes it. Used for alternating mode.
     */
    @SuppressLint("MissingPermission")
    private fun captureSingleCamera(cameraId: String, outputPath: String): Boolean {
        var device: CameraDevice? = null
        var session: CameraCaptureSession? = null
        var reader: ImageReader? = null

        try {
            reader = ImageReader.newInstance(IMAGE_WIDTH, IMAGE_HEIGHT, ImageFormat.JPEG, 2)

            // Open camera
            val openLatch = CountDownLatch(1)
            var openError: String? = null

            cameraManager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    device = camera
                    openLatch.countDown()
                }
                override fun onDisconnected(camera: CameraDevice) {
                    openError = "disconnected"
                    openLatch.countDown()
                }
                override fun onError(camera: CameraDevice, errorCode: Int) {
                    openError = "error=$errorCode"
                    openLatch.countDown()
                }
            }, backgroundHandler)

            if (!openLatch.await(OPEN_TIMEOUT_MS, TimeUnit.MILLISECONDS) || openError != null) {
                Log.e(TAG, "Single camera open failed: $cameraId - $openError")
                return false
            }

            // Create session
            val sessionLatch = CountDownLatch(1)
            var sessionFailed = false

            device!!.createCaptureSession(
                listOf(reader.surface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(s: CameraCaptureSession) {
                        session = s
                        sessionLatch.countDown()
                    }
                    override fun onConfigureFailed(s: CameraCaptureSession) {
                        sessionFailed = true
                        sessionLatch.countDown()
                    }
                },
                backgroundHandler,
            )

            if (!sessionLatch.await(OPEN_TIMEOUT_MS, TimeUnit.MILLISECONDS) || sessionFailed) {
                Log.e(TAG, "Single camera session failed: $cameraId")
                return false
            }

            // Capture
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

            val request = device!!.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE).apply {
                addTarget(reader.surface)
                set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
                set(CaptureRequest.JPEG_QUALITY, 80.toByte())
            }.build()

            session!!.capture(request, null, backgroundHandler)
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
