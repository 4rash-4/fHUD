"""Parakeet MLX WebSocket Server
--------------------------------
Streams microphone audio through a Parakeet ASR model using the MLX
runtime.  Results are sent to connected clients over WebSocket and also
returned to the shared memory ring buffer so the Swift app can display
them with minimal latency.
"""

import asyncio
import websockets
import json
import time
import numpy as np
import sounddevice as sd
import threading
from queue import Queue, Empty
import traceback
import logging
from typing import Set, Dict, List, Optional, Tuple
import os

from circular_audio_buffer import CircularAudioBuffer

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# -- Stub for fast smoke tests --
class ParakeetServerStub:
    """Yields canned transcripts without loading any model."""
    async def stream_transcripts(self):
        for text in ["[STUB] Hello world", "[STUB] Testing 1-2-3"]:
            yield text
            await asyncio.sleep(0.5)

# MLX imports
import mlx.core as mx
from parakeet_mlx import from_pretrained

class OptimizedParakeetStreamer:
    def __init__(self, model_name: str = "mlx-community/parakeet-tdt-0.6b-v2"):
        logger.info(f"🎤 Loading Parakeet model: {model_name}")
        
        try:
            self.model = from_pretrained(model_name, dtype=mx.bfloat16)
            logger.info("✅ Parakeet model loaded successfully")
        except Exception as e:
            logger.error(f"❌ Failed to load model: {e}")
            raise
        
        # Audio configuration
        self.sample_rate = 16000
        self.chunk_duration = 1.5  # Shorter chunks for lower latency
        self.overlap_duration = 0.3  # Minimal overlap
        self.chunk_samples = int(self.sample_rate * self.chunk_duration)
        
        # Streaming context
        self.stream_context = None
        self.context_size = (256, 256)
        self.depth = 2
        
        # Audio buffer management with strict limits
        self.max_buffer_size = int(self.sample_rate * 10)
        self.audio_buffer = CircularAudioBuffer(self.max_buffer_size)
        self.processing_queue = Queue(maxsize=3)  # Reduced from 5 to 3 for tighter control
        self.is_streaming = False

        # Add memory monitoring
        self.buffer_overflow_count = 0
        
        # Deduplication with time window
        self.sent_words: Dict[str, float] = {}  # word_id -> timestamp
        self.cleanup_interval = 30.0
        self.last_cleanup = time.time()
        self.dedup_window = 2.0  # 2 second window for deduplication
        
        # Performance monitoring
        self.words_processed = 0
        self.last_perf_check = time.time()
        
        # Thread safety
        self.buffer_lock = threading.Lock()
        
    def audio_callback(self, indata, frames, time_info, status):
        """Optimized audio callback with numpy ring buffer"""
        if status:
            logger.warning(f"⚠️  Audio callback status: {status}")
        audio_chunk = indata[:, 0].astype(np.float32, copy=False)
        with self.buffer_lock:
            prev_len = self.audio_buffer.length
            self.audio_buffer.write(audio_chunk)
            if prev_len == self.audio_buffer.size and self.audio_buffer.length == self.audio_buffer.size:
                self.buffer_overflow_count += 1
                if self.buffer_overflow_count % 100 == 0:
                    logger.warning(f"⚠️  Audio buffer overflow #{self.buffer_overflow_count}")
        # Trigger processing only when we have enough data
        if self.audio_buffer.length >= self.chunk_samples:
            try:
                self.processing_queue.put_nowait(time.time())
            except:
                pass
                
    def process_audio_chunk(self) -> List[Dict]:
        """Process audio chunk with streaming context"""
        with self.buffer_lock:
            if self.audio_buffer.length < self.chunk_samples:
                return []

            overlap_samples = int(self.sample_rate * self.overlap_duration)
            audio_array = self.audio_buffer.read_with_overlap(self.chunk_samples, overlap_samples)
        
        # Convert to MLX
        audio_mx = mx.array(audio_array, dtype=mx.float32)
        
        try:
            # Use streaming context for continuous processing
            if self.stream_context is None:
                self.stream_context = self.model.transcribe_stream(
                    context_size=self.context_size, 
                    depth=self.depth
                )
                self.stream_context.__enter__()
            
            # Add audio to stream
            self.stream_context.add_audio(audio_mx)
            result = self.stream_context.result
            
            # Extract new words with deduplication
            new_words = []
            current_time = time.time()
            
            for sentence in result.sentences:
                for token in sentence.tokens:
                    # Create unique word identifier
                    word_key = f"{token.text.strip().lower()}_{token.start:.3f}"
                    
                    # Check if word was recently sent
                    if word_key in self.sent_words:
                        last_sent = self.sent_words[word_key]
                        if current_time - last_sent < self.dedup_window:
                            continue  # Skip duplicate
                    
                    # Track sent word
                    self.sent_words[word_key] = current_time
                    
                    # Calculate absolute timestamp
                    absolute_time = current_time - self.chunk_duration + token.start
                    
                    new_words.append({
                        'word': token.text.strip(),
                        'timestamp': absolute_time,
                        'confidence': 0.95,  # High confidence for Parakeet
                        'duration': token.duration
                    })
                    
                    self.words_processed += 1
            
            # Periodic cleanup
            if current_time - self.last_cleanup > self.cleanup_interval:
                self.cleanup_old_words(current_time)
                self.last_cleanup = current_time
                
            # Performance monitoring
            if current_time - self.last_perf_check > 5.0:
                wps = self.words_processed / 5.0
                logger.info(f"📊 Performance: {wps:.1f} words/sec")
                self.words_processed = 0
                self.last_perf_check = current_time
                
            return new_words
            
        except Exception as e:
            logger.error(f"❌ Processing error: {e}")
            logger.error(traceback.format_exc())
            # Reset context on error
            if self.stream_context:
                try:
                    self.stream_context.__exit__(None, None, None)
                except:
                    pass
                self.stream_context = None
            return []
    
    def cleanup_old_words(self, current_time: float):
        """Remove old entries to prevent memory growth"""
        cutoff_time = current_time - 300  # 5 minutes
        
        # Remove old entries
        old_keys = [k for k, v in self.sent_words.items() if v < cutoff_time]
        for key in old_keys:
            del self.sent_words[key]
            
        logger.info(f"🧹 Cleaned {len(old_keys)} old word entries")
        
    async def start_streaming(self, websocket):
        """Start optimized streaming"""
        self.is_streaming = True
        
        # Configure audio stream for low latency
        stream = sd.InputStream(
            channels=1,
            samplerate=self.sample_rate,
            callback=self.audio_callback,
            blocksize=512,  # Small blocks for low latency
            latency='low'
        )
        
        logger.info("🎙️  Starting optimized audio stream...")
        stream.start()
        
        try:
            while self.is_streaming:
                # Process available audio chunks
                processed_any = False
                
                while not self.processing_queue.empty():
                    try:
                        self.processing_queue.get_nowait()
                        words = self.process_audio_chunk()
                        
                        # Send words immediately
                        for word_data in words:
                            try:
                                # Compact message format
                                message = {
                                    "w": word_data['word'],
                                    "t": word_data['timestamp'] - time.time(),
                                    "c": word_data['confidence']
                                }
                                
                                await websocket.send(json.dumps(message, separators=(',', ':')))
                                processed_any = True
                                
                            except websockets.exceptions.ConnectionClosed:
                                logger.info("🔌 Connection closed")
                                self.is_streaming = False
                                break
                                
                    except Empty:
                        break
                
                # Small delay if nothing processed
                if not processed_any:
                    await asyncio.sleep(0.05)
                else:
                    await asyncio.sleep(0.01)  # Tiny delay between batches
                    
        except Exception as e:
            logger.error(f"❌ Streaming error: {e}")
            logger.error(traceback.format_exc())
        finally:
            stream.stop()
            stream.close()
            
            # Cleanup streaming context
            if self.stream_context:
                try:
                    self.stream_context.__exit__(None, None, None)
                except:
                    pass
                self.stream_context = None
                
            logger.info("🛑 Stream stopped")

    def stop_streaming(self):
        """Stop streaming and cleanup"""
        self.is_streaming = False

