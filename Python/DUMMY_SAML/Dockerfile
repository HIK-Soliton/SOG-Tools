# ----- ビルド用ステージ -----
FROM golang:1.22-alpine AS builder

WORKDIR /app

# 依存ライブラリのダウンロード（go.mod / go.sum がある場合）
COPY go.mod go.sum ./
RUN go mod download

# ソースコードとメタデータXMLなどの依存ファイルをコピー
COPY . .

# 静的バイナリのビルド
RUN CGO_ENABLED=0 GOOS=linux go build -o dummy_saml dummy_saml_main.go

# ----- 実行用ステージ -----
FROM alpine:latest

RUN apk --no-cache add ca-certificates

WORKDIR /app

# ビルドしたバイナリと必要なメタデータファイルをコピー
COPY --from=builder /app/dummy_saml .
COPY --from=builder /app/OneGateCloudMetadata.xml .

# コンテナ起動時のエントリーポイント
ENTRYPOINT ["./dummy_saml"]