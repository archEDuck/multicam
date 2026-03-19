package com.example.multicam

import ai.onnxruntime.OnnxJavaType
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import ai.onnxruntime.TensorInfo
import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import org.opencv.android.OpenCVLoader
import org.opencv.calib3d.Calib3d
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfByte
import org.opencv.core.MatOfInt
import org.opencv.core.MatOfPoint2f
import org.opencv.core.MatOfPoint3f
import org.opencv.core.Point
import org.opencv.core.Point3
import org.opencv.core.Size
import org.opencv.core.TermCriteria
import org.opencv.imgcodecs.Imgcodecs
import org.opencv.imgproc.Imgproc
import java.io.File
import java.nio.FloatBuffer
import java.util.Locale

class StereoPreprocessManager(private val context: Context) {
    companion object {
        private const val TAG = "StereoPreprocess"
        private const val SQUARE_SIZE = 2.0
        private val CHECKERBOARD_CANDIDATES = listOf(
            10 to 7,
            7 to 10,
            7 to 7,
            9 to 6,
            6 to 9,
        )

        private const val MIN_VALID_PAIRS = 5
        private const val CALIBRATION_FILE_NAME = "stereo_calibration.json"
        private const val DEPTH_JPEG_QUALITY = 72
        private const val DEPTH_MODEL_ASSET_PATH =
            "flutter_assets/assets/foundation_stereo_int8.onnx"
        private const val DEPTH_MODEL_ASSET_FALLBACK =
            "assets/foundation_stereo_int8.onnx"
        private const val DEPTH_MODEL_DIRECT_ASSET =
            "foundation_stereo_int8.onnx"
        private const val DEPTH_MODEL_CACHE_DIR = "models"
        private const val DEPTH_MODEL_CACHE_VERSION = 2
        private const val DEPTH_MODEL_CACHE_VERSION_FILE = "foundation_stereo_int8.onnx.version"
        private const val MODEL_COPY_BUFFER_BYTES = 64 * 1024
        private const val MAX_DEPTH_INPUT_PIXELS = 1920 * 1080
        private const val MAX_DEPTH_OUTPUT_PIXELS = 1920 * 1080
    }

    private data class CheckerboardSpec(
        val width: Int,
        val height: Int,
    ) {
        fun asSize(): Size = Size(width.toDouble(), height.toDouble())
        fun label(): String = "${width}x${height}"
    }

    private data class CheckerboardDetection(
        val spec: CheckerboardSpec,
        val corners: MatOfPoint2f,
    )

    private data class CheckerboardPairDetection(
        val spec: CheckerboardSpec,
        val corners1: MatOfPoint2f,
        val corners2: MatOfPoint2f,
    )

    private data class CalibrationCollection(
        val spec: CheckerboardSpec,
        val imageSize: Size?,
        val validPairs: Int,
        val objectPoints: MutableList<Mat>,
        val imagePoints1: MutableList<Mat>,
        val imagePoints2: MutableList<Mat>,
    )

    private data class RectifyMaps(
        val imageSize: Size,
        val map1x: Mat,
        val map1y: Mat,
        val map2x: Mat,
        val map2y: Mat,
        val calibrationPath: String,
        val calibrationLastModifiedMs: Long,
    )

    private data class DepthInputTensorSpec(
        val name: String,
        val width: Int,
        val height: Int,
    )

    private data class DepthOutputTensorSpec(
        val index: Int,
        val name: String,
        val width: Int,
        val height: Int,
    )

    private data class DepthModelRuntime(
        val env: OrtEnvironment,
        val session: OrtSession,
        val leftInput: DepthInputTensorSpec,
        val rightInput: DepthInputTensorSpec,
        val output: DepthOutputTensorSpec,
        val backendLabel: String,
        val modelPath: String,
    )

    private var cachedRectifyMaps: RectifyMaps? = null
    private var cachedDepthModelRuntime: DepthModelRuntime? = null

    fun releaseDepthModelRuntime(reason: String = "manual"): Map<String, Any> {
        val existing = cachedDepthModelRuntime
        if (existing == null) {
            return mapOf(
                "success" to true,
                "message" to "Depth model zaten kapalı.",
                "released" to false,
                "reason" to reason,
            )
        }

        return try {
            existing.session.close()
            cachedDepthModelRuntime = null
            mapOf(
                "success" to true,
                "message" to "Depth model kapatıldı.",
                "released" to true,
                "reason" to reason,
                "backend" to existing.backendLabel,
                "modelPath" to existing.modelPath,
            )
        } catch (e: Throwable) {
            cachedDepthModelRuntime = null
            mapOf(
                "success" to false,
                "message" to (e.message ?: "Depth model kapatılırken hata oluştu."),
                "released" to false,
                "reason" to reason,
                "errorType" to e.javaClass.name,
            )
        }
    }

