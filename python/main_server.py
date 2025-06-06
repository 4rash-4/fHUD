import asyncio
import json
import struct
import sqlite3
from datetime import datetime
from multiprocessing import shared_memory
import os
import fcntl
import tempfile
from multiprocessing import Lock

import tornado.ioloop
import tornado.web
import tornado.websocket
from apscheduler.schedulers.tornado import TornadoScheduler

from gemma_concept_extractor import extract_concepts
from parakeet_mlx_server import ParakeetServer  # your existing ASR harness

# --- Logging and Error Handling ---
import logging
from contextlib import contextmanager

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('fhud_server.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

@contextmanager
def safe_database_operation():
    """Context manager for safe database operations"""
    try:
        yield
    except sqlite3.Error as e:
        logger.error(f"Database error: {e}")
        conn.rollback()
        raise
    except Exception as e:
        logger.error(f"Unexpected error in database operation: {e}")
        conn.rollback()
        raise

# --- Shared Memory Setup ---
SHM_NAME = "tc_rb"
SHM_SIZE = 64 * 1024
shm_lock = Lock()  # This lock needs to be shared across processes

try:
    shm = shared_memory.SharedMemory(name=SHM_NAME)
except FileNotFoundError:
    shm = shared_memory.SharedMemory(name=SHM_NAME, create=True, size=SHM_SIZE)

buf = shm.buf
CAPACITY = SHM_SIZE - 8

# Create a named lock that can be shared across processes
lock_file_path = os.path.join(tempfile.gettempdir(), f"{SHM_NAME}.lock")
lock_file = open(lock_file_path, 'w')

def acquire_shared_lock():
    """Acquire file-based lock for cross-process synchronization"""
    fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)

def release_shared_lock():
    """Release file-based lock"""
    fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)

# --- SQLite Persistence ---
DB_PATH = "concepts.db"
conn = sqlite3.connect(DB_PATH, check_same_thread=False)
cursor = conn.cursor()
cursor.execute("""
CREATE TABLE IF NOT EXISTS transcripts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    text TEXT NOT NULL
);
""")
cursor.execute("""
CREATE TABLE IF NOT EXISTS concepts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    transcript_id INTEGER NOT NULL,
    concept TEXT NOT NULL,
    timestamp TEXT NOT NULL,
    FOREIGN KEY(transcript_id) REFERENCES transcripts(id)
);
""")
conn.commit()

import orjson  # Faster JSON library
from functools import lru_cache

# --- WebSocket Handler for Concepts ---
class ConceptWSHandler(tornado.websocket.WebSocketHandler):
    clients = set()
    
    # Cache for frequent concept messages
    @lru_cache(maxsize=100)
    def _serialize_concept(self, transcript_id: int, concept: str, timestamp: str) -> bytes:
        """Cache serialized concept messages"""
        message = {
            "transcript_id": transcript_id,
            "concept": concept,
            "timestamp": timestamp
        }
        return orjson.dumps(message)
    
    def open(self):
        ConceptWSHandler.clients.add(self)
        logger.info(f"WebSocket client connected. Total clients: {len(self.clients)}")

    def on_close(self):
        ConceptWSHandler.clients.discard(self)  # Use discard instead of remove
        logger.info(f"WebSocket client disconnected. Total clients: {len(self.clients)}")

def broadcast_concept(message: dict):
    """Optimized concept broadcasting"""
    if not ConceptWSHandler.clients:
        return  # No clients to broadcast to
    
    try:
        # Use faster JSON serialization
        payload = orjson.dumps(message)
        
        # Remove disconnected clients
        disconnected_clients = set()
        
        for client in ConceptWSHandler.clients.copy():  # Copy to avoid modification during iteration
            try:
                client.write_message(payload)
            except Exception as e:
                logger.warning(f"Failed to send message to client: {e}")
                disconnected_clients.add(client)
        
        # Clean up disconnected clients
        ConceptWSHandler.clients -= disconnected_clients
        
        logger.debug(f"[CONCEPT] Broadcasted to {len(ConceptWSHandler.clients)} clients: {message}")
        
    except Exception as e:
        logger.error(f"Failed to broadcast concept: {e}")
        raise

