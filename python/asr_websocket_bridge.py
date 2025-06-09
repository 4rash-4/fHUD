
"""
Simple WebSocket bridge that connects to the shared memory buffer
and sends ASR results to Swift via WebSocket
"""

import asyncio
import websockets
import json
import time
import struct
from multiprocessing import shared_memory
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class ASRWebSocketBridge:
    def __init__(self):
        self.clients = set()
        
        # Connect to shared memory
        try:
            self.shm = shared_memory.SharedMemory(name="tc_rb")
            self.buf = self.shm.buf
            logger.info("✅ Connected to shared memory buffer")
        except FileNotFoundError:
            logger.error("❌ Shared memory not found. Is main_server.py running?")
            raise
            
        self.last_tail = 0
        
    async def handle_client(self, websocket, path):
        """Handle WebSocket client connections"""
        logger.info(f"🔗 Client connected: {websocket.remote_address}")
        self.clients.add(websocket)
        
        try:
            # Send test message
            await websocket.send(json.dumps({
                "w": "[Connected]",
                "t": 0.0,
                "c": 1.0
            }))
            
            # Keep connection alive
            await websocket.wait_closed()
            
        except websockets.exceptions.ConnectionClosed:
            logger.info("🔌 Client disconnected")
        finally:
            self.clients.discard(websocket)
    
    async def read_shared_memory_loop(self):
        """Read from shared memory and broadcast to clients"""
        logger.info("📖 Starting shared memory reader...")
        
        while True:
            try:
                # Read header from shared memory
                head = struct.unpack_from("I", self.buf, 0)[0]
                tail = struct.unpack_from("I", self.buf, 4)[0]
                
                capacity = len(self.buf) - 8
                
                # Check if there's new data
                if head != self.last_tail:
                    # Calculate available data
                    if head >= self.last_tail:
                        available = head - self.last_tail
                    else:
                        available = capacity - self.last_tail + head
                    
                    if available > 0:
                        # Read data from ring buffer
                        read_pos = self.last_tail % capacity
                        
                        if read_pos + available <= capacity:
                            # Simple read
                            data = bytes(self.buf[8 + read_pos : 8 + read_pos + available])
                        else:
                            # Wrap-around read
                            first_part = capacity - read_pos
                            data = bytes(self.buf[8 + read_pos :]) + bytes(self.buf[8 : 8 + available - first_part])
                        
                        try:
                            # Decode transcript
                            transcript = data.decode('utf-8')
                            
                            # Split into words and send
                            words = transcript.split()
                            current_time = time.time()
                            
                            for i, word in enumerate(words):
                                if word.strip():
                                    message = {
                                        "w": word,
                                        "t": i * 0.1,  # Simulate timing
                                        "c": 0.95
                                    }
                                    
                                    # Broadcast to all clients
                                    disconnected = set()
                                    for client in self.clients:
                                        try:
                                            await client.send(json.dumps(message))
                                        except:
                                            disconnected.add(client)
                                    
                                    self.clients -= disconnected
                                    
                                    # Small delay between words
                                    await asyncio.sleep(0.05)
                            
                            logger.info(f"📤 Sent {len(words)} words to {len(self.clients)} clients")
                            
                        except UnicodeDecodeError:
                            logger.warning("⚠️  Failed to decode data from shared memory")
                        
                        # Update position
                        self.last_tail = head
                
            except Exception as e:
                logger.error(f"❌ Error reading shared memory: {e}")
                
            await asyncio.sleep(0.1)  # Poll every 100ms
    
    async def start(self):
        """Start the WebSocket server"""
        # Start shared memory reader
        asyncio.create_task(self.read_shared_memory_loop())
        
        # Start WebSocket server (simple, no extra params)
        async with websockets.serve(self.handle_client, "127.0.0.1", 8765):
            logger.info("✅ ASR WebSocket bridge running on ws://127.0.0.1:8765")
            await asyncio.Future()  # Run forever

async def main():
    """Main entry point"""
    bridge = ASRWebSocketBridge()
    await bridge.start()

if __name__ == "__main__":
    logger.info("🌉 Starting ASR WebSocket Bridge...")
    logger.info("This bridges shared memory from main_server.py to WebSocket for Swift")
    
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("\n👋 Shutting down bridge...")
    except Exception as e:
        logger.error(f"❌ Bridge error: {e}")