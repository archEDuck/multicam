package com.example.multicam

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtException
import ai.onnxruntime.OrtSession
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.os.Environment
import android.util.Log
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.FloatBuffer
import java.util.LinkedHashMap
import kotlin.math.max
import kotlin.math.min

class Sam2Manager(private val context: Context) {
    companion object {
        private const val TAG = "Sam2Manager"
        private const val DEFAULT_ENCODER_FILE = "sam2_hiera_base_plus_encoder.onnx"
        private const val DEFAULT_DECODER_FILE = "decoder.onnx"
        private const val MASK_ALPHA = 0.45f
    }

    private data class PromptPoint(
        val x: Float,
        val y: Float,
        val label: Float,
    )

    private data class ModelFiles(
        val encoder: File,
        val decoder: File,
        val directory: File,
    )

    private data class SessionBundle(
        val environment: OrtEnvironment,
        val encoderSession: OrtSession,
        val decoderSession: OrtSession,
        val encoderPath: String,
        val decoderPath: String,
        val encoderInputNames: List<String>,
        val decoderInputNames: List<String>,
        val encoderInputWidth: Int,
        val encoderInputHeight: Int,
    )

    private val modelLocator = Sam2ModelLocator(context)
    @Volatile
    private var cachedBundle: SessionBundle? = null

    fun getStatus(): Map<String, Any> {
        val modelFiles = modelLocator.findModels()
        if (modelFiles == null) {
            val expectedDirectory = modelLocator.primaryModelDirectory().absolutePath
            return mapOf(
                "isReady" to false,
                "message" to "SAM2 modelleri bulunamadı. $DEFAULT_ENCODER_FILE ve $DEFAULT_DECODER_FILE dosyalarını $expectedDirectory içine koyun.",
                "modelDirectory" to expectedDirectory,
                "encoderPath" to "",
                "decoderPath" to "",
            )
        }

        return mapOf(
            "isReady" to true,
            "message" to "SAM2 modelleri hazır.",
            "modelDirectory" to modelFiles.directory.absolutePath,
            "encoderPath" to modelFiles.encoder.absolutePath,
            "decoderPath" to modelFiles.decoder.absolutePath,
        )
    }

