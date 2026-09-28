Three tools for movies on your Mac: English subtitles for foreign-language films (`Movie.srt`, saved next to the movie, via Groq's free Whisper API), a frame-exact Cutter/Splitter, and a Joiner. For macOS 12 Monterey or later, Intel Macs.

**Install**
1. Download `EnglishSubtitlesGenerator-CutJoinVideos-macOS.zip` below and unzip it.
2. Drag **English Subtitles Generator, Cut & Join Videos.app** into Applications.
3. First launch: right-click the app → **Open** → **Open**. If macOS still refuses, run this in Terminal:
   `xattr -dr com.apple.quarantine "/Applications/English Subtitles Generator, Cut & Join Videos.app"`
4. Paste your free Groq API key (from https://console.groq.com/keys) into the box at the top, then drop a movie on the window.

**What's in this version**
- **Fewer missing subtitles:** each part is sent to Groq with the previous part's last lines, to keep names consistent. Now and then this made Whisper skip most of a part (a Telugu test: 1 line for 21 s of dialogue). A part that comes back with very few words is now asked again without them, and the fuller reply is kept (10 lines instead of 1 in that test). The log says when this happens.
- **Cut ranges start at zero:** End time and Duration start at 00:00:00. **To end** fills in the video's last point; in Duration mode, tiny presets (5s, 10s, 15s, 20s, 30s, 1m, 2m, 3m, 4m, 5m) set common lengths.

Earlier: time dropdowns, Joiner sort, natural drop order (v1.5.5); cut parts keep the exact frame rate (v1.5.4); quick cut for open-GOP films and trailers (v1.5.3); separate logs per tab and Clear Log (v1.5.2); new name (v1.5.1); Cutter and Joiner tabs, smart cut, cleaner subtitles (v1.5.0); charcoal and green theme (v1.4.0); whisper-large-v3 only (v1.3.1); long films wait out Groq's hourly limit (v1.3.0); audio track picker (v1.1.0); 30-second parts for sync, `Movie.srt` naming (v1.0.0).

See the README for details and error codes.
