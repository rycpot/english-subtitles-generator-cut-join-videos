Three tools for movies on your Mac: English subtitles for foreign-language films (`Movie.srt`, saved next to the movie, via Groq's free Whisper API), a frame-exact Cutter/Splitter, and a Joiner. For macOS 12 Monterey or later, Intel Macs.

**Install**
1. Download `EnglishSubtitlesGenerator-CutJoinVideos-macOS.zip` below and unzip it.
2. Drag **English Subtitles Generator, Cut & Join Videos.app** into Applications.
3. First launch: right-click the app → **Open** → **Open**. If macOS still refuses, run this in Terminal:
   `xattr -dr com.apple.quarantine "/Applications/English Subtitles Generator, Cut & Join Videos.app"`
4. Paste your free Groq API key (from https://console.groq.com/keys) into the box at the top, then drop a movie on the window.

**What's in this version**
- **Time dropdowns:** Start and End/Length in the Cutter and in the Joiner's cuts are picked as hours : minutes : seconds · frame. Only times inside the video are offered (hours greyed out for videos under an hour), and the frame dropdown picks an exact frame. Right-click to copy or paste a time.
- **Joiner sort:** sort the pieces by Name (natural), Date modified or Duration, with an ascending/descending button. Files dropped together now arrive in natural name order (part 1, 2, 3, 4), in the Joiner and in the Subtitles queue.
- **Into equal parts** has an up/down counter.

Earlier: cut parts keep the exact frame rate (v1.5.4); quick cut for open-GOP films and trailers (v1.5.3); separate logs per tab and Clear Log (v1.5.2); new name (v1.5.1); Cutter and Joiner tabs, smart cut, cleaner subtitles (v1.5.0); charcoal and green theme (v1.4.0); whisper-large-v3 only (v1.3.1); long films wait out Groq's hourly limit (v1.3.0); audio track picker (v1.1.0); 30-second parts for sync, `Movie.srt` naming (v1.0.0).

See the README for details and error codes.
