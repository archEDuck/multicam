# MultiCam Projesi

Bu proje, Android cihazlarda çift arka kameradan eşzamanlı görüntü ve sensör verisi almak, bu verileri 3D modelleme (NeRF, Stereo İşleme) için ön işlemeden geçirmek amacıyla geliştirilmiş kapsamlı bir veri toplama ve işleme ekosistemidir. 

Sistem üç ana bileşenden oluşmaktadır: Flutter tabanlı arayüz (lib), native Android Camera2 entegrasyonu (android) ve post-processing / analiz işlemleri için Python betikleri (pythonFiles).

##  Proje Yapısı ve Klasör İçerikleri

### 1. lib/ (Flutter UI ve Native Köprü)
Kullanıcı arayüzünün yönetildiği ve native (Android) tarafla veri iletişiminin kurulduğu Dart/Flutter klasörüdür.
* **main.dart**: Uygulamanın başlangıç noktasıdır. Ekrandaki kamera önizlemeleri, kayıt başlatma/durdurma butonları ve FPS ayarlamaları gibi UI işlemlerini kontrol eder.
* **camera2_bridge.dart**: Flutter uygulamasıyla Kotlin'de yazılmış Native Camera2 API'si arasındaki haberleşmeyi sağlayan köprü sınıfıdır (Method Channels kullanır).

### 2. android/ (Native Kotlin & Camera2 Çekirdeği)
Kamera donanımına doğrudan erişim sağlayan ve cihaz kısıtlamalarını yöneten native klasördür.
* **DualCameraManager.kt**: Projenin kalbidir. Android Camera2 API kullanarak cihazın çift arka kamerasını aynı anda aktif eder. Görüntüleri yakalayıp cihazın sensör verileriyle (IMU, Jiroskop vb.) birlikte kaydeder.
* **MainActivity.kt**: Flutter katmanı ile native metodların çalıştığı Android aktivitesini bağlar.

### 3. pythonFiles/ (Görsel İşleme, NeRF ve İletişim Araçları)
Telefonda toplanan senkronize görsel ve sensör verilerini bilgisayarda incelemek, kablosuz aktarmak veya 3D algoritmalara beslemek için kullanılan yardımcı Python betikleridir.
* **
erf_processor.py**: Elde edilen görselleri işleyerek Neural Radiance Fields (NeRF) yapay zeka modelleriyle 3D sahneler oluşturmak için ortam hazırlar.
* **stereo_processor.py**: Çiftli sistemden gelen görüntüleri stereo algoritmalarına sokar ve derinlik tahminlemesi/3D tarama ön hazırlıkları yapar.
* **	est_rectification.py**: İşlenen stereo verilerin kalibrasyonunu ve hizalamasını (rectification) test etmek için kullanılır.
* **stereo_config.json**: Stereo işlemler ve lens distorsiyon ayarları için kullanılan parametre konfigürasyon dosyasıdır.
* **
un_viewer.py**: Verileri Android cihazdan (ADB üzerinden) hızlıca çekerek bir HTML arayüzünde senkronize kareleri incelemenizi sağlayan görüntüleyici betiktir.
* **wifi_server.py**: Toplanan arşiv (.zip vb.) kayıtlarını USB'ye ihtiyaç duymadan kablosuz ağ üzerinden bilgisayara aktarmaya yarayan lokal bağlantı sunucusudur.

##  Başlangıç
* Flutter uygulamasını lib/main.dart üzerinden derleyerek fiziksel bir Android (özellikle çift kamera destekli) cihazda çalıştırabilirsiniz.
* Kayıtlar tamamlandıktan sonra aktarım veya 3D ön-işleme için bilgisayarınızda pythonFiles altındaki betikleri kullanabilirsiniz.
* wifi.py dosyasını çalıştır. 
* Ip adresini yaz uygulamaya. 
* Önce kalibre et. 
* Sonra kalibrasyonlu modda çalıştır.
## Veriler
* Veriler session klasöründe toplanrı. 
* Zip halinde gelir zip açışır. 
