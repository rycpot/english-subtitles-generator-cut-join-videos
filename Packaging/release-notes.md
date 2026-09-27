Turns a foreign-language movie (.mp4, .mkv, …) into English subtitles (`Movie.srt`, saved next to the movie) using Groq's free Whisper API. For macOS 12 Monterey or later, Intel Macs.

**Install**
1. Download `EnglishSubtitleMaker-macOS.zip` below and unzip it.
2. Drag **English Subtitle Maker.app** into Applications.
3. First launch: right-click the app → **Open** → **Open**. If macOS still refuses, run this in Terminal:
   `xattr -dr com.apple.quarantine "/Applications/English Subtitle Maker.app"`
4. Paste your free Groq API key (from https://console.groq.com/keys) into the box at the top, then drop a movie on the window.

**What's in this version**
- Audio is sent to Whisper in parts of 30 seconds or less, cut at quiet moments. This stops subtitles from skipping lines and drifting out of sync after the first 30 seconds.
- Silent stretches are not uploaded.
- Subtitles are saved as `Movie.srt`. An existing `Movie.srt` is kept as `Movie.srt.bak`.
- A 2-hour film takes about 15 minutes, limited by Groq's free tier of 20 requests a minute. The log shows an estimate and each part's English lines.

See the README for error codes and details.
