"""Gemma Concept Extraction
---------------------------
This module wraps a small Gemma language model (via MLX) to pull
meaningful concepts from the live transcript.  The results are stored
in a lightweight SQLite knowledge graph so that recurring ideas can be
linked together.  It exposes an async API used by ``main_server.py``.
"""

import json
import time
from typing import List, Dict, Any, Optional
from dataclasses import dataclass, asdict
import re
import sqlite3
from pathlib import Path
import os
import logging

# MLX imports
import mlx.core as mx
import mlx.nn as nn
from mlx_lm import load, generate

logger = logging.getLogger(__name__)

@dataclass
class ConceptNode:
    """Represents an extracted concept or idea"""
    text: str
    category: str  # 'project', 'task', 'person', 'technology', 'emotion'
    confidence: float
    timestamp: float
    context: str  # Surrounding text
    emotional_tone: Optional[str] = None

@dataclass
class ThoughtMoment:
    """Represents a crystallized moment of thought"""
    timestamp: float
    concepts: List[ConceptNode]
    raw_text: str
    drift_indicators: Dict[str, Any]  # From Swift detectors
    connections: List[str] = None  # Links to previous concepts

class GemmaConceptExtractor:
    def __init__(self, model_name="mlx-community/gemma-3-1b-it-qat-4bit"):
        """Initialize Gemma-3 model for concept extraction"""
        print(f"🧠 Loading Gemma model: {model_name}")
        
        try:
            self.model, self.tokenizer = load(model_name)
            print("✅ Gemma model loaded successfully")
        except Exception as e:
            print(f"❌ Failed to load Gemma model: {e}")
            raise
        
        # Initialize knowledge graph database
        self.db_path = Path("python/knowledge_graph.db")
        self.init_database()
        
        # Concept extraction prompt
        self.extraction_prompt = """Extract key concepts from this speech transcript. Focus on:
- Projects or tasks mentioned
- Technologies or tools discussed  
- People or organizations referenced
- Emotional indicators (excited, concerned, frustrated)
- Important decisions or ideas

Return JSON format:
{"concepts": [{"text": "concept name", "category": "project|task|person|technology|emotion", "confidence": 0.0-1.0}]}

Transcript: {text}

JSON:"""

    def init_database(self):
        """Initialize SQLite database for knowledge graph"""
        self.db_path.parent.mkdir(exist_ok=True)
        
        with sqlite3.connect(self.db_path) as conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS concepts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    text TEXT NOT NULL,
                    category TEXT NOT NULL,
                    confidence REAL NOT NULL,
                    timestamp REAL NOT NULL,
                    context TEXT,
                    emotional_tone TEXT,
                    first_mentioned REAL NOT NULL,
                    mention_count INTEGER DEFAULT 1
                )
            """)
            
            conn.execute("""
                CREATE TABLE IF NOT EXISTS connections (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    concept1_id INTEGER NOT NULL,
                    concept2_id INTEGER NOT NULL,
                    strength REAL NOT NULL,
                    created_at REAL NOT NULL,
                    FOREIGN KEY (concept1_id) REFERENCES concepts (id),
                    FOREIGN KEY (concept2_id) REFERENCES concepts (id)
                )
            """)
            
            conn.execute("""
                CREATE TABLE IF NOT EXISTS thought_moments (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    timestamp REAL NOT NULL,
                    raw_text TEXT NOT NULL,
                    drift_indicators TEXT,
                    concept_count INTEGER NOT NULL
                )
            """)
            
            # Create indices for better performance
            conn.execute("CREATE INDEX IF NOT EXISTS idx_concepts_timestamp ON concepts(timestamp)")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_concepts_text ON concepts(text)")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_connections_strength ON connections(strength)")

    async def extract_concepts(self, text: str, timestamp: float = None) -> List[ConceptNode]:
        """Extract concepts from text using Gemma-3"""
        if timestamp is None:
            timestamp = time.time()
        
        # Skip very short texts
        if len(text.strip()) < 10:
            return []
        
        try:
            # Format prompt
            prompt = self.extraction_prompt.format(text=text)
            
            # Generate response with Gemma
            response = generate(
                self.model,
                self.tokenizer,
                prompt,
                max_tokens=200,
                temp=0.3
            )
            
            # Extract JSON from response
            json_match = re.search(r'\{.*\}', response, re.DOTALL)
            if not json_match:
                print(f"⚠️  No JSON found in Gemma response: {response}")
                return []
            
            # Parse concepts
            concepts_data = json.loads(json_match.group())
            concepts = []
            
            for concept_dict in concepts_data.get('concepts', []):
                concept = ConceptNode(
                    text=concept_dict['text'],
                    category=concept_dict['category'], 
                    confidence=concept_dict['confidence'],
                    timestamp=timestamp,
                    context=text,
                    emotional_tone=self._detect_emotional_tone(text)
                )
                concepts.append(concept)
            
            # Store concepts in database
            self._store_concepts(concepts)
            
            return concepts
            
        except Exception as e:
            print(f"❌ Concept extraction error: {e}")
            return []

    def _detect_emotional_tone(self, text: str) -> Optional[str]:
        """Simple emotional tone detection"""
        text_lower = text.lower()
        
        if any(word in text_lower for word in ['excited', 'amazing', 'great', 'love', 'awesome']):
            return 'positive'
        elif any(word in text_lower for word in ['worried', 'concerned', 'problem', 'issue', 'frustrated']):
            return 'negative'
        elif any(word in text_lower for word in ['thinking', 'considering', 'maybe', 'perhaps']):
            return 'contemplative'
        
        return None

    def _store_concepts(self, concepts: List[ConceptNode]):
        """Store concepts in SQLite database"""
        with sqlite3.connect(self.db_path) as conn:
            for concept in concepts:
                # Check if concept already exists
                existing = conn.execute(
                    "SELECT id, mention_count FROM concepts WHERE text = ? AND category = ?",
                    (concept.text, concept.category)
                ).fetchone()
                
                if existing:
                    # Update existing concept
                    concept_id, mention_count = existing
                    conn.execute(
                        "UPDATE concepts SET mention_count = ?, timestamp = ? WHERE id = ?",
                        (mention_count + 1, concept.timestamp, concept_id)
                    )
                else:
                    # Insert new concept
                    cursor = conn.execute(
                        """INSERT INTO concepts 
                           (text, category, confidence, timestamp, context, emotional_tone, first_mentioned)
                           VALUES (?, ?, ?, ?, ?, ?, ?)""",
                        (concept.text, concept.category, concept.confidence, 
                         concept.timestamp, concept.context, concept.emotional_tone, concept.timestamp)
                    )
                    concept_id = cursor.lastrowid
                
                # Build connections with recent concepts
                self._build_connections(concept_id, concept.timestamp)

    def _store_concept_in_db(self, concept: ConceptNode) -> int:
        """Store concept with explicit transaction handling"""
        with sqlite3.connect(self.db_path) as conn:
            try:
                cursor = conn.cursor()
                cursor.execute(
                    """INSERT INTO concepts (text, category, confidence, timestamp, 
                                           context, emotional_tone, mention_count)
                       VALUES (?, ?, ?, ?, ?, ?, 1)""",
                    (concept.text, concept.category, concept.confidence, 
                     concept.timestamp, concept.context, concept.emotional_tone)
                )
                concept_id = cursor.lastrowid
                conn.commit()  # Explicit commit
                return concept_id
            except Exception as e:
                conn.rollback()  # Explicit rollback on error
                logger.error(f"Failed to store concept: {e}")
                raise

    def _build_connections(self, concept_id: int, concept_text: str, timestamp: float):
        """Build connections with explicit transaction handling"""
        with sqlite3.connect(self.db_path) as conn:
            try:
                # Get recent concepts for connection building
                recent_concepts = conn.execute(
                    """SELECT id, text FROM concepts 
                       WHERE timestamp > ? AND id != ?
                       ORDER BY timestamp DESC LIMIT 10""",
                    (timestamp - 300, concept_id)  # 5 minutes window
                ).fetchall()
                
                # Build connections
                for other_id, other_text in recent_concepts:
                    similarity = self._calculate_similarity(concept_text, other_text)
                    if similarity > 0.3:
                        # Check if connection exists
                        existing = conn.execute(
                            """SELECT strength FROM connections 
                               WHERE (concept1_id = ? AND concept2_id = ?) 
                                  OR (concept1_id = ? AND concept2_id = ?)""",
                            (concept_id, other_id, other_id, concept_id)
                        ).fetchone()
                        
                        if existing:
                            # Update existing connection
                            new_strength = min(existing[0] + 0.1, 1.0)
                            conn.execute(
                                """UPDATE connections SET strength = ? 
                                   WHERE (concept1_id = ? AND concept2_id = ?) 
                                      OR (concept1_id = ? AND concept2_id = ?)""",
                                (new_strength, concept_id, other_id, other_id, concept_id)
                            )
                        else:
                            # Create new connection
                            conn.execute(
                                """INSERT INTO connections (concept1_id, concept2_id, strength, created_at)
                                   VALUES (?, ?, ?, ?)""",
                                (concept_id, other_id, similarity, timestamp)
                            )
                
                conn.commit()  # Explicit commit for all connection operations
                
            except Exception as e:
                conn.rollback()  # Explicit rollback on error
                logger.error(f"Failed to build connections: {e}")
                raise

    def get_recent_concepts(self, minutes: int = 60) -> List[Dict]:
        """Get concepts mentioned in the last N minutes"""
        cutoff = time.time() - (minutes * 60)
        
        with sqlite3.connect(self.db_path) as conn:
            concepts = conn.execute(
                """SELECT text, category, confidence, timestamp, mention_count, emotional_tone
                   FROM concepts 
                   WHERE timestamp > ?
                   ORDER BY timestamp DESC""",
                (cutoff,)
            ).fetchall()
            
            return [
                {
                    'text': row[0],
                    'category': row[1], 
                    'confidence': row[2],
                    'timestamp': row[3],
                    'mention_count': row[4],
                    'emotional_tone': row[5]
                }
                for row in concepts
            ]

    def get_concept_connections(self, concept_text: str) -> List[Dict]:
        """Get connections for a specific concept"""
        with sqlite3.connect(self.db_path) as conn:
            connections = conn.execute(
                """SELECT c2.text, c2.category, conn.strength
                   FROM concepts c1
                   JOIN connections conn ON c1.id = conn.concept1_id
                   JOIN concepts c2 ON conn.concept2_id = c2.id
                   WHERE c1.text = ?
                   ORDER BY conn.strength DESC""",
                (concept_text,)
            ).fetchall()
            
            return [
                {
                    'connected_concept': row[0],
                    'category': row[1],
                    'strength': row[2]
                }
                for row in connections
            ]

# Define GemmaExtractor for stub & real modes
if os.getenv("TC_ASR_STUB", "0") == "1":
    class GemmaExtractor:
        def extract_from_text(self, transcript: str) -> List[str]:
            # Stub mode: emit one dummy concept for testing
            return ["stub_concept"]
else:
    class GemmaExtractor:
        def __init__(self):
            # Initialize Gemma-3 model
            try:
                from mlx_lm import load, generate
                self.model, self.tokenizer = load("mlx-community/gemma-3-1b-it-qat-4bit")
                print("✅ Gemma model loaded for concept extraction")
            except Exception as e:
                print(f"❌ Failed to load Gemma model: {e}")
                self.model = None
                self.tokenizer = None

        def extract_from_text(self, transcript: str) -> List[str]:
            """Extract concepts using Gemma-3 model"""
            if not self.model or not self.tokenizer:
                # Fallback to simple keyword extraction
                return self._fallback_extraction(transcript)
            
            try:
                # Create prompt for concept extraction
                prompt = f"""Extract key concepts from this speech transcript. Return only the main concepts as a comma-separated list:
                
                Transcript: "{transcript}"
                
                Concepts:"""
                
                # Generate response
                from mlx_lm import generate
                response = generate(
                    self.model, 
                    self.tokenizer, 
                    prompt=prompt, 
                    max_tokens=100,
                    temp=0.3
                )
                
                # Parse concepts from response
                concepts = [c.strip() for c in response.split(',') if c.strip()]
                return concepts[:5]  # Limit to 5 concepts
                
            except Exception as e:
                print(f"❌ Gemma extraction failed: {e}")
                return self._fallback_extraction(transcript)
        
        def _fallback_extraction(self, transcript: str) -> List[str]:
            """Simple keyword-based fallback extraction"""
            import re
            # Extract potential concepts (nouns, proper nouns)
            words = re.findall(r'\b[A-Z][a-z]+\b|\b(?:project|task|idea|plan|meeting|work)\b', transcript)
            return list(set(words))[:3]  # Return unique concepts, max 3

# Example usage and testing
if __name__ == "__main__":
    async def test_extraction():
        extractor = GemmaConceptExtractor()
        
        test_text = "I'm really excited about the API integration project we discussed. The performance optimization might be challenging, but I think we can handle it."
        
        concepts = await extractor.extract_concepts(test_text)
        
        print("🧠 Extracted concepts:")
        for concept in concepts:
            print(f"  • {concept.text} ({concept.category}) - {concept.confidence:.2f}")
        
        print("\n📊 Recent concepts:")
        recent = extractor.get_recent_concepts(5)
        for concept in recent:
            print(f"  • {concept['text']} - mentioned {concept['mention_count']} times")
    
    import asyncio
    asyncio.run(test_extraction())

def extract_concepts(transcript: str) -> List[str]:
    """
    Wrapper for Gemma-3 concept extraction.
    Input: raw transcript string.
    Output: list of extracted concept strings.
    """
    # Replace the following with your actual extraction call:
    # e.g. concepts = GemmaExtractor().get_concepts(transcript)
    concepts = GemmaExtractor().extract_from_text(transcript)
    return concepts
