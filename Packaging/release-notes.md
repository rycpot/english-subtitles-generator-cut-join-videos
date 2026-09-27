Turns a foreign-language movie (.mp4, .mkv, …) into English subtitles (`Movie.srt`, saved next to the movie) using Groq's free Whisper API. For macOS 12 Monterey or later, Intel Macs.

**Install**
1. Download `EnglishSubtitleMaker-macOS.zip` below and unzip it.
2. Drag **English Subtitle Maker.app** into Applications.
3. First launch: right-click the app → **Open** → **Open**. If macOS still refuses, run this in Terminal:
   `xattr -dr com.apple.quarantine "/Applications/English Subtitle Maker.app"`
4. Paste your free Groq API key (from https://console.groq.com/keys) into the box at the top, then drop a movie on the window.

**What's in this version**
- **Film language menu** (under the key box): choose the language spoken in the film instead of letting Whisper guess for each 30-second part. If Groq doesn't accept a language setting for translation, the log says so and the job continues with automatic detection.
- **Audio track picker:** when a file has several audio tracks (e.g. original + English dub), the app asks which one to use, with its best guess preselected.
- **Visible click feedback:** "Copy Log" briefly shows a green "✓ Copied", and the small buttons now look pressed when clicked.

Earlier (v1.0.0): audio is sent to Whisper in parts of 30 seconds or less so subtitles stay in sync; subtitles are saved as `Movie.srt` (an existing one is kept as `Movie.srt.bak`); a 2-hour film takes about 15 minutes on Groq's free tier.

See the README for error codes and details.
