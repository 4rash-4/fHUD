"""
Bare-bones WebSocket server that mimics an ASR stream.
Later we’ll replace the generator with real Parakeet output.
"""

import asyncio, websockets, json, time, random

async def handler(ws):
    words = "hello this is a fake stream to test the swift hud".split()
    start = time.time()
    for w in words:
        await asyncio.sleep(random.uniform(0.25, 0.6))   # pretend latency
        payload = {"w": w, "t": time.time() - start}
        await ws.send(json.dumps(payload))
    await ws.close()

async def main():
    async with websockets.serve(handler, "127.0.0.1", 8765):
        print("dev-stub server running on ws://127.0.0.1:8765")
        await asyncio.Future()       # run forever

if __name__ == "__main__":
    asyncio.run(main())
