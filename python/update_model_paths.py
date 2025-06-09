#!/usr/bin/env python3
"""
Quick script to update model paths in your Python files
Run this from your python directory
"""

import os
import re

# Define the replacements
replacements = [
    # Parakeet model
    (
        r'model_name\s*=\s*"mlx-community/parakeet-tdt-0\.6b-v2"',
        'model_name="/Users/ari/fHUD/models/parakeet-tdt-0.6b-v2"'
    ),
    (
        r'model_name:\s*str\s*=\s*"mlx-community/parakeet-tdt-0\.6b-v2"',
        'model_name: str = "/Users/ari/fHUD/models/parakeet-tdt-0.6b-v2"'
    ),
    # Gemma model
    (
        r'model_name\s*=\s*"mlx-community/gemma-3-1b-it-qat-4bit"',
        'model_name="/Users/ari/fHUD/models/gemma-3-1b-it-qat-4bit"'
    ),
    (
        r'load\("mlx-community/gemma-3-1b-it-qat-4bit"\)',
        'load("/Users/ari/fHUD/models/gemma-3-1b-it-qat-4bit")'
    ),
    # Also fix the old gemma-2-2b references
    (
        r'model_name\s*=\s*"mlx-community/gemma-2-2b-it-4bit"',
        'model_name="/Users/ari/fHUD/models/gemma-3-1b-it-qat-4bit"'
    ),
]

# Files to update
files_to_update = [
    "parakeet_mlx_server.py",
    "gemma_concept_extractor.py",
    "main_server.py",
    "optimized_parakeet_server.py",
    "concept_ws_server.py"
]

print("Updating model paths to use local models...\n")

for filename in files_to_update:
    if not os.path.exists(filename):
        print(f"⚠️  {filename} not found, skipping...")
        continue
    
    print(f"Checking {filename}...")
    
    with open(filename, 'r') as f:
        content = f.read()
    
    original_content = content
    changes_made = []
    
    for pattern, replacement in replacements:
        if re.search(pattern, content):
            content = re.sub(pattern, replacement, content)
            changes_made.append(f"  ✓ Updated: {pattern[:50]}...")
    
    if content != original_content:
        with open(filename, 'w') as f:
            f.write(content)
        print(f"✅ Updated {filename}")
        for change in changes_made:
            print(change)
    else:
        print(f"  No changes needed")
    
    print()

print("\n✨ Done! Model paths updated to use local models.")
print("\nNow run your server with:")
print("  TC_ASR_STUB=0 python main_server.py")