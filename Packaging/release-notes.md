Turns a foreign-language movie (.mp4, .mkv, …) into English subtitles (`Movie.srt`, saved next to the movie) using Groq's free Whisper API. For macOS 12 Monterey or later, Intel Macs.

**Install**
1. Download `EnglishSubtitleMaker-macOS.zip` below and unzip it.
2. Drag **English Subtitle Maker.app** into Applications.
3. First launch: right-click the app → **Open** → **Open**. If macOS still refuses, run this in Terminal:
   `xattr -dr com.apple.quarantine "/Applications/English Subtitle Maker.app"`
4. Paste your free Groq API key (from https://console.groq.com/keys) into the box at the top, then drop a movie on the window.

**What's in this version**
- **New colours:** charcoal-black background with green accents. Primary buttons are deep green pills, section labels are mint in small spaced-out capitals, and the progress bar fades from green to mint. The app icon is redrawn to match.

Earlier: whisper-large-v3 always used, since turbo cannot translate (v1.3.1); long films wait out Groq's hourly limit automatically (v1.3.0); audio track picker and click feedback (v1.1.0); parts of 30 seconds or less so subtitles stay in sync, and `Movie.srt` naming (v1.0.0).

See the README for error codes and details.
