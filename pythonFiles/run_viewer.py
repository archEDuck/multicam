import os
import sys
import json
import subprocess
import tarfile
import zipfile
import csv
import webbrowser
import glob

def run_adb_command(cmd_string):
    """Run an adb command using shell routing."""
    return subprocess.run(cmd_string, shell=True, capture_output=True, text=True)

def main():
    print("======================================================")
    print("====== MULTICAM Veri Çekici ve Görüntüleyici =========")
    print("======================================================")

    # Base Klasör (pythonFiles) içerisinde sessions isimli klasör acalim
    base_dir = os.path.dirname(os.path.abspath(__file__))
    sessions_dir = os.path.join(base_dir, "sessions")
    os.makedirs(sessions_dir, exist_ok=True)

    print("\n[*} ADB Bağlantısı Kontrol Ediliyor...")
    devices_status = run_adb_command("adb devices")
    if "device\n" not in devices_status.stdout and "\tdevice" not in devices_status.stdout:
        print("  [-] DİKKAT: Cihaz ADB (Hata Ayıklama) üzerinden görülemiyor!")
        print("      Lütfen telefonu bağladığınızdan ve 'USB Hata Ayıklama' izni verdiğinizden emin olun.")
    else:
        print("  [+] ADB Cihazı bağlandı ve hazır.")

    print("\n[*] 1. Yöntem: Eskiden (Uygulama İçi - Internal) Kalan Kayıtlar Çekiliyor...")
    tar_path = os.path.join(base_dir, "sessions.tar")
    tar_cmd = 'adb exec-out "run-as com.example.multicam tar cf - -C app_flutter sessions"'
    
    try:
        with open(tar_path, "wb") as f:
            proc = subprocess.run(tar_cmd, shell=True, stdout=f, stderr=subprocess.PIPE)
        if proc.returncode == 0 and os.path.getsize(tar_path) > 100:
            print("  [+] Gizli uyguluma içi veriler bulundu, çıkartılıyor...")
            with tarfile.open(tar_path, "r") as tar:
                tar.extractall(path=sessions_dir)
        else:
            print("  [-] Gizli dizinde eski oturum bulunamadı veya çekilemedi.")
    except Exception as e:
        print(f"  [-] Hata: {str(e)}")

    print("\n[*] 2. Yöntem: Harici Depolama (External Storage) Yeni Kayıtlar Çekiliyor...")
    ext_path = "/sdcard/Android/data/com.example.multicam/files/sessions/"
    ext_cmd = f'adb pull {ext_path} "{base_dir}"'
    pull_proc = run_adb_command(ext_cmd)
    
    if "0 files pulled" in pull_proc.stdout or "does not exist" in pull_proc.stderr:
        print("  [-] Yeni external klasörde (henüz) kayıt yok.")
    elif "pulled" in pull_proc.stdout:
        print("  [+] External klasördeki veriler bilgisayara çekildi!")

    if os.path.exists(tar_path):
        os.remove(tar_path)
    
    print("\n[*] Gelen ZIP dosyaları okunuyor (eğer varsa dışarı çıkarılıyor)...")
    zips = glob.glob(os.path.join(sessions_dir, "*.zip")) + glob.glob(os.path.join(sessions_dir, "*", "*.zip"))
    
    for z in zips:
        extract_dir = z.replace(".zip", "")
        if not os.path.exists(extract_dir):
            print(f"  -> ZIP Çıkarılıyor: {os.path.basename(z)}")
            with zipfile.ZipFile(z, 'r') as zip_ref:
                zip_ref.extractall(extract_dir)

    print("\n[*] Görüntülenecek 'capture_log.csv' dosyası aranıyor...")
    csv_files = glob.glob(os.path.join(sessions_dir, "**", "capture_log.csv"), recursive=True)
    
    if not csv_files:
        print("\n[!] UYARI: Cihazdan alınmış herhangi bir geçerli oturum (capture_log.csv) bulunamadı.")
        print("    Uygulamadan henüz kayıt almamış olabilirsiniz. Kayıt alıp bilgisayara bağladığınıza emin olun.")
        input("    Çıkmak için ENTER tuşuna basın...")
        return

    # Sort descending by modification time
    latest_csv = max(csv_files, key=os.path.getmtime)
    session_folder = os.path.dirname(latest_csv)
    session_name = os.path.basename(session_folder)
    
    print(f"\n[+] Görüntüleme için en güncel oturum seçildi: {session_name}")

    # Read CSV data
    records = []
    with open(latest_csv, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            records.append(row)
            
    if not records:
        print("[-] Hata: Log dosyası boş!")
        input("Çıkmak için ENTER tuşuna basın...")
        return

    # Generate HTML content
    json_data_str = json.dumps(records)
    
    html_content = f"""<!DOCTYPE html>
<html lang="tr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Multicam Session: {session_name}</title>
    <style>
        body {{ font-family: 'Segoe UI', Tahoma, Verdana, sans-serif; background-color: #1e1e2e; color: #cdd6f4; text-align: center; padding: 20px; }}
        h2 {{ color: #a6e3a1; border-bottom: 2px solid #a6e3a1; display: inline-block; padding-bottom: 5px; }}
        .container {{ display: flex; justify-content: center; gap: 20px; margin-top: 20px; flex-wrap: wrap; }}
        .cam-box {{ border: 2px solid #313244; border-radius: 12px; overflow: hidden; background: #11111b; padding-bottom: 10px; width: 45vw; max-width: 600px; box-shadow: 0 4px 6px rgba(0,0,0,0.4); }}
        img {{ width: 100%; height: auto; object-fit: cover; display: block; }}
        .empty-placeholder {{ width: 100%; aspect-ratio: 4/3; display: flex; align-items: center; justify-content: center; background: #313244; color: #bac2de; font-size: 1.2rem; }}
        .controls {{ margin: 30px auto; background: #181825; padding: 25px; border-radius: 12px; max-width: 900px; box-shadow: 0 8px 12px rgba(0,0,0,0.5); }}
        input[type=range] {{ width: 100%; margin: 20px 0; cursor: pointer; accent-color: #89b4fa; height: 8px; }}
        .stats-grid {{ display: grid; grid-template-columns: repeat(3, 1fr); gap: 15px; margin-top: 20px; text-align: left; }}
        .stat-card {{ background: #313244; padding: 15px; border-radius: 8px; box-shadow: inset 0 2px 4px rgba(0,0,0,0.2); }}
        .stat-title {{ font-size: 0.85em; color: #a6adc8; margin-bottom: 8px; text-transform: uppercase; letter-spacing: 1px; border-bottom: 1px solid #45475a; padding-bottom: 4px; }}
        .stat-value {{ font-size: 1.1em; font-family: monospace; font-weight: bold; color: #89b4fa; line-height: 1.4; }}
    </style>
</head>
<body>
    <h2>Oturum İnceleme ({session_name})</h2>
    
    <div class="container">
        <div class="cam-box">
            <h3 style="margin: 10px 0; color: #cdd6f4;">Arka Kamera 1</h3>
            <img id="cam1" src="" onerror="this.style.display='none'; document.getElementById('ph1').style.display='flex';" onload="this.style.display='block'; document.getElementById('ph1').style.display='none';">
            <div id="ph1" class="empty-placeholder">Görüntü Yok</div>
        </div>
        <div class="cam-box">
            <h3 style="margin: 10px 0; color: #cdd6f4;">Arka Kamera 2</h3>
            <img id="cam2" src="" onerror="this.style.display='none'; document.getElementById('ph2').style.display='flex';" onload="this.style.display='block'; document.getElementById('ph2').style.display='none';">
            <div id="ph2" class="empty-placeholder">Görüntü Yok</div>
        </div>
    </div>

    <div class="controls">
        <div style="display: flex; justify-content: space-between; align-items: center; color: #bac2de;">
            <div style="font-size: 1.2rem;">
                <strong>Kare: <span id="frame_counter" style="color: #f38ba8; font-family: monospace; font-size: 1.4rem;">0 / 0</span></strong>
            </div>
            <span id="timestamp_lbl" style="font-family: monospace; font-size: 1.1rem; color: #94e2d5;"></span>
        </div>
        <input type="range" id="slider" min="0" max="0" value="0" oninput="updateView()">
        
        <div class="stats-grid">
            <div class="stat-card">
                <div class="stat-title">Sensör (Proximity/FoT)</div>
                <div class="stat-value" id="fot_lbl">-</div>
            </div>
            <div class="stat-card">
                <div class="stat-title">İvmeölçer (Acc) <small style="color: #a6adc8; font-weight: normal; font-size: 0.8em; float: right;">m/s²</small></div>
                <div class="stat-value" id="acc_lbl" style="color:#f9e2af;">-</div>
            </div>
            <div class="stat-card">
                <div class="stat-title">Jiroskop (Gyro) <small style="color: #a6adc8; font-weight: normal; font-size: 0.8em; float: right;">rad/s</small></div>
                <div class="stat-value" id="gyro_lbl" style="color:#fab387;">-</div>
            </div>
        </div>
    </div>

    <script>
        const data = {json_data_str};
        
        const slider = document.getElementById("slider");
        const img1 = document.getElementById("cam1");
        const img2 = document.getElementById("cam2");
        const frameCounter = document.getElementById("frame_counter");
        const fotLbl = document.getElementById("fot_lbl");
        const accLbl = document.getElementById("acc_lbl");
        const gyroLbl = document.getElementById("gyro_lbl");
        const tsLbl = document.getElementById("timestamp_lbl");

        if (data.length > 0) {{
            slider.max = data.length - 1;
            updateView();
        }}

        function fmt(val) {{
            if (!val || val.trim() === "") return "0.00";
            return parseFloat(val).toFixed(2).padStart(6, '\xa0');
        }}

        function updateView() {{
            const idx = parseInt(slider.value, 10);
            const frame = data[idx];
            
            // Note: frame.cam1_image is like "cam1/frame_0_2024.jpg" 
            img1.src = frame.cam1_image || "";
            img2.src = frame.cam2_image || "";
            
            frameCounter.innerText = `${{idx + 1}} / ${{data.length}}`;
            
            if (frame.timestamp_utc) {{
                try {{
                    const d = new Date(frame.timestamp_utc);
                    const t = d.toLocaleTimeString([], {{ hour12: false }});
                    tsLbl.innerText = t + "." + String(d.getMilliseconds()).padStart(3, '0') + " UTC";
                }} catch(e) {{
                    tsLbl.innerText = frame.timestamp_utc;
                }}
            }}
            
            if (frame.fot_cm && frame.fot_cm.trim() !== "" && frame.fot_cm !== "-1.000") {{
                fotLbl.innerHTML = `<span style="font-size: 1.5em; color: #a6e3a1;">${{frame.fot_cm}}</span> cm`;
            }} else {{
                fotLbl.innerHTML = `<span style="color: #f38ba8;">Kapalı / Çok Uzak</span>`;
            }}
            
            accLbl.innerHTML = frame.acc_x ? `X: ${{fmt(frame.acc_x)}}<br>Y: ${{fmt(frame.acc_y)}}<br>Z: ${{fmt(frame.acc_z)}}` : "Veri Yok";
            gyroLbl.innerHTML = frame.gyro_x ? `X: ${{fmt(frame.gyro_x)}}<br>Y: ${{fmt(frame.gyro_y)}}<br>Z: ${{fmt(frame.gyro_z)}}` : "Veri Yok";
        }}
    </script>
</body>
</html>"""

    html_path = os.path.join(session_folder, "viewer.html")
    with open(html_path, "w", encoding="utf-8") as f:
        f.write(html_content)

    print("\n[+] Arayüz başarıyla oluşturuldu!")
    print(f"    -> {html_path}")
    print("[*] Görüntüleyici tarayıcıda otomatik açılıyor...")
    
    # Open the UI
    webbrowser.open(f"file://{html_path}")

if __name__ == "__main__":
    main()
