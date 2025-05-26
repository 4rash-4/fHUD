import asyncio
import json
import struct
import sqlite3
from datetime import datetime
from multiprocessing import shared_memory, Lock

import tornado.ioloop
import tornado.web
import tornado.websocket
from apscheduler.schedulers.tornado import TornadoScheduler

from gemma_concept_extractor import extract_concepts
from parakeet_mlx_server import ParakeetServer  # your existing ASR harness

# --- Shared Memory Setup ---
SHM_NAME = "tc_rb"
SHM_SIZE = 64 * 1024
shm = shared_memory.SharedMemory(name=SHM_NAME)
buf = shm.buf
shm_lock = Lock()
CAPACITY = SHM_SIZE - 8

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

# --- WebSocket Handler for Concepts ---
class ConceptWSHandler(tornado.websocket.WebSocketHandler):
    clients = set()

    def open(self):
        ConceptWSHandler.clients.add(self)

    def on_close(self):
        ConceptWSHandler.clients.remove(self)

def broadcast_concept(message: dict):
    payload = json.dumps(message)
    for client in ConceptWSHandler.clients:
        client.write_message(payload)

# --- ASR + Concept Loop ---
async def asr_concept_loop():
    model = ParakeetServer()  # initialize your Parakeet-MLX ASR
    async for transcript in model.stream_transcripts():
        # 1. Write transcript to shared memory
        data = transcript.encode("utf-8")
        length = len(data)
        if length > CAPACITY:
            data = data[-CAPACITY:]
            length = CAPACITY

        with shm_lock:
            head, tail = struct.unpack_from("II", buf, 0)
            write_pos = head
            end_pos = write_pos + length
            if end_pos <= CAPACITY:
                buf[8 + write_pos : 8 + end_pos] = data
            else:
                first = CAPACITY - write_pos
                buf[8 + write_pos : 8 + write_pos + first] = data[:first]
                buf[8 : 8 + (length - first)] = data[first:]
            new_head = (head + length) % CAPACITY
            struct.pack_into("I", buf, 0, new_head)

        # 2. Persist transcript
        ts = datetime.utcnow().isoformat()
        cursor.execute(
            "INSERT INTO transcripts (timestamp, text) VALUES (?, ?)", (ts, transcript)
        )
        conn.commit()
        transcript_id = cursor.lastrowid

        # 3. Extract concepts
        concepts = extract_concepts(transcript)
        for concept in concepts:
            cts = datetime.utcnow().isoformat()
            cursor.execute(
                "INSERT INTO concepts (transcript_id, concept, timestamp) VALUES (?, ?, ?)",
                (transcript_id, concept, cts),
            )
            conn.commit()
            # 4. Broadcast to Swift
            broadcast_concept({
                "transcript_id": transcript_id,
                "concept": concept,
                "timestamp": cts
            })

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

if __name__ == "__main__":
    # Start Tornado application
    app = make_app()
    app.listen(8765)
    # Schedule daily export at 02:00
    scheduler = TornadoScheduler()
    scheduler.add_job(export_to_markdown, "cron", hour=2, minute=0)
    scheduler.start()
    # Launch ASR+concept loop
    tornado.ioloop.IOLoop.current().spawn_callback(asr_concept_loop)
    tornado.ioloop.IOLoop.current().start()