#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CSV 自動匯入服務 - 偵測 CSV 檔案並自動匯入到對應資料表
"""

import os, time, json, hashlib, logging, pandas as pd
from pathlib import Path
from datetime import datetime
from typing import Dict, Optional, List
from sqlalchemy import create_engine
from urllib.parse import quote_plus

# ============== 配置 ==============
MYSQL_HOST = os.getenv("MYSQL_HOST", "mysql")
MYSQL_PORT = int(os.getenv("MYSQL_PORT", "3306"))
MYSQL_USER = os.getenv("MYSQL_USER", "root")
MYSQL_PASSWORD = os.getenv("MYSQL_PASSWORD", "root")
MYSQL_DATABASE = os.getenv("MYSQL_DATABASE", "fuhsin_erp_demo")

WATCH_DIR = Path(os.getenv("CSV_WATCH_DIR", "/csv/incoming"))
DONE_DIR = WATCH_DIR / ".done"
ERROR_DIR = WATCH_DIR / ".error"
STATE_FILE = Path("/state/.csv_import_state.json")
LOG_FILE = Path("/logs/csv_importer/csv_importer.log")

SCAN_INTERVAL = int(os.getenv("CSV_SCAN_INTERVAL", "10"))
CHUNK_SIZE = int(os.getenv("CSV_CHUNK_SIZE", "5000"))

# 資料表映射（CSV 檔名前綴 -> 資料表名稱）
# 數字越小優先級越高（主表必須先匯入）
TABLE_MAPPING = {
    "technical_documents": {"table": "technical_documents", "priority": 1},
    "structured_documents": {"table": "structured_documents", "priority": 2},
    "ecn_notices": {"table": "ecn_notices", "priority": 3},
    "ecn_applications": {"table": "ecn_applications", "priority": 3},
    "complaint_records": {"table": "complaint_records", "priority": 3},
    "fmea_records": {"table": "fmea_records", "priority": 3},
    "pdf_processing_log": {"table": "pdf_processing_log", "priority": 3},
}

# ============== 日誌設定 ==============
os.makedirs(LOG_FILE.parent, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE, encoding='utf-8'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

# ============== 狀態管理 ==============
class StateManager:
    def __init__(self):
        STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
        self.state = self._load_state()

    def _load_state(self) -> Dict:
        if STATE_FILE.exists():
            try:
                return json.loads(STATE_FILE.read_text())
            except:
                return {}
        return {}

    def _save_state(self):
        STATE_FILE.write_text(json.dumps(self.state, indent=2, ensure_ascii=False))

    def is_processed(self, file_hash: str) -> bool:
        return file_hash in self.state

    def mark_processed(self, file_hash: str, file_name: str, table: str, rows: int):
        self.state[file_hash] = {
            "file_name": file_name,
            "table": table,
            "rows": rows,
            "processed_at": datetime.now().isoformat()
        }
        self._save_state()

# ============== CSV 匯入器 ==============
class CSVImporter:
    def __init__(self):
        self.state_mgr = StateManager()
        for d in [DONE_DIR, ERROR_DIR]:
            d.mkdir(parents=True, exist_ok=True)
        # 建立 SQLAlchemy engine
        password = quote_plus(MYSQL_PASSWORD)
        db_url = f"mysql+pymysql://{MYSQL_USER}:{password}@{MYSQL_HOST}:{MYSQL_PORT}/{MYSQL_DATABASE}?charset=utf8mb4"
        self.engine = create_engine(db_url, pool_pre_ping=True)

    def get_table_info(self, filename: str) -> Optional[Dict]:
        """從檔名判斷對應的資料表和優先級"""
        for prefix, info in TABLE_MAPPING.items():
            if filename.startswith(prefix):
                return info
        return None

    def import_csv(self, csv_path: Path) -> bool:
        """匯入單個 CSV 檔案"""
        file_hash = hashlib.md5(csv_path.read_bytes()).hexdigest()
        
        if self.state_mgr.is_processed(file_hash):
            logger.info(f"⏭️  跳過已處理: {csv_path.name}")
            return True

        table_info = self.get_table_info(csv_path.name)
        if not table_info:
            logger.warning(f"⚠️  無法識別資料表: {csv_path.name}")
            return False

        table_name = table_info["table"]

        try:
            logger.info(f"📥 開始匯入: {csv_path.name} -> {table_name}")
            
            # 讀取 CSV
            df = pd.read_csv(csv_path, encoding='utf-8')
            
            # 刪除 id 欄位（讓資料庫 AUTO_INCREMENT 自動生成）
            if 'id' in df.columns:
                df = df.drop(columns=['id'])
                logger.info(f"🔧 已移除 id 欄位，使用資料庫自動生成")
            
            total_rows = len(df)
            logger.info(f"📊 共 {total_rows} 筆資料")

            # 分批匯入（使用 SQLAlchemy engine）
            imported = 0
            for start in range(0, total_rows, CHUNK_SIZE):
                chunk = df.iloc[start:start + CHUNK_SIZE]
                chunk.to_sql(
                    name=table_name,
                    con=self.engine,
                    if_exists='append',
                    index=False,
                    method='multi'
                )
                imported += len(chunk)
                logger.info(f"  ✓ 已匯入 {imported}/{total_rows} 筆")

            # 標記完成
            self.state_mgr.mark_processed(file_hash, csv_path.name, table_name, total_rows)
            
            # 移動到完成目錄
            done_path = DONE_DIR / f"{csv_path.stem}_{datetime.now().strftime('%Y%m%d%H%M%S')}{csv_path.suffix}"
            csv_path.rename(done_path)
            
            logger.info(f"✅ 完成: {csv_path.name} ({total_rows} 筆)")
            return True

        except Exception as e:
            logger.error(f"❌ 匯入失敗: {csv_path.name} - {e}")
            # 移動到錯誤目錄
            error_path = ERROR_DIR / f"{csv_path.stem}_ERROR_{datetime.now().strftime('%Y%m%d%H%M%S')}{csv_path.suffix}"
            csv_path.rename(error_path)
            return False

    def scan_and_import(self):
        """掃描並按優先級順序匯入所有 CSV 檔案"""
        csv_files = list(WATCH_DIR.glob("*.csv"))
        
        if not csv_files:
            return

        # 依優先級排序（先處理主表）
        def get_priority(file_path):
            info = self.get_table_info(file_path.name)
            return (info["priority"] if info else 999, file_path.name)
        
        csv_files.sort(key=get_priority)
        
        logger.info(f"🔍 發現 {len(csv_files)} 個 CSV 檔案")
        
        for csv_file in csv_files:
            self.import_csv(csv_file)

    def run(self):
        """主循環"""
        logger.info(f"🚀 CSV 自動匯入服務啟動")
        logger.info(f"📂 監控目錄: {WATCH_DIR}")
        logger.info(f"🔄 掃描間隔: {SCAN_INTERVAL} 秒")
        
        while True:
            try:
                self.scan_and_import()
                time.sleep(SCAN_INTERVAL)
            except KeyboardInterrupt:
                logger.info("⏹️  服務停止")
                break
            except Exception as e:
                logger.error(f"❌ 主循環錯誤: {e}")
                time.sleep(SCAN_INTERVAL)

# ============== 主程式 ==============
if __name__ == "__main__":
    importer = CSVImporter()
    importer.run()