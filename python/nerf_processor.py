import os
import csv
import json
import math
import subprocess

def quaternion_to_rotation_matrix(qx, qy, qz, qw):

    r = [[1.0 - 2.0*(qy**2 + qz**2), 2.0*(qx*qy - qz*qw), 2.0*(qx*qz + qy*qw)],
         [2.0*(qx*qy + qz*qw), 1.0 - 2.0*(qx**2 + qz**2), 2.0*(qy*qz - qx*qw)],
         [2.0*(qx*qz - qy*qw), 2.0*(qy*qz + qx*qw), 1.0 - 2.0*(qx**2 + qy**2)]]
    return r

def process_orbit_session(session_dir):
    csv_path = os.path.join(session_dir, "capture_log.csv")
    if not os.path.exists(csv_path):
        return False, "capture_log.csv bulunamadı."
        
    transforms = {
        "camera_angle_x": 1.2, 
        "frames": []
    }
    
    with open(csv_path, mode='r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            tx = float(row.get("pose_tx") or 0.0)
            ty = float(row.get("pose_ty") or 0.0)
            tz = float(row.get("pose_tz") or 0.0)
            qx = float(row.get("pose_qx") or 0.0)
            qy = float(row.get("pose_qy") or 0.0)
            qz = float(row.get("pose_qz") or 0.0)
            qw = float(row.get("pose_qw") or 1.0)
            
            cam1_img = row.get("cam1_image", "")
            if not cam1_img:
                continue

            # Rotasyon matrisini oluştur (3x3)
            R = quaternion_to_rotation_matrix(qx, qy, qz, qw)
            
            # NeRF standart 4x4 transform matrisi
            transform_matrix = [
                [R[0][0], R[0][1], R[0][2], tx],
                [R[1][0], R[1][1], R[1][2], ty],
                [R[2][0], R[2][1], R[2][2], tz],
                [0.0, 0.0, 0.0, 1.0]
            ]
            
            frame_data = {
                "file_path": cam1_img, 
                "transform_matrix": transform_matrix
            }
            transforms["frames"].append(frame_data)
            
    # transforms.json'u kaydet
    out_json = os.path.join(session_dir, "transforms.json")
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(transforms, f, indent=4)
        
    print(f"  [+] transforms.json oluşturuldu: {out_json}")
    

    try:
        print("  [+] Splatfacto eğitimi başlatılıyor...")
        process = subprocess.Popen(["ns-train", "splatfacto", "--data", session_dir],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        # Sadece komutu tetikliyoruz, arayüz nerfstudio tarafından default : 7007 portunda açılır.
        print("  [+] Splatfacto arka planda çalışıyor. Lütfen http://localhost:7007 adresini kontrol edin.")
        return True, "Splatfacto başladı"
    except Exception as e:
        print(f"  [-] Nerfstudio tetiklenirken hata veya sistemde kurulu değil: {e}")
        return True, "Transforms hazır ancak ns-train tetiklenemedi"

if __name__ == "__main__":
    # Test
    import sys
    if len(sys.argv) > 1:
        process_orbit_session(sys.argv[1])
