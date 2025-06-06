"""
Concept Processing WebSocket Server (Port 8766)
Handles concept extraction requests from Swift and sends back analysis results
"""

import asyncio
import websockets
import json
import time
from gemma_concept_extractor import GemmaConceptExtractor

class ConceptWebSocketServer:
    def __init__(self):
        self.extractor = GemmaConceptExtractor()
        self.active_connections = set()
        
    async def handle_client(self, websocket, path):
        """Handle WebSocket connections from Swift client"""
        print(f"🧠 Concept client connected: {websocket.remote_address}")
        self.active_connections.add(websocket)
        
        try:
            async for message in websocket:
                await self.process_message(websocket, message)
                
        except websockets.exceptions.ConnectionClosed:
            print("🔌 Concept client disconnected")
        except Exception as e:
            print(f"❌ Concept client error: {e}")
        finally:
            self.active_connections.discard(websocket)
    
    async def process_message(self, websocket, message):
        """Process concept extraction requests from Swift"""
        try:
            data = json.loads(message)
            
            if not data.get('text'):
                return
            
            text = data['text']
            timestamp = data.get('timestamp', time.time())
            drift_indicators = json.loads(data.get('driftIndicators', '{}'))
            
            print(f"🧠 Processing concept extraction for: {text[:50]}...")
            
            # Extract concepts using Gemma
            concepts = await self.extractor.extract_concepts(text, timestamp)
            
            if concepts:
                # Send concepts back to Swift
                concept_data = {
                    "type": "concepts",
                    "data": [
                        {
                            "text": concept.text,
                            "category": concept.category,
                            "confidence": concept.confidence,
                            "emotional_tone": concept.emotional_tone
                        }
                        for concept in concepts
                    ]
                }
                
                await websocket.send(json.dumps(concept_data))
                print(f"📤 Sent {len(concepts)} concepts to Swift")
                
                # Send connections if any concepts were found
                await self.send_recent_connections(websocket)
        
        except Exception as e:
            print(f"❌ Error processing concept message: {e}")
    
    async def send_recent_connections(self, websocket):
        """Send recent concept connections to Swift"""
        try:
            # Get recent concepts to find connections
            recent_concepts = self.extractor.get_recent_concepts(15)  # Last 15 minutes
            
            all_connections = []
            for concept in recent_concepts[:5]:  # Top 5 recent concepts
                connections = self.extractor.get_concept_connections(concept['text'])
                for conn in connections:
                    all_connections.append({
                        "from": concept['text'],
                        "to": conn['connected_concept'],
                        "strength": conn['strength']
                    })
            
            if all_connections:
                connection_data = {
                    "type": "connections", 
                    "data": all_connections
                }
                
                await websocket.send(json.dumps(connection_data))
                print(f"📤 Sent {len(all_connections)} connections to Swift")
                
        except Exception as e:
            print(f"❌ Error sending connections: {e}")
    
    async def broadcast_periodic_updates(self):
        """Send periodic updates to all connected clients"""
        while True:
            await asyncio.sleep(30)  # Every 30 seconds
            
            if not self.active_connections:
                continue
            
            try:
                # Get recent concepts summary
                recent = self.extractor.get_recent_concepts(5)  # Last 5 minutes
                
                if recent:
                    summary_data = {
                        "type": "summary",
                        "data": {
                            "recent_concepts": len(recent),
                            "top_concepts": [
                                {
                                    "text": concept['text'],
                                    "category": concept['category'],
                                    "mentions": concept['mention_count']
                                }
                                for concept in recent[:3]  # Top 3
                            ]
                        }
                    }
                    
                    # Broadcast to all connections
                    disconnected = []
                    for websocket in self.active_connections:
                        try:
                            await websocket.send(json.dumps(summary_data))
                        except websockets.exceptions.ConnectionClosed:
                            disconnected.append(websocket)
                    
                    # Remove disconnected clients
                    for ws in disconnected:
                        self.active_connections.discard(ws)
                        
            except Exception as e:
                print(f"❌ Error in periodic broadcast: {e}")

async def main():
    """Start the concept processing WebSocket server"""
    server = ConceptWebSocketServer()
    
    print("🧠 Starting Concept Processing WebSocket server...")
    print("📡 Listening on ws://127.0.0.1:8766")
    
    # Start periodic updates task
    asyncio.create_task(server.broadcast_periodic_updates())
    
    # Start WebSocket server
    async with websockets.serve(server.handle_client, "127.0.0.1", 8766):
        print("✅ Concept server running. Press Ctrl+C to stop.")
        await asyncio.Future()  # Run forever

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n👋 Shutting down concept server...")
    except Exception as e:
        print(f"❌ Concept server error: {e}")
