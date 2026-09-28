Three tools for movies on your Mac: English subtitles for foreign-language films (`Movie.srt`, saved next to the movie, via Groq's free Whisper API), a frame-exact Cutter/Splitter, and a Joiner. For macOS 12 Monterey or later, Intel Macs.

**Install**
1. Download `EnglishSubtitlesGenerator-CutJoinVideos-macOS.zip` below and unzip it.
2. Drag **English Subtitles Generator, Cut & Join Videos.app** into Applications.
3. First launch: right-click the app → **Open** → **Open**. If macOS still refuses, run this in Terminal:
   `xattr -dr com.apple.quarantine "/Applications/English Subtitles Generator, Cut & Join Videos.app"`
4. Paste your free Groq API key (from https://console.groq.com/keys) into the box at the top, then drop a movie on the window.

**What's in this version**
- **New name:** *English Subtitles Generator, Cut & Join Videos*, since the app now does all three. After installing, delete the old *English Subtitle Maker* app from Applications. Your Groq key and settings carry over.

Earlier: Cutter and Joiner tabs, smart cut, cleaner subtitles (v1.5.0); charcoal and green theme (v1.4.0); whisper-large-v3 only (v1.3.1); long films wait out Groq's hourly limit (v1.3.0); audio track picker (v1.1.0); 30-second parts for sync, `Movie.srt` naming (v1.0.0).

See the README for details and error codes.
