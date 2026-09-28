Turns a foreign-language movie (.mp4, .mkv, …) into English subtitles (`Movie.srt`, saved next to the movie) using Groq's free Whisper API. For macOS 12 Monterey or later, Intel Macs.

**Install**
1. Download `EnglishSubtitleMaker-macOS.zip` below and unzip it.
2. Drag **English Subtitle Maker.app** into Applications.
3. First launch: right-click the app → **Open** → **Open**. If macOS still refuses, run this in Terminal:
   `xattr -dr com.apple.quarantine "/Applications/English Subtitle Maker.app"`
4. Paste your free Groq API key (from https://console.groq.com/keys) into the box at the top, then drop a movie on the window.

**What's in this version**
- **New Cutter tab:** cut a video from a start time to an end time (or for a length), with stills of the first and last frame. Optionally split the cut into equal parts or parts of a fixed length.
- **New Joiner tab:** join whole videos and/or cuts of them (several cuts per file are fine) in any order you like.
- **Quality is kept:** H.264 videos are smart-cut, so everything between keyframes is copied bit for bit and only a few frames at each cut are re-encoded; cuts are exact to the frame. All audio and subtitle tracks, languages, chapters and the title are kept. Videos of different formats are converted to the format that makes up most of the running time (you can pick another).
- **Cleaner subtitles:** parts that come back in the wrong language (e.g. Chinese or Japanese for a Korean film) are asked again, leftover non-English words and self-repeating lines are cleaned up, and more Whisper filler is filtered out.

Earlier: charcoal and green theme (v1.4.0); whisper-large-v3 only (v1.3.1); long films wait out Groq's hourly limit (v1.3.0); audio track picker (v1.1.0); 30-second parts for sync, `Movie.srt` naming (v1.0.0).

See the README for details and error codes.
