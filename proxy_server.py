from flask import Flask, request, jsonify
import json
import urllib.parse
from datetime import datetime
import os

app = Flask(__name__)

# 建立 log 目錄
if not os.path.exists('logs'):
    os.makedirs('logs')

@app.route('/log', methods=['POST'])
def proxy_log():
    try:
        data = request.get_json(force=True)
        
        url = data.get('url', 'Unknown URL')
        request_body = data.get('request_body', '')
        response_body = data.get('response_body', '')
        req_type = data.get('type', '')
        
        # 為了避免洗頻，我們只關注跟歌詞或歌曲資訊有關的 API (例如 next 或是 browse)
        if "next" in url or "browse" in url:
            
            timestamp = datetime.now().strftime("%H-%M-%S")
            print(f"\n[{timestamp}] 🎯 攔截到關鍵 API: {url}")
            
            # 將 Request 儲存成檔案方便分析
            with open(f"logs/{timestamp}_req.json", "w", encoding="utf-8") as f:
                f.write(f"URL: {url}\n\n[REQUEST BODY]\n{request_body}\n\n[RESPONSE BODY]\n{response_body}")
                
            # 如果是 JSON 格式，我們試著在終端機漂亮地印出來
            try:
                if request_body.startswith('{'):
                    req_json = json.loads(request_body)
                    # 如果有 browseId，這很可能是歌詞請求！
                    if "browseId" in req_json:
                        print(f"🔥 發現 browseId: {req_json['browseId']}")
            except:
                pass
                
    except Exception as e:
        print("Log 接收失敗:", e)

    return jsonify({"status": "ok"})

if __name__ == '__main__':
    print("日誌伺服器已啟動: http://0.0.0.0:8000/log")
    print("請在手機上操作 YouTube Music，所有 API 請求將會顯示在這裡並存入 logs 資料夾。")
    app.run(host='0.0.0.0', port=20016, debug=True)