    fun checkCheckerboard(cam1Path: String, cam2Path: String): Map<String, Any> {
        return try {
            ensureOpenCvLoaded()

            val img1 = Imgcodecs.imread(cam1Path, Imgcodecs.IMREAD_COLOR)
            val img2 = Imgcodecs.imread(cam2Path, Imgcodecs.IMREAD_COLOR)

            if (img1.empty() || img2.empty()) {
                img1.release()
                img2.release()
                return mapOf(
                    "success" to false,
                    "message" to "Önizleme kareleri okunamadı. Kamera görüntüsünün güncel olduğundan emin olun.",
                    "processedPairs" to 0,
                    "outputPath" to "",
                )
            }

            val gray1 = Mat()
            val gray2 = Mat()
            Imgproc.cvtColor(img1, gray1, Imgproc.COLOR_BGR2GRAY)
            Imgproc.cvtColor(img2, gray2, Imgproc.COLOR_BGR2GRAY)

            val cornerCriteria = TermCriteria(
                TermCriteria.EPS + TermCriteria.MAX_ITER,
                30,
                0.001,
            )

            val pairDetection = detectPairCheckerboard(gray1, gray2, cornerCriteria)

            val cam1Detection = pairDetection?.let {
                CheckerboardDetection(it.spec, it.corners1)
            } ?: detectFirstCheckerboard(gray1, cornerCriteria)

            val cam2Detection = pairDetection?.let {
                CheckerboardDetection(it.spec, it.corners2)
            } ?: detectFirstCheckerboard(gray2, cornerCriteria)

            val found1 = cam1Detection != null
            val found2 = cam2Detection != null
            val foundPair = pairDetection != null

            val cam1Width = gray1.cols()
            val cam1Height = gray1.rows()
            val cam2Width = gray2.cols()
            val cam2Height = gray2.rows()
            val cam1CornerList = if (found1) cornersToList(cam1Detection!!.corners) else emptyList()
            val cam2CornerList = if (found2) cornersToList(cam2Detection!!.corners) else emptyList()

            cam1Detection?.corners?.release()
            if (cam2Detection?.corners !== cam1Detection?.corners) {
                cam2Detection?.corners?.release()
            }
            gray1.release()
            gray2.release()
            img1.release()
            img2.release()

            val message = when {
                foundPair -> "✓ Dama tahtası bulundu (${pairDetection.spec.label()} iç köşe, iki kamera)."
                found1 && found2 -> "✗ İki kamera farklı checkerboard düzeni algıladı. Aynı kartı iki kadrajda da benzer ölçekte tutun."
                found1 || found2 -> "✗ Dama tahtası iki kamerada aynı anda bulunamadı. Kartı her iki kadraja da ortalayın."
                else -> "✗ Dama tahtası bulunamadı. 10x7 iç köşe (önerilen) veya 7x7 kartı kadraja yaklaştırıp daha iyi aydınlatın."
            }

            mapOf(
                "success" to foundPair,
                "message" to message,
                "processedPairs" to (if (foundPair) 1 else 0),
                "outputPath" to "",
                "foundCam1" to found1,
                "foundCam2" to found2,
                "cam1Corners" to cam1CornerList,
                "cam2Corners" to cam2CornerList,
                "cam1ImageWidth" to cam1Width,
                "cam1ImageHeight" to cam1Height,
                "cam2ImageWidth" to cam2Width,
                "cam2ImageHeight" to cam2Height,
                "boardWidth" to (if (foundPair) pairDetection.spec.width else 0),
                "boardHeight" to (if (foundPair) pairDetection.spec.height else 0),
            )
        } catch (e: Exception) {
            Log.e(TAG, "Checkerboard detection failed", e)
            mapOf(
                "success" to false,
                "message" to (e.message ?: "Checkerboard kontrolü sırasında hata oluştu."),
                "processedPairs" to 0,
                "outputPath" to "",
            )
        }
    }

    private fun cornersToList(corners: MatOfPoint2f): List<Map<String, Double>> {
        val points: Array<Point> = corners.toArray()
        return points.map { point ->
            mapOf(
                "x" to point.x,
                "y" to point.y,
            )
        }
    }

    fun getCalibrationStatus(): Map<String, Any> {
        val calibrationFile = calibrationOutputFile()
        if (!calibrationFile.exists()) {
            return mapOf(
                "success" to false,
                "message" to "Kayıtlı kalibrasyon bulunamadı.",
                "processedPairs" to 0,
                "outputPath" to "",
                "exists" to false,
            )
        }

        return mapOf(
            "success" to true,
            "message" to "Kayıtlı kalibrasyon hazır.",
            "processedPairs" to 1,
            "outputPath" to calibrationFile.absolutePath,
            "exists" to true,
            "lastUpdatedMs" to calibrationFile.lastModified(),
        )
    }

    fun rectifyFramePair(cam1Bytes: ByteArray, cam2Bytes: ByteArray): Map<String, Any> {
        return try {
            ensureOpenCvLoaded()

            if (cam1Bytes.isEmpty() || cam2Bytes.isEmpty()) {
                return mapOf(
                    "success" to false,
                    "message" to "Canlı rectify için iki kamera önizleme karesi gerekli.",
                    "processedPairs" to 0,
                    "outputPath" to "",
                )
            }

            val calibrationFile = calibrationOutputFile()
            if (!calibrationFile.exists()) {
                return mapOf(
                    "success" to false,
                    "message" to "Kalibrasyon dosyası bulunamadı. Önce Faz 2 kalibrasyonu çalıştırın.",
                    "processedPairs" to 0,
                    "outputPath" to "",
                )
            }

            val rectifyMaps = getOrCreateRectifyMaps(calibrationFile)
                ?: return mapOf(
                    "success" to false,
                    "message" to "Kalibrasyon verisi okunamadı veya bozuk.",
                    "processedPairs" to 0,
                    "outputPath" to calibrationFile.absolutePath,
                )

            val encoded1 = MatOfByte(*cam1Bytes)
            val encoded2 = MatOfByte(*cam2Bytes)
            val src1 = Imgcodecs.imdecode(encoded1, Imgcodecs.IMREAD_COLOR)
            val src2 = Imgcodecs.imdecode(encoded2, Imgcodecs.IMREAD_COLOR)
            encoded1.release()
            encoded2.release()

            if (src1.empty() || src2.empty()) {
                src1.release()
                src2.release()
                return mapOf(
                    "success" to false,
                    "message" to "Önizleme kareleri decode edilemedi.",
                    "processedPairs" to 0,
                    "outputPath" to calibrationFile.absolutePath,
                )
            }

            if (src1.size() != rectifyMaps.imageSize) {
                Imgproc.resize(src1, src1, rectifyMaps.imageSize)
            }
            if (src2.size() != rectifyMaps.imageSize) {
                Imgproc.resize(src2, src2, rectifyMaps.imageSize)
            }

            val rect1 = Mat()
            val rect2 = Mat()
            Imgproc.remap(src1, rect1, rectifyMaps.map1x, rectifyMaps.map1y, Imgproc.INTER_LINEAR)
            Imgproc.remap(src2, rect2, rectifyMaps.map2x, rectifyMaps.map2y, Imgproc.INTER_LINEAR)

            val out1 = MatOfByte()
            val out2 = MatOfByte()
            val ok1 = Imgcodecs.imencode(".jpg", rect1, out1)
            val ok2 = Imgcodecs.imencode(".jpg", rect2, out2)

            val rectifiedBytes1 = if (ok1) out1.toArray() else ByteArray(0)
            val rectifiedBytes2 = if (ok2) out2.toArray() else ByteArray(0)

            out1.release()
            out2.release()
            src1.release()
            src2.release()
            rect1.release()
            rect2.release()

            if (!ok1 || !ok2 || rectifiedBytes1.isEmpty() || rectifiedBytes2.isEmpty()) {
                return mapOf(
                    "success" to false,
                    "message" to "Canlı rectify çıktısı üretilemedi.",
                    "processedPairs" to 0,
                    "outputPath" to calibrationFile.absolutePath,
                )
            }

            mapOf(
                "success" to true,
                "message" to "Canlı rectify aktif.",
                "processedPairs" to 1,
                "outputPath" to calibrationFile.absolutePath,
                "cam1Bytes" to rectifiedBytes1,
                "cam2Bytes" to rectifiedBytes2,
                "imageWidth" to rectifyMaps.imageSize.width.toInt(),
                "imageHeight" to rectifyMaps.imageSize.height.toInt(),
            )
        } catch (e: Exception) {
            Log.e(TAG, "Live rectification failed", e)
            mapOf(
                "success" to false,
                "message" to (e.message ?: "Canlı rectify sırasında hata oluştu."),
                "processedPairs" to 0,
                "outputPath" to "",
            )
        }
    }

