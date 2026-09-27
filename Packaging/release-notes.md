Turns a foreign-language movie (.mp4, .mkv, …) into English subtitles (`Movie.srt`, saved next to the movie) using Groq's free Whisper API. For macOS 12 Monterey or later, Intel Macs.

**Install**
1. Download `EnglishSubtitleMaker-macOS.zip` below and unzip it.
2. Drag **English Subtitle Maker.app** into Applications.
3. First launch: right-click the app → **Open** → **Open**. If macOS still refuses, run this in Terminal:
   `xattr -dr com.apple.quarantine "/Applications/English Subtitle Maker.app"`
4. Paste your free Groq API key (from https://console.groq.com/keys) into the box at the top, then drop a movie on the window.

**What's in this version**
- **New look:** a dark "cinema" theme matching the icon, with amber highlights, a slim amber progress bar and buttons that visibly press.
- **Simpler:** the Film language menu and the two-step (transcribe, then translate text) route are gone. Whisper's one-step translation, which gave the better results, is the only route.
- **Long films finish on their own:** when Groq's hourly limit (2 hours of audio per hour) is reached, the app now waits with a countdown and carries on, instead of stopping. A 3-hour film takes roughly 45–75 minutes. Only the daily limit (about 8 hours of audio) stops a job, and it resumes when you drop the file again.

Earlier: audio track picker and click feedback (v1.1.0); parts of 30 seconds or less so subtitles stay in sync, and `Movie.srt` naming (v1.0.0).

See the README for error codes and details.