    fun segmentFrame(
        imageBytes: ByteArray,
        rawPoints: List<Map<String, Any?>>,
    ): Map<String, Any> {
        return try {
            val modelFiles = modelLocator.findModels()
                ?: return missingModelResponse()

            val prompts = rawPoints.mapNotNull(::parsePoint)
            if (prompts.isEmpty()) {
                return mapOf(
                    "success" to false,
                    "message" to "SAM2 için en az bir geçerli nokta gerekli.",
                    "overlayBytes" to ByteArray(0),
                    "score" to 0.0,
                    "coverageRatio" to 0.0,
                    "imageWidth" to 0,
                    "imageHeight" to 0,
                )
            }

            val sourceBitmap = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
                ?.copy(Bitmap.Config.ARGB_8888, false)
                ?: return mapOf(
                    "success" to false,
                    "message" to "Preview karesi decode edilemedi.",
                    "overlayBytes" to ByteArray(0),
                    "score" to 0.0,
                    "coverageRatio" to 0.0,
                    "imageWidth" to 0,
                    "imageHeight" to 0,
                )

            val bundle = getOrCreateBundle(modelFiles)
            val preprocessed = Sam2ImagePreprocessor.prepare(
                bitmap = sourceBitmap,
                inputWidth = bundle.encoderInputWidth,
                inputHeight = bundle.encoderInputHeight,
            )

            val encoderTensor = OnnxTensor.createTensor(
                bundle.environment,
                FloatBuffer.wrap(preprocessed.tensorData),
                longArrayOf(1, 3, bundle.encoderInputHeight.toLong(), bundle.encoderInputWidth.toLong()),
            )

            val encoderInputs = LinkedHashMap<String, OnnxTensor>()
            encoderInputs[bundle.encoderInputNames.first()] = encoderTensor

            val encoderOutputNames = bundle.encoderSession.outputInfo.keys.toList()
            val encoderEmbeddings = bundle.encoderSession.run(encoderInputs).use { outputs ->
                val highRes0 = tensorToFloatArray(requireTensor(outputs, encoderOutputNames[0]))
                val highRes1 = tensorToFloatArray(requireTensor(outputs, encoderOutputNames[1]))
                val imageEmbedding = tensorToFloatArray(requireTensor(outputs, encoderOutputNames[2]))

                Triple(highRes0, highRes1, imageEmbedding)
            }
            encoderTensor.close()

            val promptTensors = Sam2PromptTensorFactory.create(
                environment = bundle.environment,
                prompts = prompts,
                originalWidth = sourceBitmap.width,
                originalHeight = sourceBitmap.height,
                encoderWidth = bundle.encoderInputWidth,
                encoderHeight = bundle.encoderInputHeight,
            )

            val decoderInputs = LinkedHashMap<String, OnnxTensor>()
            decoderInputs[bundle.decoderInputNames[0]] = OnnxTensor.createTensor(
                bundle.environment,
                FloatBuffer.wrap(encoderEmbeddings.third),
                longArrayOf(1, 256, 64, 64),
            )
            decoderInputs[bundle.decoderInputNames[1]] = OnnxTensor.createTensor(
                bundle.environment,
                FloatBuffer.wrap(encoderEmbeddings.first),
                longArrayOf(1, 32, 256, 256),
            )
            decoderInputs[bundle.decoderInputNames[2]] = OnnxTensor.createTensor(
                bundle.environment,
                FloatBuffer.wrap(encoderEmbeddings.second),
                longArrayOf(1, 64, 128, 128),
            )
            decoderInputs[bundle.decoderInputNames[3]] = promptTensors.pointCoords
            decoderInputs[bundle.decoderInputNames[4]] = promptTensors.pointLabels
            decoderInputs[bundle.decoderInputNames[5]] = promptTensors.maskInput
            decoderInputs[bundle.decoderInputNames[6]] = promptTensors.hasMaskInput
            decoderInputs[bundle.decoderInputNames[7]] = promptTensors.originalSize

            val decoderOutputNames = bundle.decoderSession.outputInfo.keys.toList()
            val (maskData, scoreData, maskShape) = bundle.decoderSession.run(decoderInputs).use { outputs ->
                val maskTensor = requireTensor(outputs, decoderOutputNames[0])
                val scoreTensor = requireTensor(outputs, decoderOutputNames[1])
                val info = maskTensor.info
                val shape = if (info is ai.onnxruntime.TensorInfo) info.shape else longArrayOf()
                Triple(
                    tensorToFloatArray(maskTensor),
                    tensorToFloatArray(scoreTensor),
                    shape,
                )
            }

            decoderInputs.values.forEach { it.close() }

            val composed = Sam2MaskComposer.composeOverlay(
                source = sourceBitmap,
                maskData = maskData,
                maskShape = maskShape,
            )

            if (composed.overlayBytes.isEmpty()) {
                return mapOf(
                    "success" to false,
                    "message" to "SAM2 mask çıktısı üretilemedi.",
                    "overlayBytes" to ByteArray(0),
                    "score" to 0.0,
                    "coverageRatio" to 0.0,
                    "imageWidth" to sourceBitmap.width,
                    "imageHeight" to sourceBitmap.height,
                )
            }

            mapOf(
                "success" to true,
                "message" to "SAM2 segmentasyonu tamamlandı.",
                "overlayBytes" to composed.overlayBytes,
                "score" to (scoreData.firstOrNull()?.toDouble() ?: 0.0),
                "coverageRatio" to composed.coverageRatio,
                "imageWidth" to sourceBitmap.width,
                "imageHeight" to sourceBitmap.height,
            )
        } catch (error: Exception) {
            Log.e(TAG, "SAM2 segmentation failed", error)
            mapOf(
                "success" to false,
                "message" to (error.message ?: "SAM2 segmentasyonu sırasında hata oluştu."),
                "overlayBytes" to ByteArray(0),
                "score" to 0.0,
                "coverageRatio" to 0.0,
                "imageWidth" to 0,
                "imageHeight" to 0,
            )
        }
    }