    fun depthFramePair(cam1Bytes: ByteArray, cam2Bytes: ByteArray): Map<String, Any> {
        val totalStartNs = System.nanoTime()
        return try {
            ensureOpenCvLoaded()

            if (cam1Bytes.isEmpty() || cam2Bytes.isEmpty()) {
                return mapOf(
                    "success" to false,
                    "message" to "Canlı derinlik için iki kamera önizleme karesi gerekli.",
                    "processedPairs" to 0,
                    "outputPath" to "",
                    "stage" to "validation",
                )
            }

            val calibrationFile = calibrationOutputFile()
            if (!calibrationFile.exists()) {
                return mapOf(
                    "success" to false,
                    "message" to "Kalibrasyon dosyası bulunamadı. Önce Faz 2 kalibrasyonu çalıştırın.",
                    "processedPairs" to 0,
                    "outputPath" to "",
                    "stage" to "validation",
                )
            }

            val rectifyMaps = getOrCreateRectifyMaps(calibrationFile)
                ?: return mapOf(
                    "success" to false,
                    "message" to "Kalibrasyon verisi okunamadı veya bozuk.",
                    "processedPairs" to 0,
                    "outputPath" to calibrationFile.absolutePath,
                    "stage" to "rectify_maps",
                )

            val encoded1 = MatOfByte(*cam1Bytes)
            val encoded2 = MatOfByte(*cam2Bytes)
            val src1 = Imgcodecs.imdecode(encoded1, Imgcodecs.IMREAD_COLOR)
            val src2 = Imgcodecs.imdecode(encoded2, Imgcodecs.IMREAD_COLOR)
            encoded1.release()
            encoded2.release()

            if (src1.empty() || src2.empty()) {
                src1.release()
                src2.release()
                return mapOf(
                    "success" to false,
                    "message" to "Önizleme kareleri decode edilemedi.",
                    "processedPairs" to 0,
                    "outputPath" to calibrationFile.absolutePath,
                    "stage" to "decode",
                )
            }

            if (src1.size() != rectifyMaps.imageSize) {
                Imgproc.resize(src1, src1, rectifyMaps.imageSize)
            }
            if (src2.size() != rectifyMaps.imageSize) {
                Imgproc.resize(src2, src2, rectifyMaps.imageSize)
            }

            val rect1 = Mat()
            val rect2 = Mat()
            try {
                Imgproc.remap(src1, rect1, rectifyMaps.map1x, rectifyMaps.map1y, Imgproc.INTER_LINEAR)
                Imgproc.remap(src2, rect2, rectifyMaps.map2x, rectifyMaps.map2y, Imgproc.INTER_LINEAR)

                val runtime = getOrCreateDepthModelRuntime()
                if (
                    runtime.leftInput.width != runtime.rightInput.width ||
                        runtime.leftInput.height != runtime.rightInput.height
                ) {
                    return mapOf(
                        "success" to false,
                        "message" to "Model giriş tensor boyutları eşleşmiyor.",
                        "processedPairs" to 0,
                        "outputPath" to calibrationFile.absolutePath,
                        "stage" to "runtime_validation",
                        "backend" to runtime.backendLabel,
                        "modelPath" to runtime.modelPath,
                    )
                }

                val modelInputs = hashMapOf<String, OnnxTensor>(
                    runtime.leftInput.name to buildRgbInputTensor(
                        env = runtime.env,
                        sourceBgr = rect1,
                        width = runtime.leftInput.width,
                        height = runtime.leftInput.height,
                    ),
                    runtime.rightInput.name to buildRgbInputTensor(
                        env = runtime.env,
                        sourceBgr = rect2,
                        width = runtime.rightInput.width,
                        height = runtime.rightInput.height,
                    ),
                )

                val inferenceStartNs = System.nanoTime()
                val disparityValues: FloatArray = try {
                    runtime.session.run(modelInputs, setOf(runtime.output.name)).use { outputs ->
                        readModelOutputDisparity(outputs, runtime.output)
                    }
                } finally {
                    modelInputs.values.forEach { tensor ->
                        runCatching { tensor.close() }
                    }
                    modelInputs.clear()
                }
                val inferenceMs = ((System.nanoTime() - inferenceStartNs).toDouble() / 1_000_000.0)

                val depthBytes = disparityToDepthJpeg(
                    disparityValues = disparityValues,
                    outputWidth = runtime.output.width,
                    outputHeight = runtime.output.height,
                )
                val totalMs = ((System.nanoTime() - totalStartNs).toDouble() / 1_000_000.0)

                mapOf(
                    "success" to true,
                    "message" to "Canlı derinlik aktif (AI ${runtime.backendLabel}).",
                    "processedPairs" to 1,
                    "outputPath" to calibrationFile.absolutePath,
                    "depthBytes" to depthBytes,
                    "imageWidth" to runtime.output.width,
                    "imageHeight" to runtime.output.height,
                    "backend" to runtime.backendLabel,
                    "modelInputWidth" to runtime.leftInput.width,
                    "modelInputHeight" to runtime.leftInput.height,
                    "modelOutputName" to runtime.output.name,
                    "modelOutputWidth" to runtime.output.width,
                    "modelOutputHeight" to runtime.output.height,
                    "stage" to "inference",
                    "modelPath" to runtime.modelPath,
                    "depthBytesSize" to depthBytes.size,
                    "inferenceMs" to String.format(Locale.US, "%.2f", inferenceMs),
                    "totalMs" to String.format(Locale.US, "%.2f", totalMs),
                )
            } finally {
                src1.release()
                src2.release()
                rect1.release()
                rect2.release()
            }
        } catch (e: Throwable) {
            Log.e(TAG, "Live depth map failed", e)
            val runtime = cachedDepthModelRuntime
            mapOf(
                "success" to false,
                "message" to (e.message ?: "Canlı derinlik sırasında hata oluştu."),
                "processedPairs" to 0,
                "outputPath" to "",
                "errorType" to e.javaClass.name,
                "stage" to "runtime_exception",
                "backend" to (runtime?.backendLabel ?: "unknown"),
                "modelPath" to (runtime?.modelPath ?: ""),
                "totalMs" to String.format(
                    Locale.US,
                    "%.2f",
                    (System.nanoTime() - totalStartNs).toDouble() / 1_000_000.0,
                ),
            )
        }
    }

