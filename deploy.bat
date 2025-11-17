@echo off
REM ==========================================
REM RAG 系統一鍵部署腳本 (Windows)
REM ==========================================

chcp 65001 >nul
color 0A

echo.
echo ╔════════════════════════════════════════╗
echo ║   RAG 智能檢索系統 - 一鍵部署          ║
echo ╚════════════════════════════════════════╝
echo.

REM ==================== 步驟 1: 環境檢查 ====================
echo [1/5] 環境檢查
echo.

REM 檢查 Docker
docker --version >nul 2>&1
if errorlevel 1 (
    echo ❌ 未安裝 Docker，請先安裝 Docker Desktop
    pause
    exit /b 1
)

REM 檢查 .env 檔案
if not exist .env (
    echo ❌ 缺少 .env 檔案
    echo 請複製 .env.example 並填入 OPENAI_API_KEY
    pause
    exit /b 1
)

echo ✅ 環境檢查完成
echo.

REM ==================== 步驟 2: 準備目錄 ====================
echo [2/5] 準備目錄
echo.

if not exist "sql\init" mkdir sql\init
if not exist "sql\incoming" mkdir sql\incoming
if not exist "logs\importer" mkdir logs\importer
if not exist "logs\db-sync" mkdir logs\db-sync
if not exist "logs\vector" mkdir logs\vector
if not exist "logs\api" mkdir logs\api
if not exist "csv\incoming" mkdir csv\incoming

REM 複製 SQL 檔案
if exist "sql\00_init.sql" (
    if not exist "sql\init\00_init.sql" (
        copy sql\00_init.sql sql\init\ >nul
    )
)

REM 複製資料檔案到 incoming
for %%f in (sql\*_*.sql) do (
    if not exist "sql\incoming\%%~nxf" (
        copy "%%f" sql\incoming\ >nul
    )
)

REM 複製資料檔案到 incoming
for %%f in (csv\*_*.csv) do (
    if not exist "csv\incoming\%%~nxf" (
        copy "%%f" csv\incoming\ >nul
    )
)

echo ✅ 目錄準備完成
echo.

REM ==================== 步驟 3: 啟動基礎服務 ====================
echo [3/5] 啟動 MySQL ^& Elasticsearch (60秒)
echo.

docker-compose up -d mysql elasticsearch

echo 等待服務啟動...
timeout /t 60 /nobreak >nul

echo ✅ 基礎服務已啟動
echo.

REM ==================== 步驟 4: 匯入資料 ====================
echo [4/5] 匯入資料
echo.

echo → MySQL 自動初始化 (30秒)...
timeout /t 30 /nobreak >nul

echo -> 建立服務
docker-compose build --no-cache csv_importer
docker-compose build --no-cache db-sync

echo → 匯入 SQL 檔案...
docker-compose up -d csv_importer

echo → 同步到 Elasticsearch...
docker-compose up -d db-sync

echo ✅ 資料匯入完成
echo.

REM ==================== 步驟 5: 啟動服務 ====================
echo [5/5] 啟動服務
echo.

REM 檢查是否有 OpenAI API Key
findstr /C:"your-openai-api-key" .env >nul
if errorlevel 1 (
    echo → 生成向量...
    docker-compose up vector-service
) else (
    echo ⚠️  跳過向量生成 (未設定 API Key)
)

echo 建立 RAG API...
docker-compose build --no-cache rag-api

echo → 啟動 RAG API...
docker-compose up -d rag-api
docker-compose up -d web-ui-dev

echo ✅ 系統啟動完成！
echo.

REM ==================== 顯示訪問資訊 ====================
echo ╔════════════════════════════════════════╗
echo ║          🎉 部署成功！                 ║
echo ╚════════════════════════════════════════╝
echo.
echo 📍 訪問地址：
echo    http://localhost:8010              (RAG API)
echo    http://localhost:8010/docs         (API 文檔)
echo.
echo 🧪 快速測試：
echo    curl http://localhost:8010/health
echo.
echo 📊 管理指令：
echo    docker-compose logs -f rag-api     (查看日誌)
echo    docker-compose ps                  (查看狀態)
echo    docker-compose down                (停止系統)
echo.
pause