    private fun missingModelResponse(): Map<String, Any> {
        val expectedDirectory = modelLocator.primaryModelDirectory().absolutePath
        return mapOf(
            "success" to false,
            "message" to "SAM2 modelleri bulunamadı. Modelleri $expectedDirectory içine kopyalayın.",
            "overlayBytes" to ByteArray(0),
            "score" to 0.0,
            "coverageRatio" to 0.0,
            "imageWidth" to 0,
            "imageHeight" to 0,
        )
    }

    private fun parsePoint(raw: Map<String, Any?>): PromptPoint? {
        val x = (raw["x"] as? Number)?.toFloat() ?: return null
        val y = (raw["y"] as? Number)?.toFloat() ?: return null
        val label = (raw["label"] as? Number)?.toFloat() ?: return null
        return PromptPoint(x = x, y = y, label = label)
    }

    private fun requireTensor(outputs: OrtSession.Result, outputName: String): OnnxTensor {
        val onnxValue = outputs[outputName]
            .orElseThrow { OrtException("SAM2 çıktısı bulunamadı: $outputName") }
        return onnxValue as? OnnxTensor
            ?: throw OrtException("SAM2 çıktısı tensor değil: $outputName")
    }

    private fun tensorToFloatArray(tensor: OnnxTensor): FloatArray {
        val buffer = tensor.floatBuffer
        val copy = FloatArray(buffer.remaining())
        buffer.get(copy)
        return copy
    }

    @Synchronized
    private fun getOrCreateBundle(modelFiles: ModelFiles): SessionBundle {
        val current = cachedBundle
        if (
            current != null &&
            current.encoderPath == modelFiles.encoder.absolutePath &&
            current.decoderPath == modelFiles.decoder.absolutePath
        ) {
            return current
        }

        closeBundle(current)

        val environment = OrtEnvironment.getEnvironment()
        val sessionOptions = OrtSession.SessionOptions().apply {
            setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            setIntraOpNumThreads(2)
            setInterOpNumThreads(1)
        }

        val encoderSession = environment.createSession(modelFiles.encoder.absolutePath, sessionOptions)
        val decoderSession = environment.createSession(modelFiles.decoder.absolutePath, sessionOptions)

        val encoderInputName = encoderSession.inputNames.first()
        val encoderInfo = encoderSession.inputInfo[encoderInputName]?.info as? ai.onnxruntime.TensorInfo
            ?: throw OrtException("Encoder input bilgisi okunamadı.")
        val encoderShape = encoderInfo.shape
        val encoderInputHeight = encoderShape[2].toInt()
        val encoderInputWidth = encoderShape[3].toInt()

        return SessionBundle(
            environment = environment,
            encoderSession = encoderSession,
            decoderSession = decoderSession,
            encoderPath = modelFiles.encoder.absolutePath,
            decoderPath = modelFiles.decoder.absolutePath,
            encoderInputNames = encoderSession.inputNames.toList(),
            decoderInputNames = decoderSession.inputNames.toList(),
            encoderInputWidth = encoderInputWidth,
            encoderInputHeight = encoderInputHeight,
        ).also {
            cachedBundle = it
        }
    }

    private fun closeBundle(bundle: SessionBundle?) {
        if (bundle == null) {
            return
        }

        try {
            bundle.encoderSession.close()
        } catch (_: Exception) {
        }
        try {
            bundle.decoderSession.close()
        } catch (_: Exception) {
        }
    }

    private class Sam2ModelLocator(private val context: Context) {
        fun primaryModelDirectory(): File {
            return File(context.filesDir, "sam2-models")
        }

        fun downloadModelDirectory(): File {
            return File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                "Multicam/models",
            )
        }

