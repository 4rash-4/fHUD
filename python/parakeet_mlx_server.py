"""
Real-time Parakeet MLX WebSocket server for fHUD
Streams word-level transcription with precise timestamps to Swift client
"""

import asyncio
import websockets
import json
import time
import numpy as np
import sounddevice as sd
from collections import deque
import threading
from queue import Queue
import traceback

# MLX imports
import mlx.core as mx
from parakeet_mlx import from_pretrained

class ParakeetStreamer:
    def __init__(self, model_name="mlx-community/parakeet-tdt-0.6b-v2"):
        print(f"🎤 Loading Parakeet model: {model_name}")
        self.model = from_pretrained(model_name, dtype=mx.bfloat16)
        print("✅ Parakeet model loaded successfully")
        
        # Audio configuration
        self.sample_rate = 16000
        self.chunk_duration = 2.0  # Process 2-second chunks
        self.overlap_duration = 0.5  # 0.5s overlap between chunks
        
        # Audio buffer management
        self.audio_buffer = deque(maxlen=int(self.sample_rate * 10))  # 10 seconds max
        self.processing_queue = Queue()
        self.is_streaming = False
        
        # Results tracking
        self.processed_words = set()  # Track words we've already sent
        self.last_chunk_end = 0.0
        
    def audio_callback(self, indata, frames, time_info, status):
        """Called by sounddevice for each audio chunk"""
        if status:
            print(f"⚠️  Audio callback status: {status}")
        
        # Convert to float32 and add to buffer
        audio_chunk = indata[:, 0].astype(np.float32)  # Take mono channel
        self.audio_buffer.extend(audio_chunk)
        
        # Trigger processing if we have enough data
        if len(self.audio_buffer) >= int(self.sample_rate * self.chunk_duration):
            self.processing_queue.put(time.time())

    def process_audio_chunk(self):
        """Process accumulated audio through Parakeet"""
        if len(self.audio_buffer) < int(self.sample_rate * self.chunk_duration):
            return []
        
        # Extract audio chunk with overlap
        chunk_samples = int(self.sample_rate * self.chunk_duration)
        audio_array = np.array(list(self.audio_buffer)[-chunk_samples:])
        
        # Convert to MLX array
        audio_mx = mx.array(audio_array)
        
        try:
            # Transcribe with Parakeet
            result = self.model.transcribe_stream(context_size=(256, 256), depth=1)
            with result:
                result.add_audio(audio_mx)
                transcription_result = result.result
            
            # Extract new words with timestamps
            new_words = []
            current_time = time.time()
            
            for sentence in transcription_result.sentences:
                for token in sentence.tokens:
                    # Create unique identifier for this word
                    word_id = f"{token.text}_{token.start:.3f}"
                    
                    if word_id not in self.processed_words:
                        self.processed_words.add(word_id)
                        
                        # Calculate absolute timestamp
                        absolute_time = current_time - self.chunk_duration + token.start
                        
                        new_words.append({
                            'word': token.text.strip(),
                            'timestamp': absolute_time,
                            'confidence': 1.0,  # Parakeet doesn't provide confidence
                            'start': token.start,
                            'duration': token.duration
                        })
            
            return new_words
            
        except Exception as e:
            print(f"❌ Parakeet processing error: {e}")
            traceback.print_exc()
            return []

    async def start_streaming(self, websocket):
        """Start audio streaming and processing"""
        self.is_streaming = True
        
        # Start audio input stream
        stream = sd.InputStream(
            channels=1,
            samplerate=self.sample_rate,
            callback=self.audio_callback,
            blocksize=1024
        )
        
        print("🎙️  Starting audio stream...")
        stream.start()
        
        try:
            while self.is_streaming:
                # Process audio chunks as they become available
                if not self.processing_queue.empty():
                    self.processing_queue.get()
                    
                    words = self.process_audio_chunk()
                    
                    # Send new words to Swift client
                    for word_data in words:
                        try:
                            message = {
                                "w": word_data['word'],
                                "t": word_data['timestamp'] - time.time(),  # Relative time
                                "confidence": word_data.get('confidence', 1.0)
                            }
                            await websocket.send(json.dumps(message))
                            print(f"📤 Sent: {word_data['word']} @ {message['t']:.2f}s")
                            
                        except websockets.exceptions.ConnectionClosed:
                            print("🔌 WebSocket connection closed")
                            break
                
                await asyncio.sleep(0.1)  # Small delay to prevent busy waiting
                
        except Exception as e:
            print(f"❌ Streaming error: {e}")
            traceback.print_exc()
        finally:
            stream.stop()
            stream.close()
            print("🛑 Audio stream stopped")

    def stop_streaming(self):
        """Stop the streaming process"""
        self.is_streaming = False

# Global streamer instance
streamer = None

async def handle_client(websocket, path):
    """Handle WebSocket connections from Swift client"""
    global streamer
    
    print(f"🔗 New client connected: {websocket.remote_address}")
    
    try:
        # Initialize streamer if not already created
        if streamer is None:
            streamer = ParakeetStreamer()
        
        # Start streaming audio to this client
        await streamer.start_streaming(websocket)
        
    except websockets.exceptions.ConnectionClosed:
        print("🔌 Client disconnected")
    except Exception as e:
        print(f"❌ Client handling error: {e}")
        traceback.print_exc()
    finally:
        if streamer:
            streamer.stop_streaming()

async def main():
    """Start the WebSocket server"""
    print("🚀 Starting Parakeet MLX WebSocket server...")
    print("📡 Listening on ws://127.0.0.1:8765")
    print("🎯 Ready for Swift fHUD connections")
    
    async with websockets.serve(handle_client, "127.0.0.1", 8765):
        print("✅ Server running. Press Ctrl+C to stop.")
        await asyncio.Future()  # Run forever

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n👋 Shutting down server...")
    except Exception as e:
        print(f"❌ Server error: {e}")
        traceback.print_exc()