# Global instance management
streamer: Optional[OptimizedParakeetStreamer] = None
streamer_lock = threading.Lock()

async def handle_client(websocket, path):
    """Handle WebSocket connections with proper cleanup"""
    global streamer
    
    client_info = f"{websocket.remote_address[0]}:{websocket.remote_address[1]}"
    logger.info(f"🔗 Client connected: {client_info}")
    
    try:
        # Initialize streamer with thread safety
        with streamer_lock:
            if streamer is None:
                streamer = OptimizedParakeetStreamer()
        
        # Start streaming
        await streamer.start_streaming(websocket)
        
    except websockets.exceptions.ConnectionClosed:
        logger.info(f"🔌 Client disconnected: {client_info}")
    except Exception as e:
        logger.error(f"❌ Client error: {e}")
        logger.error(traceback.format_exc())
    finally:
        if streamer:
            streamer.stop_streaming()

async def main():
    """Start optimized WebSocket server with health monitoring"""
    logger.info("🚀 Starting Optimized Parakeet MLX Server...")
    logger.info("📡 Listening on ws://127.0.0.1:8765")
    logger.info("⚡ Optimizations: Low latency, deduplication, memory management")
    
    # Server configuration
    server_config = {
        "max_size": 2 ** 20,  # 1MB max message size
        "max_queue": 32,      # Max queued messages
        "read_limit": 2 ** 16,  # 64KB read limit
        "write_limit": 2 ** 16,  # 64KB write limit
    }
    
    async with websockets.serve(handle_client, "127.0.0.1", 8765, **server_config):
        logger.info("✅ Server running. Press Ctrl+C to stop.")
        
        # Keep server running
        try:
            await asyncio.Future()
        except asyncio.CancelledError:
            logger.info("🛑 Server shutdown requested")

if __name__ == "__main__":
    try:
        # Run with proper event loop
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("\n👋 Shutting down server gracefully...")
    except Exception as e:
        logger.error(f"❌ Server error: {e}")
        logger.error(traceback.format_exc())
        
# Alias for main_server.py compatibility and stub support
if os.getenv("TC_ASR_STUB", "0") == "1":
    ParakeetServer = ParakeetServerStub
else:
    ParakeetServer = OptimizedParakeetStreamer
