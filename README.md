# MultiCam

Bu proje Flutter + Android (Kotlin) tabanlı bir stereo yakalama uygulamasıdır.

## Mimari

- `lib/`: Flutter arayüzü ve uygulama akışı
- `android/`: Native Camera2 ve OpenCV entegrasyonu

## Stereo Akışı

1. Faz 1: Kamera çifti seçilir ve açılır.
2. Faz 2: Checkerboard (7x7 iç köşe) ile kalibrasyon yapılır.
3. Faz 3: Kalibrasyon çıktılarıyla stereo rectify çalıştırılır.
4. Faz 4: Ham frame çiftleri belirli aralıkla alınır, cihazda `stereo_sessions/session_xxx/cam1|cam2` altına yazılır ve yerel sunucuya upload edilir.

## Kamera Çalışma Prensibi

- Uygulama **tek mod** ile çalışır: `logical_multi_camera`.
- `alternating`/sıralı fallback modu kullanılmaz.
- Seçilen kamera çifti logical multi-camera olarak açılamıyorsa uygulama hata döndürür.

## Not

- Python tabanlı yardımcı betikler bu depodan kaldırılmıştır.

## Faz 4 Yerel Sunucu

Bilgisayarda Flask sunucusu çalıştırmak için:

1. `pip install flask`
2. `python3 tools/local_stereo_upload_server.py --host 0.0.0.0 --port 8000`

Endpoint: `POST /upload-file`

- form-data alanları: `session_id`, `camera_label` (`cam1`/`cam2`), `frame_index`, `timestamp`, `file`
- çıktı klasörü: `~/stereo_data/<session_id>/cam1|cam2`
- log dosyası: `~/stereo_data/<session_id>/image_log.csv`
