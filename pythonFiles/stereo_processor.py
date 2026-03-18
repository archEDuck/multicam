import cv2
import numpy as np
import os
import glob
import json
import csv

CONFIG_FILE = os.path.join(os.path.dirname(__file__), "stereo_config.json")

# Satranç tahtası özellikleri (iç köşelerin sayısı, kenar uzunluğu değişebilir, genelde 9x6 olur)
CHESSBOARD_SIZE = (7, 7)
SQUARE_SIZE = 2.0 # Örnek cm veya mm değeri


def _read_session_camera_info(session_dir):
    csv_path = os.path.join(session_dir, "capture_log.csv")
    if not os.path.exists(csv_path):
        return {}

    try:
        with open(csv_path, "r", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            first = next(reader, None)
            if not first:
                return {}
            return {
                "cam1_id": (first.get("cam1_id") or "").strip(),
                "cam2_id": (first.get("cam2_id") or "").strip(),
                "capture_mode": (first.get("capture_mode") or "").strip(),
            }
    except Exception:
        return {}


def _image_score(img):
    if img is None or img.size == 0:
        return -1.0
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    mean_v = float(np.mean(gray))
    std_v = float(np.std(gray))
    non_black_ratio = float(np.mean(gray > 10))
    # Siyah/tekdüze görüntülerde skor düşer.
    return (mean_v * 0.4) + (std_v * 0.4) + (non_black_ratio * 100.0 * 0.2)


def _choose_rectification_mapping(img1, img2, map1x, map1y, map2x, map2y, prefer_swapped=False):
    rect1_normal = cv2.remap(img1, map1x, map1y, cv2.INTER_LINEAR)
    rect2_normal = cv2.remap(img2, map2x, map2y, cv2.INTER_LINEAR)
    score_normal = _image_score(rect1_normal) + _image_score(rect2_normal)

    rect1_swapped = cv2.remap(img1, map2x, map2y, cv2.INTER_LINEAR)
    rect2_swapped = cv2.remap(img2, map1x, map1y, cv2.INTER_LINEAR)
    score_swapped = _image_score(rect1_swapped) + _image_score(rect2_swapped)

    if prefer_swapped:
        return True, score_normal, score_swapped

    if score_swapped > (score_normal * 1.10):
        return True, score_normal, score_swapped

    return False, score_normal, score_swapped

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
    session_info = _read_session_camera_info(session_dir)

    data = {
        'mtx1': CM1.tolist(), 'dist1': dist1.tolist(),
        'mtx2': CM2.tolist(), 'dist2': dist2.tolist(),
        'R': R.tolist(), 'T': T.tolist(),
        'R1': R1.tolist(), 'R2': R2.tolist(),
        'P1': P1.tolist(), 'P2': P2.tolist(),
        'Q': Q.tolist(),
        'img_shape': img_shape,
        'cam1_id': session_info.get("cam1_id", ""),
        'cam2_id': session_info.get("cam2_id", ""),
        'capture_mode': session_info.get("capture_mode", "")
    }

    with open(CONFIG_FILE, 'w') as f:
        json.dump(data, f)

    return True, "Kalibrasyon başarıyla tamamlandı ve kaydedildi!"


def process_rectification_session(session_dir):
    """
    Kaydedilmiş extrinsic/intrinsic matrisleri alıp, çekim seansını sadece rectify eder (düzeltip hizalar).
    Derinlik haritası hesaplamaz.
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

    calib_cam1_id = (calib.get("cam1_id") or "").strip()
    calib_cam2_id = (calib.get("cam2_id") or "").strip()

    session_info = _read_session_camera_info(session_dir)
    sess_cam1_id = session_info.get("cam1_id", "")
    sess_cam2_id = session_info.get("cam2_id", "")

    # Undistortion ve Rectification Mapping'i hesapla
    map1x, map1y = cv2.initUndistortRectifyMap(CM1, dist1, R1, P1, img_shape, cv2.CV_32FC1)
    map2x, map2y = cv2.initUndistortRectifyMap(CM2, dist2, R2, P2, img_shape, cv2.CV_32FC1)

    cam1_dir = os.path.join(session_dir, "cam1")
    cam2_dir = os.path.join(session_dir, "cam2")
    rectified_dir = os.path.join(session_dir, "rectified")
    os.makedirs(rectified_dir, exist_ok=True)
    os.makedirs(os.path.join(rectified_dir, "cam1"), exist_ok=True)
    os.makedirs(os.path.join(rectified_dir, "cam2"), exist_ok=True)

    c1_images = sorted(glob.glob(os.path.join(cam1_dir, "*.jpg")))
    c2_images = sorted(glob.glob(os.path.join(cam2_dir, "*.jpg")))
    count = min(len(c1_images), len(c2_images))

    if count == 0:
        return False, "Rectify için işlenecek görüntü bulunamadı (cam1/cam2 boş)."

    force_swapped = False
    if calib_cam1_id and calib_cam2_id and sess_cam1_id and sess_cam2_id:
        if calib_cam1_id == sess_cam1_id and calib_cam2_id == sess_cam2_id:
            force_swapped = False
            print(f"  [+] Kamera ID eşleşmesi OK: {sess_cam1_id} + {sess_cam2_id}")
        elif calib_cam1_id == sess_cam2_id and calib_cam2_id == sess_cam1_id:
            force_swapped = True
            print("  [!] Kamera ID sırası ters tespit edildi. Rectify için mapler otomatik swap edilecek.")
        else:
            return False, (
                "Kalibrasyon kamera ID'leri ile bu oturumun kamera ID'leri farklı. "
                f"Calib=({calib_cam1_id},{calib_cam2_id}), Session=({sess_cam1_id},{sess_cam2_id}). "
                "Lütfen aynı kamera çiftiyle yeniden kalibrasyon yapın."
            )

    # İlk geçerli kare ile en sağlıklı map yönünü seç.
    use_swapped_maps = force_swapped
    if not force_swapped:
        for i in range(count):
            probe1 = cv2.imread(c1_images[i])
            probe2 = cv2.imread(c2_images[i])
            if probe1 is None or probe2 is None:
                continue
            if probe1.shape[:2][::-1] != img_shape:
                probe1 = cv2.resize(probe1, img_shape)
            if probe2.shape[:2][::-1] != img_shape:
                probe2 = cv2.resize(probe2, img_shape)

            use_swapped_maps, score_normal, score_swapped = _choose_rectification_mapping(
                probe1,
                probe2,
                map1x,
                map1y,
                map2x,
                map2y,
                prefer_swapped=False,
            )
            mode_text = "SWAPPED" if use_swapped_maps else "NORMAL"
            print(f"  [+] Rectify map modu secildi: {mode_text} (normal={score_normal:.2f}, swapped={score_swapped:.2f})")
            break

    processed_files = []
    for i in range(count):
        img1 = cv2.imread(c1_images[i])
        img2 = cv2.imread(c2_images[i])
        
        if img1 is None or img2 is None: continue

        # Eğer sensör boyutları farklı gelirse Scale Normalization
        if img1.shape[:2][::-1] != img_shape: img1 = cv2.resize(img1, img_shape)
        if img2.shape[:2][::-1] != img_shape: img2 = cv2.resize(img2, img_shape)

        # 1. Tam boyutta orijinal distorsiyon ve kalibrasyon düzeltmesini (remap) uygula
        if use_swapped_maps:
            rect1 = cv2.remap(img1, map2x, map2y, cv2.INTER_LINEAR)
            rect2 = cv2.remap(img2, map1x, map1y, cv2.INTER_LINEAR)
        else:
            rect1 = cv2.remap(img1, map1x, map1y, cv2.INTER_LINEAR)
            rect2 = cv2.remap(img2, map2x, map2y, cv2.INTER_LINEAR)

        name1 = os.path.basename(c1_images[i])
        name2 = os.path.basename(c2_images[i])

        out1_path = os.path.join(rectified_dir, "cam1", f"rect_{name1}")
        out2_path = os.path.join(rectified_dir, "cam2", f"rect_{name2}")
        
        cv2.imwrite(out1_path, rect1)
        cv2.imwrite(out2_path, rect2)
        
        # log için
        processed_files.append({
            "index": i, 
            "rectified_cam1": f"rectified/cam1/rect_{name1}",
            "rectified_cam2": f"rectified/cam2/rect_{name2}"
        })

    return True, processed_files