# --- ASR + Concept Loop ---
async def asr_concept_loop():
    """Enhanced ASR loop with comprehensive error handling"""
    model = None
    retry_count = 0
    max_retries = 3

    while retry_count < max_retries:
        try:
            model = ParakeetServer()
            logger.info("✅ ASR model initialized successfully")
            break
        except Exception as e:
            retry_count += 1
            logger.error(f"❌ Failed to initialize ASR model (attempt {retry_count}/{max_retries}): {e}")
            if retry_count >= max_retries:
                logger.critical("Failed to initialize ASR after max retries, exiting")
                return
            await asyncio.sleep(2 ** retry_count)  # Exponential backoff

    try:
        async for transcript in model.stream_transcripts():
            try:
                await process_transcript(transcript)
            except Exception as e:
                logger.error(f"Error processing transcript '{transcript[:50]}...': {e}")
                # Continue processing other transcripts
                continue
    except Exception as e:
        logger.critical(f"Critical error in ASR loop: {e}")
        raise

async def process_transcript(transcript: str):
    """Process individual transcript with error handling"""
    try:
        # Write to shared memory with error handling
        write_to_shared_memory(transcript)

        # Persist transcript with error handling
        with safe_database_operation():
            ts = datetime.utcnow().isoformat()
            cursor.execute(
                "INSERT INTO transcripts (timestamp, text) VALUES (?, ?)", 
                (ts, transcript)
            )
            conn.commit()
            transcript_id = cursor.lastrowid

        # Extract concepts with error handling
        try:
            concepts = extract_concepts(transcript)
        except Exception as e:
            logger.warning(f"Concept extraction failed for transcript {transcript_id}: {e}")
            concepts = []  # Continue with empty concepts

        # Store concepts
        for concept in concepts:
            try:
                with safe_database_operation():
                    cts = datetime.utcnow().isoformat()
                    cursor.execute(
                        "INSERT INTO concepts (transcript_id, concept, timestamp) VALUES (?, ?, ?)",
                        (transcript_id, concept, cts),
                    )
                    conn.commit()

                    # Broadcast to Swift
                    broadcast_concept({
                        "transcript_id": transcript_id,
                        "concept": concept,
                        "timestamp": cts
                    })
            except Exception as e:
                logger.error(f"Failed to store/broadcast concept '{concept}': {e}")
                continue

    except Exception as e:
        logger.error(f"Failed to process transcript: {e}")
        raise

def write_to_shared_memory(transcript: str):
    """Write transcript to shared memory with optimized zero-copy and wrap-around handling"""
    try:
        data = transcript.encode("utf-8")
        length = len(data)
        if length > CAPACITY:
            data = data[:CAPACITY]  # Use slicing instead of re-encoding
            length = CAPACITY
            logger.warning(f"Transcript truncated from {len(transcript.encode('utf-8'))} to {length} bytes")

        acquire_shared_lock()
        try:
            with memoryview(buf) as m:
                head = struct.unpack_from("I", m, 0)[0]
                tail = struct.unpack_from("I", m, 4)[0]
                # Calculate available space in the ring buffer
                space_left = CAPACITY - ((head - tail) % CAPACITY)
                if length > space_left:
                    # Not enough space, move tail forward to make room
                    tail = (tail + (length - space_left)) % CAPACITY
                    struct.pack_into("I", m, 4, tail)
                write_pos = head
                end_pos = write_pos + length
                if end_pos <= CAPACITY:
                    m[8 + write_pos : 8 + end_pos] = data
                else:
                    first = CAPACITY - write_pos
                    m[8 + write_pos : 8 + write_pos + first] = data[:first]
                    m[8 : 8 + (length - first)] = data[first:]
                new_head = (head + length) % CAPACITY
                struct.pack_into("I", m, 0, new_head)
        finally:
            release_shared_lock()
    except Exception as e:
        logger.error(f"Failed to write to shared memory: {e}")
        raise

