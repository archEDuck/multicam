import cv2
import numpy as np
import os
import glob
import json

CONFIG_FILE = os.path.join(os.path.dirname(__file__), "stereo_config.json")

# Satranç tahtası özellikleri (iç köşelerin sayısı, kenar uzunluğu değişebilir, genelde 9x6 olur)
CHESSBOARD_SIZE = (7, 7)
SQUARE_SIZE = 2.0 # Örnek cm veya mm değeri

def calibrate_and_save(session_dir):
    """
    Kamera kalibrasyonu yapar ve extrinsic/intrinsic matrisleri kaydeder.
    """
    print("[*] Kalibrasyon başlatılıyor...")
    cam1_dir = os.path.join(session_dir, "cam1")
    cam2_dir = os.path.join(session_dir, "cam2")
    
    if not os.path.exists(cam1_dir) or not os.path.exists(cam2_dir):
        print("  [-] Hata: cam1 veya cam2 klasörleri eksik.")
        return False, "Klasörler eksik"

    objp = np.zeros((CHESSBOARD_SIZE[0] * CHESSBOARD_SIZE[1], 3), np.float32)
    objp[:, :2] = np.mgrid[0:CHESSBOARD_SIZE[0], 0:CHESSBOARD_SIZE[1]].T.reshape(-1, 2)
    objp = objp * SQUARE_SIZE

    objpoints = [] # Gerçek dünya 3D nokta koordinatları
    imgpoints1 = [] # Kamera 1, 2D noktaları
    imgpoints2 = [] # Kamera 2, 2D noktaları

    c1_images = sorted(glob.glob(os.path.join(cam1_dir, "*.jpg")))
    c2_images = sorted(glob.glob(os.path.join(cam2_dir, "*.jpg")))

    # En az eşleşen sayıda devam et
    count = min(len(c1_images), len(c2_images))
    img_shape = None

    valid_pairs = 0
    for i in range(count):
        img1 = cv2.imread(c1_images[i])
        img2 = cv2.imread(c2_images[i])
        if img1 is None or img2 is None: continue

        gray1 = cv2.cvtColor(img1, cv2.COLOR_BGR2GRAY)
        gray2 = cv2.cvtColor(img2, cv2.COLOR_BGR2GRAY)

        if img_shape is None:
            img_shape = gray1.shape[::-1] # Width, Height

        # OpenCV ile satranç tahtası köşelerini bul
        ret1, corners1 = cv2.findChessboardCorners(gray1, CHESSBOARD_SIZE, None)
        ret2, corners2 = cv2.findChessboardCorners(gray2, CHESSBOARD_SIZE, None)

        if ret1 and ret2:
            criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.001)
            corners1 = cv2.cornerSubPix(gray1, corners1, (11, 11), (-1, -1), criteria)
            corners2 = cv2.cornerSubPix(gray2, corners2, (11, 11), (-1, -1), criteria)

            objpoints.append(objp)
            imgpoints1.append(corners1)
            imgpoints2.append(corners2)
            valid_pairs += 1

    print(f"  [+] Bulunan geçerli Stereo çifti: {valid_pairs}")
    
    if valid_pairs < 5:
        return False, "Yeterli satranç tahtası görüntüsü bulunamadı. Lütfen daha çok açıdan çekim yapın."

    # Bireysel Kamera Kalibrasyonları (Intrinsic)
    ret1, mtx1, dist1, rvecs1, tvecs1 = cv2.calibrateCamera(objpoints, imgpoints1, img_shape, None, None)
    ret2, mtx2, dist2, rvecs2, tvecs2 = cv2.calibrateCamera(objpoints, imgpoints2, img_shape, None, None)

    # Stereo Kalibrasyon (Extrinsic R ve T)
    flags = cv2.CALIB_FIX_INTRINSIC
    criteria_stereo = (cv2.TERM_CRITERIA_MAX_ITER + cv2.TERM_CRITERIA_EPS, 100, 1e-5)
    
    ret_stereo, CM1, dist1, CM2, dist2, R, T, E, F = cv2.stereoCalibrate(
        objpoints, imgpoints1, imgpoints2,
        mtx1, dist1, mtx2, dist2, 
        img_shape, criteria=criteria_stereo, flags=flags)

    # Stereo Rectification Matrisleri
    R1, R2, P1, P2, Q, roi1, roi2 = cv2.stereoRectify(CM1, dist1, CM2, dist2, img_shape, R, T, alpha=0)

    # Parametreleri kaydet (Listeye çevrilerek JSON olarak kaydedilir)
    data = {
        'mtx1': CM1.tolist(), 'dist1': dist1.tolist(),
        'mtx2': CM2.tolist(), 'dist2': dist2.tolist(),
        'R': R.tolist(), 'T': T.tolist(),
        'R1': R1.tolist(), 'R2': R2.tolist(),
        'P1': P1.tolist(), 'P2': P2.tolist(),
        'Q': Q.tolist(),
        'img_shape': img_shape
    }

    with open(CONFIG_FILE, 'w') as f:
        json.dump(data, f)

    return True, "Kalibrasyon başarıyla tamamlandı ve kaydedildi!"


