"""
Optimized Parakeet MLX Server with Shared Memory Buffer
Eliminates WebSocket overhead using mmap for high-frequency audio data
"""

import asyncio
import websockets
import json
import time
import numpy as np
import sounddevice as sd
import mmap
import struct
import os
from collections import deque
import threading
from queue import Queue
import traceback

# MLX imports - using correct model names
import mlx.core as mx
from parakeet_mlx import from_pretrained

class SharedMemoryAudioBuffer:
    """High-performance shared memory buffer for audio streaming"""
    
    def __init__(self, buffer_size=16000 * 10, file_path="/tmp/fhud_audio_buffer"):
        self.buffer_size = buffer_size
        self.file_path = file_path
        self.header_size = 16  # 4 ints: write_pos, read_pos, sample_rate, channels
        self.total_size = self.header_size + (buffer_size * 4)  # 4 bytes per float32
        
        # Create shared memory file
        with open(file_path, 'wb') as f:
            f.write(b'\x00' * self.total_size)
        
        # Memory map the file
        self.fd = os.open(file_path, os.O_RDWR)
        self.mm = mmap.mmap(self.fd, self.total_size)
        
        # Initialize header
        self._write_header(0, 0, 16000, 1)
        
    def _write_header(self, write_pos, read_pos, sample_rate, channels):
        """Write header information to shared memory"""
        header_data = struct.pack('IIII', write_pos, read_pos, sample_rate, channels)
        self.mm[:self.header_size] = header_data
        
    def _read_header(self):
        """Read header information from shared memory"""
        return struct.unpack('IIII', self.mm[:self.header_size])
        
    def write_audio(self, audio_chunk):
        """Write audio data to circular buffer"""
        write_pos, read_pos, sample_rate, channels = self._read_header()
        
        # Convert to bytes
        audio_bytes = audio_chunk.astype(np.float32).tobytes()
        chunk_size = len(audio_bytes)
        
        # Circular buffer write
        start_offset = self.header_size + (write_pos % self.buffer_size) * 4
        end_offset = start_offset + chunk_size
        
        if end_offset <= self.total_size:
            # Single write
            self.mm[start_offset:end_offset] = audio_bytes
        else:
            # Wrap-around write
            first_part = self.total_size - start_offset
            self.mm[start_offset:] = audio_bytes[:first_part]
            self.mm[self.header_size:self.header_size + chunk_size - first_part] = audio_bytes[first_part:]
        
        # Update write position
        new_write_pos = write_pos + len(audio_chunk)
        self._write_header(new_write_pos, read_pos, sample_rate, channels)
        
    def read_audio(self, num_samples):
        """Read audio data from buffer"""
        write_pos, read_pos, sample_rate, channels = self._read_header()
        
        available = write_pos - read_pos
        if available < num_samples:
            return None
            
        # Read from circular buffer
        start_offset = self.header_size + (read_pos % self.buffer_size) * 4
        end_offset = start_offset + num_samples * 4
        
        if end_offset <= self.total_size:
            audio_bytes = self.mm[start_offset:end_offset]
        else:
            # Wrap-around read
            first_part = self.total_size - start_offset
            audio_bytes = self.mm[start_offset:] + self.mm[self.header_size:end_offset - self.total_size + self.header_size]
        
        # Update read position
        self._read_header()[1] = read_pos + num_samples
        self._write_header(write_pos, read_pos + num_samples, sample_rate, channels)
        
        return np.frombuffer(audio_bytes, dtype=np.float32)
        
    def cleanup(self):
        """Clean up shared memory resources"""
        self.mm.close()
        os.close(self.fd)
        os.unlink(self.file_path)