    fun calibrateSession(sessionDirPath: String): Map<String, Any> {
        return try {
            ensureOpenCvLoaded()

            val sessionDir = File(sessionDirPath)
            val cam1Dir = File(sessionDir, "cam1")
            val cam2Dir = File(sessionDir, "cam2")

            if (!cam1Dir.exists() || !cam2Dir.exists()) {
                return mapOf(
                    "success" to false,
                    "message" to "cam1/cam2 klasörleri bulunamadı.",
                    "processedPairs" to 0,
                    "outputPath" to "",
                )
            }

            val cam1Images = listImageFiles(cam1Dir)
            val cam2Images = listImageFiles(cam2Dir)
            val pairCount = minOf(cam1Images.size, cam2Images.size)

            if (pairCount == 0) {
                return mapOf(
                    "success" to false,
                    "message" to "Kalibrasyon için görüntü çifti bulunamadı.",
                    "processedPairs" to 0,
                    "outputPath" to "",
                )
            }

            val collections = checkerboardSpecs().map { spec ->
                collectCalibrationForSpec(cam1Images, cam2Images, spec)
            }

            val bestCollection = collections.maxByOrNull { it.validPairs }
            if (bestCollection == null || bestCollection.validPairs < MIN_VALID_PAIRS || bestCollection.imageSize == null) {
                val details = collections.joinToString(", ") { "${it.spec.label()}:${it.validPairs}" }
                collections.forEach {
                    releaseMatList(it.objectPoints)
                    releaseMatList(it.imagePoints1)
                    releaseMatList(it.imagePoints2)
                }

                return mapOf(
                    "success" to false,
                    "message" to "Yeterli checkerboard çifti bulunamadı (en az $MIN_VALID_PAIRS). Denenen düzenler: $details",
                    "processedPairs" to (bestCollection?.validPairs ?: 0),
                    "outputPath" to "",
                )
            }

            collections.forEach {
                if (it !== bestCollection) {
                    releaseMatList(it.objectPoints)
                    releaseMatList(it.imagePoints1)
                    releaseMatList(it.imagePoints2)
                }
            }

            val selectedSpec = bestCollection.spec
            val imageSize = checkNotNull(bestCollection.imageSize)
            val validPairs = bestCollection.validPairs
            val objectPoints = bestCollection.objectPoints
            val imagePoints1 = bestCollection.imagePoints1
            val imagePoints2 = bestCollection.imagePoints2

            val k1 = Mat.eye(3, 3, CvType.CV_64F)
            val d1 = Mat.zeros(8, 1, CvType.CV_64F)
            val k2 = Mat.eye(3, 3, CvType.CV_64F)
            val d2 = Mat.zeros(8, 1, CvType.CV_64F)

            val rvecs1 = mutableListOf<Mat>()
            val tvecs1 = mutableListOf<Mat>()
            val rvecs2 = mutableListOf<Mat>()
            val tvecs2 = mutableListOf<Mat>()

            val rms1 = Calib3d.calibrateCamera(
                objectPoints,
                imagePoints1,
                imageSize,
                k1,
                d1,
                rvecs1,
                tvecs1,
            )
            val rms2 = Calib3d.calibrateCamera(
                objectPoints,
                imagePoints2,
                imageSize,
                k2,
                d2,
                rvecs2,
                tvecs2,
            )

            val r = Mat()
            val t = Mat()
            val e = Mat()
            val f = Mat()

            val stereoRms = Calib3d.stereoCalibrate(
                objectPoints,
                imagePoints1,
                imagePoints2,
                k1,
                d1,
                k2,
                d2,
                imageSize,
                r,
                t,
                e,
                f,
                Calib3d.CALIB_FIX_INTRINSIC,
                TermCriteria(TermCriteria.EPS + TermCriteria.MAX_ITER, 100, 1e-5),
            )

            val r1 = Mat()
            val r2 = Mat()
            val p1 = Mat()
            val p2 = Mat()
            val q = Mat()
            Calib3d.stereoRectify(
                k1,
                d1,
                k2,
                d2,
                imageSize,
                r,
                t,
                r1,
                r2,
                p1,
                p2,
                q,
            )

            val cameraIds = readCameraIdsFromCaptureLog(sessionDir)
            val calibrationJson = JSONObject().apply {
                put("imageWidth", imageSize.width.toInt())
                put("imageHeight", imageSize.height.toInt())
                put("checkerboardWidth", selectedSpec.width)
                put("checkerboardHeight", selectedSpec.height)
                put("squareSize", SQUARE_SIZE)
                put("cam1Id", cameraIds.first)
                put("cam2Id", cameraIds.second)
                put("sessionDir", sessionDir.absolutePath)
                put("k1", matToJson(k1))
                put("d1", matToJson(d1))
                put("k2", matToJson(k2))
                put("d2", matToJson(d2))
                put("r", matToJson(r))
                put("t", matToJson(t))
                put("r1", matToJson(r1))
                put("r2", matToJson(r2))
                put("p1", matToJson(p1))
                put("p2", matToJson(p2))
                put("q", matToJson(q))
                put("rmsCam1", rms1)
                put("rmsCam2", rms2)
                put("rmsStereo", stereoRms)
                put("createdAtMs", System.currentTimeMillis())
            }

            val outputFile = calibrationOutputFile()
            outputFile.writeText(calibrationJson.toString())
            releaseRectifyMaps(cachedRectifyMaps)
            cachedRectifyMaps = null

            releaseMatList(objectPoints)
            releaseMatList(imagePoints1)
            releaseMatList(imagePoints2)
            releaseMatList(rvecs1)
            releaseMatList(tvecs1)
            releaseMatList(rvecs2)
            releaseMatList(tvecs2)
            k1.release()
            d1.release()
            k2.release()
            d2.release()
            r.release()
            t.release()
            e.release()
            f.release()
            r1.release()
            r2.release()
            p1.release()
            p2.release()
            q.release()

            mapOf(
                "success" to true,
                "message" to "Kalibrasyon tamamlandı (${selectedSpec.label()} iç köşe).",
                "processedPairs" to validPairs,
                "outputPath" to outputFile.absolutePath,
            )
        } catch (e: Exception) {
            Log.e(TAG, "Calibration failed", e)
            mapOf(
                "success" to false,
                "message" to (e.message ?: "Kalibrasyon sırasında hata oluştu."),
                "processedPairs" to 0,
                "outputPath" to "",
            )
        }
    }

