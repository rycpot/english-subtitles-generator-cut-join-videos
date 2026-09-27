Turns a foreign-language movie (.mp4, .mkv, …) into English subtitles (`Movie.srt`, saved next to the movie) using Groq's free Whisper API. For macOS 12 Monterey or later, Intel Macs.

**Install**
1. Download `EnglishSubtitleMaker-macOS.zip` below and unzip it.
2. Drag **English Subtitle Maker.app** into Applications.
3. First launch: right-click the app → **Open** → **Open**. If macOS still refuses, run this in Terminal:
   `xattr -dr com.apple.quarantine "/Applications/English Subtitle Maker.app"`
4. Paste your free Groq API key (from https://console.groq.com/keys) into the box at the top, then drop a movie on the window.

**What's in this version**
- **Film language now makes a real difference.** Choose the film's language (e.g. Telugu) and the app works in two steps:
  1. Whisper writes down the dialogue in that language, without guessing.
  2. A free Groq text model (`openai/gpt-oss-120b` by default) translates the lines to English, keeping each line's timing.

  Whisper's one-step translation often skips whole sentences in languages like Telugu; this route is meant to fill those gaps. It takes roughly 30% longer.
- **Auto** works exactly as before (one step), and **English** now just writes down the dialogue.
- **Translation model** can be changed in Settings (⌘,). If a model is withdrawn from Groq's free tier, the app switches to the next one automatically.
- New error codes E210 and E211 for the translation step (see the README).

Earlier: audio track picker and click feedback (v1.1.0); parts of 30 seconds or less so subtitles stay in sync, and `Movie.srt` naming (v1.0.0).

See the README for error codes and details.
