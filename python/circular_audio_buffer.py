import numpy as np

class CircularAudioBuffer:
    """Efficient circular buffer for real-time audio."""

    def __init__(self, size: int):
        self.buffer = np.zeros(size, dtype=np.float32)
        self.read_ptr = 0
        self.write_ptr = 0
        self.size = size
        self.length = 0

    def write(self, data: np.ndarray) -> None:
        n = len(data)
        if n == 0:
            return
        if n > self.size:
            # Only keep the last `size` samples
            data = data[-self.size:]
            n = self.size
        end_ptr = self.write_ptr + n
        if end_ptr <= self.size:
            self.buffer[self.write_ptr:end_ptr] = data
        else:
            split = self.size - self.write_ptr
            self.buffer[self.write_ptr:] = data[:split]
            self.buffer[:n - split] = data[split:]
        self.write_ptr = (self.write_ptr + n) % self.size
        self.length = min(self.length + n, self.size)
        if self.length == self.size and self.read_ptr == self.write_ptr:
            # Overwrite old data; move read pointer
            self.read_ptr = self.write_ptr

    def read(self, n: int) -> np.ndarray:
        if n <= 0 or self.length == 0:
            return np.empty(0, dtype=np.float32)
        n = min(n, self.length)
        end_ptr = self.read_ptr + n
        if end_ptr <= self.size:
            data = self.buffer[self.read_ptr:end_ptr].copy()
        else:
            split = self.size - self.read_ptr
            data = np.concatenate([
                self.buffer[self.read_ptr:],
                self.buffer[:n - split]
            ])
        self.read_ptr = (self.read_ptr + n) % self.size
        self.length -= n
        return data

    def read_with_overlap(self, chunk_size: int, overlap: int) -> np.ndarray:
        """Read ``chunk_size`` samples but retain ``overlap`` samples for the next read."""
        if chunk_size <= 0 or self.length < chunk_size:
            return np.empty(0, dtype=np.float32)

        end_ptr = self.read_ptr + chunk_size
        if end_ptr <= self.size:
            data = self.buffer[self.read_ptr:end_ptr].copy()
        else:
            split = self.size - self.read_ptr
            data = np.concatenate([
                self.buffer[self.read_ptr:],
                self.buffer[:chunk_size - split]
            ])

        # Advance read pointer leaving ``overlap`` samples unread
        advance = chunk_size - overlap
        self.read_ptr = (self.read_ptr + advance) % self.size
        self.length -= advance
        return data