# --- Daily Markdown Export ---
def export_to_markdown():
    cursor.execute("SELECT id, timestamp, text FROM transcripts ORDER BY id")
    transcripts = cursor.fetchall()
    cursor.execute("SELECT transcript_id, concept, timestamp FROM concepts ORDER BY id")
    concepts = cursor.fetchall()
    date = datetime.now().strftime("%Y-%m-%d")
    filename = f"journal_{date}.md"
    with open(filename, "w", encoding="utf-8") as f:
        f.write(f"# Thought Crystallizer Journal — {date}\n\n")
        for tid, ts, text in transcripts:
            f.write(f"## [{ts}] Transcript {tid}\n{text}\n\n")
            related = [c for c in concepts if c[0] == tid]
            for _, concept, cts in related:
                f.write(f"- [{cts}] {concept}\n")
            f.write("\n")

# --- Server & Scheduler Startup ---
def make_app():
    return tornado.web.Application([
        (r"/concepts", ConceptWSHandler),
    ])

from dataclasses import dataclass
from typing import Optional

@dataclass
class ServerConfig:
    """Server configuration with environment variable support"""
    # Shared Memory
    shm_name: str = "tc_rb"
    shm_size: int = 64 * 1024

    # Database
    db_path: str = "concepts.db"

    # WebSocket
    ws_port: int = 8765

    # ASR
    asr_model: str = "mlx-community/parakeet-tdt-0.6b-v2"
    asr_stub_mode: bool = False

    # Concept Extraction
    gemma_model: str = "mlx-community/gemma-2-2b-it-4bit"
    concept_extraction_enabled: bool = True

    # Performance
    max_reconnect_attempts: int = 5
    cleanup_interval_minutes: int = 30

    # Logging
    log_level: str = "INFO"
    log_file: Optional[str] = "fhud_server.log"

    @classmethod
    def from_env(cls) -> 'ServerConfig':
        """Load configuration from environment variables"""
        return cls(
            shm_name=os.getenv("FHUD_SHM_NAME", cls.shm_name),
            shm_size=int(os.getenv("FHUD_SHM_SIZE", cls.shm_size)),
            db_path=os.getenv("FHUD_DB_PATH", cls.db_path),
            ws_port=int(os.getenv("FHUD_WS_PORT", cls.ws_port)),
            asr_model=os.getenv("FHUD_ASR_MODEL", cls.asr_model),
            asr_stub_mode=os.getenv("FHUD_ASR_STUB", "0") == "1",
            gemma_model=os.getenv("FHUD_GEMMA_MODEL", cls.gemma_model),
            concept_extraction_enabled=os.getenv("FHUD_CONCEPTS_ENABLED", "1") == "1",
            max_reconnect_attempts=int(os.getenv("FHUD_MAX_RECONNECTS", cls.max_reconnect_attempts)),
            cleanup_interval_minutes=int(os.getenv("FHUD_CLEANUP_INTERVAL", cls.cleanup_interval_minutes)),
            log_level=os.getenv("FHUD_LOG_LEVEL", cls.log_level),
            log_file=os.getenv("FHUD_LOG_FILE", cls.log_file)
        )

# Initialize configuration
config = ServerConfig.from_env()

# Update global variables to use config
SHM_NAME = config.shm_name
SHM_SIZE = config.shm_size
DB_PATH = config.db_path

# Configure logging based on config
logging.basicConfig(
    level=getattr(logging, config.log_level.upper()),
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(config.log_file) if config.log_file else logging.NullHandler(),
        logging.StreamHandler()
    ]
)

if __name__ == "__main__":
    # Start Tornado application
    app = make_app()
    app.listen(8765, address="127.0.0.1")
    # Schedule daily export at 02:00
    scheduler = TornadoScheduler()
    scheduler.add_job(export_to_markdown, "cron", hour=2, minute=0)
    scheduler.start()
    # Launch ASR+concept loop
    tornado.ioloop.IOLoop.current().spawn_callback(asr_concept_loop)
    tornado.ioloop.IOLoop.current().start()