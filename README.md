# MultiCam

Bu proje Flutter + Android (Kotlin) tabanlı bir stereo yakalama uygulamasıdır.

## Mimari

- `lib/`: Flutter arayüzü ve uygulama akışı
- `android/`: Native Camera2 ve OpenCV entegrasyonu

## Stereo Akışı

1. Faz 1: Kamera çifti seçilir ve açılır.
2. Faz 2: Checkerboard (7x7 iç köşe) ile kalibrasyon yapılır.
3. Faz 3: Kalibrasyon çıktılarıyla stereo rectify çalıştırılır.

## Kamera Çalışma Prensibi

- Uygulama **tek mod** ile çalışır: `logical_multi_camera`.
- `alternating`/sıralı fallback modu kullanılmaz.
- Seçilen kamera çifti logical multi-camera olarak açılamıyorsa uygulama hata döndürür.

## Not

- Python tabanlı yardımcı betikler bu depodan kaldırılmıştır.