def process_depth_session(session_dir):
    """
    Kaydedilmiş extrinsic/intrinsic matrisleri alıp, depth mode seansını derinlik haritalarına çevirir
    """
    if not os.path.exists(CONFIG_FILE):
        return False, "Kamera kalibrasyon verisi yok. Önce 'Kalibrasyon' modunda çekim yapın!"
        
    with open(CONFIG_FILE, 'r') as f:
        calib = json.load(f)

    CM1 = np.array(calib['mtx1']); dist1 = np.array(calib['dist1'])
    CM2 = np.array(calib['mtx2']); dist2 = np.array(calib['dist2'])
    R1 = np.array(calib['R1']); R2 = np.array(calib['R2'])
    P1 = np.array(calib['P1']); P2 = np.array(calib['P2'])
    img_shape = tuple(calib['img_shape'])

    # Undistortion ve Rectification Mapping'i hesapla
    map1x, map1y = cv2.initUndistortRectifyMap(CM1, dist1, R1, P1, img_shape, cv2.CV_32FC1)
    map2x, map2y = cv2.initUndistortRectifyMap(CM2, dist2, R2, P2, img_shape, cv2.CV_32FC1)

    # Ufak boyut için ayarlar (Hız ve SGBM stabilitesi için)
    scale_percent = 0.25 # %25 boyut
    w_new = int(img_shape[0] * scale_percent)
    h_new = int(img_shape[1] * scale_percent)

    # SGBM (Semi-Global Block Matching) Derinlik ayarları ufalmış resme göre güncellendi!
    min_disp = -32 # Ters olma durumuna tolerans (Ufalmış resimde 32px orjinalde 128'e denk gelir)
    num_disp = 16 * 8 # Toplam 128 piksellik arama (16'nın katı)
    block_size = 9 # Daha büyük blok kalibrasyon hatalarına karşı tolerans sağlar
    stereo = cv2.StereoSGBM_create(
        minDisparity=min_disp,
        numDisparities=num_disp,
        blockSize=block_size,
        P1=8 * 3 * block_size ** 2,
        P2=32 * 3 * block_size ** 2,
        disp12MaxDiff=10,
        uniquenessRatio=5,
        speckleWindowSize=50,
        speckleRange=16,
        mode=cv2.STEREO_SGBM_MODE_SGBM_3WAY
    )

    cam1_dir = os.path.join(session_dir, "cam1")
    cam2_dir = os.path.join(session_dir, "cam2")
    depth_dir = os.path.join(session_dir, "depth")
    os.makedirs(depth_dir, exist_ok=True)

    c1_images = sorted(glob.glob(os.path.join(cam1_dir, "*.jpg")))
    c2_images = sorted(glob.glob(os.path.join(cam2_dir, "*.jpg")))
    count = min(len(c1_images), len(c2_images))

    processed_files = []
    for i in range(count):
        img1 = cv2.imread(c1_images[i])
        img2 = cv2.imread(c2_images[i])
        
        if img1 is None or img2 is None: continue

        # Eğer sensör boyutları farklı gelirse Scale Normalization
        if img1.shape[:2][::-1] != img_shape: img1 = cv2.resize(img1, img_shape)
        if img2.shape[:2][::-1] != img_shape: img2 = cv2.resize(img2, img_shape)

        # 1. Önce tam boyutta orijinal distorsiyon ve kalibrasyon düzeltmesini (remap) uygula
        rect1 = cv2.remap(img1, map1x, map1y, cv2.INTER_LINEAR)
        rect2 = cv2.remap(img2, map2x, map2y, cv2.INTER_LINEAR)

        # 2. SGBM hesabını hızlandırmak ve boşlukları kapamak için ufaltıp griye çevir
        gray1 = cv2.cvtColor(cv2.resize(rect1, (w_new, h_new)), cv2.COLOR_BGR2GRAY)
        gray2 = cv2.cvtColor(cv2.resize(rect2, (w_new, h_new)), cv2.COLOR_BGR2GRAY)

        # 3. Derinliği hesapla
        disparity = stereo.compute(gray1, gray2).astype(np.float32) / 16.0

        # Diskalifikasyon alanını (boş siyahı) yumuşatmak ve eşleşmeleri teşvik etmek için filtrelenmiş normalizasyon
        mask = disparity > stereo.getMinDisparity()
        norm_disp = np.zeros_like(disparity, dtype=np.uint8)

        if np.any(mask):
            # Geçerli bölgeler için min-max normalizasyonu
            min_val = disparity[mask].min()
            max_val = disparity[mask].max()
            
            # 0'a bölme hatasından kaçın 
            if max_val > min_val:
                # Normalizasyon formülü: (x - min) / (max - min) * 255
                norm_disp[mask] = ((disparity[mask] - min_val) / (max_val - min_val) * 255).astype(np.uint8)
            else:
                norm_disp[mask] = 128
                
        colored_disp = cv2.applyColorMap(norm_disp, cv2.COLORMAP_JET)

        # Eşleşmeyen yerler siyah yapılıyor
        colored_disp[~mask] = 0

        # Gösterim ve UI için orijinal boyuta geri ölçekle
        colored_disp = cv2.resize(colored_disp, img_shape, interpolation=cv2.INTER_NEAREST)

        out_name = f"depth_{i}.jpg"
        out_path = os.path.join(depth_dir, out_name)
        cv2.imwrite(out_path, colored_disp)
        
        # log için
        processed_files.append({"index": i, "depth_image": f"depth/{out_name}"})

    return True, processed_files