    fun rectifySession(sessionDirPath: String): Map<String, Any> {
        return try {
            ensureOpenCvLoaded()

            val sessionDir = File(sessionDirPath)
            val cam1Dir = File(sessionDir, "cam1")
            val cam2Dir = File(sessionDir, "cam2")

            if (!cam1Dir.exists() || !cam2Dir.exists()) {
                return mapOf(
                    "success" to false,
                    "message" to "cam1/cam2 klasörleri bulunamadı.",
                    "processedPairs" to 0,
                    "outputPath" to "",
                )
            }

            val calibrationFile = calibrationOutputFile()
            if (!calibrationFile.exists()) {
                return mapOf(
                    "success" to false,
                    "message" to "Kalibrasyon dosyası bulunamadı. Önce Faz 2'yi çalıştırın.",
                    "processedPairs" to 0,
                    "outputPath" to "",
                )
            }

            val rectifyMaps = getOrCreateRectifyMaps(calibrationFile)
            if (rectifyMaps == null) {
                return mapOf(
                    "success" to false,
                    "message" to "Kalibrasyon verisi okunamadı veya bozuk.",
                    "processedPairs" to 0,
                    "outputPath" to "",
                )
            }

            val imageSize = rectifyMaps.imageSize

            val outputDir = File(sessionDir, "rectified")
            val outputCam1Dir = File(outputDir, "cam1")
            val outputCam2Dir = File(outputDir, "cam2")
            outputCam1Dir.mkdirs()
            outputCam2Dir.mkdirs()

            val cam1Images = listImageFiles(cam1Dir)
            val cam2Images = listImageFiles(cam2Dir)
            val pairCount = minOf(cam1Images.size, cam2Images.size)

            var processed = 0

            for (index in 0 until pairCount) {
                val src1 = Imgcodecs.imread(cam1Images[index].absolutePath, Imgcodecs.IMREAD_COLOR)
                val src2 = Imgcodecs.imread(cam2Images[index].absolutePath, Imgcodecs.IMREAD_COLOR)

                if (src1.empty() || src2.empty()) {
                    src1.release()
                    src2.release()
                    continue
                }

                if (src1.size() != imageSize) {
                    Imgproc.resize(src1, src1, imageSize)
                }
                if (src2.size() != imageSize) {
                    Imgproc.resize(src2, src2, imageSize)
                }

                val rect1 = Mat()
                val rect2 = Mat()

                Imgproc.remap(src1, rect1, rectifyMaps.map1x, rectifyMaps.map1y, Imgproc.INTER_LINEAR)
                Imgproc.remap(src2, rect2, rectifyMaps.map2x, rectifyMaps.map2y, Imgproc.INTER_LINEAR)

                val out1 = File(outputCam1Dir, "rect_${cam1Images[index].name}")
                val out2 = File(outputCam2Dir, "rect_${cam2Images[index].name}")

                val ok1 = Imgcodecs.imwrite(out1.absolutePath, rect1)
                val ok2 = Imgcodecs.imwrite(out2.absolutePath, rect2)

                if (ok1 && ok2) {
                    processed += 1
                }

                src1.release()
                src2.release()
                rect1.release()
                rect2.release()
            }

            if (processed == 0) {
                return mapOf(
                    "success" to false,
                    "message" to "Rectify için işlenen kare bulunamadı.",
                    "processedPairs" to 0,
                    "outputPath" to outputDir.absolutePath,
                )
            }

            mapOf(
                "success" to true,
                "message" to "Rectify tamamlandı.",
                "processedPairs" to processed,
                "outputPath" to outputDir.absolutePath,
            )
        } catch (e: Exception) {
            Log.e(TAG, "Rectification failed", e)
            mapOf(
                "success" to false,
                "message" to (e.message ?: "Rectify sırasında hata oluştu."),
                "processedPairs" to 0,
                "outputPath" to "",
            )
        }
    }

    private fun getOrCreateRectifyMaps(calibrationFile: File): RectifyMaps? {
        val currentCache = cachedRectifyMaps
        val currentModified = calibrationFile.lastModified()

        if (
            currentCache != null &&
            currentCache.calibrationPath == calibrationFile.absolutePath &&
            currentCache.calibrationLastModifiedMs == currentModified
        ) {
            return currentCache
        }

        val calibration = JSONObject(calibrationFile.readText())
        val imageWidth = calibration.optInt("imageWidth", 0)
        val imageHeight = calibration.optInt("imageHeight", 0)
        if (imageWidth <= 0 || imageHeight <= 0) {
            return null
        }

        val imageSize = Size(imageWidth.toDouble(), imageHeight.toDouble())

        val k1 = jsonToMat(calibration.getJSONObject("k1"))
        val d1 = jsonToMat(calibration.getJSONObject("d1"))
        val k2 = jsonToMat(calibration.getJSONObject("k2"))
        val d2 = jsonToMat(calibration.getJSONObject("d2"))
        val r1 = jsonToMat(calibration.getJSONObject("r1"))
        val r2 = jsonToMat(calibration.getJSONObject("r2"))
        val p1 = jsonToMat(calibration.getJSONObject("p1"))
        val p2 = jsonToMat(calibration.getJSONObject("p2"))

        val map1x = Mat()
        val map1y = Mat()
        val map2x = Mat()
        val map2y = Mat()

        Calib3d.initUndistortRectifyMap(
            k1,
            d1,
            r1,
            p1,
            imageSize,
            CvType.CV_32FC1,
            map1x,
            map1y,
        )
        Calib3d.initUndistortRectifyMap(
            k2,
            d2,
            r2,
            p2,
            imageSize,
            CvType.CV_32FC1,
            map2x,
            map2y,
        )

        k1.release()
        d1.release()
        k2.release()
        d2.release()
        r1.release()
        r2.release()
        p1.release()
        p2.release()

        releaseRectifyMaps(cachedRectifyMaps)
        val fresh = RectifyMaps(
            imageSize = imageSize,
            map1x = map1x,
            map1y = map1y,
            map2x = map2x,
            map2y = map2y,
            calibrationPath = calibrationFile.absolutePath,
            calibrationLastModifiedMs = currentModified,
        )
        cachedRectifyMaps = fresh
        return fresh
    }

    private fun releaseRectifyMaps(maps: RectifyMaps?) {
        maps?.map1x?.release()
        maps?.map1y?.release()
        maps?.map2x?.release()
        maps?.map2y?.release()
    }

    private fun getOrCreateDepthModelRuntime(): DepthModelRuntime {
        cachedDepthModelRuntime?.let { return it }

        val env = OrtEnvironment.getEnvironment()
        val modelPath = ensureDepthModelFilePath()
        val (session, backendLabel) = createDepthSession(env, modelPath)

        val (leftInput, rightInput) = resolveModelInputSpecs(session)
        if (leftInput.width != rightInput.width || leftInput.height != rightInput.height) {
            session.close()
            throw IllegalStateException(
                "Model sol/sağ girişleri aynı çözünürlükte olmalı: " +
                    "left=${leftInput.width}x${leftInput.height}, " +
                    "right=${rightInput.width}x${rightInput.height}",
            )
        }
        validateDepthInputDimensions(leftInput)
        validateDepthInputDimensions(rightInput)

        val output = selectDepthOutputSpec(session)
        validateDepthOutputDimensions(output)
        val runtime = DepthModelRuntime(
            env = env,
            session = session,
            leftInput = leftInput,
            rightInput = rightInput,
            output = output,
            backendLabel = backendLabel,
            modelPath = modelPath,
        )
        cachedDepthModelRuntime = runtime

        Log.i(
            TAG,
            "Depth model hazır: backend=$backendLabel, " +
                "input=${leftInput.width}x${leftInput.height}, " +
                "output=${output.name}:${output.width}x${output.height}",
        )

        return runtime
    }

