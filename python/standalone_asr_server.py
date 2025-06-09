#!/usr/bin/env python3
"""
Standalone ASR WebSocket server that runs independently
Run this INSTEAD of main_server.py for testing
"""

import asyncio
import websockets
import json
import time
import numpy as np
import sounddevice as sd
from queue import Queue, Empty
import logging
import threading

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Import your existing Parakeet components
from circular_audio_buffer import CircularAudioBuffer
import mlx.core as mx
from parakeet_mlx import from_pretrained

class SimpleASRServer:
    def __init__(self):
        logger.info("🎤 Loading Parakeet model...")
        self.model = from_pretrained("/Users/ari/fHUD/models/parakeet-tdt-0.6b-v2", dtype=mx.bfloat16)
        logger.info("✅ Model loaded!")
        
        self.sample_rate = 16000
        self.chunk_duration = 1.5
        self.chunk_samples = int(self.sample_rate * self.chunk_duration)
        self.audio_buffer = CircularAudioBuffer(self.sample_rate * 10)
        self.processing_queue = Queue(maxsize=3)
        self.clients = set()
        self.is_streaming = False
        self.buffer_lock = threading.Lock()
        
    def audio_callback(self, indata, frames, time_info, status):
        """Audio callback"""
        if status:
            logger.warning(f"Audio status: {status}")
        
        audio_chunk = indata[:, 0].astype(np.float32)
        
        with self.buffer_lock:
            self.audio_buffer.write(audio_chunk)
            
        if self.audio_buffer.length >= self.chunk_samples:
            try:
                self.processing_queue.put_nowait(time.time())
            except:
                pass
    
    async def handle_client(self, websocket, path):
        """Handle WebSocket client"""
        logger.info(f"🔗 Client connected: {websocket.remote_address}")
        self.clients.add(websocket)
        
        try:
            # Send test message
            await websocket.send(json.dumps({
                "w": "Connected",
                "t": 0.0,
                "c": 1.0
            }))
            
            # Start streaming if not already
            if not self.is_streaming:
                asyncio.create_task(self.audio_processing_loop())
                self.start_audio_stream()
            
            # Keep connection alive
            await websocket.wait_closed()
            
        except websockets.exceptions.ConnectionClosed:
            logger.info("Client disconnected")
        finally:
            self.clients.discard(websocket)
            
            # Stop streaming if no clients
            if not self.clients and self.is_streaming:
                self.stop_audio_stream()
    
    def start_audio_stream(self):
        """Start audio input"""
        self.is_streaming = True
        self.stream = sd.InputStream(
            channels=1,
            samplerate=self.sample_rate,
            callback=self.audio_callback,
            blocksize=512,
            latency='low'
        )
        self.stream.start()
        logger.info("🎙️ Audio stream started")
    
    def stop_audio_stream(self):
        """Stop audio input"""
        self.is_streaming = False
        if hasattr(self, 'stream'):
            self.stream.stop()
            self.stream.close()
        logger.info("🛑 Audio stream stopped")
    
    async def audio_processing_loop(self):
        """Process audio and send words"""
        stream_context = None
        
        try:
            while self.is_streaming:
                if not self.processing_queue.empty():
                    self.processing_queue.get()
                    
                    # Get audio chunk
                    with self.buffer_lock:
                        if self.audio_buffer.length < self.chunk_samples:
                            continue
                        audio_array = self.audio_buffer.read(self.chunk_samples)
                    
                    # Convert to MLX
                    audio_mx = mx.array(audio_array, dtype=mx.float32)
                    
                    try:
                        # Create streaming context if needed
                        if stream_context is None:
                            stream_context = self.model.transcribe_stream(
                                context_size=(256, 256),
                                depth=2
                            )
                            stream_context.__enter__()
                        
                        # Process audio
                        stream_context.add_audio(audio_mx)
                        result = stream_context.result
                        
                        # Send words to clients
                        current_time = time.time()
                        for sentence in result.sentences:
                            for token in sentence.tokens:
                                word = token.text.strip()
                                if word:
                                    message = {
                                        "w": word,
                                        "t": current_time - self.chunk_duration + token.start,
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
                                    
                                    if self.clients:
                                        logger.info(f"Sent word: {word}")
                    
                    except Exception as e:
                        logger.error(f"Processing error: {e}")
                        if stream_context:
                            try:
                                stream_context.__exit__(None, None, None)
                            except:
                                pass
                            stream_context = None
                
                await asyncio.sleep(0.05)
                
        finally:
            if stream_context:
                try:
                    stream_context.__exit__(None, None, None)
                except:
                    pass

async def main():
    """Start server"""
    server = SimpleASRServer()
    
    logger.info("🚀 Starting Simple ASR Server...")
    logger.info("📡 Listening on ws://127.0.0.1:8765")
    
    async with websockets.serve(server.handle_client, "127.0.0.1", 8765):
        logger.info("✅ Server running. Press Ctrl+C to stop.")
        await asyncio.Future()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("\n👋 Shutting down...")
    except Exception as e:
        logger.error(f"❌ Server error: {e}")