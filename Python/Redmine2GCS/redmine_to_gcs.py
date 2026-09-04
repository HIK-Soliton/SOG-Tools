import os
import json
import argparse
import requests
from google.cloud import storage

def fetch_redmine_tickets(redmine_url, api_key, project_id):
    """Redmine REST APIからチケット一覧を取得する"""
    print("Redmineからデータを取得中...")
    url = f"{redmine_url}/issues.json"
    headers = {"X-Redmine-API-Key": api_key}
    
    # 1回のリクエストで最大100件取得（必要に応じてループでページネーションを処理してください）
    params = {
        "project_id": project_id,
        "status_id": "*",  # 終了したチケットも含める場合
        "limit": 100
    }
    
    response = requests.get(url, headers=headers, params=params)
    response.raise_for_status()
    return response.json().get("issues", [])

def convert_to_vertex_format(issues, redmine_url):
    """Vertex AI用のフォーマット(JSONL)に変換する"""
    print("Vertex AI向けのフォーマット(JSONL)に変換中...")
    jsonl_lines = []
    
    for issue in issues:
        # チケットのタイトル、説明、カテゴリなどを結合して1つのテキスト（コンテキスト）にする
        title = issue.get("subject", "")
        description = issue.get("description", "")
        category = issue.get("category", {}).get("name", "未分類")
        
        # 例：RAG（検索AI）のドキュメントとして食わせる場合の構造化テキスト例
        combined_text = f"【タイトル】: {title}\n【カテゴリ】: {category}\n【詳細内容】:\n{description}"
        
        # Vertex AI Search等にインポートしやすい単純なJSON構造にする
        record = {
            "id": str(issue.get("id")),
            "content": combined_text,
            "url": f"{redmine_url}/issues/{issue.get('id')}"
        }
        
        # JSONを文字列化してリストに格納
        jsonl_lines.append(json.dumps(record, ensure_ascii=False))
        
    # 改行で結合してJSONLデータを作る
    return "\n".join(jsonl_lines)

def upload_to_gcs(data_string, gcp_project, bucket_name, blob_name):
    """Cloud Storageへデータをアップロードする"""
    print(f"Cloud Storage (gs://{bucket_name}/{blob_name}) へアップロード中...")
    storage_client = storage.Client(project=gcp_project)
    bucket = storage_client.bucket(bucket_name)
    blob = bucket.blob(blob_name)
    
    # メモリ上のテキストデータをそのままGCSへ書き込み
    blob.upload_from_string(data_string, content_type="application/jsonl")
    print("アップロードが完了しました！")

def parse_arguments():
    """コマンドライン引数をパースする"""
    parser = argparse.ArgumentParser(
        description="RedmineのチケットデータをGoogle Cloud Storageに格納します",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
使用例:
  python redmine_to_gcs.py \\
    --redmine-url https://redmine.example.com \\
    --api-key YOUR_API_KEY \\
    --project-id my-project \\
    --gcp-project my-gcp-project \\
    --bucket my-bucket \\
    --blob-path redmine_data/tickets.jsonl \\
    --credentials /path/to/key.json
        """
    )
    
    # Redmine設定
    parser.add_argument(
        "--redmine-url",
        required=True,
        help="RedmineのベースURL（例: https://redmine.example.com）"
    )
    parser.add_argument(
        "--api-key",
        required=True,
        help="RedmineのAPIキー"
    )
    parser.add_argument(
        "--project-id",
        required=True,
        help="対象のRedmineプロジェクトID"
    )
    
    # GCP設定
    parser.add_argument(
        "--gcp-project",
        required=True,
        help="Google CloudプロジェクトID"
    )
    parser.add_argument(
        "--bucket",
        required=True,
        help="格納先のGCSバケット名"
    )
    parser.add_argument(
        "--blob-path",
        default="redmine_data/tickets.jsonl",
        help="GCS上のファイル保存パス（デフォルト: redmine_data/tickets.jsonl）"
    )
    parser.add_argument(
        "--credentials",
        help="サービスアカウントキー（JSON）へのパス（省略時は環境変数GOOGLE_APPLICATION_CREDENTIALSを使用）"
    )
    
    return parser.parse_args()

def main():
    args = parse_arguments()
    
    # サービスアカウントキーが指定されている場合は環境変数にセット
    if args.credentials:
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = args.credentials
    
    try:
        tickets = fetch_redmine_tickets(args.redmine_url, args.api_key, args.project_id)
        if not tickets:
            print("対象のチケットが見つかりませんでした。")
            return
            
        jsonl_data = convert_to_vertex_format(tickets, args.redmine_url)
        upload_to_gcs(jsonl_data, args.gcp_project, args.bucket, args.blob_path)
        
    except Exception as e:
        print(f"エラーが発生しました: {e}")

if __name__ == "__main__":
    main()