    private fun createDepthSession(
        env: OrtEnvironment,
        modelPath: String,
    ): Pair<OrtSession, String> {
        val cpuOptions = OrtSession.SessionOptions()
        try {
            cpuOptions.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            cpuOptions.setIntraOpNumThreads(4)
            cpuOptions.setInterOpNumThreads(1)
            val cpuSession = env.createSession(modelPath, cpuOptions)
            return cpuSession to "CPU"
        } finally {
            cpuOptions.close()
        }
    }

    private fun resolveModelInputSpecs(session: OrtSession): Pair<DepthInputTensorSpec, DepthInputTensorSpec> {
        val namedLeft = resolveInputTensorSpec(session, "left_image")
        val namedRight = resolveInputTensorSpec(session, "right_image")
        if (namedLeft != null && namedRight != null) {
            return namedLeft to namedRight
        }

        val candidates = session.inputInfo.entries.mapNotNull { (name, nodeInfo) ->
            val tensorInfo = nodeInfo.info as? TensorInfo ?: return@mapNotNull null
            if (tensorInfo.type != OnnxJavaType.FLOAT) return@mapNotNull null
            val shape = tensorInfo.shape
            if (shape.size != 4) return@mapNotNull null

            val height = toPositiveIntDimension(shape[2]) ?: return@mapNotNull null
            val width = toPositiveIntDimension(shape[3]) ?: return@mapNotNull null
            DepthInputTensorSpec(name = name, width = width, height = height)
        }

        if (candidates.size < 2) {
            throw IllegalStateException(
                "Model en az iki adet float 4D giriş tensoru bekliyor.",
            )
        }

        val left = candidates.first()
        val right = candidates.firstOrNull {
            it.name != left.name && it.width == left.width && it.height == left.height
        } ?: candidates[1]

        return left to right
    }

    private fun resolveInputTensorSpec(
        session: OrtSession,
        inputName: String,
    ): DepthInputTensorSpec? {
        val nodeInfo = session.inputInfo[inputName] ?: return null
        val tensorInfo = nodeInfo.info as? TensorInfo ?: return null
        if (tensorInfo.type != OnnxJavaType.FLOAT) return null
        val shape = tensorInfo.shape
        if (shape.size != 4) return null

        val height = toPositiveIntDimension(shape[2]) ?: return null
        val width = toPositiveIntDimension(shape[3]) ?: return null

        return DepthInputTensorSpec(name = inputName, width = width, height = height)
    }

    private fun selectDepthOutputSpec(session: OrtSession): DepthOutputTensorSpec {
        val candidates = session.outputInfo.entries.mapIndexedNotNull { index, (name, nodeInfo) ->
            val tensorInfo = nodeInfo.info as? TensorInfo ?: return@mapIndexedNotNull null
            if (tensorInfo.type != OnnxJavaType.FLOAT) return@mapIndexedNotNull null
            val shape = tensorInfo.shape
            if (shape.size < 2) return@mapIndexedNotNull null

            val height = toPositiveIntDimension(shape[shape.size - 2]) ?: return@mapIndexedNotNull null
            val width = toPositiveIntDimension(shape[shape.size - 1]) ?: return@mapIndexedNotNull null
            DepthOutputTensorSpec(
                index = index,
                name = name,
                width = width,
                height = height,
            )
        }

        val preferred = candidates.firstOrNull { it.name.equals("disparity_map", ignoreCase = true) }
        if (preferred != null) {
            return preferred
        }

        val semanticCandidates = candidates.filter {
            val lowered = it.name.lowercase(Locale.ROOT)
            lowered.contains("dispar") || lowered.contains("depth")
        }
        if (semanticCandidates.isNotEmpty()) {
            return semanticCandidates.minByOrNull { pixelCount(it.width, it.height) }
                ?: semanticCandidates.first()
        }

        return candidates.minByOrNull { pixelCount(it.width, it.height) }
            ?: throw IllegalStateException("Modelde uygun float çıkış tensoru bulunamadı.")
    }

    private fun pixelCount(width: Int, height: Int): Long = width.toLong() * height.toLong()

    private fun validateDepthInputDimensions(input: DepthInputTensorSpec) {
        val pixels = pixelCount(input.width, input.height)
        if (pixels <= 0L || pixels > MAX_DEPTH_INPUT_PIXELS.toLong()) {
            throw IllegalStateException(
                "Model giriş boyutu çok büyük: ${input.name}=${input.width}x${input.height} " +
                    "($pixels px). Maksimum: $MAX_DEPTH_INPUT_PIXELS px.",
            )
        }
    }

    private fun validateDepthOutputDimensions(output: DepthOutputTensorSpec) {
        val pixels = pixelCount(output.width, output.height)
        if (pixels <= 0L || pixels > MAX_DEPTH_OUTPUT_PIXELS.toLong()) {
            throw IllegalStateException(
                "Model çıkış boyutu çok büyük: ${output.name}=${output.width}x${output.height} " +
                    "($pixels px). Maksimum: $MAX_DEPTH_OUTPUT_PIXELS px.",
            )
        }
    }

    private fun toPositiveIntDimension(value: Long): Int? {
        if (value <= 0L || value > Int.MAX_VALUE.toLong()) {
            return null
        }
        return value.toInt()
    }

    private fun buildRgbInputTensor(
        env: OrtEnvironment,
        sourceBgr: Mat,
        width: Int,
        height: Int,
    ): OnnxTensor {
        val resized = Mat()
        val rgb = Mat()
        try {
            Imgproc.resize(
                sourceBgr,
                resized,
                Size(width.toDouble(), height.toDouble()),
                0.0,
                0.0,
                Imgproc.INTER_AREA,
            )
            Imgproc.cvtColor(resized, rgb, Imgproc.COLOR_BGR2RGB)
            val nchw = matToNormalizedRgbNchw(rgb, width, height)
            val tensorShape = longArrayOf(1L, 3L, height.toLong(), width.toLong())
            return OnnxTensor.createTensor(env, FloatBuffer.wrap(nchw), tensorShape)
        } finally {
            resized.release()
            rgb.release()
        }
    }

