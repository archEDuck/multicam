# multicam

Samsung S23 gibi Android cihazlarda iki arka kameradan eşzamanlı görüntü alıp
3D tarama ön-işleme verisi toplamak için hazırlanan Flutter uygulaması.

Kamera altyapısı `multicamera` paketi ile çalışır.

## Özellikler

- İki arka kamerayı aynı anda açar ve canlı önizleme sunar.
- `Kaydı Başlat` ile oturum kaydı başlatır, `Kaydı Durdur` ile bitirir.
- Her döngüde iki kameradan birer kare alıp dosyaya yazar.
- Kare metadata bilgisini `capture_log.csv` dosyasına ekler.
- Android `TYPE_PROXIMITY` sensör değerini `fot_cm` kolonu olarak kaydeder.
- IMU verilerini (user accelerometer + gyroscope) CSV'ye ekler.
- Kayıt hızını UI slider ile değiştirir (yakalama aralığı/FPS).
- Kayıt durduğunda oturum klasörünü otomatik `.zip` dosyasına paketler.
- Native Camera2 bridge ile arka kamera concurrent destek raporunu UI'de gösterir.

## Çıktı Yapısı

Kayıtlar uygulama doküman klasörü altında tutulur:

`.../Documents/sessions/<YYYYMMDD_HHMMSS>/`

- `cam1/` : 1. arka kameradan kaydedilen kareler
- `cam2/` : 2. arka kameradan kaydedilen kareler
- `capture_log.csv` : kare index, UTC zaman damgası, resim yolları, FoT/proximity ve IMU verileri
- `<session>.zip` : aynı oturumun sıkıştırılmış hali

CSV kolonları:

`frame,timestamp_utc,cam1_image,cam2_image,fot_cm,acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z`

## Flutter Uygulamasını Çalıştırma

1. Flutter SDK'yı yükleyin ve ortam değişkenlerini ayarlayın.
2. Proje dizininde aşağıdaki komutları çalıştırın:

   ```bash
   flutter pub get
   flutter run
   ```

3. Uygulama, bağlı bir Android cihazda veya emülatörde başlatılacaktır.

## Python Araçlarını Kullanma

### `run_viewer.py`

Bu Python betiği, cihazdan alınan kayıtları bilgisayara çeker ve bir HTML tabanlı görüntüleyici oluşturur.

#### İşlevleri:

- **ADB Bağlantısı Kontrolü:** Telefonun USB hata ayıklama modunda bağlı olup olmadığını kontrol eder.
- **Kayıtları Çekme:**
  - Uygulama içi kayıtları (`sessions.tar`) çeker ve açar.
  - Harici depolama alanındaki (`/sdcard/Download/Multicam/sessions/`) kayıtları indirir.
- **ZIP Dosyalarını Açma:** Çekilen ZIP dosyalarını açar ve oturum klasörlerine yerleştirir.
- **CSV Dosyasını Okuma:** En güncel `capture_log.csv` dosyasını bulur ve içeriğini işler.
- **HTML Görüntüleyici Oluşturma:** Kayıtları görselleştiren bir HTML dosyası oluşturur ve tarayıcıda açar.

#### Çalıştırma Adımları:

1. Python 3.x yüklü olduğundan emin olun.
2. Gerekli bağımlılıkları yükleyin (örneğin, `pip install adb`).
3. Komut satırında aşağıdaki komutu çalıştırın:

   ```bash
   python pythonFiles/run_viewer.py
   ```

4. Betik, kayıtları çeker ve tarayıcıda bir görüntüleyici açar.

### `stereo_processor.py`

Bu betik, çekilen görüntüleri işlemek için kullanılır. Örneğin, 3D tarama veya derinlik haritası oluşturma işlemleri burada yapılabilir.

#### Çalıştırma Adımları:

1. Gerekli bağımlılıkları yükleyin (örneğin, OpenCV).
2. Komut satırında aşağıdaki komutu çalıştırın:

   ```bash
   python pythonFiles/stereo_processor.py
   ```

### `wifi_server.py`

Bu betik, cihaz ile bilgisayar arasında kablosuz veri aktarımı için bir sunucu başlatır.

#### Çalıştırma Adımları:

1. Komut satırında aşağıdaki komutu çalıştırın:

   ```bash
   python pythonFiles/wifi_server.py
   ```

