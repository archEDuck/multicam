package com.example.multicam

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import org.opencv.android.OpenCVLoader
import org.opencv.calib3d.Calib3d
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
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

        private const val CHESSBOARD_WIDTH = 7
        private const val CHESSBOARD_HEIGHT = 7
        private const val SQUARE_SIZE = 2.0

        private const val MIN_VALID_PAIRS = 5
        private const val CALIBRATION_FILE_NAME = "stereo_calibration.json"
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

            val boardSize = Size(CHESSBOARD_WIDTH.toDouble(), CHESSBOARD_HEIGHT.toDouble())
            val corners1 = MatOfPoint2f()
            val corners2 = MatOfPoint2f()

            val cornerCriteria = TermCriteria(
                TermCriteria.EPS + TermCriteria.MAX_ITER,
                30,
                0.001,
            )

            val flags = Calib3d.CALIB_CB_ADAPTIVE_THRESH or
                Calib3d.CALIB_CB_NORMALIZE_IMAGE

            val found1 = Calib3d.findChessboardCorners(gray1, boardSize, corners1, flags)
            val found2 = Calib3d.findChessboardCorners(gray2, boardSize, corners2, flags)

            if (found1) {
                Imgproc.cornerSubPix(
                    gray1,
                    corners1,
                    Size(11.0, 11.0),
                    Size(-1.0, -1.0),
                    cornerCriteria,
                )
            }
            if (found2) {
                Imgproc.cornerSubPix(
                    gray2,
                    corners2,
                    Size(11.0, 11.0),
                    Size(-1.0, -1.0),
                    cornerCriteria,
                )
            }

            val foundPair = found1 && found2

            val cam1Width = gray1.cols()
            val cam1Height = gray1.rows()
            val cam2Width = gray2.cols()
            val cam2Height = gray2.rows()
            val cam1CornerList = if (found1) cornersToList(corners1) else emptyList()
            val cam2CornerList = if (found2) cornersToList(corners2) else emptyList()

            corners1.release()
            corners2.release()
            gray1.release()
            gray2.release()
            img1.release()
            img2.release()

            val message = when {
                foundPair -> "✓ Dama tahtası bulundu (iki kamera)."
                found1 || found2 -> "✗ Dama tahtası iki kamerada aynı anda bulunamadı. Kartı her iki kadraja da ortalayın."
                else -> "✗ Dama tahtası bulunamadı. Kartı kadraja yaklaştırıp daha iyi aydınlatın."
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

            val objectPoints = mutableListOf<Mat>()
            val imagePoints1 = mutableListOf<Mat>()
            val imagePoints2 = mutableListOf<Mat>()
            val objectTemplate = createObjectTemplate()

            var imageSize: Size? = null
            var validPairs = 0

            val boardSize = Size(CHESSBOARD_WIDTH.toDouble(), CHESSBOARD_HEIGHT.toDouble())
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

                val corners1 = MatOfPoint2f()
                val corners2 = MatOfPoint2f()

                val found1 = Calib3d.findChessboardCorners(
                    gray1,
                    boardSize,
                    corners1,
                    Calib3d.CALIB_CB_ADAPTIVE_THRESH or Calib3d.CALIB_CB_NORMALIZE_IMAGE,
                )
                val found2 = Calib3d.findChessboardCorners(
                    gray2,
                    boardSize,
                    corners2,
                    Calib3d.CALIB_CB_ADAPTIVE_THRESH or Calib3d.CALIB_CB_NORMALIZE_IMAGE,
                )

                if (found1 && found2) {
                    Imgproc.cornerSubPix(
                        gray1,
                        corners1,
                        Size(11.0, 11.0),
                        Size(-1.0, -1.0),
                        cornerCriteria,
                    )
                    Imgproc.cornerSubPix(
                        gray2,
                        corners2,
                        Size(11.0, 11.0),
                        Size(-1.0, -1.0),
                        cornerCriteria,
                    )

                    objectPoints.add(objectTemplate.clone())
                    imagePoints1.add(corners1)
                    imagePoints2.add(corners2)
                    validPairs += 1
                } else {
                    corners1.release()
                    corners2.release()
                }

                gray1.release()
                gray2.release()
                img1.release()
                img2.release()
            }

            if (validPairs < MIN_VALID_PAIRS || imageSize == null) {
                releaseMatList(objectPoints)
                releaseMatList(imagePoints1)
                releaseMatList(imagePoints2)
                objectTemplate.release()

                return mapOf(
                    "success" to false,
                    "message" to "Yeterli checkerboard çifti bulunamadı (en az $MIN_VALID_PAIRS).",
                    "processedPairs" to validPairs,
                    "outputPath" to "",
                )
            }

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
                put("checkerboardWidth", CHESSBOARD_WIDTH)
                put("checkerboardHeight", CHESSBOARD_HEIGHT)
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

            releaseMatList(objectPoints)
            releaseMatList(imagePoints1)
            releaseMatList(imagePoints2)
            releaseMatList(rvecs1)
            releaseMatList(tvecs1)
            releaseMatList(rvecs2)
            releaseMatList(tvecs2)
            objectTemplate.release()
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
                "message" to "Kalibrasyon tamamlandı.",
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

            val calibration = JSONObject(calibrationFile.readText())
            val imageWidth = calibration.optInt("imageWidth", 0)
            val imageHeight = calibration.optInt("imageHeight", 0)
            if (imageWidth <= 0 || imageHeight <= 0) {
                return mapOf(
                    "success" to false,
                    "message" to "Kalibrasyon çözünürlük verisi bozuk.",
                    "processedPairs" to 0,
                    "outputPath" to "",
                )
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

                Imgproc.remap(src1, rect1, map1x, map1y, Imgproc.INTER_LINEAR)
                Imgproc.remap(src2, rect2, map2x, map2y, Imgproc.INTER_LINEAR)

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

            k1.release()
            d1.release()
            k2.release()
            d2.release()
            r1.release()
            r2.release()
            p1.release()
            p2.release()
            map1x.release()
            map1y.release()
            map2x.release()
            map2y.release()

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

    private fun ensureOpenCvLoaded() {
        val loaded = OpenCVLoader.initDebug()
        if (!loaded) {
            throw IllegalStateException(
                "OpenCV yüklenemedi. Gradle bağımlılığı ve native kütüphaneleri kontrol edin.",
            )
        }
    }

    private fun createObjectTemplate(): MatOfPoint3f {
        val points = mutableListOf<Point3>()
        for (y in 0 until CHESSBOARD_HEIGHT) {
            for (x in 0 until CHESSBOARD_WIDTH) {
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