    private fun matToNormalizedRgbNchw(
        rgbMat: Mat,
        width: Int,
        height: Int,
    ): FloatArray {
        val pixelCount = width * height
        val interleaved = ByteArray(pixelCount * 3)
        rgbMat.get(0, 0, interleaved)

        val nchw = FloatArray(pixelCount * 3)
        var srcIndex = 0

        for (pixelIndex in 0 until pixelCount) {
            val r = interleaved[srcIndex++].toInt() and 0xFF
            val g = interleaved[srcIndex++].toInt() and 0xFF
            val b = interleaved[srcIndex++].toInt() and 0xFF

            nchw[pixelIndex] = r / 255f
            nchw[pixelIndex + pixelCount] = g / 255f
            nchw[pixelIndex + (pixelCount * 2)] = b / 255f
        }

        return nchw
    }

    private fun readModelOutputDisparity(
        outputs: OrtSession.Result,
        outputSpec: DepthOutputTensorSpec,
    ): FloatArray {
        val byName = outputs.get(outputSpec.name).orElse(null)
        val selected = byName ?: try {
            outputs.get(outputSpec.index)
        } catch (_: Exception) {
            null
        } ?: throw IllegalStateException(
            "Model çıktısı bulunamadı: ${outputSpec.name} (index=${outputSpec.index})",
        )

        val tensor = selected as? OnnxTensor
            ?: throw IllegalStateException("Model çıktısı tensor değil: ${selected.javaClass.name}")

        val expected = outputSpec.width * outputSpec.height
        val floatBuffer = tensor.floatBuffer
        floatBuffer.rewind()
        val available = floatBuffer.remaining()
        if (available < expected) {
            throw IllegalStateException(
                "Model çıktısı beklenenden küçük: $available < $expected (${outputSpec.name})",
            )
        }

        if (available > expected) {
            Log.w(
                TAG,
                "Model çıktısı $available eleman içeriyor; sadece ilk $expected eleman kullanılacak (${outputSpec.name}).",
            )
        }

        val disparity = FloatArray(expected)
        floatBuffer.get(disparity, 0, expected)
        return disparity
    }

    private fun disparityToDepthJpeg(
        disparityValues: FloatArray,
        outputWidth: Int,
        outputHeight: Int,
    ): ByteArray {
        val expected = outputWidth * outputHeight
        if (disparityValues.size < expected) {
            throw IllegalStateException(
                "Model çıktısı beklenenden küçük: ${disparityValues.size} < $expected",
            )
        }

        val rawBytes = ByteArray(expected)
        for (index in 0 until expected) {
            val value = disparityValues[index]
            val raw = if (!value.isFinite()) {
                0
            } else {
                value.toInt().coerceIn(0, 255)
            }
            rawBytes[index] = raw.toByte()
        }

        val disparity8 = Mat(outputHeight, outputWidth, CvType.CV_8U)
        val outDepth = MatOfByte()
        val encodeParams = MatOfInt(Imgcodecs.IMWRITE_JPEG_QUALITY, DEPTH_JPEG_QUALITY)

        try {
            disparity8.put(0, 0, rawBytes)

            val encoded = Imgcodecs.imencode(".jpg", disparity8, outDepth, encodeParams)
            if (!encoded) {
                throw IllegalStateException("Derinlik JPEG encode başarısız.")
            }

            val depthBytes = outDepth.toArray()
            if (depthBytes.isEmpty()) {
                throw IllegalStateException("Derinlik JPEG çıktısı boş.")
            }
            return depthBytes
        } finally {
            disparity8.release()
            outDepth.release()
            encodeParams.release()
        }
    }

    private fun ensureDepthModelFilePath(): String {
        val cacheDir = File(context.noBackupFilesDir, DEPTH_MODEL_CACHE_DIR)
        if (!cacheDir.exists()) {
            cacheDir.mkdirs()
        }

        val cachedModelFile = File(cacheDir, DEPTH_MODEL_DIRECT_ASSET)
        val versionFile = File(cacheDir, DEPTH_MODEL_CACHE_VERSION_FILE)
        val hasCurrentVersion =
            versionFile.exists() &&
                runCatching { versionFile.readText().trim() == DEPTH_MODEL_CACHE_VERSION.toString() }
                    .getOrDefault(false)

        if (cachedModelFile.exists() && cachedModelFile.length() > 0L && hasCurrentVersion) {
            return cachedModelFile.absolutePath
        }

        if (cachedModelFile.exists()) {
            cachedModelFile.delete()
        }
        if (versionFile.exists()) {
            versionFile.delete()
        }

        val candidates = listOf(
            DEPTH_MODEL_ASSET_PATH,
            DEPTH_MODEL_ASSET_FALLBACK,
            DEPTH_MODEL_DIRECT_ASSET,
        )

        for (candidate in candidates) {
            try {
                context.assets.open(candidate).use { input ->
                    cachedModelFile.outputStream().buffered(MODEL_COPY_BUFFER_BYTES).use { output ->
                        input.copyTo(output, MODEL_COPY_BUFFER_BYTES)
                        output.flush()
                    }

                    if (cachedModelFile.length() > 0L) {
                        versionFile.writeText(DEPTH_MODEL_CACHE_VERSION.toString())
                        Log.i(
                            TAG,
                            "Depth model dosyaya kopyalandı: ${cachedModelFile.absolutePath} " +
                                "(${cachedModelFile.length()} bytes)",
                        )
                        return cachedModelFile.absolutePath
                    }
                }
            } catch (_: Exception) {
                if (cachedModelFile.exists() && cachedModelFile.length() == 0L) {
                    cachedModelFile.delete()
                }
                if (versionFile.exists()) {
                    versionFile.delete()
                }
                // try next candidate
            }
        }

        throw IllegalStateException(
            "Derinlik modeli asset bulunamadı. pubspec.yaml içinde " +
                "assets/foundation_stereo_int8.onnx tanımlı olmalı.",
        )
    }

    private fun checkerboardSpecs(): List<CheckerboardSpec> {
        return CHECKERBOARD_CANDIDATES.map { CheckerboardSpec(it.first, it.second) }
    }

    private fun detectCheckerboard(
        gray: Mat,
        spec: CheckerboardSpec,
        cornerCriteria: TermCriteria,
    ): MatOfPoint2f? {
        val corners = MatOfPoint2f()
        val found = Calib3d.findChessboardCorners(
            gray,
            spec.asSize(),
            corners,
            Calib3d.CALIB_CB_ADAPTIVE_THRESH or
                Calib3d.CALIB_CB_NORMALIZE_IMAGE or
                Calib3d.CALIB_CB_FILTER_QUADS,
        )

        if (!found) {
            corners.release()
            return null
        }

        Imgproc.cornerSubPix(
            gray,
            corners,
            Size(11.0, 11.0),
            Size(-1.0, -1.0),
            cornerCriteria,
        )
        return corners
    }

