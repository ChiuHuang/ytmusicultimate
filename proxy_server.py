from flask import Flask, request, jsonify

app = Flask(__name__)

@app.route('/api/lyrics', methods=['GET'])
def get_lyrics():
    video_id = request.args.get('v')
    
    print("========================================")
    print(f"🌟 收到手機端歌詞請求！Video ID: {video_id}")
    print("========================================")
    
    if not video_id:
        return jsonify({"error": "Missing video ID"}), 400
        
    # TODO: 下一步我們會在這裡實作：
    # 1. 用 yt-dlp 或是 YouTube 網頁爬蟲，透過 video_id 抓出「歌名」與「歌手」。
    # 2. 將歌名傳給 Netease 或是 LRCLIB API 搜尋。
    # 3. 解析回傳的雙語歌詞。
    
    # 目前我們先回傳一段假的測試歌詞，確認手機端能成功收到並蓋掉原本的畫面！
    mock_lyrics = f"""[測試成功！成功攔截 Video ID: {video_id}]
    
如果這段文字出現在你的手機上，
代表我們的 UI 覆寫技術完全成功了！🎉

Next step:
我們將會在伺服器端把這個 ID 轉換成真實的雙語歌詞！
"""

    # 回傳給手機的 JSON 格式
    return jsonify({
        "translated_lyrics": mock_lyrics
    })

if __name__ == '__main__':
    print("API 伺服器已啟動: http://0.0.0.0:20016/api/lyrics")
    app.run(host='0.0.0.0', port=20016, debug=True)