        fun findModels(): ModelFiles? {
            ensureBundledModelsIfAvailable()

            val candidateDirectories = buildList {
                add(primaryModelDirectory())
                add(downloadModelDirectory())
                add(File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), ""))
                context.getExternalFilesDir(null)?.let { add(File(it, "models")) }
            }.distinctBy { it.absolutePath }

            var bestEncoder: File? = null
            var bestDecoder: File? = null
            var chosenDirectory: File? = null

            for (directory in candidateDirectories) {
                if (!directory.exists()) {
                    continue
                }

                val files = directory.walkTopDown()
                    .maxDepth(2)
                    .filter { it.isFile && it.extension.equals("onnx", ignoreCase = true) }
                    .toList()

                val exactEncoder = files.firstOrNull { it.name.equals(DEFAULT_ENCODER_FILE, ignoreCase = true) }
                val exactDecoder = files.firstOrNull { it.name.equals(DEFAULT_DECODER_FILE, ignoreCase = true) }
                val fallbackEncoder = files
                    .filter { it.name.contains("encoder", ignoreCase = true) }
                    .maxByOrNull { it.lastModified() }
                val fallbackDecoder = files
                    .filter { it.name.contains("decoder", ignoreCase = true) }
                    .maxByOrNull { it.lastModified() }

                val encoder = exactEncoder ?: fallbackEncoder
                val decoder = exactDecoder ?: fallbackDecoder

                if (encoder != null && decoder != null) {
                    bestEncoder = encoder
                    bestDecoder = decoder
                    chosenDirectory = encoder.parentFile ?: directory
                    break
                }
            }

            if (bestEncoder == null || bestDecoder == null || chosenDirectory == null) {
                return null
            }

            return ModelFiles(
                encoder = bestEncoder,
                decoder = bestDecoder,
                directory = chosenDirectory,
            )
        }

        private fun ensureBundledModelsIfAvailable() {
            val assetNames = context.assets.list("models")?.toList().orEmpty()
            if (assetNames.isEmpty()) {
                return
            }

            val encoderAsset = assetNames.firstOrNull {
                it.equals(DEFAULT_ENCODER_FILE, ignoreCase = true) ||
                    it.contains("encoder", ignoreCase = true)
            } ?: return
            val decoderAsset = assetNames.firstOrNull {
                it.equals(DEFAULT_DECODER_FILE, ignoreCase = true) ||
                    it.contains("decoder", ignoreCase = true)
            } ?: return

            val targetDir = primaryModelDirectory()
            if (!targetDir.exists()) {
                targetDir.mkdirs()
            }

            copyAssetIfMissing("models/$encoderAsset", File(targetDir, encoderAsset))
            copyAssetIfMissing("models/$decoderAsset", File(targetDir, decoderAsset))
        }

        private fun copyAssetIfMissing(assetPath: String, targetFile: File) {
            if (targetFile.exists() && targetFile.length() > 0L) {
                return
            }

            context.assets.open(assetPath).use { input ->
                targetFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
        }
    }

    private data class PreprocessedImage(
        val tensorData: FloatArray,
    )

    private object Sam2ImagePreprocessor {
        private val mean = floatArrayOf(0.485f, 0.456f, 0.406f)
        private val std = floatArrayOf(0.229f, 0.224f, 0.225f)

        fun prepare(
            bitmap: Bitmap,
            inputWidth: Int,
            inputHeight: Int,
        ): PreprocessedImage {
            val scaled = Bitmap.createScaledBitmap(bitmap, inputWidth, inputHeight, true)
            val pixels = IntArray(inputWidth * inputHeight)
            scaled.getPixels(pixels, 0, inputWidth, 0, 0, inputWidth, inputHeight)

            val chw = FloatArray(3 * inputWidth * inputHeight)
            val planeSize = inputWidth * inputHeight

            for (index in pixels.indices) {
                val pixel = pixels[index]
                val r = Color.red(pixel) / 255.0f
                val g = Color.green(pixel) / 255.0f
                val b = Color.blue(pixel) / 255.0f

                chw[index] = (r - mean[0]) / std[0]
                chw[planeSize + index] = (g - mean[1]) / std[1]
                chw[(2 * planeSize) + index] = (b - mean[2]) / std[2]
            }

            return PreprocessedImage(tensorData = chw)
        }
    }

    private data class PromptTensors(
        val pointCoords: OnnxTensor,
        val pointLabels: OnnxTensor,
        val maskInput: OnnxTensor,
        val hasMaskInput: OnnxTensor,
        val originalSize: OnnxTensor,
    )

    private object Sam2PromptTensorFactory {
        fun create(
            environment: OrtEnvironment,
            prompts: List<PromptPoint>,
            originalWidth: Int,
            originalHeight: Int,
            encoderWidth: Int,
            encoderHeight: Int,
        ): PromptTensors {
            val pointCoords = FloatArray(prompts.size * 2)
            val pointLabels = FloatArray(prompts.size)

            for ((index, prompt) in prompts.withIndex()) {
                pointCoords[index * 2] =
                    (prompt.x / max(1, originalWidth).toFloat()) * encoderWidth.toFloat()
                pointCoords[(index * 2) + 1] =
                    (prompt.y / max(1, originalHeight).toFloat()) * encoderHeight.toFloat()
                pointLabels[index] = prompt.label
            }

            val maskInput = FloatArray((encoderWidth / 4) * (encoderHeight / 4))

            return PromptTensors(
                pointCoords = OnnxTensor.createTensor(
                    environment,
                    FloatBuffer.wrap(pointCoords),
                    longArrayOf(1, prompts.size.toLong(), 2),
                ),
                pointLabels = OnnxTensor.createTensor(
                    environment,
                    FloatBuffer.wrap(pointLabels),
                    longArrayOf(1, prompts.size.toLong()),
                ),
                maskInput = OnnxTensor.createTensor(
                    environment,
                    FloatBuffer.wrap(maskInput),
                    longArrayOf(1, 1, (encoderHeight / 4).toLong(), (encoderWidth / 4).toLong()),
                ),
                hasMaskInput = OnnxTensor.createTensor(
                    environment,
                    FloatBuffer.wrap(floatArrayOf(0f)),
                    longArrayOf(1),
                ),
                originalSize = OnnxTensor.createTensor(
                    environment,
                    intArrayOf(originalHeight, originalWidth),
                ),
            )
        }
    }

    private data class ComposedMask(
        val overlayBytes: ByteArray,
        val coverageRatio: Double,
    )

    private object Sam2MaskComposer {
        fun composeOverlay(
            source: Bitmap,
            maskData: FloatArray,
            maskShape: LongArray,
        ): ComposedMask {
            if (maskData.isEmpty()) {
                return ComposedMask(ByteArray(0), 0.0)
            }

            val maskHeight = if (maskShape.size >= 3) maskShape[maskShape.size - 2].toInt() else source.height
            val maskWidth = if (maskShape.isNotEmpty()) maskShape.last().toInt() else source.width

            val srcWidth = source.width
            val srcHeight = source.height
            val pixels = IntArray(srcWidth * srcHeight)
            source.getPixels(pixels, 0, srcWidth, 0, 0, srcWidth, srcHeight)

            var coveredPixelCount = 0

            for (y in 0 until srcHeight) {
                val maskY = min(maskHeight - 1, (y.toFloat() / srcHeight.toFloat() * maskHeight).toInt())
                for (x in 0 until srcWidth) {
                    val maskX = min(maskWidth - 1, (x.toFloat() / srcWidth.toFloat() * maskWidth).toInt())
                    val maskIndex = (maskY * maskWidth) + maskX
                    if (maskIndex < 0 || maskIndex >= maskData.size || maskData[maskIndex] <= 0f) {
                        continue
                    }

                    val pixelIndex = (y * srcWidth) + x
                    pixels[pixelIndex] = blendWithGreen(pixels[pixelIndex])
                    coveredPixelCount += 1
                }
            }

            val mutable = source.copy(Bitmap.Config.ARGB_8888, true)
            mutable.setPixels(pixels, 0, srcWidth, 0, 0, srcWidth, srcHeight)

            val output = ByteArrayOutputStream()
            mutable.compress(Bitmap.CompressFormat.PNG, 100, output)

            val totalPixels = max(1, srcWidth * srcHeight)
            return ComposedMask(
                overlayBytes = output.toByteArray(),
                coverageRatio = coveredPixelCount.toDouble() / totalPixels.toDouble(),
            )
        }

        private fun blendWithGreen(original: Int): Int {
            val red = ((Color.red(original) * (1.0f - MASK_ALPHA)) + (64f * MASK_ALPHA)).toInt()
            val green = ((Color.green(original) * (1.0f - MASK_ALPHA)) + (255f * MASK_ALPHA)).toInt()
            val blue = ((Color.blue(original) * (1.0f - MASK_ALPHA)) + (110f * MASK_ALPHA)).toInt()
            return Color.argb(255, red, green, blue)
        }
    }
}
