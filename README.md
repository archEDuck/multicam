# multicam

Samsung S23 gibi Android cihazlarda iki arka kameradan eszamanli goruntu alip
3D tarama on-isleme verisi toplamak icin hazirlanan Flutter uygulamasi.

Kamera altyapisi `multicamera` paketi ile calisir.

## Ozellikler

- Iki arka kamerayi ayni anda acar ve canli onizleme sunar.
- `Kaydi Baslat` ile oturum kaydi baslatir, `Kaydi Durdur` ile bitirir.
- Her dongude iki kameradan birer kare alip dosyaya yazar.
- Kare metadata bilgisini `capture_log.csv` dosyasina ekler.
- Android `TYPE_PROXIMITY` sensor degerini `fot_cm` kolonu olarak kaydeder.
- IMU verilerini (user accelerometer + gyroscope) CSV'ye ekler.
- Kayit hizini UI slider ile degistirir (yakalama araligi/FPS).
- Kayit durdugunda oturum klasorunu otomatik `.zip` dosyasina paketler.
- Native Camera2 bridge ile arka kamera concurrent destek raporunu UI'de gosterir.

## Cikti Yapisi

Kayitlar uygulama dokuman klasoru altinda tutulur:

`.../Documents/sessions/<YYYYMMDD_HHMMSS>/`

- `cam1/` : 1. arka kameradan kaydedilen kareler
- `cam2/` : 2. arka kameradan kaydedilen kareler
- `capture_log.csv` : kare index, UTC zaman damgasi, resim yollari, FoT/proximity ve IMU verileri
- `<session>.zip` : ayni oturumun sikistirilmis hali

CSV kolonlari:

`frame,timestamp_utc,cam1_image,cam2_image,fot_cm,acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z`

## Calistirma

```bash
flutter pub get
flutter run
```

## Notlar

- Cihazda ayni anda kullanilabilir en az 2 arka kamera yoksa uygulama kayit baslatmaz.
- FoT verisi cihazdan cihaza farklilik gosterebilir. Bu projede Android proximity sensor
	akisi kullanilir ve `fot_cm` olarak yazilir.
- Uygulama acilisinda kamera izni istenir. Izin verilmezse kamera akisi baslatilmaz.