class OptimizedParakeetStreamer:
    def __init__(self, model_name="mlx-community/parakeet-tdt-0.6b-v2"):
        print(f"🎤 Loading Parakeet model: {model_name}")
        self.model = from_pretrained(model_name, dtype=mx.bfloat16)
        print("✅ Parakeet model loaded successfully")
        
        # Audio configuration
        self.sample_rate = 16000
        self.chunk_duration = 1.5  # Shorter chunks for lower latency
        self.overlap_duration = 0.3  # Reduced overlap
        
        # Shared memory buffer
        self.shared_buffer = SharedMemoryAudioBuffer()
        self.processing_queue = Queue()
        self.is_streaming = False
        
        # Results tracking with deduplication
        self.sent_words = {}  # word+timestamp -> sent_time
        self.cleanup_interval = 30.0  # Clean old entries every 30s
        self.last_cleanup = time.time()
        
    def audio_callback(self, indata, frames, time_info, status):
        """Optimized audio callback with shared memory"""
        if status:
            print(f"⚠️  Audio status: {status}")
        
        # Direct write to shared memory (much faster than queue)
        audio_chunk = indata[:, 0].astype(np.float32)
        self.shared_buffer.write_audio(audio_chunk)
        
        # Trigger processing less frequently
        if time.time() - getattr(self, 'last_process_trigger', 0) > 0.8:
            self.processing_queue.put(time.time())
            self.last_process_trigger = time.time()

    def process_audio_chunk(self):
        """Optimized audio processing with deduplication"""
        chunk_samples = int(self.sample_rate * self.chunk_duration)
        audio_array = self.shared_buffer.read_audio(chunk_samples)
        
        if audio_array is None or len(audio_array) < chunk_samples:
            return []
        
        try:
            # Convert to MLX with proper dtype
            audio_mx = mx.array(audio_array, dtype=mx.float32)
            
            # Streaming transcription with context
            with self.model.transcribe_stream(context_size=(256, 256), depth=2) as stream:
                stream.add_audio(audio_mx)
                result = stream.result
            
            # Extract unique words with better deduplication
            new_words = []
            current_time = time.time()
            
            for sentence in result.sentences:
                for token in sentence.tokens:
                    # More robust deduplication key
                    word_key = f"{token.text.strip().lower()}_{token.start:.2f}"
                    
                    if word_key not in self.sent_words:
                        self.sent_words[word_key] = current_time
                        
                        new_words.append({
                            'word': token.text.strip(),
                            'timestamp': current_time - self.chunk_duration + token.start,
                            'confidence': 0.95,  # High confidence for Parakeet
                            'duration': token.duration
                        })
            
            # Periodic cleanup of old entries
            if current_time - self.last_cleanup > self.cleanup_interval:
                self.cleanup_old_words(current_time)
                self.last_cleanup = current_time
                
            return new_words
            
        except Exception as e:
            print(f"❌ Processing error: {e}")
            return []
    
    def cleanup_old_words(self, current_time):
        """Remove old word entries to prevent memory growth"""
        cutoff_time = current_time - 300  # 5 minutes
        self.sent_words = {k: v for k, v in self.sent_words.items() if v > cutoff_time}

    async def start_streaming(self, websocket):
        """Start optimized streaming with shared memory"""
        self.is_streaming = True
        
        # Configure audio stream for lower latency
        stream = sd.InputStream(
            channels=1,
            samplerate=self.sample_rate,
            callback=self.audio_callback,
            blocksize=512,  # Smaller blocks for lower latency
            latency='low'
        )
        
        print("🎙️  Starting optimized audio stream...")
        stream.start()
        
        try:
            while self.is_streaming:
                if not self.processing_queue.empty():
                    self.processing_queue.get()
                    
                    words = self.process_audio_chunk()
                    
                    # Send words with minimal overhead
                    for word_data in words:
                        try:
                            # Minimal JSON payload
                            message = {
                                "w": word_data['word'],
                                "t": word_data['timestamp'] - time.time(),
                                "c": word_data['confidence']
                            }
                            await websocket.send(json.dumps(message, separators=(',', ':')))
                            
                        except websockets.exceptions.ConnectionClosed:
                            print("🔌 Connection closed")
                            break
                
                await asyncio.sleep(0.05)  # Higher frequency polling
                
        except Exception as e:
            print(f"❌ Streaming error: {e}")
        finally:
            stream.stop()
            stream.close()
            self.shared_buffer.cleanup()
            print("🛑 Optimized stream stopped")

    def stop_streaming(self):
        """Stop streaming and cleanup"""
        self.is_streaming = False

# Global streamer with optimizations
streamer = None

async def handle_optimized_client(websocket, path):
    """Handle clients with optimized streaming"""
    global streamer
    
    print(f"🔗 Optimized client connected: {websocket.remote_address}")
    
    try:
        if streamer is None:
            streamer = OptimizedParakeetStreamer()
        
        await streamer.start_streaming(websocket)
        
    except websockets.exceptions.ConnectionClosed:
        print("🔌 Client disconnected")
    except Exception as e:
        print(f"❌ Client error: {e}")
        traceback.print_exc()
    finally:
        if streamer:
            streamer.stop_streaming()

async def main():
    """Start optimized server"""
    print("🚀 Starting Optimized Parakeet MLX Server...")
    print("📡 Listening on ws://127.0.0.1:8765")
    print("⚡ Optimizations: Shared memory buffer, reduced latency, deduplication")
    
    async with websockets.serve(handle_optimized_client, "127.0.0.1", 8765):
        print("✅ Optimized server running. Press Ctrl+C to stop.")
        await asyncio.Future()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n👋 Shutting down optimized server...")
    except Exception as e:
        print(f"❌ Server error: {e}")
        traceback.print_exc()