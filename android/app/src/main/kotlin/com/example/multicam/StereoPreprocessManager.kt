package com.example.multicam

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import org.opencv.android.OpenCVLoader
import org.opencv.calib3d.Calib3d
import org.opencv.calib3d.StereoBM
import org.opencv.core.Core
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
        private const val DEPTH_DOWNSCALE = 0.5
        private const val DEPTH_BLOCK_SIZE = 15
        private const val DEPTH_TARGET_NUM_DISPARITIES = 96
        private const val DEPTH_JPEG_QUALITY = 72
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

    private var cachedRectifyMaps: RectifyMaps? = null
    private var cachedStereoBm: StereoBM? = null
    private var cachedStereoBmNumDisparities: Int = -1

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

            val hasUsableRectifiedPair =
                hasUsableVisualContent(rect1) && hasUsableVisualContent(rect2)
            if (!hasUsableRectifiedPair) {
                src1.release()
                src2.release()
                rect1.release()
                rect2.release()
                return mapOf(
                    "success" to false,
                    "message" to "Rectify çıktısı neredeyse tamamen siyah kaldı. Büyük olasılıkla kalibrasyon bu preview ile uyumlu değil; Faz 2 kalibrasyonunu tekrar üretin.",
                    "processedPairs" to 0,
                    "outputPath" to calibrationFile.absolutePath,
                )
            }

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
        return try {
            ensureOpenCvLoaded()

            if (cam1Bytes.isEmpty() || cam2Bytes.isEmpty()) {
                return mapOf(
                    "success" to false,
                    "message" to "Canlı derinlik için iki kamera önizleme karesi gerekli.",
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

            val gray1 = Mat()
            val gray2 = Mat()
            Imgproc.cvtColor(rect1, gray1, Imgproc.COLOR_BGR2GRAY)
            Imgproc.cvtColor(rect2, gray2, Imgproc.COLOR_BGR2GRAY)

            val depthSize = depthProcessingSize(rectifyMaps.imageSize)
            val smallGray1 = Mat()
            val smallGray2 = Mat()
            Imgproc.resize(gray1, smallGray1, depthSize, 0.0, 0.0, Imgproc.INTER_AREA)
            Imgproc.resize(gray2, smallGray2, depthSize, 0.0, 0.0, Imgproc.INTER_AREA)

            val disparity16 = Mat()
            val stereoBm = getOrCreateStereoBm(smallGray1.cols())
            stereoBm.compute(smallGray1, smallGray2, disparity16)

            val disparity32 = Mat()
            disparity16.convertTo(disparity32, CvType.CV_32F, 1.0 / 16.0)
            Imgproc.threshold(disparity32, disparity32, 0.0, 0.0, Imgproc.THRESH_TOZERO)

            val disparity8 = Mat()
            Core.normalize(disparity32, disparity8, 0.0, 255.0, Core.NORM_MINMAX, CvType.CV_8U)

            val depthColor = Mat()
            Imgproc.applyColorMap(disparity8, depthColor, Imgproc.COLORMAP_TURBO)
            if (depthColor.size() != rectifyMaps.imageSize) {
                Imgproc.resize(depthColor, depthColor, rectifyMaps.imageSize, 0.0, 0.0, Imgproc.INTER_LINEAR)
            }

            val outDepth = MatOfByte()
            val encodeParams = MatOfInt(Imgcodecs.IMWRITE_JPEG_QUALITY, DEPTH_JPEG_QUALITY)
            val ok = Imgcodecs.imencode(".jpg", depthColor, outDepth, encodeParams)
            val depthBytes = if (ok) outDepth.toArray() else ByteArray(0)

            outDepth.release()
            encodeParams.release()
            src1.release()
            src2.release()
            rect1.release()
            rect2.release()
            gray1.release()
            gray2.release()
            smallGray1.release()
            smallGray2.release()
            disparity16.release()
            disparity32.release()
            disparity8.release()
            depthColor.release()

            if (!ok || depthBytes.isEmpty()) {
                return mapOf(
                    "success" to false,
                    "message" to "Canlı derinlik çıktısı üretilemedi.",
                    "processedPairs" to 0,
                    "outputPath" to calibrationFile.absolutePath,
                )
            }

            mapOf(
                "success" to true,
                "message" to "Canlı derinlik aktif.",
                "processedPairs" to 1,
                "outputPath" to calibrationFile.absolutePath,
                "depthBytes" to depthBytes,
                "imageWidth" to rectifyMaps.imageSize.width.toInt(),
                "imageHeight" to rectifyMaps.imageSize.height.toInt(),
            )
        } catch (e: Exception) {
            Log.e(TAG, "Live depth map failed", e)
            mapOf(
                "success" to false,
                "message" to (e.message ?: "Canlı derinlik sırasında hata oluştu."),
                "processedPairs" to 0,
                "outputPath" to "",
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

    private fun depthProcessingSize(sourceSize: Size): Size {
        val scaledWidth = (sourceSize.width * DEPTH_DOWNSCALE).toInt().coerceAtLeast(160)
        val scaledHeight = (sourceSize.height * DEPTH_DOWNSCALE).toInt().coerceAtLeast(120)
        return Size(scaledWidth.toDouble(), scaledHeight.toDouble())
    }

    private fun hasUsableVisualContent(image: Mat): Boolean {
        if (image.empty()) {
            return false
        }

        val gray = Mat()
        Imgproc.cvtColor(image, gray, Imgproc.COLOR_BGR2GRAY)
        val nonZeroPixels = Core.countNonZero(gray)
        val totalPixels = gray.rows() * gray.cols()
        val usableRatio = if (totalPixels > 0) nonZeroPixels.toDouble() / totalPixels.toDouble() else 0.0
        val meanIntensity = Core.mean(gray).`val`[0]
        gray.release()

        return usableRatio >= 0.05 && meanIntensity >= 8.0
    }

    private fun getOrCreateStereoBm(imageWidth: Int): StereoBM {
        val maxByWidth = ((imageWidth / 16) * 16).coerceAtLeast(16)
        val numDisparities = minOf(DEPTH_TARGET_NUM_DISPARITIES, maxByWidth)

        if (cachedStereoBm != null && cachedStereoBmNumDisparities == numDisparities) {
            return checkNotNull(cachedStereoBm)
        }

        val stereoBm = StereoBM.create(numDisparities, DEPTH_BLOCK_SIZE)
        stereoBm.setPreFilterCap(31)
        stereoBm.setTextureThreshold(8)
        stereoBm.setUniquenessRatio(12)
        stereoBm.setSpeckleWindowSize(80)
        stereoBm.setSpeckleRange(16)
        stereoBm.setDisp12MaxDiff(1)

        cachedStereoBm = stereoBm
        cachedStereoBmNumDisparities = numDisparities
        return stereoBm
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
