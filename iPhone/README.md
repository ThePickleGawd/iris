# Iris iPhone App

iPhone session controller for Iris.

## What it does

- Home screen is a list of active sessions
- Per-session screen supports:
  - on-device voice transcription + transcript send
  - status glance for that specific session

## Backend endpoints used

- `POST /api/sessions`
- `GET /api/sessions`
- `POST /api/transcripts`
- `GET /api/agent-status?session_id=...`

## Setup

1. Open `iPhone/iris-app.xcodeproj` in Xcode.
2. Choose an iPhone simulator or physical iPhone target.
3. Run backend on your Mac:
   - `cd backend`
   - `uv run python app.py`
4. In app Settings, set backend URL to your Mac LAN address:
   - Example: `http://192.168.1.42:5000`
   - Do not use `localhost` on physical iPhone.

## Notes

- The target is iPhone-only (`TARGETED_DEVICE_FAMILY = 1`).
- Bundle ID is `com.dylan.iris.iphone`.
- The app requests microphone + speech recognition permissions.
