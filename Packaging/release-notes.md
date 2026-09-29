Three tools for movies on your Mac: English subtitles for foreign-language films (`Movie.srt`, saved next to the movie, via Groq's free Whisper API), a frame-exact Cutter/Splitter, and a Joiner. For macOS 12 Monterey or later, Intel Macs.

**Install**
1. Download `EnglishSubtitlesGenerator-CutJoinVideos-macOS.zip` below and unzip it.
2. Drag **English Subtitles Generator, Cut & Join Videos.app** into Applications.
3. First launch: right-click the app → **Open** → **Open**. If macOS still refuses, run this in Terminal:
   `xattr -dr com.apple.quarantine "/Applications/English Subtitles Generator, Cut & Join Videos.app"`
4. Paste your free Groq API key (from https://console.groq.com/keys) into the box at the top, then drop a movie on the window.

**What's in this version**
- **New Merge tab:** audio + pictures into a **YouTube-ready 1080p H.264 .mp4** (30 fps, BT.709, 48 kHz AAC). A 1920 × 1080 canvas after the design editor: drag with sticky snapping and guides (⌥ to move freely), corner resize with proportions kept, crop, Fit / Fill, background colour, zoom, and **Undo (⌘Z)**. Slideshows of several pictures (equal shares or set times), part of the audio, fade in/out, loudness evened to YouTube's -14 LUFS.
- **Cutter → Merge:** with Audio only, **Send to Merge** cuts the audio straight into the Merge tab; the video is saved next to the original.
- **HEVC quick cut:** 8/10-bit HEVC (x265 releases) is now copied between keyframes like H.264 and only the edges are re-encoded: a 1.5-hour film cuts in about a minute instead of hours.
- **Audio only** in the Cutter: one audio track for the range and parts, copied unchanged (.m4a, .ac3, .eac3, .mp3, .flac, …), with a track picker.
- **Live progress** with time left during long encodes.

Earlier: fewer missing subtitles, To end button and length presets (v1.5.6); time dropdowns, Joiner sort, natural drop order (v1.5.5); cut parts keep the exact frame rate (v1.5.4); quick cut for open-GOP films and trailers (v1.5.3); separate logs per tab and Clear Log (v1.5.2); new name (v1.5.1); Cutter and Joiner tabs, smart cut, cleaner subtitles (v1.5.0); charcoal and green theme (v1.4.0); whisper-large-v3 only (v1.3.1); long films wait out Groq's hourly limit (v1.3.0); audio track picker (v1.1.0); 30-second parts for sync, `Movie.srt` naming (v1.0.0).

See the README for details and error codes.
