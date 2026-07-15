from flask import Flask, request, jsonify
import json

app = Flask(__name__)

@app.route('/lyrics', methods=['POST', 'GET'])
def proxy_lyrics():
    print("====== 收到來自 YTMusicUltimate 的歌詞請求 ======")
    
    # 印出 YTMusic 傳送過來的 Headers
    # print("Headers:", request.headers)
    
    # 嘗試解析 YTMusic 傳送過來的 JSON Body
    try:
        body = request.get_json(force=True)
        # print("Body:", json.dumps(body, indent=2))
        
        # 通常 browseId 會放在 browseRequest 裡面，我們之後可以從這裡抓出歌曲資訊
        # 例如 browseId = body.get('browseId')
        
    except Exception as e:
        print("無法解析 Body:", e)

    print("===============================================")
    
    # 為了測試手機端是否有成功收到攔截後的資料，我們隨便回傳一個假的回應 (JSON 格式)。
    # 這裡的回傳格式目前不是 YTMusic 的標準格式，因為我們需要先抓到原本 YTMusic 真正的回傳格式才能模仿它。
    # 下一步我們會教你怎麼抓包看 Youtube 真正的回傳格式。
    return jsonify({
        "status": "success",
        "message": "這是一份從你的 Python 代理伺服器回傳的假歌詞！",
        "proxy_active": True
    })

if __name__ == '__main__':
    # 啟動伺服器在 Port 3000
    print("伺服器已啟動: http://127.0.0.1:3000/lyrics")
    app.run(host='0.0.0.0', port=3000, debug=True)
