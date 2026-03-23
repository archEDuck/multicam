import os
import json
import csv
import zipfile
import webbrowser
import socket
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

try:
    import stereo_processor
except ImportError:
    stereo_processor = None
    pass

try:
    import nerf_processor
except ImportError:
    nerf_processor = None
    pass

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
SESSIONS_DIR = os.path.join(BASE_DIR, "sessions")
os.makedirs(SESSIONS_DIR, exist_ok=True)

class UploadHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        parsed_path = urlparse(self.path)
        if parsed_path.path == '/upload':
            query = parse_qs(parsed_path.query)
            filename = query.get('file', ['session.zip'])[0]
            filepath = os.path.join(SESSIONS_DIR, filename)
            content_length = int(self.headers.get('Content-Length', 0))
            
            print(f"\n[*] '{filename}' dosyası alınıyor... Content-Length: {content_length} bytes")
            if content_length == 0:
                self.send_error(400, "Bad Request: No content (Length 0)")
                print("  [-] Hata: Gelen icerik boyutu 0. Gonderim bossa, Flutter tarafinda olusturulan Zip bos olabilir.")
                return
            with open(filepath, 'wb') as f:
                chunk_size = 65536
                bytes_read = 0
                while bytes_read < content_length:
                    chunk = self.rfile.read(min(chunk_size, content_length - bytes_read))
                    if not chunk:
                        break
                    f.write(chunk)
                    bytes_read += len(chunk)
            
            self.send_response(200)
            self.send_header('Content-type', 'text/plain')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(b'OK')
            
            print(f"[+] Dosya telefondan basariyla alindi: {filename}")
            self.process_and_show(filepath)
        else:
            self.send_response(404)
            self.end_headers()

    def process_and_show(self, zip_path):
        print("  -> ZIP cikariliyor...")
        extract_dir = zip_path.replace('.zip', '')
        os.makedirs(extract_dir, exist_ok=True)
        try:
            with zipfile.ZipFile(zip_path, 'r') as zip_ref:
                zip_ref.extractall(extract_dir)
        except Exception as e:
            print(f"  [-] ZIP Cikartma Hatasi: {e}")
            return
        
        # Oijinal zip'i silebilirsiniz, saklamak isterseniz kalsin.
        
        csv_path = os.path.join(extract_dir, "capture_log.csv")
        if not os.path.exists(csv_path):
            print("  [-] capture_log.csv bulunamadi, UI acilmayacak.")
            return
        
        records = []
        with open(csv_path, "r", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            for row in reader:
                records.append(row)
        
        session_name = os.path.basename(extract_dir)

        # ====== HETEROGENEOUS STEREO YÖNETİMİ ======
        if session_name.startswith("calib_"):
            if stereo_processor is not None:
                success, msg = stereo_processor.calibrate_and_save(extract_dir)
                if success:
                    print(f"  [+] {msg}")
                else:
                    print(f"  [-] Kalibrasyon Hatası: {msg}")
            else:
                print("  [-] OpenCV / NumPy yüklü değil, Kalibrasyon atlandı.")

        if session_name.startswith("rectify_"):
            if stereo_processor is not None:
                success, results = stereo_processor.process_rectification_session(extract_dir)
                if success:
                    print(f"  [+] Görüntüler başarıyla hizalandı (Rectified).")
                    # Burada results içerisindeki yolları records dizisine ekleyebiliriz
                    for r, rec in zip(results, records):
                        rec["rectified_cam1"] = r.get("rectified_cam1", "")
                        rec["rectified_cam2"] = r.get("rectified_cam2", "")
                else:
                    print(f"  [-] Hizalama Hatası: {results}")
            else:
                print("  [-] OpenCV yüklü değil, Hizalama (Rectification) işlemi yapılamıyor.")

        if session_name.startswith("orbit_"):
            if nerf_processor is not None:
                success, msg = nerf_processor.process_orbit_session(extract_dir)
                if success:
                    print(f"  [+] 3D Orbit (NeRF/Splat) veri hazırlığı başarıyla tamamlandı: {msg}")
                else:
                    print(f"  [-] Orbit İşlem Hatası: {msg}")
            else:
                print("  [-] nerf_processor yüklenemedi.")

        # ============================================

        json_data_str = json.dumps(records)
        
        html_content = f"""<!DOCTYPE html>
<html lang="tr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Multicam Oynatıcı: {session_name}</title>
    <style>
        body {{ font-family: 'Segoe UI', Tahoma, Verdana, sans-serif; background-color: #1e1e2e; color: #cdd6f4; text-align: center; padding: 20px; }}
        h2 {{ color: #a6e3a1; border-bottom: 2px solid #a6e3a1; display: inline-block; padding-bottom: 5px; }}
        .container {{ display: flex; justify-content: center; gap: 20px; margin-top: 20px; flex-wrap: wrap; }}
        .cam-box {{ border: 2px solid #313244; border-radius: 12px; overflow: hidden; background: #11111b; padding-bottom: 10px; width: 45vw; max-width: 600px; box-shadow: 0 4px 6px rgba(0,0,0,0.4); }}
        img {{ width: 100%; height: auto; object-fit: cover; display: block; min-height: 200px; }}
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
        <div class="cam-box" style="width: 30vw;">
            <h3 style="margin: 10px 0; color: #cdd6f4;">Arka Kamera 1</h3>
            <img id="cam1" src="" onerror="this.style.display='none'; document.getElementById('ph1').style.display='flex';" onload="this.style.display='block'; document.getElementById('ph1').style.display='none';">
            <div id="ph1" class="empty-placeholder">Görüntü Yok</div>
        </div>
        <div class="cam-box" style="width: 30vw;">
            <h3 style="margin: 10px 0; color: #cdd6f4;">Arka Kamera 2</h3>
            <img id="cam2" src="" onerror="this.style.display='none'; document.getElementById('ph2').style.display='flex';" onload="this.style.display='block'; document.getElementById('ph2').style.display='none';">
            <div id="ph2" class="empty-placeholder">Görüntü Yok</div>
        </div>
        <div class="cam-box" style="width: 30vw;" id="depthBox">
            <h3 style="margin: 10px 0; color: #cdd6f4;">Derinlik Haritası</h3>
            <img id="depthImg" src="" onerror="this.style.display='none'; document.getElementById('ph3').style.display='flex';" onload="this.style.display='block'; document.getElementById('ph3').style.display='none';">
            <div id="ph3" class="empty-placeholder">Görüntü Yok</div>
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
        const imgDepth = document.getElementById("depthImg");
        const depthBox = document.getElementById("depthBox");
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
            
            img1.src = frame.rectified_cam1 || frame.cam1_image || "";
            img2.src = frame.rectified_cam2 || frame.cam2_image || "";
            if (frame.depth_image) {{
                depthBox.style.display = 'block';
                imgDepth.src = frame.depth_image;
            }} else {{
                depthBox.style.display = 'none';
            }}

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

        html_path = os.path.join(extract_dir, "viewer.html")
        with open(html_path, "w", encoding="utf-8") as f:
            f.write(html_content)
        
        print(f"  [+] Arayuz olusturuldu! Tarayicida aciliyor...")
        webbrowser.open(f"file://{html_path}")

def run(server_class=HTTPServer, handler_class=UploadHandler, port=5000):
    local_ip = "188.191.107.81"
    # Sunucu IP'sini bildiğimizde sabit
    # try:
    #     s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    #     s.connect(("8.8.8.8", 80))
    #     local_ip = s.getsockname()[0]
    #     s.close()
    # except:
    #     pass

    server_address = ('0.0.0.0', port)
    httpd = server_class(server_address, handler_class)
    
    print("==================================================")
    print("====== MULTICAM WİFİ DOSYA ALICI SUNUCUSU =======")
    print("==================================================")
    print(f"[*] Sunucu baslatildi.")
    print(f"[*] Telefondaki uygulamaya yazilacak IP: {local_ip}")
    print(f"[*] Port numarasi: {port}")
    print("==================================================")
    print("[*] Bekleniyor... Yeni kayit telefondan gönderilince burada belirecek ve acilacak.")
    
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    
    httpd.server_close()
    print("\n[-] Sunucu kapatildi.")

if __name__ == '__main__':
    run()
