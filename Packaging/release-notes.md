Turns a foreign-language movie (.mp4, .mkv, …) into English subtitles (`Movie.srt`, saved next to the movie) using Groq's free Whisper API. For macOS 12 Monterey or later, Intel Macs.

**Install**
1. Download `EnglishSubtitleMaker-macOS.zip` below and unzip it.
2. Drag **English Subtitle Maker.app** into Applications.
3. First launch: right-click the app → **Open** → **Open**. If macOS still refuses, run this in Terminal:
   `xattr -dr com.apple.quarantine "/Applications/English Subtitle Maker.app"`
4. Paste your free Groq API key (from https://console.groq.com/keys) into the box at the top, then drop a movie on the window.

**What's in this version**
- Fixes error E205 ("does not support translate") for anyone who had picked the turbo model in Settings. Only `whisper-large-v3` can translate to English, so the model choice is removed and the app always uses it.

Earlier: dark theme, and long films wait out Groq's hourly limit automatically (v1.3.0); audio track picker and click feedback (v1.1.0); parts of 30 seconds or less so subtitles stay in sync, and `Movie.srt` naming (v1.0.0).

See the README for error codes and details.
