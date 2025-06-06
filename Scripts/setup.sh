#!/bin/bash
# Setup script for development environment
# Creates Python virtualenv and installs dependencies
python3 -m venv venv
source venv/bin/activate
pip install -r python/requirements.txt