2. Sunucu başlatıldıktan sonra, cihazdan bilgisayara veri aktarımı yapılabilir.

## Notlar

- Cihazda aynı anda kullanılabilir en az 2 arka kamera yoksa uygulama kayıt başlatmaz.
- FoT verisi cihazdan cihaza farklılık gösterebilir. Bu projede Android proximity sensör
  akışı kullanılır ve `fot_cm` olarak yazılır.
- Uygulama açılışında kamera izni istenir. İzin verilmezse kamera akışı başlatılmaz.

## Sistemi Uçtan Uca Çalıştırma

### 1. Bilgisayar Tarafı (Sunucuyu Başlatma)

Önce derinlik hesabı için gerekli görüntü işleme kütüphanelerini kurmalısınız (Eğer kurulu değilse). Bilgisayarınızın terminalini/komut satırını açıp şu komutu girin:

```bash
pip install opencv-python numpy
```

Daha sonra projenizin ana klasöründeyken Python dosya sunucunuzu çalıştırın:

```bash
python pythonFiles/wifi_server.py
```

Sunucu başladığında terminalde büyük harflerle **MULTICAM WİFİ DOSYA ALICI SUNUCUSU** yazacak ve size telefondaki uygulamaya yazılacak IP: `188.191.107.81` (veya bilgisayarınızın local IP'si neyse o) şeklinde bir bilgi verecektir.

### 2. Telefon Tarafı (Bağlantı)

Telefon uygulamasında sağ üstteki veya alttaki IP adresi kutusuna bilgisayarınızın ekranında yazan bu IP adresini eksiksiz girin. (Aynı Wi-Fi ağına bağlı olmanız gerektiğini unutmayın).

> **Not:** Derinlik çıkarabilmek için bilgisayarın, farklı olan iki lensinizin bükülme payını ve birbirlerine olan mesafesini öğrenmesi gerekir. Bunu da bir seferliğine Satranç Tahtası yardımı ile öğretmeliyiz.

### 3. Kalibrasyon Aşaması (Sadece 1 Kere)

1. İnternetten "Checkerboard calibration pattern" (Genellikle 9x6 veya 8x6 veya 10x7 kareli siyah-beyaz desendir) bulup tabletinizde veya başka bir ekranda tam sayfa açın (veya kağıda çıktı alın). A4 kağıdı idealdir.
2. Flutter uygulamanızda Çekim Modunu açılır menüden **Kalibrasyon** olarak seçin.
3. Kaydı başlatın.
4. Kamerayı satranç tahtasına tutarken farklı açılardan (sağdan, soldan, eğik, üstten, uzak, yakın) yavaşça hareket ettirin (Yaklaşık 10-15 farklı kare/fotoğraf çekilmesi yeterlidir. Ancak kameranın her iki lensinin de bu tahtayı aynı anda ve net gördüğünden emin olun).
5. Kaydı durdurun.
6. Uygulama ZIP dosyasını bilgisayara gönderecek.
7. Bilgisayar terminaline bakın: Sistemin fotoğrafları inceleyip **"Kalibrasyon başarıyla tamamlandı ve kaydedildi!"** yazısını görmelisiniz (Klasörde `stereo_config.json` dosyası oluşacaktır).

### 4. Derinlik (Depth) Çekimi (Artık Hazırsınız!)

Kalibrasyon veriniz oluştuktan sonra asıl işleme geçebilirsiniz.

1. Flutter uygulamasında Çekim Modunu açılır menüden **Derinlik** olarak seçin.
2. İstediğiniz bir odanın veya nesnenin karşısında kaydı başlatıp çekim yapın.
3. Kaydı durdurun.
4. Dosya (`depth_2026...zip`) bilgisayara gidecek.
5. Python sunucusu bu dosya adını görecek, az önce oluşturduğu profili (`stereo_config.json`) alıp fotoğrafların hizalamalarını (Rectification) yapacak ve OpenCV ile ısı haritalarını hesaplayacak.
6. Ve bingo! İşlem bitince tarayıcınızda otomatik olarak gösterici web sayfası açılacak; hem orijinal kamerayı hem geniş açılı kamerayı hem de 3. kutucukta çıkarılan Derinlik Haritasını renkli bir şekilde kaydırarak izleyebileceksiniz.
