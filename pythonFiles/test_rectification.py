import os
import sys
import cv2
import glob
import json
import numpy as np

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(BASE_DIR, "stereo_config.json")

def rectify_session_images(session_dir):
    """
    Kamera kalibrasyon verilerini kullanarak iki kameradan gelen raw(ham)
    görüntülerin mercek bükülmelerini (undistortion) düzeltir ve
    birbirleriyle aynı yatay düzleme hizalar (rectification).
    Sonuçları yan yana birleşik (üstünde hizalama çizgileriyle) kaydeder.
    """
    if not os.path.exists(CONFIG_FILE):
        print("[-] Hata: stereo_config.json bulunamadı! Önce 'calib_' modunda çekim yapıp sunucuya atarak kalibrasyonun tamamlandığına emin olun.")
        return

    with open(CONFIG_FILE, 'r') as f:
        calib = json.load(f)

    CM1 = np.array(calib['mtx1']); dist1 = np.array(calib['dist1'])
    CM2 = np.array(calib['mtx2']); dist2 = np.array(calib['dist2'])
    R1 = np.array(calib['R1']); R2 = np.array(calib['R2'])
    P1 = np.array(calib['P1']); P2 = np.array(calib['P2'])
    img_shape = tuple(calib['img_shape'])

    map1x, map1y = cv2.initUndistortRectifyMap(CM1, dist1, R1, P1, img_shape, cv2.CV_32FC1)
    map2x, map2y = cv2.initUndistortRectifyMap(CM2, dist2, R2, P2, img_shape, cv2.CV_32FC1)

    cam1_dir = os.path.join(session_dir, "cam1")
    cam2_dir = os.path.join(session_dir, "cam2")
    out_dir = os.path.join(session_dir, "rectified_preview")
    os.makedirs(out_dir, exist_ok=True)

    c1_images = sorted(glob.glob(os.path.join(cam1_dir, "*.jpg")))
    c2_images = sorted(glob.glob(os.path.join(cam2_dir, "*.jpg")))
    count = min(len(c1_images), len(c2_images))

    if count == 0:
        print(f"[-] Hata: {session_dir} klasörü içerisinde eşleşecek 'cam1' ve 'cam2' fotoğrafları bulunamadı.")
        return

    print(f"[*] Toplam {count} çift fotoğraf hizalanıyor (Rectification)...")

    for i in range(count):
        img1 = cv2.imread(c1_images[i])
        img2 = cv2.imread(c2_images[i])
        if img1 is None or img2 is None: continue

        # Kameraların çekim boyutu kalibrasyondan farklı gelirse düzelt
        if img1.shape[:2][::-1] != img_shape: img1 = cv2.resize(img1, img_shape)
        if img2.shape[:2][::-1] != img_shape: img2 = cv2.resize(img2, img_shape)

        # Temel sihirin yapıldığı yer (Bükülmeleri geri al ve hizala)
        rect1 = cv2.remap(img1, map1x, map1y, cv2.INTER_LINEAR)
        rect2 = cv2.remap(img2, map2x, map2y, cv2.INTER_LINEAR)

        # Kullanıcının hizalamayı gözüyle onaylayabilmesi için resimleri yan yana birleştiriyoruz
        combined = np.hstack((rect1, rect2))

        # Üstüne her 100 pikselde bir yatay yeşil çizgi çizelim.
        # EğER KALİBRASYON BAŞARILIYSA, sol resimdeki bir nesnenin köşesi ile,
        # sağ resimdeki aynı nesnenin köşesi TAM OLARAK AYNI YEŞİL ÇİZGİYE DENK GELMELİDİR.
        for line_y in range(0, combined.shape[0], 100):
            cv2.line(combined, (0, line_y), (combined.shape[1], line_y), (0, 255, 0), 2)

        out_path = os.path.join(out_dir, f"hizalanmis_cift_{i}.jpg")
        
        # Orijinal boyut çok büyükse (örneğin 2x4K = 8K) diski dondurmamak ve hızlı açmak için %50 ufaltıp kaydedelim
        preview_scale = cv2.resize(combined, (combined.shape[1] // 2, combined.shape[0] // 2))
        cv2.imwrite(out_path, preview_scale)

    print(f"\n[+] İşlem Başarılı! Hizalanmış (Rectified) resimlerinizi şu klasörde bulabilirsiniz:\n    -> {out_dir}")
    print("[*] Resmi açıp inceleyin: Soldaki nesne detayları ile Sağdaki aynı detaylar tam olarak aynı yatay yeşil çizgide mi? Eğer aynı hizada değilse kalibrasyon çekiminizde sorun var demektir.")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Kullanım: python pythonFiles/test_rectification.py <session_klasör_yolu>")
        print("Örnek: python pythonFiles/test_rectification.py pythonFiles/sessions/depth_2026...")
    else:
        rectify_session_images(sys.argv[1])
