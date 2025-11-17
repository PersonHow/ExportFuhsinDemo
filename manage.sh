#!/bin/bash
# ==========================================
# RAG 系統一鍵部署腳本
# ==========================================

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}"
cat << "EOF"
╔════════════════════════════════════════╗
║   RAG 智能檢索系統 - 一鍵部署          ║
╚════════════════════════════════════════╝
EOF
echo -e "${NC}"

# ==================== 步驟 1: 環境檢查 ====================
echo -e "${GREEN}[1/5] 環境檢查${NC}"

if [ ! -f .env ]; then
    echo -e "${RED}❌ 缺少 .env 檔案${NC}"
    echo "請複製 .env.example 並填入 OPENAI_API_KEY"
    exit 1
fi

echo -e "${GREEN}✅ 環境檢查完成${NC}\n"

# ==================== 步驟 2: 準備目錄 ====================
echo -e "${GREEN}[2/5] 準備目錄${NC}"

mkdir -p sql/{init,incoming}
mkdir -p logs/{importer,db-sync,vector,api}


# 複製 SQL 檔案
[ -f sql/00_init.sql ] && cp sql/00_init.sql sql/init/ 2>/dev/null || true
for f in sql/*_*.sql; do
    [ -f "$f" ] && cp "$f" sql/incoming/ 2>/dev/null || true
done

echo -e "${GREEN}✅ 目錄準備完成${NC}\n"

# ==================== 步驟 3: 啟動基礎服務 ====================
echo -e "${GREEN}[3/5] 啟動 MySQL & Elasticsearch (60秒)${NC}"

docker-compose up -d mysql elasticsearch
sleep 60

echo -e "${GREEN}✅ 基礎服務已啟動${NC}\n"

# ==================== 步驟 4: 匯入資料 ====================
echo -e "${GREEN}[4/5] 匯入資料${NC}"

echo "→ MySQL 自動初始化 (30秒)..."
sleep 30

echo "→ 匯入 SQL 檔案..."
docker-compose up mysql-importer

echo "→ 同步到 Elasticsearch..."
docker-compose up db-sync

echo -e "${GREEN}✅ 資料匯入完成${NC}\n"

# ==================== 步驟 5: 啟動服務 ====================
echo -e "${GREEN}[5/5] 啟動服務${NC}"

# 向量生成 (可選)
if ! grep -q "your-openai-api-key" .env 2>/dev/null; then
    echo "→ 生成向量..."
    docker-compose up vector-service
else
    echo -e "${YELLOW}⚠️  跳過向量生成 (未設定 API Key)${NC}"
fi

# 啟動 API
echo "→ 啟動 RAG API..."
docker-compose up -d rag-api

echo -e "${GREEN}✅ 系統啟動完成！${NC}\n"

# ==================== 顯示訪問資訊 ====================
echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║          🎉 部署成功！                 ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}📍 訪問地址：${NC}"
echo "   http://localhost:8010              (RAG API)"
echo "   http://localhost:8010/docs         (API 文檔)"
echo ""
echo -e "${YELLOW}🧪 快速測試：${NC}"
echo "   curl http://localhost:8010/health"
echo '   curl -X POST http://localhost:8010/query -H "Content-Type: application/json" -d '"'"'{"query":"FMEA","mode":"keyword","top_k":3}'"'"
echo ""
echo -e "${YELLOW}📊 管理指令：${NC}"
echo "   docker-compose logs -f rag-api     (查看日誌)"
echo "   docker-compose ps                  (查看狀態)"
echo "   docker-compose down                (停止系統)"
echo ""