    private fun detectFirstCheckerboard(
        gray: Mat,
        cornerCriteria: TermCriteria,
    ): CheckerboardDetection? {
        for (spec in checkerboardSpecs()) {
            val corners = detectCheckerboard(gray, spec, cornerCriteria)
            if (corners != null) {
                return CheckerboardDetection(spec, corners)
            }
        }
        return null
    }

    private fun detectPairCheckerboard(
        gray1: Mat,
        gray2: Mat,
        cornerCriteria: TermCriteria,
    ): CheckerboardPairDetection? {
        for (spec in checkerboardSpecs()) {
            val corners1 = detectCheckerboard(gray1, spec, cornerCriteria) ?: continue
            val corners2 = detectCheckerboard(gray2, spec, cornerCriteria)
            if (corners2 == null) {
                corners1.release()
                continue
            }
            return CheckerboardPairDetection(spec, corners1, corners2)
        }
        return null
    }

    private fun collectCalibrationForSpec(
        cam1Images: List<File>,
        cam2Images: List<File>,
        spec: CheckerboardSpec,
    ): CalibrationCollection {
        val objectPoints = mutableListOf<Mat>()
        val imagePoints1 = mutableListOf<Mat>()
        val imagePoints2 = mutableListOf<Mat>()
        val objectTemplate = createObjectTemplate(spec.width, spec.height)

        val pairCount = minOf(cam1Images.size, cam2Images.size)
        var imageSize: Size? = null
        var validPairs = 0

        val cornerCriteria = TermCriteria(
            TermCriteria.EPS + TermCriteria.MAX_ITER,
            30,
            0.001,
        )

        for (index in 0 until pairCount) {
            val img1 = Imgcodecs.imread(cam1Images[index].absolutePath, Imgcodecs.IMREAD_COLOR)
            val img2 = Imgcodecs.imread(cam2Images[index].absolutePath, Imgcodecs.IMREAD_COLOR)

            if (img1.empty() || img2.empty()) {
                img1.release()
                img2.release()
                continue
            }

            val gray1 = Mat()
            val gray2 = Mat()
            Imgproc.cvtColor(img1, gray1, Imgproc.COLOR_BGR2GRAY)
            Imgproc.cvtColor(img2, gray2, Imgproc.COLOR_BGR2GRAY)

            if (imageSize == null) {
                imageSize = gray1.size()
            }

            if (gray1.size() != imageSize) {
                Imgproc.resize(gray1, gray1, imageSize)
            }
            if (gray2.size() != imageSize) {
                Imgproc.resize(gray2, gray2, imageSize)
            }

            val corners1 = detectCheckerboard(gray1, spec, cornerCriteria)
            val corners2 = detectCheckerboard(gray2, spec, cornerCriteria)

            if (corners1 != null && corners2 != null) {
                objectPoints.add(objectTemplate.clone())
                imagePoints1.add(corners1)
                imagePoints2.add(corners2)
                validPairs += 1
            } else {
                corners1?.release()
                corners2?.release()
            }

            gray1.release()
            gray2.release()
            img1.release()
            img2.release()
        }

        objectTemplate.release()
        return CalibrationCollection(
            spec = spec,
            imageSize = imageSize,
            validPairs = validPairs,
            objectPoints = objectPoints,
            imagePoints1 = imagePoints1,
            imagePoints2 = imagePoints2,
        )
    }

    private fun ensureOpenCvLoaded() {
        val loaded = OpenCVLoader.initDebug()
        if (!loaded) {
            throw IllegalStateException(
                "OpenCV yüklenemedi. Gradle bağımlılığı ve native kütüphaneleri kontrol edin.",
            )
        }
    }

    private fun createObjectTemplate(width: Int, height: Int): MatOfPoint3f {
        val points = mutableListOf<Point3>()
        for (y in 0 until height) {
            for (x in 0 until width) {
                points.add(Point3(x * SQUARE_SIZE, y * SQUARE_SIZE, 0.0))
            }
        }
        return MatOfPoint3f(*points.toTypedArray())
    }

    private fun listImageFiles(dir: File): List<File> {
        if (!dir.exists()) return emptyList()
        return dir.listFiles()
            ?.filter { file ->
                file.isFile &&
                    when (file.extension.lowercase(Locale.US)) {
                        "jpg", "jpeg", "png" -> true
                        else -> false
                    }
            }
            ?.sortedBy { it.name }
            ?: emptyList()
    }

    private fun calibrationOutputFile(): File {
        val base = File("/storage/emulated/0/Download/Multicam")
        if (!base.exists()) {
            base.mkdirs()
        }
        return File(base, CALIBRATION_FILE_NAME)
    }

    private fun releaseMatList(list: List<Mat>) {
        list.forEach { it.release() }
    }

    private fun matToJson(mat: Mat): JSONObject {
        val channels = mat.channels()
        val total = mat.rows() * mat.cols() * channels
        val values = DoubleArray(total)
        mat.get(0, 0, values)

        val arr = JSONArray()
        for (value in values) {
            arr.put(value)
        }

        return JSONObject().apply {
            put("rows", mat.rows())
            put("cols", mat.cols())
            put("type", mat.type())
            put("channels", channels)
            put("data", arr)
        }
    }

    private fun jsonToMat(json: JSONObject): Mat {
        val rows = json.getInt("rows")
        val cols = json.getInt("cols")
        val type = json.getInt("type")
        val data = json.getJSONArray("data")

        val mat = Mat(rows, cols, type)
        val values = DoubleArray(data.length())
        for (i in 0 until data.length()) {
            values[i] = data.getDouble(i)
        }
        mat.put(0, 0, *values)
        return mat
    }

    private fun readCameraIdsFromCaptureLog(sessionDir: File): Pair<String, String> {
        val csv = File(sessionDir, "capture_log.csv")
        if (!csv.exists()) {
            return "" to ""
        }

        return try {
            val lines = csv.readLines()
            if (lines.size < 2) return "" to ""

            val header = lines[0].split(',')
            val firstData = lines[1]

            val cam1Index = header.indexOf("cam1_id")
            val cam2Index = header.indexOf("cam2_id")
            if (cam1Index < 0 || cam2Index < 0) {
                return "" to ""
            }

            val cols = firstData.split(',')
            val cam1 = cols.getOrNull(cam1Index)?.trim() ?: ""
            val cam2 = cols.getOrNull(cam2Index)?.trim() ?: ""
            cam1 to cam2
        } catch (_: Exception) {
            "" to ""
        }
    }
}
