Three tools for movies on your Mac: English subtitles for foreign-language films (`Movie.srt`, saved next to the movie, via Groq's free Whisper API), a frame-exact Cutter/Splitter, and a Joiner. For macOS 12 Monterey or later, Intel Macs.

**Install**
1. Download `EnglishSubtitlesGenerator-CutJoinVideos-macOS.zip` below and unzip it.
2. Drag **English Subtitles Generator, Cut & Join Videos.app** into Applications.
3. First launch: right-click the app → **Open** → **Open**. If macOS still refuses, run this in Terminal:
   `xattr -dr com.apple.quarantine "/Applications/English Subtitles Generator, Cut & Join Videos.app"`
4. Paste your free Groq API key (from https://console.groq.com/keys) into the box at the top, then drop a movie on the window.

**What's in this version**
- **Simple colour picker** (like the design editor's): every colour swatch in Merge opens a small popover with a saturation/brightness square, a hue bar, an eyedropper for any colour on screen, and a **hex field** (type #FF6A00 and press Return).
- **Exact font sizes:** sizes are whole pixels; type one (e.g. 40) in the size box, or use the arrows, which now step by 1. The slider no longer lands between sizes.

Earlier: working Upload Font… and Choose Files… buttons (v1.7.2); louder, clearer YouTube audio from 5.1 (v1.7.1); text in Merge with fonts and styles (v1.7.0); Merge tab, HEVC quick cut, Audio only, Send to Merge (v1.6.0); fewer missing subtitles, To end button and length presets (v1.5.6); time dropdowns, Joiner sort, natural drop order (v1.5.5); cut parts keep the exact frame rate (v1.5.4); quick cut for open-GOP films and trailers (v1.5.3); separate logs per tab and Clear Log (v1.5.2); new name (v1.5.1); Cutter and Joiner tabs, smart cut, cleaner subtitles (v1.5.0); charcoal and green theme (v1.4.0); whisper-large-v3 only (v1.3.1); long films wait out Groq's hourly limit (v1.3.0); audio track picker (v1.1.0); 30-second parts for sync, `Movie.srt` naming (v1.0.0).

See the README for details and error codes.
